-- ============================================================
-- Phase 5 — KRW deposit reconciliation tests (Wave 9.1)
-- ============================================================

-- ── Test -1: pending deposit match row is locked before credit ───────────────
BEGIN;
DO $$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef('public._try_match_krw_deposit(text,text,text,text)'::regprocedure);

  ASSERT v_def LIKE '%WHERE reference_code = p_reference_code%'
     AND v_def LIKE '%AND status = ''pending''%'
     AND v_def LIKE '%FOR UPDATE%',
    '_try_match_krw_deposit must lock the pending deposit request with FOR UPDATE before matching';

  RAISE NOTICE 'KRW DEPOSIT MATCH LOCK OK — pending request SELECT uses FOR UPDATE';
END;
$$;
ROLLBACK;

-- ── Test 0: KRW deposit request rejects missing PHON/KRW rate ────────────────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_msg       TEXT;
  v_blocked   BOOLEAN := FALSE;
  v_phon      TEXT;
  v_rows      INT;
  v_ledger    INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_no_rate_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true'
    WHERE key = 'feature_deposit_enabled';

  UPDATE exchange_rate_snapshots
     SET is_active = FALSE
   WHERE base_currency = 'PHON' AND quote_currency = 'KRW';

  INSERT INTO sanctions_screenings (user_id, status, screened_at)
  VALUES (v_uid, 'clear', NOW());

  SELECT phon_available INTO v_phon FROM wallets WHERE user_id = v_uid;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  BEGIN
    PERFORM rpc_create_krw_deposit_request('10000', 'dep-no-rate-' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'phon_krw_rate_unavailable' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('missing PHON/KRW rate must raise phon_krw_rate_unavailable, got %s', COALESCE(v_msg, '<none>'));

  SELECT count(*) INTO v_rows
    FROM krw_deposit_requests
   WHERE user_id = v_uid;
  ASSERT v_rows = 0, format('missing-rate request must create no deposit rows, got %s', v_rows);

  SELECT count(*) INTO v_ledger
    FROM wallet_ledger
   WHERE user_id = v_uid
     AND reason_code = 'krw_deposit_credit';
  ASSERT v_ledger = 0, format('missing-rate request must create no deposit ledger rows, got %s', v_ledger);

  ASSERT (SELECT phon_available FROM wallets WHERE user_id = v_uid) = v_phon,
    format('missing-rate request must not change PHON balance, before=%s after=%s',
           v_phon, (SELECT phon_available FROM wallets WHERE user_id = v_uid));

  RAISE NOTICE 'KRW DEPOSIT RATE GATE OK — missing active PHON/KRW rate rejects request with no ledger movement';
END;
$$;
ROLLBACK;

-- ── Test 0b: KRW deposit request requires clear sanctions screening ──────────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_msg       TEXT;
  v_blocked   BOOLEAN := FALSE;
  v_rows      INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_no_screening_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true'
    WHERE key = 'feature_deposit_enabled';

  INSERT INTO exchange_rate_snapshots (base_currency, quote_currency, rate, source, is_active)
  VALUES ('PHON', 'KRW', '10.000000', 'test', TRUE);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  BEGIN
    PERFORM rpc_create_krw_deposit_request('10000', 'dep-no-screening-' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'sanctions_stale' THEN v_blocked := TRUE; END IF;
  END;

  ASSERT v_blocked,
    format('deposit request without clear screening must raise sanctions_stale, got %s', COALESCE(v_msg, '<none>'));

  SELECT count(*) INTO v_rows
    FROM krw_deposit_requests
   WHERE user_id = v_uid;
  ASSERT v_rows = 0, format('no-screening deposit request must create no rows, got %s', v_rows);

  RAISE NOTICE 'KRW DEPOSIT SCREENING GATE OK — no screening row blocks deposit request without residue';
END;
$$;
ROLLBACK;

-- ── Test 1: Duplicate transfer_id blocked at DB (no double PHON credit) ───────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_wallet_id UUID;
  v_dep_id    UUID;
  v_ref       TEXT := 'REFDUPE001';
  v_res1      JSONB;
  v_res2      JSONB;
  v_phon1     TEXT;
  v_phon2     TEXT;
  v_duped     BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_dupe_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET legal_name = 'Kim Minsoo', kyc_tier = 'email_verified' WHERE id = v_uid;
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_uid;

  INSERT INTO krw_deposit_requests (
    user_id, wallet_id, reference_code, amount_krw, expected_phon, status
  ) VALUES (
    v_uid, v_wallet_id, v_ref, '10000', '100.000000', 'pending'
  ) RETURNING id INTO v_dep_id;

  PERFORM set_config('request.jwt.claims', '{}', true);

  v_res1 := rpc_process_bank_transfer(
    'TXN-DUPE-001', '10000', 'Kim Minsoo', v_ref
  );
  ASSERT (v_res1->>'ok')::BOOLEAN, format('first transfer must match, got %s', v_res1);

  SELECT phon_available INTO v_phon1 FROM wallets WHERE user_id = v_uid;

  BEGIN
    v_res2 := rpc_process_bank_transfer(
      'TXN-DUPE-001', '10000', 'Kim Minsoo', v_ref
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'duplicate_transfer_id' THEN v_duped := TRUE; END IF;
  END;

  ASSERT v_duped, 'duplicate transfer_id must raise duplicate_transfer_id';

  SELECT phon_available INTO v_phon2 FROM wallets WHERE user_id = v_uid;
  ASSERT v_phon1 = v_phon2,
    format('PHON balance must not double-credit on duplicate transfer, %s vs %s', v_phon1, v_phon2);

  RAISE NOTICE 'DUPLICATE TRANSFER ID OK — idempotency blocks double PHON credit';
END;
$$;
ROLLBACK;

-- ── Test 1b: Different transfer_ids cannot match the same pending request twice ─
BEGIN;
DO $$
DECLARE
  v_uid          UUID := gen_random_uuid();
  v_wallet_id    UUID;
  v_ref          TEXT := 'REFONCE001';
  v_amount_krw   TEXT := '10000';
  v_expected_phon TEXT := '100.000000';
  v_res1         JSONB;
  v_res2         JSONB;
  v_phon_before  NUMERIC;
  v_phon_first   NUMERIC;
  v_phon_second  NUMERIC;
  v_first_delta  NUMERIC;
  v_second_delta NUMERIC;
  v_status       TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_once_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET legal_name = 'Kim Minsoo', kyc_tier = 'email_verified' WHERE id = v_uid;
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_uid;

  INSERT INTO missions (user_id, mission, phon_awarded, completed_at)
  VALUES (v_uid, 'first_deposit', '0.000000', NOW());

  INSERT INTO krw_deposit_requests (
    user_id, wallet_id, reference_code, amount_krw, expected_phon, status
  ) VALUES (
    v_uid, v_wallet_id, v_ref, v_amount_krw, v_expected_phon, 'pending'
  );

  SELECT phon_available::NUMERIC INTO v_phon_before FROM wallets WHERE user_id = v_uid;

  PERFORM set_config('request.jwt.claims', '{}', true);

  v_res1 := rpc_process_bank_transfer(
    'TXN-ONCE-001-A', v_amount_krw, 'Kim Minsoo', v_ref
  );
  ASSERT (v_res1->>'ok')::BOOLEAN, format('first transfer must match, got %s', v_res1);

  SELECT phon_available::NUMERIC INTO v_phon_first FROM wallets WHERE user_id = v_uid;
  v_first_delta := v_phon_first - v_phon_before;
  ASSERT v_first_delta = v_expected_phon::NUMERIC,
    format('first transfer must credit expected PHON delta, expected=%s got=%s',
           v_expected_phon, v_first_delta);

  SELECT status INTO v_status FROM krw_deposit_requests WHERE reference_code = v_ref;
  ASSERT v_status = 'credited', format('first transfer must credit the request, got status=%s', v_status);

  v_res2 := rpc_process_bank_transfer(
    'TXN-ONCE-001-B', v_amount_krw, 'Kim Minsoo', v_ref
  );
  ASSERT NOT (v_res2->>'ok')::BOOLEAN,
    format('second transfer against same reference must not match, got %s', v_res2);
  ASSERT (v_res2->>'reason') = 'reference_not_found',
    format('second transfer must see no pending request, got %s', v_res2);

  SELECT phon_available::NUMERIC INTO v_phon_second FROM wallets WHERE user_id = v_uid;
  v_second_delta := v_phon_second - v_phon_first;
  ASSERT v_second_delta = 0,
    format('second transfer must not add another PHON credit, second_delta=%s',
           v_second_delta);

  RAISE NOTICE 'DIFFERENT TRANSFER SAME PENDING OK — only the first match credits PHON';
END;
$$;
ROLLBACK;

-- ── Test 2: Depositor name mismatch → exception queue, no auto credit ─────────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_wallet_id UUID;
  v_ref       TEXT := 'REFNAME002';
  v_res       JSONB;
  v_phon      TEXT;
  v_exc_count INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_name_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET legal_name = 'Park Jiyoung', kyc_tier = 'email_verified' WHERE id = v_uid;
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_uid;

  SELECT phon_available INTO v_phon FROM wallets WHERE user_id = v_uid;

  INSERT INTO krw_deposit_requests (
    user_id, wallet_id, reference_code, amount_krw, expected_phon, status
  ) VALUES (
    v_uid, v_wallet_id, v_ref, '20000', '200.000000', 'pending'
  );

  PERFORM set_config('request.jwt.claims', '{}', true);

  v_res := rpc_process_bank_transfer(
    'TXN-NAME-002', '20000', 'Kim Minsoo', v_ref
  );

  ASSERT NOT (v_res->>'ok')::BOOLEAN, 'wrong depositor name must not auto-match';
  ASSERT (v_res->>'reason') = 'depositor_name_mismatch', format('expected name mismatch, got %s', v_res);

  ASSERT (SELECT phon_available FROM wallets WHERE user_id = v_uid) = v_phon,
    format('must not credit PHON on name mismatch, before=%s after=%s',
           v_phon, (SELECT phon_available FROM wallets WHERE user_id = v_uid));

  SELECT COUNT(*) INTO v_exc_count
    FROM admin_review_queue
   WHERE user_id = v_uid AND queue_type = 'deposit_exception' AND status = 'pending';
  ASSERT v_exc_count >= 1, 'name mismatch must enqueue admin exception';

  RAISE NOTICE 'NAME MISMATCH OK — exception queue, zero PHON credit';
END;
$$;
ROLLBACK;

-- ── Test 3: Exact match auto-credits PHON ─────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid   UUID := gen_random_uuid();
  v_wid   UUID;
  v_ref   TEXT := 'REFGOOD003';
  v_res   JSONB;
  v_before TEXT;
  v_after  TEXT;
  v_delta  NUMERIC;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'dep_ok_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET legal_name = 'Lee Hyun', kyc_tier = 'email_verified' WHERE id = v_uid;
  SELECT id INTO v_wid FROM wallets WHERE user_id = v_uid;

  INSERT INTO krw_deposit_requests (
    user_id, wallet_id, reference_code, amount_krw, expected_phon, status
  ) VALUES (
    v_uid, v_wid, v_ref, '30000', '300.000000', 'pending'
  );

  SELECT phon_available INTO v_before FROM wallets WHERE user_id = v_uid;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_process_bank_transfer('TXN-OK-003', '30000', 'Lee Hyun', v_ref);

  ASSERT (v_res->>'ok')::BOOLEAN, format('valid match must succeed, got %s', v_res);

  SELECT phon_available INTO v_after FROM wallets WHERE user_id = v_uid;
  v_delta := v_after::NUMERIC - v_before::NUMERIC;
  ASSERT v_delta >= 300,
    format('expected at least 300 PHON deposit credit, delta=%s', v_delta);

  ASSERT EXISTS (
    SELECT 1 FROM krw_deposit_requests
     WHERE reference_code = v_ref AND status = 'credited'
  ), 'deposit request must reach credited status';

  RAISE NOTICE 'AUTO MATCH OK — reference+amount+name exact credits PHON';
END;
$$;
ROLLBACK;
