-- ============================================================
-- Migration: 20260611000055_profiles_wallets_table_grants
-- Pin profiles/wallets table grants for RLS + service_role ops
-- ============================================================
-- profiles/wallets rows are created only by SECURITY DEFINER triggers
-- (handle_new_user / create_wallet_for_profile). Client roles must not
-- INSERT directly; service_role keeps explicit write access for admin
-- automation and local E2E fixture setup (PostgREST bypasses RLS but
-- still requires base table GRANT).
-- ============================================================

SET search_path = public, pg_temp;

REVOKE INSERT, DELETE, TRUNCATE ON public.profiles FROM anon, authenticated;
REVOKE INSERT, DELETE, TRUNCATE ON public.wallets FROM anon, authenticated;

REVOKE ALL ON public.profiles FROM anon;
REVOKE ALL ON public.wallets FROM anon;

GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT ON public.wallets TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wallets TO service_role;
