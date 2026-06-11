-- ============================================================
-- Wallet / ledger privileged write guard
-- ============================================================
-- RED-first coverage for:
--   1. privileged direct wallet balance UPDATE must be rejected,
--   2. privileged direct wallet_ledger INSERT must be rejected,
--   3. branch duplicate prev_hash rows must be rejected by a unique index even
--      when triggers are disabled to simulate a bypass attempt.
--
-- Each block runs in a transaction and ROLLBACKs, leaving no residue.
-- ============================================================

-- ── Test 1: service_role cannot mutate wallet balances directly ─────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_wallet_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  SET LOCAL ROLE service_role;
  BEGIN
    UPDATE wallets
       SET phon_available = (phon_available::NUMERIC + 100)::TEXT
     WHERE user_id = v_uid;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'ledger_write_not_allowed' THEN
      v_blocked := TRUE;
    END IF;
  END;
  RESET ROLE;

  ASSERT v_blocked,
    format('service_role direct wallet balance UPDATE must raise ledger_write_not_allowed, got: %s', coalesce(v_msg, '<no error>'));

  RAISE NOTICE 'WALLET DIRECT UPDATE GUARD OK';
END;
$$;
ROLLBACK;

-- ── Test 2: non-balance wallet UPDATE remains allowed ───────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_meta_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  SET LOCAL ROLE service_role;
  UPDATE wallets
     SET updated_at = NOW()
   WHERE user_id = v_uid;
  RESET ROLE;

  RAISE NOTICE 'WALLET NON-BALANCE UPDATE OK';
END;
$$;
ROLLBACK;

-- ── Test 3: service_role cannot insert wallet_ledger rows directly ──────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_wallet_id UUID;
  v_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_ledger_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_uid;

  SET LOCAL ROLE service_role;
  BEGIN
    INSERT INTO wallet_ledger (
      wallet_id, user_id, idempotency_key, direction, currency, amount,
      available_before, locked_before, available_after, locked_after, reason_code
    ) VALUES (
      v_wallet_id, v_uid, 'direct-ledger:' || v_uid::TEXT, 'credit', 'PHON', '1.000000',
      '0.000000', '0.000000', '1.000000', '0.000000', 'direct_insert'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'ledger_write_not_allowed' THEN
      v_blocked := TRUE;
    END IF;
  END;
  RESET ROLE;

  ASSERT v_blocked,
    format('service_role direct wallet_ledger INSERT must raise ledger_write_not_allowed, got: %s', coalesce(v_msg, '<no error>'));

  RAISE NOTICE 'WALLET LEDGER DIRECT INSERT GUARD OK';
END;
$$;
ROLLBACK;

-- ── Test 4: duplicate prev_hash branches are structurally rejected ───────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_wallet_id UUID;
  v_prev_hash TEXT := repeat('a', 64);
  v_unique_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_branch_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_uid;

  ALTER TABLE wallet_ledger DISABLE TRIGGER USER;
  BEGIN
    INSERT INTO wallet_ledger (
      wallet_id, user_id, idempotency_key, direction, currency, amount,
      available_before, locked_before, available_after, locked_after, reason_code,
      prev_hash, row_hash
    ) VALUES (
      v_wallet_id, v_uid, 'branch-a:' || v_uid::TEXT, 'credit', 'PHON', '1.000000',
      '0.000000', '0.000000', '1.000000', '0.000000', 'branch_probe',
      v_prev_hash, repeat('b', 64)
    );

    INSERT INTO wallet_ledger (
      wallet_id, user_id, idempotency_key, direction, currency, amount,
      available_before, locked_before, available_after, locked_after, reason_code,
      prev_hash, row_hash
    ) VALUES (
      v_wallet_id, v_uid, 'branch-b:' || v_uid::TEXT, 'credit', 'PHON', '1.000000',
      '1.000000', '0.000000', '2.000000', '0.000000', 'branch_probe',
      v_prev_hash, repeat('c', 64)
    );
  EXCEPTION WHEN unique_violation THEN
    v_unique_blocked := TRUE;
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
  END;
  ALTER TABLE wallet_ledger ENABLE TRIGGER USER;

  ASSERT v_unique_blocked,
    format('duplicate wallet_ledger prev_hash branch must raise unique_violation, got: %s', coalesce(v_msg, '<no error>'));

  RAISE NOTICE 'WALLET LEDGER BRANCH UNIQUE OK';
END;
$$;
ROLLBACK;
