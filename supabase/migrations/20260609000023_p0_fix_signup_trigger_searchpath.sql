-- ============================================================
-- P0 FIX — signup trigger chain failed for real auth signups
-- ============================================================
-- Root cause: handle_new_user / create_wallet_for_profile / init_user_streak are
-- SECURITY DEFINER trigger functions but did NOT pin `search_path`. They run with
-- the search_path of the role that performs the triggering INSERT. The GoTrue
-- role (`supabase_auth_admin`) does not have `public` on its search_path, so the
-- unqualified `profiles` / `wallets` / `user_streaks` failed to resolve:
--   ERROR: relation "profiles" does not exist
--   CONTEXT: PL/pgSQL function public.handle_new_user() line 3
-- which GoTrue surfaces as "Database error creating new user". This blocked ALL
-- real user signups (auth.users INSERT -> on_auth_user_created).
--
-- The SQL integration tests never caught this because they INSERT into auth.users
-- as the `postgres` superuser, whose default search_path already includes public.
--
-- Fix (rule 25): pin `SET search_path = public, pg_temp` in each function header
-- AND schema-qualify the target tables. Behavior is otherwise identical. Existing
-- privileges are preserved by CREATE OR REPLACE (these stay revoked from
-- PUBLIC/anon/authenticated per migration 000010).
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION create_wallet_for_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.wallets (user_id)
  VALUES (NEW.id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION init_user_streak()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.user_streaks (user_id)
  VALUES (NEW.id)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
