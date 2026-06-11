-- ============================================================
-- Phase 5 — Withdrawal RPC gate integration tests
-- ============================================================

-- ── Withdrawal blocked without KYC ────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'wd_kyc_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'email_verified' WHERE id = v_uid;
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  BEGIN
    PERFORM rpc_request_withdrawal(
      'PHON', '10.000000', '{}'::JSONB, 'wd-test-kyc-block-001', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'kyc_insufficient' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked, format('withdrawal RPC must enforce KYC gate, got: %s', v_msg);
  RAISE NOTICE 'WITHDRAWAL RPC KYC BLOCK OK';
END;
$$;
ROLLBACK;

-- ── RED: admin must not approve their own withdrawal ─────────────────────────
BEGIN;
DO $$
DECLARE
  v_admin_user UUID := gen_random_uuid();
  v_res JSONB;
  v_wr_id UUID;
  v_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_admin_user, 'authenticated', 'authenticated',
          'wd_self_admin_' || v_admin_user::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET role = 'admin', kyc_tier = 'id_verified' WHERE id = v_admin_user;
  PERFORM _credit_wallet_internal(v_admin_user, 'PHON', '100.000000',
    'test_funding', 'wd-self-approve-fund-001');
  PERFORM _debit_system_account('reward_issuance_phon', '100.000000',
    'test_funding', v_admin_user, 'wd-self-approve-fund-001', NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_admin_user, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;
  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_admin_user, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user::TEXT)::TEXT, true);
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-self-approve-001', NULL);
  v_wr_id := (v_res->>'withdrawal_id')::UUID;

  BEGIN
    PERFORM rpc_approve_withdrawal(v_wr_id, 'self approval must be blocked');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'self_approval_forbidden' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('admin must not approve own withdrawal, got: %s', COALESCE(v_msg, '<none>'));

  RAISE NOTICE 'WITHDRAWAL SELF APPROVAL BLOCK OK';
END;
$$;
ROLLBACK;

