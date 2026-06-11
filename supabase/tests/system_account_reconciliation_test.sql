-- ============================================================
-- E foundation ①-3 (audit A2-3 / A8-3) — reconciliation integrity wiring
-- ============================================================
-- Extends rpc_run_reconciliation beyond the wallet-only sum check (000026) so the
-- daily 02:00 cron also catches system-account corruption and ledger tampering
-- that preserves sums. Five checks per run:
--   (1) wallet conservation   Σ wallet balances == wallet_ledger net   (existing)
--   (2) system conservation   Σ system balances == system_ledger net   (A2-3 new)
--   (3) global Σ=0            Σ wallets + Σ system == 0 per currency    (A2-3 new)
--   (4) wallet hash-chain     verify_ledger_hash_chain() == 0 broken    (A8-3 new)
--   (5) system hash-chain     verify_system_account_hash_chain() == 0   (A8-2 wiring)
-- Any failure → system_readonly=true + reconciliation_log (no RAISE; the log must
-- survive — rule 25-postgres).
--
-- RED (before 000047): reconciliation_log has no `check_type` column AND the old
--   reconciliation ignores system accounts + hash-chains → a system tamper or a
--   sum-preserving ledger tamper returns mismatch=false. Either the missing column
--   (SQLSTATE 42703) or the false-negative assert fails the file = RED.
-- GREEN (after 000047): every tamper class below sets mismatch=true and logs the
--   specific failing check.
--
-- Solvency_reconciliation_test.sql keeps covering the wallet-sum path; this file
-- owns the system + hash-chain additions (no duplication).
--
-- Every block runs in its own transaction and ROLLS BACK — no residue.
-- ============================================================

-- ── Test 1: normal clean state logs all 5 checks, no false positive ──────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_res JSONB;
  v_types INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'recon_ok_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();  -- double-entry: wallet +PHON, reward_issuance_phon -PHON

  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';
  PERFORM set_config('request.jwt.claims', '{}', true);  -- service-role path
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'ok')::BOOLEAN, 'reconciliation must return ok';
  ASSERT NOT (v_res->>'mismatch')::BOOLEAN,
    format('clean welcome bonus must NOT mismatch (rewards keep Σ=0), got: %s', v_res);
  ASSERT NOT (v_res->>'readonly_set')::BOOLEAN, 'no readonly on clean state';

  -- All five check types must be present and matching.
  SELECT count(DISTINCT check_type) INTO v_types
    FROM reconciliation_log
   WHERE check_type IN ('wallet','system','global_zero','hash_chain_wallet','hash_chain_system');
  ASSERT v_types = 5, format('expected 5 distinct check types logged, got %s', v_types);

  ASSERT NOT EXISTS (SELECT 1 FROM reconciliation_log WHERE is_match = FALSE),
    'no check may report a mismatch on a clean welcome bonus';

  RAISE NOTICE 'A2-3/A8-3 Test1 OK — 5 checks logged, clean state no false positive';
END;
$$;
ROLLBACK;

-- ── Test 2: system-account conservation tamper (A2-3) ────────────────────────
-- Balance mutated with no ledger entry → system balance ≠ system_ledger net.
BEGIN;
DO $$
DECLARE
  v_res JSONB;
  v_sys_broken INT;
BEGIN
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- TAMPER: inflate a system balance directly (no ledger row).
  UPDATE system_accounts
     SET balance = (balance::NUMERIC + 9999)::TEXT
   WHERE code = 'insurance_fund_phon';

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'mismatch')::BOOLEAN,
    format('system-balance tamper must be detected (A2-3), got: %s', v_res);
  ASSERT (v_res->>'readonly_set')::BOOLEAN, 'system tamper must set readonly';

  SELECT count(*) INTO v_sys_broken
    FROM reconciliation_log
   WHERE check_type = 'system' AND is_match = FALSE AND currency = 'PHON';
  ASSERT v_sys_broken >= 1, 'a system-conservation check row must report the mismatch';

  RAISE NOTICE 'A2-3 Test2 OK — system-account conservation tamper detected';
END;
$$;
ROLLBACK;

-- ── Test 3: global Σ=0 break, independent of system conservation (A2-3) ───────
-- A lone system credit keeps balance==ledger (conservation OK) but unbalances the
-- wallet+system total → only the global_zero check fires. Proves the two checks
-- are independent (a leg created without its counterpart is caught here).
BEGIN;
DO $$
DECLARE
  v_res JSONB;
  v_global_broken INT;
  v_system_ok INT;
