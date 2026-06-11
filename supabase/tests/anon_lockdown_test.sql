-- ============================================================
-- Anon lockdown — SQL integration test (DB-level)
-- ============================================================
-- Guards migration 000012 (p1_anon_lockdown_oracle_liquidate). Proves that the
-- anonymous PostgREST role can no longer reach the price-oracle and manual
-- liquidation RPCs, while admins (authenticated) and the price feed
-- (service_role) keep access. Also proves the in-body NULL-uid guard on
-- rpc_liquidate_position is closed (defense in depth beyond the GRANT).
--
-- Runs in one transaction and ROLLS BACK — no residue.
-- ============================================================

BEGIN;

-- ── Test 1: EXECUTE privilege state (GRANT/REVOKE) ───────────────────────────
DO $$
BEGIN
  -- rpc_update_oracle_price: anon REVOKED, authenticated + service_role keep it.
  ASSERT NOT has_function_privilege('anon',
    'public.rpc_update_oracle_price(text,text,text,text)', 'EXECUTE'),
    'anon must NOT execute rpc_update_oracle_price';
  ASSERT has_function_privilege('authenticated',
    'public.rpc_update_oracle_price(text,text,text,text)', 'EXECUTE'),
    'authenticated (admins) must still execute rpc_update_oracle_price';
  ASSERT has_function_privilege('service_role',
    'public.rpc_update_oracle_price(text,text,text,text)', 'EXECUTE'),
    'service_role (price feed) must still execute rpc_update_oracle_price';

  -- rpc_liquidate_position: anon REVOKED, authenticated keeps it.
  ASSERT NOT has_function_privilege('anon',
    'public.rpc_liquidate_position(uuid)', 'EXECUTE'),
    'anon must NOT execute rpc_liquidate_position';
  ASSERT has_function_privilege('authenticated',
    'public.rpc_liquidate_position(uuid)', 'EXECUTE'),
    'authenticated (owner/admin) must still execute rpc_liquidate_position';

  RAISE NOTICE 'ANON PRIVILEGE LOCKDOWN OK — anon revoked; authenticated/service_role intact';
END;
$$;

-- ── Test 1b: advisor cleanup (000013) — anon revoked on client RPCs ──────────
-- Every auth-required / admin-only RPC must reject anon at the API boundary,
-- while authenticated keeps EXECUTE. Sampling representative money/auth RPCs.
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
        'rpc_claim_welcome_bonus','rpc_claim_daily_reward','rpc_spin_roulette',
        'rpc_spot_market_buy','rpc_spot_market_sell','rpc_open_futures_position',
        'rpc_close_futures_position','rpc_stake_phon','rpc_unstake_phon',
        'rpc_claim_staking_reward','rpc_register_referral',
        'rpc_record_consent','rpc_check_onboarding_consent','rpc_resume_market'
      )
  LOOP
    v_sig := r.sig::TEXT;
    ASSERT NOT has_function_privilege('anon', v_sig, 'EXECUTE'),
      format('anon must NOT execute %s after advisor cleanup', v_sig);
    ASSERT has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      format('authenticated must still execute %s', v_sig);
  END LOOP;

  -- rpc_complete_mission is now sealed (000025): authenticated revoked, service_role only.
  ASSERT NOT has_function_privilege('authenticated',
    'public.rpc_complete_mission(text)', 'EXECUTE'),
    'authenticated must NOT execute rpc_complete_mission after 000025 seal';
  ASSERT NOT has_function_privilege('anon',
    'public.rpc_complete_mission(text)', 'EXECUTE'),
    'anon must NOT execute rpc_complete_mission after 000025 seal';

  RAISE NOTICE 'ADVISOR ANON CLEANUP OK — 14 client RPCs revoked from anon; rpc_complete_mission sealed';
END;
$$;

-- ── Test 1c: advisor cleanup (000013) — search_path pinned at function level ─
DO $$
DECLARE
  r RECORD;
  v_bad TEXT := '';