-- ── RED: withdrawal feature-off blocks approve and mark-sent ─────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_res JSONB;
  v_wr_approve UUID;
  v_wr_sent UUID;
  v_approve_blocked BOOLEAN := FALSE;
  v_sent_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_uid, 'authenticated', 'authenticated', 'wd_feature_user_' || v_uid::TEXT || '@test.local', NOW(), NOW()),
    (v_admin, 'authenticated', 'authenticated', 'wd_feature_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '100.000000',
    'test_funding', 'wd-feature-off-fund-001');
  PERFORM _debit_system_account('reward_issuance_phon', '100.000000',
    'test_funding', v_uid, 'wd-feature-off-fund-001', NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;
  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-feature-approve-001', NULL);
  v_wr_approve := (v_res->>'withdrawal_id')::UUID;
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-feature-sent-001', NULL);
  v_wr_sent := (v_res->>'withdrawal_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  PERFORM rpc_approve_withdrawal(v_wr_sent, 'prepare sent feature-off case');

  UPDATE app_config SET value = 'false' WHERE key = 'feature_withdrawal_enabled';

  BEGIN
    PERFORM rpc_approve_withdrawal(v_wr_approve, 'feature off approve must fail');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'feature_disabled' THEN v_approve_blocked := TRUE; END IF;
  END;

  v_msg := NULL;
  BEGIN
    PERFORM rpc_mark_withdrawal_sent(v_wr_sent, 'feature off sent must fail');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'feature_disabled' THEN v_sent_blocked := TRUE; END IF;
  END;

  ASSERT v_approve_blocked,
    format('feature_withdrawal_enabled=false must block approve, got: %s', COALESCE(v_msg, '<none>'));
  ASSERT v_sent_blocked,
    format('feature_withdrawal_enabled=false must block mark sent, got: %s', COALESCE(v_msg, '<none>'));

  RAISE NOTICE 'WITHDRAWAL FEATURE-OFF APPROVE/SENT BLOCK OK';
END;
$$;
ROLLBACK;

-- ── Regression: approve idempotency and feature-off ordering ─────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_res JSONB;
  v_wr_id UUID;
  v_feature_off_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_uid, 'authenticated', 'authenticated', 'wd_idem_user_' || v_uid::TEXT || '@test.local', NOW(), NOW()),
    (v_admin, 'authenticated', 'authenticated', 'wd_idem_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '50.000000',
    'test_funding', 'wd-idem-fund-001');
  PERFORM _debit_system_account('reward_issuance_phon', '50.000000',
    'test_funding', v_uid, 'wd-idem-fund-001', NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;
  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-idem-approve-001', NULL);
  v_wr_id := (v_res->>'withdrawal_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  PERFORM rpc_approve_withdrawal(v_wr_id, 'initial approval');
  v_res := rpc_approve_withdrawal(v_wr_id, 'idempotent approval');
  ASSERT v_res->>'idempotent' = 'true',
    format('approved withdrawal re-approve must remain idempotent when feature is on, got %s', v_res);

  UPDATE app_config SET value = 'false' WHERE key = 'feature_withdrawal_enabled';
  BEGIN
    PERFORM rpc_approve_withdrawal(v_wr_id, 'feature off idempotent ordering check');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'feature_disabled' THEN v_feature_off_blocked := TRUE; END IF;
  END;

  ASSERT v_feature_off_blocked,
    format('feature-off approved re-approve must hit feature guard before idempotent return, got: %s', COALESCE(v_msg, '<none>'));

  RAISE NOTICE 'WITHDRAWAL APPROVE IDEMPOTENCY ORDER OK';
END;
$$;
ROLLBACK;

-- ── P0 lifecycle RED-first: request locks, reject refunds exactly ─────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_res JSONB;
  v_wr_id UUID;
  v_total_before NUMERIC;
  v_total_after NUMERIC;
  v_available_before NUMERIC;
  v_locked_before NUMERIC;
  v_available NUMERIC;
  v_locked NUMERIC;
  v_status withdrawal_status;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_uid, 'authenticated', 'authenticated', 'wd_lifecycle_' || v_uid::TEXT || '@test.local', NOW(), NOW()),
    (v_admin, 'authenticated', 'authenticated', 'wd_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  -- Balanced funding (double-entry) so the global Σ=0 reconciliation holds.
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '100.000000',
    'test_funding', 'wd-lock-reject-fund-001');
  PERFORM _debit_system_account('reward_issuance_phon', '100.000000',
    'test_funding', v_uid, 'wd-lock-reject-fund-001', NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  SELECT phon_available::NUMERIC, phon_locked::NUMERIC
    INTO v_available_before, v_locked_before
  FROM wallets WHERE user_id = v_uid;

  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_total_before;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-lock-reject-001', NULL);
  v_wr_id := (v_res->>'withdrawal_id')::UUID;

  SELECT phon_available, phon_locked INTO v_available, v_locked
  FROM wallets WHERE user_id = v_uid;

  ASSERT v_available = v_available_before - 10,
    format('request must move PHON from available, got available=%s', v_available);
  ASSERT v_locked = v_locked_before + 10,
    format('request must lock PHON instead of immediate debit, got locked=%s', v_locked);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  PERFORM rpc_reject_withdrawal(v_wr_id, 'RED-first reject refund check');

  SELECT phon_available, phon_locked INTO v_available, v_locked
  FROM wallets WHERE user_id = v_uid;
  SELECT status INTO v_status FROM withdrawal_requests WHERE id = v_wr_id;
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_total_after;

  ASSERT v_available = v_available_before,
    format('reject must restore available balance exactly, got %s', v_available);
  ASSERT v_locked = v_locked_before,
    format('reject must clear locked balance, got %s', v_locked);
  ASSERT v_status = 'rejected', format('reject must set status=rejected, got %s', v_status);
  ASSERT v_total_after = v_total_before,
    format('reject path must conserve PHON: before=%s after=%s', v_total_before, v_total_after);
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
     WHERE actor_id = v_admin
       AND action = 'withdrawal_rejected'
       AND entity_type = 'withdrawal_request'
       AND entity_id = v_wr_id
       AND payload->>'reason' = 'RED-first reject refund check'
  ), 'reject must append audit log with reason';

  RAISE NOTICE 'WITHDRAWAL LOCK + REJECT REFUND OK';
END;
$$;
ROLLBACK;

-- ── P0 lifecycle: approve consumes locked funds and books system leg ──────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_admin UUID := gen_random_uuid();
  v_res JSONB;
  v_wr_id UUID;
  v_total_before NUMERIC;
  v_total_after NUMERIC;
  v_available_before NUMERIC;
  v_locked_before NUMERIC;
  v_available NUMERIC;
  v_locked NUMERIC;
  v_status withdrawal_status;
  v_payout_before NUMERIC;
  v_payout_balance NUMERIC;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_uid, 'authenticated', 'authenticated', 'wd_approve_' || v_uid::TEXT || '@test.local', NOW(), NOW()),
    (v_admin, 'authenticated', 'authenticated', 'wd_admin2_' || v_admin::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  -- Balanced funding (double-entry) so the global Σ=0 reconciliation holds.
  PERFORM _credit_wallet_internal(v_uid, 'PHON', '100.000000',
    'test_funding', 'wd-lock-approve-fund-001');
  PERFORM _debit_system_account('reward_issuance_phon', '100.000000',
    'test_funding', v_uid, 'wd-lock-approve-fund-001', NULL);

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_withdrawal_enabled';
  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  SELECT phon_available::NUMERIC, phon_locked::NUMERIC
    INTO v_available_before, v_locked_before
  FROM wallets WHERE user_id = v_uid;
  SELECT COALESCE(balance::NUMERIC, 0) INTO v_payout_before
  FROM system_accounts WHERE code = 'withdrawal_payout_phon';

  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_total_before;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_res := rpc_request_withdrawal('PHON', '10.000000', '{}'::JSONB, 'wd-lock-approve-001', NULL);
  v_wr_id := (v_res->>'withdrawal_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  PERFORM rpc_approve_withdrawal(v_wr_id, 'RED-first approve payout check');

  SELECT phon_available, phon_locked INTO v_available, v_locked
  FROM wallets WHERE user_id = v_uid;
  SELECT status INTO v_status FROM withdrawal_requests WHERE id = v_wr_id;
  SELECT balance::NUMERIC INTO v_payout_balance
  FROM system_accounts WHERE code = 'withdrawal_payout_phon';
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_total_after;

  ASSERT v_available = v_available_before - 10,
    format('approve must leave user available debited, got %s', v_available);
  ASSERT v_locked = v_locked_before,
    format('approve must consume locked balance, got %s', v_locked);
  ASSERT v_status = 'approved', format('approve must set status=approved, got %s', v_status);
  ASSERT v_payout_balance = v_payout_before + 10,
    format('approve must credit withdrawal payout system account, before=%s after=%s',
      v_payout_before, v_payout_balance);
  ASSERT v_total_after = v_total_before,
    format('approve path must conserve PHON: before=%s after=%s', v_total_before, v_total_after);
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
     WHERE actor_id = v_admin
       AND action = 'withdrawal_approved'
       AND entity_type = 'withdrawal_request'
       AND entity_id = v_wr_id
       AND payload->>'reason' = 'RED-first approve payout check'
  ), 'approve must append audit log with reason';

  PERFORM rpc_mark_withdrawal_sent(v_wr_id, 'external transfer confirmed');
  SELECT status INTO v_status FROM withdrawal_requests WHERE id = v_wr_id;
  ASSERT v_status::TEXT = 'sent', format('mark sent must set status=sent, got %s', v_status);

  RAISE NOTICE 'WITHDRAWAL LOCK + APPROVE PAYOUT OK';
END;
$$;
ROLLBACK;

-- ── GRANT order proof: authenticated has execute; internal gate revoked ───────
BEGIN;
DO $$
BEGIN
  ASSERT has_function_privilege(
    'authenticated', 'public.rpc_request_withdrawal(text,text,jsonb,text,text)', 'EXECUTE'),
    'rpc_request_withdrawal must be granted to authenticated after gates green';

  ASSERT NOT has_function_privilege(
    'authenticated', 'public._assert_solvency_withdrawal_gate(currency)', 'EXECUTE'),
    'internal solvency gate must not be callable by authenticated';

  RAISE NOTICE 'WITHDRAWAL GRANT ORDER OK — user RPC granted, internal gate revoked';
END;
$$;
ROLLBACK;

-- ── Kill switch: feature_withdrawal_enabled=false blocks until approve flow ───
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'wd_kill_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET kyc_tier = 'id_verified' WHERE id = v_uid;
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
    FROM unnest(ARRAY[
      'terms_of_service','privacy_policy','risk_disclosure','age_verification'
    ]::TEXT[]) AS doc_type;
  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'false' WHERE key = 'feature_withdrawal_enabled';

  UPDATE treasury_reserves SET real_balance = '99999999.000000' WHERE currency = 'PHON';
  PERFORM rpc_run_reconciliation();

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  BEGIN
    PERFORM rpc_request_withdrawal(
      'PHON', '1.000000', '{}'::JSONB, 'wd-kill-switch-test-01', NULL
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'feature_disabled' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('withdrawal must be blocked when feature_withdrawal_enabled=false, got: %s', v_msg);

  RAISE NOTICE 'WITHDRAWAL KILL SWITCH OK — feature_disabled until approve/reject flow';
END;
$$;
ROLLBACK;
