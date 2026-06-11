-- ============================================================
-- Group E E1-a — insurance capital contribution RPC
-- ============================================================
-- RED before 000050:
--   rpc_contribute_insurance_capital(...) and
--   operator_contributed_capital_{phon,usdt} do not exist.
--
-- GREEN after 000050:
--   Admin can contribute PHON/USDT operator capital into the insurance fund with
--   balanced system-account legs, idempotency, audit, transfer_id pairing,
--   hash-chain integrity, and no reconciliation side effects.
--
-- Runs in one transaction and ROLLBACKs — no residue.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user UUID := gen_random_uuid();
  v_res JSONB;
  v_res_again JSONB;
  v_recon JSONB;
  v_msg TEXT;
  v_blocked BOOLEAN;
  v_phon_total_before NUMERIC;
  v_usdt_total_before NUMERIC;
  v_phon_total_after NUMERIC;
  v_usdt_total_after NUMERIC;
  v_transfer_id UUID;
  v_pair_count INT;
  v_idem_count_before INT;
  v_idem_count_after INT;
  v_ins_before NUMERIC;
  v_ins_after NUMERIC;
  v_op_before NUMERIC;
  v_op_after NUMERIC;
  v_broken INT;
  v_readonly TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'ins_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user, 'authenticated', 'authenticated', 'ins_user_' || v_user::TEXT || '@test.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON'),
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'USDT')
  INTO v_phon_total_before, v_usdt_total_before;

  -- T1/T2: admin contributions for both supported currencies. The insurance
  -- fund starts at zero, so the large-change guard is intentionally a no-op.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_res := rpc_contribute_insurance_capital(
    'PHON', '1000.000000', 'E1-a test PHON contribution', 'ins-e1a-phon-001', FALSE
  );
  ASSERT (v_res->>'ok')::BOOLEAN, format('PHON contribution failed: %s', v_res);
  ASSERT v_res->>'currency' = 'PHON', format('expected PHON response, got: %s', v_res);

  v_res := rpc_contribute_insurance_capital(
    'USDT', '500.000000', 'E1-a test USDT contribution', 'ins-e1a-usdt-001', FALSE
  );
  ASSERT (v_res->>'ok')::BOOLEAN, format('USDT contribution failed: %s', v_res);
  ASSERT v_res->>'currency' = 'USDT', format('expected USDT response, got: %s', v_res);

  -- T3: non-admin blocked with exact treasury-style casing.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::TEXT)::TEXT, true);
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_contribute_insurance_capital(
      'PHON', '1.000000', 'non-admin should fail', 'ins-e1a-user-001', FALSE
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'FORBIDDEN' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, format('non-admin must fail with FORBIDDEN, got %s', COALESCE(v_msg, '<none>'));

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);

  -- T4: KRW is deliberately out of scope for E1-a.
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_contribute_insurance_capital(
      'KRW', '1.000000', 'KRW should fail', 'ins-e1a-krw-001', FALSE
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'invalid_currency' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, format('KRW must fail with invalid_currency, got %s', COALESCE(v_msg, '<none>'));

  -- T5: manual/admin path requires a reason.
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_contribute_insurance_capital(
      'PHON', '1.000000', '   ', 'ins-e1a-reason-001', FALSE
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'reason_required' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, format('blank reason must fail with reason_required, got %s', COALESCE(v_msg, '<none>'));

  -- T6: large-change only fires when the insurance balance is positive. T1 made
  -- PHON insurance positive, so this must require explicit confirmation.
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_contribute_insurance_capital(
      'PHON', '100000.000000', 'large change should require confirmation',
      'ins-e1a-large-001', FALSE
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'attested_change_requires_confirm' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked,
    format('large positive-balance contribution must require confirmation, got %s', COALESCE(v_msg, '<none>'));

  -- T7: idempotency. Reusing the key must not append another system pair.
  SELECT count(*) INTO v_idem_count_before
    FROM system_account_ledger
   WHERE reason_code = 'insurance_capital_contribution'
     AND related_tx_id = 'ins-e1a-idem-001';
  SELECT balance::NUMERIC INTO v_ins_before FROM system_accounts WHERE code = 'insurance_fund_phon';
  SELECT balance::NUMERIC INTO v_op_before FROM system_accounts WHERE code = 'operator_contributed_capital_phon';

  v_res := rpc_contribute_insurance_capital(
    'PHON', '12.3456789', 'E1-a idempotency check', 'ins-e1a-idem-001', FALSE
  );
  v_res_again := rpc_contribute_insurance_capital(
    'PHON', '12.3456789', 'E1-a idempotency check', 'ins-e1a-idem-001', FALSE
  );

  SELECT count(*) INTO v_idem_count_after
    FROM system_account_ledger
   WHERE reason_code = 'insurance_capital_contribution'
     AND related_tx_id = 'ins-e1a-idem-001';
  SELECT balance::NUMERIC INTO v_ins_after FROM system_accounts WHERE code = 'insurance_fund_phon';
  SELECT balance::NUMERIC INTO v_op_after FROM system_accounts WHERE code = 'operator_contributed_capital_phon';

  ASSERT v_idem_count_before = 0, 'idempotency test key must start unused';
  ASSERT v_idem_count_after = 2,
    format('idempotent contribution must create exactly one debit/credit pair, got %s rows', v_idem_count_after);
  ASSERT v_res->>'transfer_id' = v_res_again->>'transfer_id',
    format('idempotent retry must return the original transfer_id, first=%s second=%s', v_res, v_res_again);
  ASSERT v_ins_after = v_ins_before + 12.345678,
    format('insurance balance must move once by truncated amount, before=%s after=%s', v_ins_before, v_ins_after);
  ASSERT v_op_after = v_op_before - 12.345678,
    format('operator balance must move once by truncated amount, before=%s after=%s', v_op_before, v_op_after);
  ASSERT (v_res_again->>'insurance_balance')::NUMERIC = v_ins_after,
    format('idempotent response must read current insurance balance, got %s expected %s', v_res_again, v_ins_after);

  -- T8: global conservation remains unchanged across all successful contributions.
  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON'),
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'USDT')
  INTO v_phon_total_after, v_usdt_total_after;

  ASSERT v_phon_total_after = v_phon_total_before,
    format('PHON Σ=0 must hold: before=%s after=%s', v_phon_total_before, v_phon_total_after);
  ASSERT v_usdt_total_after = v_usdt_total_before,
    format('USDT Σ=0 must hold: before=%s after=%s', v_usdt_total_before, v_usdt_total_after);

  -- T9: transfer_id pairs exactly one operator debit with one insurance credit.
  v_transfer_id := (v_res->>'transfer_id')::UUID;
  SELECT count(*) INTO v_pair_count
    FROM system_account_ledger
   WHERE transfer_id = v_transfer_id
     AND reason_code = 'insurance_capital_contribution'
     AND (
       (account_code = 'operator_contributed_capital_phon' AND direction = 'debit')
       OR (account_code = 'insurance_fund_phon' AND direction = 'credit')
     );
  ASSERT v_pair_count = 2, format('transfer_id pair must have two expected legs, got %s', v_pair_count);

  -- T10: both involved system-account chains stay valid.
  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_phon');
  ASSERT v_broken = 0, format('insurance_fund_phon hash chain broken rows=%s', v_broken);
  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('operator_contributed_capital_phon');
  ASSERT v_broken = 0, format('operator_contributed_capital_phon hash chain broken rows=%s', v_broken);

  -- T11: audit is append-only INSERT path and records reason/amount/currency.
  ASSERT EXISTS (
    SELECT 1
      FROM audit_logs
     WHERE actor_id = v_admin
       AND action = 'insurance_capital_contribution'
       AND entity_type = 'system_accounts'
       AND payload->>'currency' = 'PHON'
       AND payload->>'amount' = '12.345678'
       AND payload->>'reason' = 'E1-a idempotency check'
       AND payload->>'idempotency_key' = 'ins-e1a-idem-001'
  ), 'insurance capital contribution audit row missing expected payload';

  -- T12: balanced system↔system movement must not trip reconciliation/readonly.
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_recon := rpc_run_reconciliation();
  SELECT value INTO v_readonly FROM app_config WHERE key = 'system_readonly';

  ASSERT (v_recon->>'ok')::BOOLEAN, format('reconciliation must return ok, got %s', v_recon);
  ASSERT NOT (v_recon->>'mismatch')::BOOLEAN, format('contribution must not create reconciliation mismatch: %s', v_recon);
  ASSERT NOT (v_recon->>'readonly_set')::BOOLEAN, format('contribution must not set readonly: %s', v_recon);
  ASSERT v_readonly = 'false', format('system_readonly must remain false, got %s', v_readonly);

  RAISE NOTICE 'E1-a INSURANCE CONTRIBUTION OK — authz, idempotency, Σ=0, transfer pairing, audit, chain, reconciliation';
END;
$$;

ROLLBACK;
