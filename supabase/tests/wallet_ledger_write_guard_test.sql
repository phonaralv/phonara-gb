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

-- ── Test 3: service_role cannot create a wallet with non-zero balances ──────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_blocked BOOLEAN := FALSE;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_insert_nonzero_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  DELETE FROM wallets WHERE user_id = v_uid;

  SET LOCAL ROLE service_role;
  BEGIN
    INSERT INTO wallets (user_id, phon_available)
    VALUES (v_uid, '1.000000');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'ledger_write_not_allowed' THEN
      v_blocked := TRUE;
    END IF;
  END;
  RESET ROLE;

  ASSERT v_blocked,
    format('service_role direct non-zero wallet INSERT must raise ledger_write_not_allowed, got: %s', coalesce(v_msg, '<no error>'));

  RAISE NOTICE 'WALLET NON-ZERO INSERT GUARD OK';
END;
$$;
ROLLBACK;

-- ── Test 4: service_role can create a zero-balance wallet row ────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_insert_zero_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  DELETE FROM wallets WHERE user_id = v_uid;

  SET LOCAL ROLE service_role;
  INSERT INTO wallets (user_id)
  VALUES (v_uid);
  RESET ROLE;

  ASSERT EXISTS (
    SELECT 1
      FROM wallets
     WHERE user_id = v_uid
       AND phon_available::NUMERIC = 0
       AND phon_locked::NUMERIC = 0
       AND usdt_available::NUMERIC = 0
       AND usdt_locked::NUMERIC = 0
       AND krw_available::NUMERIC = 0
       AND krw_locked::NUMERIC = 0
  ), 'service_role zero-balance wallet INSERT should remain allowed';

  RAISE NOTICE 'WALLET ZERO INSERT OK';
END;
$$;
ROLLBACK;

-- ── Test 5: signup trigger still creates a zero-balance wallet ───────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'guard_signup_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  ASSERT EXISTS (
    SELECT 1
      FROM wallets
     WHERE user_id = v_uid
       AND phon_available::NUMERIC = 0
       AND phon_locked::NUMERIC = 0
       AND usdt_available::NUMERIC = 0
       AND usdt_locked::NUMERIC = 0
       AND krw_available::NUMERIC = 0
       AND krw_locked::NUMERIC = 0
  ), 'create_wallet_for_profile should create exactly one zero-balance wallet without ledger_write GUC';

  RAISE NOTICE 'SIGNUP ZERO WALLET REGRESSION OK';
END;
$$;
ROLLBACK;

-- ── Test 6: direct wallet_ledger INSERTs are blocked ────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_wallet_id UUID;
  v_service_role_blocked BOOLEAN := FALSE;
  v_owner_guard_blocked BOOLEAN := FALSE;
  v_msg TEXT;
  v_state TEXT;
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
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg = 'ledger_write_not_allowed' OR v_state = '42501' THEN
      v_service_role_blocked := TRUE;
    END IF;
  END;
  RESET ROLE;

  ASSERT v_service_role_blocked,
    format('service_role direct wallet_ledger INSERT must be blocked by grant belt or ledger guard, got: %s', coalesce(v_msg, '<no error>'));

  BEGIN
    INSERT INTO wallet_ledger (
      wallet_id, user_id, idempotency_key, direction, currency, amount,
      available_before, locked_before, available_after, locked_after, reason_code
    ) VALUES (
      v_wallet_id, v_uid, 'owner-direct-ledger:' || v_uid::TEXT, 'credit', 'PHON', '1.000000',
      '0.000000', '0.000000', '1.000000', '0.000000', 'direct_insert'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'ledger_write_not_allowed' THEN
      v_owner_guard_blocked := TRUE;
    END IF;
  END;

  ASSERT v_owner_guard_blocked,
    format('privileged direct wallet_ledger INSERT must raise ledger_write_not_allowed, got: %s', coalesce(v_msg, '<no error>'));

  RAISE NOTICE 'WALLET LEDGER DIRECT INSERT GUARD OK';
END;
$$;
ROLLBACK;

-- ── Test 7: duplicate prev_hash branches are structurally rejected ───────────
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
