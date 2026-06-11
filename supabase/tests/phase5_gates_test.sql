-- ============================================================
-- Phase 5 — Withdrawal gate RED-first tests (Wave 9.1)
-- ============================================================
-- Proves _assert_kyc_withdrawal_gate, _assert_sanctions_screening,
-- _assert_solvency_withdrawal_gate block before any withdrawal RPC GRANT.
-- Each block runs in BEGIN…ROLLBACK — no residue.
-- ============================================================

-- ── Gate 1 RED: KYC insufficient blocks withdrawal path ─────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_kyc_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'email_verified' WHERE id = v_uid;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  BEGIN
    PERFORM _assert_kyc_withdrawal_gate(v_uid);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'kyc_insufficient' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('KYC gate must block below id_verified, got: %s', v_msg);

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  PERFORM _assert_kyc_withdrawal_gate(v_uid);

  RAISE NOTICE 'KYC GATE OK — blocks email_verified, passes id_verified';
END;
$$;
ROLLBACK;

-- ── Gate 2 RED: Sanctions hit / pending blocks withdrawal ───────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_sanc_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'hit', NOW());

  BEGIN
    PERFORM _assert_sanctions_screening(v_uid);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'sanctions_blocked' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('sanctions gate must block on hit, got: %s', v_msg);

  UPDATE sanctions_screenings SET status = 'clear', screened_at = NOW() WHERE user_id = v_uid;
  PERFORM _assert_sanctions_screening(v_uid);

  RAISE NOTICE 'SANCTIONS GATE OK — blocks hit, passes clear';
END;
$$;
ROLLBACK;

