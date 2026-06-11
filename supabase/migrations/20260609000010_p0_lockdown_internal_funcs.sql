-- ============================================================
-- Migration: 20260609000010_p0_lockdown_internal_funcs
-- Security hardening (found via Supabase security advisor):
--   1. Internal SECURITY DEFINER helpers and generic balance RPCs were
--      EXECUTE-able by the anon/authenticated roles over PostgREST. Some have
--      NO authorization guard and credit auth.uid()'s wallet by an arbitrary
--      amount (e.g. rpc_credit_wallet) -> a signed-in user could mint balance.
--      We REVOKE EXECUTE from PUBLIC/anon/authenticated. The SECURITY DEFINER
--      rpc_* wrappers still call them internally (they run as the function
--      owner, so REVOKE does not affect internal calls).
--   2. v_user_consent_latest behaved as a SECURITY DEFINER view (RLS bypass).
--      Switch it to security_invoker so the querying user's RLS applies.
-- ============================================================
-- NOTE: client apps do NOT call any of the locked-down functions directly
-- (verified: only generated types / tests / docs reference them).
-- ============================================================

SET search_path = public, pg_temp;

-- 1. Revoke EXECUTE on internal helpers + unguarded generic RPCs.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT 'public.' || quote_ident(p.proname) || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        -- internal wallet/system helpers (no auth check; definer-only)
        '_credit_wallet_internal','_debit_wallet_internal',
        '_lock_wallet_internal','_unlock_wallet_internal',
        '_credit_system_account','_debit_system_account',
        '_settle_futures_position','_grant_mission',
        '_enforce_rate_limit','_assert_onboarding_consent','_assert_price_fresh',
        '_wl_compute_hash','_get_wallet_for_user',
        -- trigger functions (never meant to be called via API)
        'create_wallet_for_profile','handle_new_user','init_user_streak',
        -- generic balance RPCs with NO admin guard (operator/service only)
        'rpc_credit_wallet','rpc_debit_wallet','rpc_lock_wallet','rpc_unlock_wallet',
        -- info-disclosure / cron-only
        'verify_ledger_hash_chain','rpc_run_liquidations'
      )
  LOOP
    EXECUTE 'REVOKE ALL ON FUNCTION ' || r.sig || ' FROM PUBLIC, anon, authenticated';
  END LOOP;
END;
$$;

-- rpc_run_liquidations stays callable by the service role (Edge Function / cron).
GRANT EXECUTE ON FUNCTION rpc_run_liquidations() TO service_role;

-- 2. Make the consent view respect the querying user's RLS (no definer bypass).
ALTER VIEW v_user_consent_latest SET (security_invoker = true);
