-- ============================================================
-- E foundation — system_account hardening (audit A1-1 + A2-1)
-- Migration: 000045_e_foundation_system_account_hardening.sql
--
-- Test 1 (A1-1): postgres(superuser) UPDATE on system_account_ledger must not
--   mutate rows when append-only RULEs exist (DO INSTEAD NOTHING — same as
--   wallet_ledger). Pre-000045: UPDATE succeeds (RED). Post-000045: amount unchanged.
-- Test 2 (A2-1): simulated accidental permissive UPDATE policy on system_accounts;
--   authenticated must be able to mutate only when table UPDATE is deliberately
--   granted (true RED), then get permission denied after the REVOKE belt is
--   restored (GREEN). The transaction ROLLBACK removes the temporary policy/GRANT.
-- Test 3: _credit/_debit_system_account definer path regression.
--
-- Runs in one transaction and ROLLS BACK — no residue.
-- ============================================================

BEGIN;

-- ── Test 1: A1-1 append-only RULE blocks superuser UPDATE ───────────────────
DO $$
DECLARE
  v_id           UUID;
  v_amount_before TEXT;
  v_amount_after  TEXT;
  v_count_before  BIGINT;
  v_count_after   BIGINT;
BEGIN
  PERFORM _credit_system_account(
    'insurance_fund_phon', '1.000000', 'test_sal_append_only', NULL, NULL, gen_random_uuid()
  );

  SELECT id, amount
    INTO v_id, v_amount_before
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_phon'
     AND reason_code = 'test_sal_append_only'
   ORDER BY created_at DESC
   LIMIT 1;

  ASSERT v_id IS NOT NULL, 'seed ledger row missing';
  ASSERT current_user = 'postgres',
    format('expected postgres session for RULE test, got %s', current_user);

  UPDATE system_account_ledger
     SET amount = '999.000000'
   WHERE id = v_id;

  SELECT amount INTO v_amount_after FROM system_account_ledger WHERE id = v_id;
  ASSERT v_amount_after = v_amount_before,
    format(
      'append-only RULE must block mutation (before=%s after=%s user=%s)',
      v_amount_before, v_amount_after, current_user
    );

  SELECT count(*) INTO v_count_before FROM system_account_ledger WHERE id = v_id;

  DELETE FROM system_account_ledger WHERE id = v_id;

  SELECT count(*) INTO v_count_after FROM system_account_ledger WHERE id = v_id;
  ASSERT v_count_after = v_count_before,
    'append-only RULE must block DELETE (row count unchanged)';

  -- Post-000045 only: prove RULE is the guard (wallet_ledger hardening pattern).
  IF EXISTS (
    SELECT 1 FROM pg_rules
     WHERE schemaname = 'public'
       AND tablename = 'system_account_ledger'
       AND rulename = 'system_account_ledger_no_update'
  ) THEN
    ALTER TABLE system_account_ledger DISABLE RULE system_account_ledger_no_update;
    UPDATE system_account_ledger SET amount = '888.000000' WHERE id = v_id;
    SELECT amount INTO v_amount_after FROM system_account_ledger WHERE id = v_id;
    ASSERT v_amount_after = '888.000000',
      'with RULE disabled, postgres UPDATE must mutate (proves RULE is the guard)';
    ALTER TABLE system_account_ledger ENABLE RULE system_account_ledger_no_update;
  END IF;

  RAISE NOTICE 'A1-1 SYSTEM ACCOUNT LEDGER APPEND-ONLY OK — postgres UPDATE/DELETE blocked';
END;
$$;