-- ── W9-R2 RED-first: sanctions hit freezes money surfaces ────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_round JSONB;
  v_round_id UUID;
  v_dep JSONB;
  v_ref TEXT;
  v_msg TEXT;
  v_spot_blocked BOOLEAN := FALSE;
  v_futures_blocked BOOLEAN := FALSE;
  v_stake_blocked BOOLEAN := FALSE;
  v_game_blocked BOOLEAN := FALSE;
  v_withdraw_blocked BOOLEAN := FALSE;
  v_deposit_blocked BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_sanc_hit_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified', legal_name = 'Sanctions User' WHERE id = v_uid;
  -- Balanced funding: mint into the wallet against a same-currency system leg so
  -- the global Σ=0 reconciliation invariant holds (real flows are double-entry).
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '10000.000000', 'test_funding', 'sanc-hit-phon-' || v_uid::TEXT);
  PERFORM _debit_system_account('reward_issuance_phon', '10000.000000', 'test_funding', v_uid, 'sanc-hit-phon-' || v_uid::TEXT, NULL);
  PERFORM _credit_wallet_internal(v_uid, 'USDT', '10000.000000', 'test_funding', 'sanc-hit-usdt-' || v_uid::TEXT);
  PERFORM _debit_system_account('house_liquidity_usdt', '10000.000000', 'test_funding', v_uid, 'sanc-hit-usdt-' || v_uid::TEXT, NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN (
      'feature_spot_enabled','feature_futures_enabled','feature_staking_enabled',
      'feature_game_enabled','feature_game_dice_enabled','feature_deposit_enabled',
      'feature_withdrawal_enabled','consent_gate_enabled'
    );
  UPDATE treasury_reserves SET real_balance = '999999999.000000' WHERE currency = 'PHON';
  INSERT INTO oracle_prices (symbol, price, updated_at) VALUES
    ('PHON_USDT', '0.010000', NOW()),
    ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = EXCLUDED.price, updated_at = NOW();
  INSERT INTO exchange_rate_snapshots (base_currency, quote_currency, rate, source, is_active)
  VALUES ('PHON', 'KRW', '10.000000', 'test', TRUE);
  UPDATE market_circuit_breakers
     SET is_halted = FALSE, staleness_seconds = 86400
   WHERE symbol IN ('PHON_USDT', 'PHONUSDT-PERP');
  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_round := rpc_open_game_round('dice');
  v_round_id := (v_round->>'round_id')::UUID;
  v_dep := rpc_create_krw_deposit_request('50000', 'sanc-hit-dep-' || v_uid::TEXT);
  v_ref := v_dep->>'reference_code';

  PERFORM _apply_sanctions_hit(v_uid, '{"source":"test"}'::JSONB);

  BEGIN
    PERFORM rpc_spot_market_buy('1.000000');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'account_activity_frozen' THEN v_spot_blocked := TRUE; END IF;
  END;

  BEGIN
    PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '1.000000', '2');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'account_activity_frozen' THEN v_futures_blocked := TRUE; END IF;
  END;

  BEGIN
    PERFORM rpc_stake_phon('flexible', '1.000000', 'sanc-hit-stake-' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'account_activity_frozen' THEN v_stake_blocked := TRUE; END IF;
  END;

  BEGIN
    PERFORM rpc_place_game_bet(
      v_round_id, 'PHON', '1.000000',
      '{"target":"50.00","direction":"over"}'::JSONB,
      'sanc-hit-seed', 'sanc-hit-game-' || v_uid::TEXT
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'account_activity_frozen' THEN v_game_blocked := TRUE; END IF;
  END;

  BEGIN
    PERFORM rpc_request_withdrawal('PHON', '1.000000', '{}'::JSONB, 'sanc-hit-wd-' || v_uid::TEXT, NULL);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'account_activity_frozen' THEN v_withdraw_blocked := TRUE; END IF;
  END;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_dep := rpc_process_bank_transfer('sanc-hit-transfer-' || v_uid::TEXT, '50000', 'Sanctions User', v_ref);
  v_deposit_blocked := COALESCE((v_dep->>'exception')::BOOLEAN, FALSE)
    AND v_dep->>'reason' = 'sanctions_or_freeze';

  ASSERT v_spot_blocked, 'sanctions hit must block spot trade';
  ASSERT v_futures_blocked, 'sanctions hit must block futures trade';
  ASSERT v_stake_blocked, 'sanctions hit must block staking';
  ASSERT v_game_blocked, 'sanctions hit must block game bet';
  ASSERT v_withdraw_blocked, 'sanctions hit must block withdrawal';
  ASSERT v_deposit_blocked, 'sanctions hit must block deposit credit';
  ASSERT EXISTS (
    SELECT 1 FROM risk_flags
     WHERE user_id = v_uid AND flag_type = 'sanctions_hit' AND status = 'active'
  ), 'sanctions_hit flag missing';
  ASSERT EXISTS (
    SELECT 1 FROM risk_flags
     WHERE user_id = v_uid AND flag_type = 'account_activity_frozen' AND status = 'active'
  ), 'account_activity_frozen flag missing';

  RAISE NOTICE 'SANCTIONS HIT SURFACE BLOCK OK — game/trade/stake/deposit/withdrawal';
END;
$$;
ROLLBACK;

-- ── W9-R2: sanctions pending blocks withdrawal + deposit credit ───────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_dep JSONB;
  v_ref TEXT;
  v_msg TEXT;
  v_withdraw_blocked BOOLEAN := FALSE;
  v_deposit_blocked BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_sanc_pending_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified', legal_name = 'Pending User' WHERE id = v_uid;
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '10000.000000', 'test_funding', 'sanc-pending-phon-' || v_uid::TEXT);
  PERFORM _debit_system_account('reward_issuance_phon', '10000.000000', 'test_funding', v_uid, 'sanc-pending-phon-' || v_uid::TEXT, NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_deposit_enabled','feature_withdrawal_enabled','consent_gate_enabled');
  UPDATE treasury_reserves SET real_balance = '999999999.000000' WHERE currency = 'PHON';
  INSERT INTO exchange_rate_snapshots (base_currency, quote_currency, rate, source, is_active)
  VALUES ('PHON', 'KRW', '10.000000', 'test', TRUE);
  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_dep := rpc_create_krw_deposit_request('50000', 'sanc-pending-dep-' || v_uid::TEXT);
  v_ref := v_dep->>'reference_code';

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'pending', NOW());
  INSERT INTO risk_flags (user_id, flag_type, status, details)
  VALUES (v_uid, 'sanctions_pending', 'active', '{"source":"test"}'::JSONB);

  BEGIN
    PERFORM rpc_request_withdrawal('PHON', '1.000000', '{}'::JSONB, 'sanc-pending-wd-' || v_uid::TEXT, NULL);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'sanctions_pending' THEN v_withdraw_blocked := TRUE; END IF;
  END;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_dep := rpc_process_bank_transfer('sanc-pending-transfer-' || v_uid::TEXT, '50000', 'Pending User', v_ref);
  v_deposit_blocked := COALESCE((v_dep->>'exception')::BOOLEAN, FALSE)
    AND v_dep->>'reason' = 'sanctions_or_freeze';

  ASSERT v_withdraw_blocked, format('sanctions pending must block withdrawal, got: %s', v_msg);
  ASSERT v_deposit_blocked, 'sanctions pending must block deposit credit';

  RAISE NOTICE 'SANCTIONS PENDING OK — browse only, no deposit credit/withdrawal';
END;
$$;
ROLLBACK;

-- ── Gate 3 RED: Solvency gate — stale reconciliation blocks ─────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_solv_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';

  UPDATE treasury_reserves
     SET real_balance = '1000000.000000', buffer_pct = 10
   WHERE currency = 'PHON';

  -- No reconciliation within 24h → must block
  BEGIN
    PERFORM _assert_solvency_withdrawal_gate('PHON');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'withdrawal_solvency_hold' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('solvency gate must block without fresh reconciliation, got: %s', v_msg);

  RAISE NOTICE 'SOLVENCY GATE RED→GREEN — blocks stale reconciliation';
END;
$$;
ROLLBACK;

-- ── Gate 3b: Solvency gate — insufficient attested blocks ───────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_solv2_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';

  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM rpc_run_reconciliation();

  UPDATE treasury_reserves
     SET real_balance = '100.000000', buffer_pct = 10
   WHERE currency = 'PHON';

  BEGIN
    PERFORM _assert_solvency_withdrawal_gate('PHON');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'withdrawal_solvency_hold' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('solvency gate must block when attested below obligations, got: %s', v_msg);

  RAISE NOTICE 'SOLVENCY GATE OK — blocks insufficient attested after fresh recon';
END;
$$;
ROLLBACK;

-- ── Gate 3c: Solvency passes when all conditions met ────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_ok  BOOLEAN := TRUE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'gate_solv3_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';

  UPDATE treasury_reserves
     SET real_balance = '10000000.000000', buffer_pct = 10
   WHERE currency = 'PHON';

  PERFORM rpc_run_reconciliation();

  BEGIN
    PERFORM _assert_solvency_withdrawal_gate('PHON');
  EXCEPTION WHEN OTHERS THEN
    v_ok := FALSE;
  END;

  ASSERT v_ok, 'solvency gate must pass with fresh recon and sufficient attested';

  RAISE NOTICE 'SOLVENCY GATE PASS OK — all conditions met';
END;
$$;
ROLLBACK;
