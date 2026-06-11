-- ============================================================
-- Migration: 20260609000013_p1_advisor_cleanup_anon_searchpath
-- ============================================================
-- Security-advisor cleanup (all WARN-level; no behaviour or data change):
--
--   1. anon_security_definer_function_executable — every client-facing RPC
--      already rejects unauthenticated callers in-body (RAISE 'UNAUTHENTICATED')
--      or is admin-only, but EXECUTE defaults to PUBLIC and `anon` inherits it.
--      Revoking FROM anon alone is NOT enough (PUBLIC still grants it), so we
--      REVOKE FROM PUBLIC + anon and re-GRANT explicitly to `authenticated` and
--      `service_role`. The rejection now happens at the API boundary instead of
--      inside the function; no signed-in user is affected. (rpc_update_oracle_price
--      / rpc_liquidate_position were already locked the same way in 000012.)
--
--   2. function_search_path_mutable — these functions set search_path in their
--      BODY (first statement), which the advisor still flags because DECLARE
--      initializers run under the caller's search_path first. ALTER FUNCTION ...
--      SET search_path attaches it at the function level (proconfig) WITHOUT
--      rewriting the body, which is exactly what the advisor wants.
--
-- Both steps iterate via oid::regprocedure so every overload is covered and no
-- signature is hand-typed. Idempotent: re-running REVOKE/ALTER is a no-op.
-- ============================================================

SET search_path = public, pg_temp;

-- 1. Lock anon out of auth-required / admin-only client RPCs.
--    REVOKE from PUBLIC + anon (PUBLIC is the inherited path), then re-GRANT to
--    authenticated + service_role so legitimate callers keep access.
DO $$
DECLARE
  r RECORD;
  v_sig TEXT;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'rpc_check_onboarding_consent','rpc_claim_daily_reward','rpc_claim_staking_reward',
        'rpc_claim_welcome_bonus','rpc_close_futures_position','rpc_complete_mission',
        'rpc_open_futures_position','rpc_record_consent','rpc_register_referral',
        'rpc_resume_market','rpc_spin_roulette','rpc_spot_market_buy','rpc_spot_market_sell',
        'rpc_stake_phon','rpc_unstake_phon'
      )
  LOOP
    v_sig := r.sig::TEXT;
    EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || v_sig || ' FROM PUBLIC';
    EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || v_sig || ' FROM anon';
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || v_sig || ' TO authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || v_sig || ' TO service_role';
  END LOOP;
END;
$$;

-- 2. Pin search_path at the function level for everything the advisor flagged.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'rpc_close_futures_position','rpc_spot_market_sell','_settle_futures_position',
        'rpc_resume_market','rpc_spot_market_buy','rpc_record_consent',
        'rpc_check_onboarding_consent','_debit_system_account','rpc_open_futures_position',
        'rpc_stake_phon','rpc_claim_staking_reward','rpc_unstake_phon',
        '_credit_system_account','_credit_wallet_internal','_enforce_rate_limit',
        '_wl_compute_hash','verify_ledger_hash_chain','rpc_run_liquidations',
        'rpc_update_oracle_price'
      )
  LOOP
    EXECUTE 'ALTER FUNCTION ' || r.sig::TEXT || ' SET search_path = public, pg_temp';
  END LOOP;
END;
$$;
