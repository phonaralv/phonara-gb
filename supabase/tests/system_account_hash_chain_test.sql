-- ============================================================
-- E foundation ①-2 (audit A8-2) — system_account_ledger hash-chain
-- ============================================================
-- Mirrors the wallet_ledger hash-chain tests (hardening_test.sql A4/A4b) for the
-- internal system-account ledger that the E insurance fund / fee legs write to.
--
-- Chain unit  : account_code (per-account chain, like wallet_ledger per user_id)
-- Order key   : global IDENTITY seq
-- Signed by   : _sal_row_hash(...) — single source of truth (trigger/verifier/backfill)
-- Verifier    : verify_system_account_hash_chain(p_account_code TEXT DEFAULT NULL)
--
-- RED (before 000046): verify_system_account_hash_chain / chain columns do not
--   exist → first reference raises SQLSTATE 42883/42703 → ON_ERROR_STOP aborts
--   the file = RED. (Distinct from ①-1's "UPDATE 999 succeeds" RED.)
-- GREEN (after 000046): tamper is detected (broken >= 1) and the honest chain
--   verifies clean.
--
-- Role separation (①-1 vs ①-2):
--   * ①-1 append-only RULE blocks NORMAL UPDATE/DELETE (see system_account_
--     hardening_test.sql Test1). It is the FIRST line of defence.
--   * ①-2 hash-chain detects tampering that BYPASSES the RULE (RULE disabled,
--     superuser, future buggy migration). It is the audit/forensic line.
--   A tamper here can only succeed AFTER disabling the RULE, which is exactly
--   why both layers are needed.
--
-- Every block runs in its own transaction and ROLLS BACK — no residue.
-- ============================================================

-- ── Test 1: A8-2 core — RULE-bypass amount tamper is detected ────────────────
BEGIN;
DO $$
DECLARE
  v_lid           UUID;
  v_amount_before TEXT;
  v_amount_after  TEXT;
  v_broken        INT;
BEGIN
  PERFORM _credit_system_account(
    'insurance_fund_phon', '1.000000', 'test_sal_chain_tamper', NULL, NULL, gen_random_uuid()
  );

  SELECT id, amount INTO v_lid, v_amount_before
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_phon'
     AND reason_code = 'test_sal_chain_tamper'
   ORDER BY seq DESC
   LIMIT 1;
  ASSERT v_lid IS NOT NULL, 'seed ledger row missing';

  -- Honest chain must verify clean before any tamper.
  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_phon');
  ASSERT v_broken = 0, format('chain reported broken BEFORE tamper (broken=%s)', v_broken);

  -- Role separation: with the ①-1 RULE ENABLED, the tamper UPDATE is a no-op.
  UPDATE system_account_ledger SET amount = '999.000000' WHERE id = v_lid;
  SELECT amount INTO v_amount_after FROM system_account_ledger WHERE id = v_lid;
  ASSERT v_amount_after = v_amount_before,
    format('append-only RULE must block normal UPDATE (before=%s after=%s)',
           v_amount_before, v_amount_after);

  -- Tamper that BYPASSES the RULE (attacker / buggy migration) must be detected.
  ALTER TABLE system_account_ledger DISABLE RULE system_account_ledger_no_update;
  UPDATE system_account_ledger SET amount = (amount::NUMERIC + 1)::TEXT WHERE id = v_lid;
  ALTER TABLE system_account_ledger ENABLE RULE system_account_ledger_no_update;

  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_phon');
  ASSERT v_broken >= 1, 'RULE-bypass amount tamper was NOT detected';

  RAISE NOTICE 'A8-2 Test1 OK — amount tamper detected (broken=%); RULE blocks normal UPDATE', v_broken;
END;
$$;
ROLLBACK;

-- ── Test 2: payload binding — every signed field breaks the chain when tampered ─
-- Proves _sal_row_hash actually folds account_code's per-row fields, and in
-- particular the system-specific additions over wallet-v2 (related_user_id,
-- related_tx_id, transfer_id, balance_after). Without this, an arg could be
-- declared but accidentally left OUT of the concatenation (silent tamper hole —
-- exactly the wallet v1→v2 bug this design avoids).
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_ids    UUID[];
  v_broken INT;
BEGIN
  -- Real profile so related_user_id satisfies its FK (handle_new_user auto-creates
  -- profiles + wallets; never INSERT those manually — rule 25-postgres).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'sal_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  -- Four honest rows, every nullable signed field populated so each is tamperable.
  PERFORM _credit_system_account('insurance_fund_phon', '1.000000', 'test_sal_bind',
    v_uid, 'tx_' || v_uid::TEXT, gen_random_uuid());
  PERFORM _credit_system_account('insurance_fund_phon', '2.000000', 'test_sal_bind',
    v_uid, 'tx_' || v_uid::TEXT, gen_random_uuid());
  PERFORM _credit_system_account('insurance_fund_phon', '3.000000', 'test_sal_bind',
    v_uid, 'tx_' || v_uid::TEXT, gen_random_uuid());
  PERFORM _credit_system_account('insurance_fund_phon', '4.000000', 'test_sal_bind',
    v_uid, 'tx_' || v_uid::TEXT, gen_random_uuid());

  SELECT array_agg(id ORDER BY seq) INTO v_ids
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_phon' AND reason_code = 'test_sal_bind';
  ASSERT array_length(v_ids, 1) = 4, 'expected 4 seeded rows';

  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_phon');
  ASSERT v_broken = 0, format('chain broken BEFORE tamper (broken=%s)', v_broken);

  -- One distinct signed field tampered per row (RULE bypassed).
  ALTER TABLE system_account_ledger DISABLE RULE system_account_ledger_no_update;
  UPDATE system_account_ledger SET related_user_id = NULL              WHERE id = v_ids[1];
  UPDATE system_account_ledger SET related_tx_id   = related_tx_id || '_x' WHERE id = v_ids[2];
  UPDATE system_account_ledger SET transfer_id     = gen_random_uuid() WHERE id = v_ids[3];
  UPDATE system_account_ledger SET balance_after   = (balance_after::NUMERIC + 1)::TEXT WHERE id = v_ids[4];
  ALTER TABLE system_account_ledger ENABLE RULE system_account_ledger_no_update;

  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_phon');
  ASSERT v_broken = 4,
    format('every signed field must break the chain: expected 4 broken, got %s '
        || '(related_user_id / related_tx_id / transfer_id / balance_after)', v_broken);

  RAISE NOTICE 'A8-2 Test2 OK — all 4 system-specific signed fields detected (broken=%)', v_broken;
END;
$$;
ROLLBACK;

-- ── Test 3: honest multi-row chain links per account_code ────────────────────
BEGIN;
DO $$
DECLARE
  v_r1_prev TEXT; v_r1_hash TEXT;
  v_r2_prev TEXT; v_r2_hash TEXT;
  v_broken  INT;
BEGIN
  PERFORM _credit_system_account('insurance_fund_usdt', '1.000000', 'test_sal_link', NULL, NULL, gen_random_uuid());
  PERFORM _credit_system_account('insurance_fund_usdt', '2.000000', 'test_sal_link', NULL, NULL, gen_random_uuid());

  SELECT prev_hash, row_hash INTO v_r1_prev, v_r1_hash
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_usdt' AND reason_code = 'test_sal_link'
   ORDER BY seq ASC LIMIT 1;
  SELECT prev_hash, row_hash INTO v_r2_prev, v_r2_hash
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_usdt' AND reason_code = 'test_sal_link'
   ORDER BY seq DESC LIMIT 1;

  ASSERT v_r1_prev IS NULL,      'first row of a fresh account must be genesis (prev_hash NULL)';
  ASSERT v_r1_hash IS NOT NULL,  'first row must have a row_hash';
  ASSERT v_r2_hash IS NOT NULL,  'second row must have a row_hash';
  ASSERT v_r2_prev = v_r1_hash,  'second row prev_hash must equal first row row_hash (chain link)';
  ASSERT v_r2_hash <> v_r1_hash, 'distinct rows must produce distinct hashes';

  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('insurance_fund_usdt');
  ASSERT v_broken = 0, format('honest chain must verify clean (broken=%s)', v_broken);

  RAISE NOTICE 'A8-2 Test3 OK — genesis + chain link + clean verify';
END;
$$;
ROLLBACK;

-- ── Test 4: definer path (_credit + _debit) produces a valid chain ───────────
-- Replaces the duplicated balance/row-count regression from ①-1's Test3 with the
-- chain-specific guarantee: the PRODUCTION definer path signs every insert.
BEGIN;
DO $$
DECLARE
  v_r1_prev TEXT; v_r1_hash TEXT;
  v_r2_prev TEXT; v_r2_hash TEXT;
  v_rows    INT;
  v_broken  INT;
BEGIN
  PERFORM _credit_system_account('house_fee_phon', '2.500000', 'test_sal_definer', NULL, NULL, gen_random_uuid());
  PERFORM _debit_system_account ('house_fee_phon', '0.500000', 'test_sal_definer', NULL, NULL, gen_random_uuid());

  SELECT count(*) INTO v_rows
    FROM system_account_ledger
   WHERE account_code = 'house_fee_phon' AND reason_code = 'test_sal_definer';
  ASSERT v_rows = 2, 'definer credit+debit must append two ledger rows';

  SELECT prev_hash, row_hash INTO v_r1_prev, v_r1_hash
    FROM system_account_ledger
   WHERE account_code = 'house_fee_phon' AND reason_code = 'test_sal_definer'
   ORDER BY seq ASC LIMIT 1;
  SELECT prev_hash, row_hash INTO v_r2_prev, v_r2_hash
    FROM system_account_ledger
   WHERE account_code = 'house_fee_phon' AND reason_code = 'test_sal_definer'
   ORDER BY seq DESC LIMIT 1;

  ASSERT v_r1_hash IS NOT NULL AND v_r2_hash IS NOT NULL,
    'definer path must populate row_hash on both credit and debit inserts';
  ASSERT v_r2_prev = v_r1_hash,
    'definer path must chain debit.prev_hash to credit.row_hash';

  SELECT count(*) INTO v_broken
    FROM verify_system_account_hash_chain('house_fee_phon');
  ASSERT v_broken = 0, format('definer-path chain must verify clean (broken=%s)', v_broken);

  RAISE NOTICE 'A8-2 Test4 OK — definer credit/debit produce a clean signed chain';
END;
$$;
ROLLBACK;