BEGIN
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- Lone credit: balance and ledger both move together (conservation intact) but
  -- there is no offsetting wallet/system leg → global Σ ≠ 0.
  PERFORM _credit_system_account('insurance_fund_phon', '500.000000', 'test_recon_lone',
    NULL, NULL, gen_random_uuid());

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'mismatch')::BOOLEAN,
    format('unbalanced leg must break global Σ=0 (A2-3), got: %s', v_res);

  SELECT count(*) INTO v_global_broken
    FROM reconciliation_log
   WHERE check_type = 'global_zero' AND is_match = FALSE AND currency = 'PHON';
  ASSERT v_global_broken >= 1, 'global_zero check must report the imbalance';

  SELECT count(*) INTO v_system_ok
    FROM reconciliation_log
   WHERE check_type = 'system' AND is_match = TRUE AND currency = 'PHON';
  ASSERT v_system_ok >= 1,
    'system-conservation must still MATCH (balance moved with its ledger) — checks are independent';

  RAISE NOTICE 'A2-3 Test3 OK — global Σ=0 break caught while system conservation stays clean';
END;
$$;
ROLLBACK;

-- ── Test 4: system hash-chain via reconciliation (A8-2 wiring) ───────────────
-- A balanced system pair keeps Σ=0 AND conservation; a sum-preserving field tamper
-- (reason_code) on a system ledger row is invisible to the sum checks but breaks
-- the system hash-chain. Proves reconciliation now wires verify_system_account_*.
BEGIN;
DO $$
DECLARE
  v_lid UUID;
  v_res JSONB;
  v_chain_broken INT;
  v_sys_ok INT;
  v_global_ok INT;
BEGIN
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- Balanced pair: system PHON net change = 0, balances net = 0.
  PERFORM _credit_system_account('insurance_fund_phon',  '7.000000', 'test_recon_sal', NULL, NULL, gen_random_uuid());
  PERFORM _debit_system_account ('house_liquidity_phon', '7.000000', 'test_recon_sal', NULL, NULL, gen_random_uuid());

  SELECT id INTO v_lid
    FROM system_account_ledger
   WHERE account_code = 'insurance_fund_phon' AND reason_code = 'test_recon_sal'
   ORDER BY seq DESC LIMIT 1;

  -- TAMPER: sum-preserving (reason_code only), RULE bypassed.
  ALTER TABLE system_account_ledger DISABLE RULE system_account_ledger_no_update;
  UPDATE system_account_ledger SET reason_code = reason_code || '_x' WHERE id = v_lid;
  ALTER TABLE system_account_ledger ENABLE RULE system_account_ledger_no_update;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'mismatch')::BOOLEAN,
    format('sum-preserving system-ledger tamper must be caught by hash-chain (A8-2), got: %s', v_res);

  SELECT count(*) INTO v_chain_broken
    FROM reconciliation_log WHERE check_type = 'hash_chain_system' AND is_match = FALSE;
  ASSERT v_chain_broken >= 1, 'hash_chain_system check must report the tamper';

  SELECT count(*) INTO v_sys_ok
    FROM reconciliation_log WHERE check_type = 'system' AND is_match = TRUE AND currency = 'PHON';
  SELECT count(*) INTO v_global_ok
    FROM reconciliation_log WHERE check_type = 'global_zero' AND is_match = TRUE AND currency = 'PHON';
  ASSERT v_sys_ok >= 1 AND v_global_ok >= 1,
    'sum checks must stay clean (only the chain detects a sum-preserving tamper)';

  RAISE NOTICE 'A8-2 Test4 OK — system hash-chain wired into reconciliation';
END;
$$;
ROLLBACK;

-- ── Test 5: wallet hash-chain via reconciliation (A8-3) ─────────────────────
-- The headline gap: a balanced wallet_ledger row tamper that preserves the sum
-- escapes the existing sum reconciliation but is caught by the wallet hash-chain.
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_lid UUID;
  v_res JSONB;
  v_chain_broken INT;
  v_wallet_ok INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'recon_wl_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();

  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- TAMPER: sum-preserving (reason_code), RULE bypassed.
  ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
  SELECT id INTO v_lid FROM wallet_ledger WHERE user_id = v_uid ORDER BY seq ASC LIMIT 1;
  UPDATE wallet_ledger SET reason_code = reason_code || '_x' WHERE id = v_lid;
  ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'mismatch')::BOOLEAN,
    format('sum-preserving wallet-ledger tamper must be caught by hash-chain (A8-3), got: %s', v_res);

  SELECT count(*) INTO v_chain_broken
    FROM reconciliation_log WHERE check_type = 'hash_chain_wallet' AND is_match = FALSE;
  ASSERT v_chain_broken >= 1, 'hash_chain_wallet check must report the tamper';

  SELECT count(*) INTO v_wallet_ok
    FROM reconciliation_log WHERE check_type = 'wallet' AND is_match = TRUE AND currency = 'PHON';
  ASSERT v_wallet_ok >= 1,
    'wallet sum-check must stay clean (only the chain detects a sum-preserving tamper)';

  RAISE NOTICE 'A8-3 Test5 OK — wallet hash-chain wired into reconciliation (sum check would miss it)';
END;
$$;
ROLLBACK;
