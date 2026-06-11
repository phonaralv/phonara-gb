-- ============================================================
-- Solvency & Reconciliation — SQL integration test
-- ============================================================
-- Guards migration 000026 (s1_solvency_reconciliation). Proves that:
--   1. rpc_run_reconciliation() passes when wallets match ledger (normal).
--   2. Direct wallet tamper is detected: reconciliation flags mismatch,
--      sets system_readonly = true, logs triggered_halt = true.
--   3. After reconciliation mismatch, _assert_system_live() raises system_readonly.
--   4. rpc_run_reconciliation() is NOT callable by authenticated (service_role only).
--   5. Solvency gate is unified: the authoritative _assert_solvency_withdrawal_gate
--      exists and the orphan _assert_withdrawal_gate is removed (A1-4/A2-6/A7-3).
--      Behavioural coverage of the authoritative gate lives in phase5_gates_test.
--
-- Each test runs in its own transaction and ROLLBACKs — no residue.
-- ============================================================

-- ── Test 1: Privilege check — authenticated cannot call reconciliation ─────────
BEGIN;
DO $$
BEGIN
  ASSERT NOT has_function_privilege(
    'authenticated', 'public.rpc_run_reconciliation()', 'EXECUTE'),
    'authenticated must NOT execute rpc_run_reconciliation (service_role only)';

  ASSERT has_function_privilege(
    'service_role', 'public.rpc_run_reconciliation()', 'EXECUTE'),
    'service_role must execute rpc_run_reconciliation';

  RAISE NOTICE 'RECON PRIVILEGE LOCK OK — authenticated revoked; service_role intact';
END;
$$;
ROLLBACK;

-- ── Test 2: Normal reconciliation — wallet matches ledger (no mismatch) ────────
BEGIN;
DO $$
DECLARE
  v_uid   UUID := gen_random_uuid();
  v_res   JSONB;
  v_match BOOLEAN;
BEGIN
  -- Create a user who claims their welcome bonus (creates ledger entries).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'recon_ok_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();

  -- Run reconciliation (as service role: uid=NULL).
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'ok')::BOOLEAN, 'reconciliation must return ok=true';
  ASSERT NOT (v_res->>'mismatch')::BOOLEAN,
    format('no mismatch expected after normal ops, got: %s', v_res);
  ASSERT NOT (v_res->>'readonly_set')::BOOLEAN,
    'system_readonly must not be set after clean reconciliation';

  RAISE NOTICE 'NORMAL RECONCILIATION OK — wallet matches ledger, no halt';
END;
$$;
ROLLBACK;

-- ── Test 3: Tamper detection — direct wallet update triggers readonly ──────────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_res       JSONB;
  v_readonly  TEXT;
  v_log_count INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'recon_tamper_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_claim_welcome_bonus();

  -- Reset system_readonly to false before the test.
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- TAMPER: directly add balance without a ledger entry (simulates exploit/bug).
  -- The wallet balance guard is intentionally bypassed here so this test keeps
  -- exercising reconciliation's detection path rather than the prevention layer.
  ALTER TABLE wallets DISABLE TRIGGER trg_00_wallets_balance_write_guard;
  UPDATE wallets SET phon_available = (phon_available::NUMERIC + 9999)::TEXT
   WHERE user_id = v_uid;
  ALTER TABLE wallets ENABLE TRIGGER trg_00_wallets_balance_write_guard;

  -- Run reconciliation.
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_reconciliation();

  ASSERT (v_res->>'mismatch')::BOOLEAN,
    format('reconciliation must detect tamper, got: %s', v_res);
  ASSERT (v_res->>'readonly_set')::BOOLEAN,
    'system_readonly must be set after mismatch';

  -- Verify system_readonly flag in app_config.
  SELECT value INTO v_readonly FROM app_config WHERE key = 'system_readonly';
  ASSERT v_readonly = 'true', format('app_config system_readonly must be true, got %s', v_readonly);

  -- Verify reconciliation_log has triggered_halt=true.
  SELECT COUNT(*) INTO v_log_count
    FROM reconciliation_log
   WHERE triggered_halt = TRUE AND is_match = FALSE
     AND run_at >= NOW() - INTERVAL '10 seconds';
  ASSERT v_log_count > 0,
    'reconciliation_log must have triggered_halt=true rows after mismatch';

  RAISE NOTICE 'TAMPER DETECTION OK — mismatch detected, system_readonly set, log written';
END;
$$;
ROLLBACK;

-- ── Test 4: Post-mismatch guard — _assert_system_live blocks ops ──────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg     TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'recon_guard_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  -- Simulate the readonly state that reconciliation would set.
  UPDATE app_config SET value = 'true' WHERE key = 'system_readonly';
  -- Reset halt to false so we isolate the readonly path.
  UPDATE app_config SET value = 'false' WHERE key = 'system_halt';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  BEGIN
    PERFORM rpc_claim_welcome_bonus();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'system_readonly' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('rpc_claim_welcome_bonus must be blocked in system_readonly mode, got: %s', v_msg);

  RAISE NOTICE 'READONLY GUARD OK — welcome bonus blocked in system_readonly mode';
END;
$$;
ROLLBACK;

-- ── Test 5: solvency gate is unified — orphan _assert_withdrawal_gate removed ─
-- A1-4 / A2-6 / A7-3: the 2-arg _assert_withdrawal_gate (000026) was superseded by
-- the authoritative 1-arg _assert_solvency_withdrawal_gate (000033), which is what
-- rpc_request_withdrawal actually calls. The orphan implemented a DIFFERENT,
-- never-shipped solvency model (supply ≥ demand×(1+buffer)) and ONLY this test
-- file referenced it — i.e. it was dead code exercised by a dead test (false
-- confidence). The authoritative gate's inactive/blocking behaviour is fully
-- covered by phase5_gates_test (Gate 3 stale-reconciliation, Gate 4/5 reserve
-- coverage), so the old behavioural Test 5/6 are replaced by this structural
-- guard proving the de-duplication actually happened (migration 000048).
BEGIN;
DO $$
BEGIN
  ASSERT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = '_assert_solvency_withdrawal_gate'
  ), 'authoritative solvency gate _assert_solvency_withdrawal_gate must exist';

  ASSERT NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = '_assert_withdrawal_gate'
  ), 'orphan _assert_withdrawal_gate must be removed (single solvency gate — A1-4/A2-6)';

  RAISE NOTICE 'SOLVENCY GATE UNIFIED OK — orphan removed, single authoritative gate';
END;
$$;
ROLLBACK;