BEGIN
  FOR r IN
    SELECT p.proname, p.oid::regprocedure AS sig, p.proconfig
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
        'rpc_update_oracle_price','rpc_get_candles',
        '_lock_wallet_internal','_unlock_wallet_internal','_debit_wallet_internal',
        '_assert_position_limits','_is_admin'
      )
  LOOP
    IF r.proconfig IS NULL
       OR NOT EXISTS (SELECT 1 FROM unnest(r.proconfig) c WHERE c LIKE 'search_path=%') THEN
      v_bad := v_bad || ' ' || r.sig::TEXT;
    END IF;
  END LOOP;
  ASSERT v_bad = '',
    format('functions missing function-level search_path:%s', v_bad);
  RAISE NOTICE 'ADVISOR SEARCH_PATH OK — flagged functions now pin search_path via proconfig';
END;
$$;

-- ── Test 1c-2: _is_admin is safe inside anon-evaluated RLS policies ──────────
DO $$
DECLARE
  v_anon_public_config INT;
  v_anon_profile_rows INT := 0;
  v_profile_blocked BOOLEAN := FALSE;
BEGIN
  ASSERT EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = '_is_admin'
       AND p.prosecdef = TRUE
  ), '_is_admin must be SECURITY DEFINER so anon RLS policy evaluation never needs profiles SELECT';

  PERFORM set_config('request.jwt.claims', '{}', true);
  SET ROLE anon;
  BEGIN
    SELECT COUNT(*) INTO v_anon_profile_rows
      FROM profiles;
  EXCEPTION WHEN insufficient_privilege THEN
    v_profile_blocked := TRUE;
    v_anon_profile_rows := 0;
  END;
  SELECT COUNT(*) INTO v_anon_public_config
    FROM app_config
   WHERE key = 'feature_withdrawal_enabled';
  RESET ROLE;

  ASSERT v_profile_blocked OR v_anon_profile_rows = 0,
    'anon profiles access must be blocked by table privileges or RLS';
  ASSERT v_anon_profile_rows = 0,
    format('anon must not read profile rows without a matching auth.uid(), got %s', v_anon_profile_rows);
  ASSERT v_anon_public_config = 1,
    format('anon must read public app_config rows without profiles permission errors, got %s', v_anon_public_config);

  RAISE NOTICE 'IS_ADMIN DEFINER OK — anon app_config RLS works while profiles stays closed';
END;
$$;

-- ── Test 1d: dead generic wallet mutators are fully removed ─────────────────
DO $$
BEGIN
  ASSERT to_regprocedure('public.rpc_credit_wallet(currency,text,text,text,uuid,uuid)') IS NULL,
    'rpc_credit_wallet must be dropped after all shipped callers moved to guarded internals';
  ASSERT to_regprocedure('public.rpc_debit_wallet(currency,text,text,text,uuid,uuid)') IS NULL,
    'rpc_debit_wallet must be dropped after withdrawal moved to lock/approve lifecycle';

  RAISE NOTICE 'DEAD WALLET MUTATORS OK — rpc_credit_wallet/rpc_debit_wallet are absent';
END;
$$;

-- ── Test 2: runtime denial — NULL-uid in-body guard (rpc_liquidate_position) ──
-- NOTE: SET LOCAL ROLE anon + SECURITY DEFINER call pattern crashes the
-- PostgreSQL backend in the Supabase local Docker image (pre-existing platform
-- bug, not related to our migrations). The privilege check in Tests 1/1b is the
-- authoritative gate — has_function_privilege proves the REVOKE is effective at
-- the database level, which is what PostgREST enforces at the API boundary.
-- We test the in-body NULL-uid guard here instead (uses set_config, not SET ROLE).

-- ── Test 3: rpc_liquidate_position rejects NULL-uid (service/anon) callers ────
DO $$
DECLARE
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  -- Empty claims -> auth.uid() resolves to NULL (the old service-role bypass path).
  PERFORM set_config('request.jwt.claims', '{}', true);
  BEGIN
    PERFORM rpc_liquidate_position(gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'UNAUTHENTICATED' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('rpc_liquidate_position must reject NULL-uid callers with UNAUTHENTICATED, got: %s', v_msg);
  RAISE NOTICE 'LIQUIDATE NULL-UID GUARD OK — anonymous/service caller blocked at body (UNAUTHENTICATED)';
END;
$$;

ROLLBACK;