-- ── Test 2: A2-1 REVOKE belt blocks authenticated even if RLS policy leaks ──
DO $$
DECLARE
  v_before  TEXT;
  v_after   TEXT;
  v_red_after TEXT;
  v_err     TEXT;
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.system_accounts', 'UPDATE'),
    'authenticated must NOT hold UPDATE on system_accounts (REVOKE belt)';
  ASSERT NOT has_table_privilege('authenticated', 'public.system_account_ledger', 'INSERT'),
    'authenticated must NOT hold INSERT on system_account_ledger (REVOKE belt)';

  SELECT balance INTO v_before
    FROM system_accounts
   WHERE code = 'insurance_fund_phon';

  DROP POLICY IF EXISTS _test_accidental_sa_read ON system_accounts;
  DROP POLICY IF EXISTS _test_accidental_sa_write ON system_accounts;
  CREATE POLICY _test_accidental_sa_read ON system_accounts
    FOR SELECT TO authenticated
    USING (true);
  CREATE POLICY _test_accidental_sa_write ON system_accounts
    FOR UPDATE TO authenticated
    USING (true)
    WITH CHECK (true);

  PERFORM set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001"}', true);

  -- RED proof: if a future migration accidentally grants SELECT+UPDATE and opens
  -- RLS, a normal authenticated role can mutate the system balance. This proves
  -- the REVOKE belt is the difference between vulnerable and protected states.
  GRANT SELECT ON system_accounts TO authenticated;
  GRANT UPDATE ON system_accounts TO authenticated;
  SET ROLE authenticated;
  UPDATE system_accounts
     SET balance = '123456.000000', updated_at = NOW()
   WHERE code = 'insurance_fund_phon';
  RESET ROLE;

  SELECT balance INTO v_red_after
    FROM system_accounts
   WHERE code = 'insurance_fund_phon';
  ASSERT v_red_after = '123456.000000',
    format('RED proof failed: temporary GRANT+policy should allow mutation, got %s', v_red_after);

  UPDATE system_accounts
     SET balance = v_before, updated_at = NOW()
   WHERE code = 'insurance_fund_phon';
  REVOKE UPDATE ON system_accounts FROM authenticated;

  SET ROLE authenticated;

  BEGIN
    UPDATE system_accounts
       SET balance = '999999.000000', updated_at = NOW()
     WHERE code = 'insurance_fund_phon';
    RESET ROLE;
    RAISE EXCEPTION 'REVOKE belt missing: authenticated UPDATE succeeded under accidental RLS policy';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RESET ROLE;
      v_err := SQLERRM;
    WHEN OTHERS THEN
      RESET ROLE;
      RAISE;
  END;

  ASSERT v_err IS NOT NULL,
    'authenticated UPDATE must fail with insufficient_privilege when REVOKE belt is on';
  ASSERT v_err LIKE '%permission denied%',
    format('expected permission denied, got: %s', v_err);

  SELECT balance INTO v_after
    FROM system_accounts
   WHERE code = 'insurance_fund_phon';
  ASSERT v_after = v_before,
    format('balance must be unchanged (before=%s after=%s)', v_before, v_after);

  REVOKE SELECT ON system_accounts FROM authenticated;
  DROP POLICY IF EXISTS _test_accidental_sa_write ON system_accounts;
  DROP POLICY IF EXISTS _test_accidental_sa_read ON system_accounts;

  RAISE NOTICE 'A2-1 REVOKE BELT OK — accidental RLS policy still blocked by GRANT revoke';
END;
$$;

-- ── Test 3: definer credit/debit path regression ────────────────────────────
DO $$
DECLARE
  v_before  TEXT;
  v_after   TEXT;
  v_ledger  BIGINT;
BEGIN
  SELECT balance INTO v_before
    FROM system_accounts
   WHERE code = 'insurance_fund_phon';

  PERFORM _credit_system_account(
    'insurance_fund_phon', '2.500000', 'test_definer_credit', NULL, NULL, gen_random_uuid()
  );
  PERFORM _debit_system_account(
    'insurance_fund_phon', '0.500000', 'test_definer_debit', NULL, NULL, gen_random_uuid()
  );

  SELECT balance INTO v_after
    FROM system_accounts
   WHERE code = 'insurance_fund_phon';

  ASSERT v_after::NUMERIC = v_before::NUMERIC + 2.0,
    format('definer credit/debit must move balance (before=%s after=%s)', v_before, v_after);

  SELECT count(*) INTO v_ledger
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_phon'
     AND reason_code IN ('test_definer_credit', 'test_definer_debit');

  ASSERT v_ledger = 2, 'definer path must append two ledger rows';

  RAISE NOTICE 'A2-1 DEFINER PATH OK — _credit/_debit_system_account still work';
END;
$$;

ROLLBACK;
