-- ============================================================
-- Casino schema — SQL integration test
-- ============================================================
-- Guards migrations 000028–000029. Proves atomic place+settle,
-- conservation, idempotency scope, exposure cap, parity hold, stale sweep,
-- reveal, and privilege boundaries.
-- ============================================================

-- ── 1. Atomic place+settle keeps Σ=0 and releases locked stake ────────────────
BEGIN;
DO $$
DECLARE
  v_uid          UUID := gen_random_uuid();
  v_round_id     UUID;
  v_bet          JSONB;
  v_server_seed  TEXT := 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';
  v_grand_before NUMERIC;
  v_grand_after  NUMERIC;
  v_locked_after NUMERIC;
  v_house_rows   INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled', 'consent_gate_enabled');

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', v_server_seed)->>'round_id')::UUID;

  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_grand_before;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_bet := rpc_place_game_bet(
    v_round_id, 'PHON', '100.000000',
    '{"target": "50.00", "direction": "over"}'::JSONB,
    'my_client_seed', 'casino_test_idem_' || v_uid::TEXT
  );

  ASSERT (v_bet->>'already_placed')::BOOLEAN = FALSE, 'should not be already placed';
  ASSERT v_bet->>'status' IN ('won', 'lost'), 'atomic place must terminally settle';

  SELECT
    (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON')
  INTO v_grand_after;
  ASSERT v_grand_after = v_grand_before,
    format('Σ=0 violated after bet placement: before=%s after=%s', v_grand_before, v_grand_after);

  SELECT phon_locked::NUMERIC INTO v_locked_after FROM wallets WHERE user_id = v_uid;
  ASSERT v_locked_after = 0,
    format('stake lock should be released by atomic settlement, got %s', v_locked_after);

  SELECT count(*) INTO v_house_rows
  FROM system_account_ledger
  WHERE account_code = 'game_house_phon' AND related_user_id = v_uid;
  ASSERT v_house_rows = 1, 'house leg must be recorded exactly once';

  RAISE NOTICE 'CASINO ATOMIC SETTLEMENT OK — terminal status, lock released, Σ=0 intact';
END;
$$;
ROLLBACK;

-- ── 1b. Client path: open committed round, place atomically, reveal seed ───────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_round     JSONB;
  v_round_id  UUID;
  v_bet       JSONB;
  v_reveal    JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_client_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;

  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled', 'consent_gate_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_round := rpc_open_game_round('dice');
  v_round_id := (v_round->>'round_id')::UUID;

  ASSERT v_round ? 'server_seed_hash', 'client round must expose seed hash';
  ASSERT NOT (v_round ? 'server_seed'), 'client round must not expose server_seed';
  ASSERT length(v_round->>'server_seed_hash') = 64, 'server seed hash must be sha256 hex';

  v_bet := rpc_place_game_bet(
    v_round_id, 'PHON', '25.000000',
    '{"target": "50.00", "direction": "over"}'::JSONB,
    'client_path_seed', 'client_path_' || v_uid::TEXT
  );
  ASSERT v_bet->>'status' IN ('won', 'lost'), 'client path must terminally settle';
  ASSERT v_bet->>'server_seed_hash' = v_round->>'server_seed_hash',
    'place result must carry the committed hash';

  v_reveal := rpc_reveal_game_round(v_round_id);
  ASSERT v_reveal->>'server_seed_hash' = v_round->>'server_seed_hash',
    'reveal hash must match commitment';
  ASSERT encode(extensions.digest(v_reveal->>'server_seed', 'sha256'), 'hex') = v_round->>'server_seed_hash',
    'revealed seed must hash to commitment';
  ASSERT v_reveal->'result' = v_bet->'result', 'reveal result must match settled result';

  RAISE NOTICE 'CASINO CLIENT ROUND OK — hash before bet, atomic settle, reveal verifies';
END;
$$;
ROLLBACK;

-- ── 2. Idempotency is scoped by user_id + idempotency_key ─────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_uid2    UUID := gen_random_uuid();
  v_round_id UUID;
  v_round_id2 UUID;
  v_bet1    JSONB;
  v_bet2    JSONB;
  v_bet3    JSONB;
  v_server_seed TEXT := 'testserver123456789012345678901234567890abcdef';
  v_idem_key TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_idem_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid2, 'authenticated', 'authenticated',
          'casino_idem_' || v_uid2::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id IN (v_uid, v_uid2);
  UPDATE app_config SET value = 'false'
    WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled');

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', v_server_seed)->>'round_id')::UUID;
  v_round_id2 := (rpc_create_game_round('dice', v_server_seed || '_other')->>'round_id')::UUID;

  v_idem_key := 'idem_test_' || v_uid::TEXT;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  v_bet1 := rpc_place_game_bet(v_round_id, 'PHON', '50.000000',
    '{"target":"40.00","direction":"over"}'::JSONB, 'cs', v_idem_key);
  v_bet2 := rpc_place_game_bet(v_round_id, 'PHON', '50.000000',
    '{"target":"40.00","direction":"over"}'::JSONB, 'cs', v_idem_key);

  ASSERT (v_bet2->>'already_placed')::BOOLEAN = TRUE,
    'second call with same idem_key must return already_placed=true';
  ASSERT (v_bet1->>'bet_id') = (v_bet2->>'bet_id'),
    'both calls must return the same bet_id';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid2::TEXT)::TEXT, true);
  v_bet3 := rpc_place_game_bet(v_round_id2, 'PHON', '50.000000',
    '{"target":"40.00","direction":"over"}'::JSONB, 'cs', v_idem_key);
  ASSERT (v_bet3->>'already_placed')::BOOLEAN = FALSE,
    'same idempotency key must be accepted for a different user';

  RAISE NOTICE 'CASINO IDEMPOTENCY OK — duplicate user key returns existing, cross-user key is independent';
END;
$$;
ROLLBACK;

-- ── 3. Seed hash mismatch is rejected at round creation ───────────────────────
BEGIN;
DO $$
DECLARE
  v_rejected BOOLEAN := FALSE;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);
  BEGIN
    PERFORM rpc_create_game_round('dice', 'correct_seed_value_for_validation', repeat('0', 64));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'seed_hash_mismatch' THEN v_rejected := TRUE; END IF;
  END;

  ASSERT v_rejected, 'mismatched seed hash must be rejected with seed_hash_mismatch';

  RAISE NOTICE 'SEED HASH COMMITMENT OK — mismatched seed/hash rejected';
END;
$$;
ROLLBACK;

-- ── 4. Exposure cap rejects oversized maximum payout ──────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_round_id UUID;
  v_rejected BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_cap_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled');
  UPDATE app_config SET value = '10.000000' WHERE key = 'casino_max_payout_phon';
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', 'cap_seed_value_for_validation')->>'round_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  BEGIN
    PERFORM rpc_place_game_bet(v_round_id, 'PHON', '100.000000',
      '{"target":"50.00","direction":"over"}'::JSONB, 'cs', 'cap_idem_' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'house_exposure_cap' THEN v_rejected := TRUE; END IF;
  END;

  ASSERT v_rejected, 'exposure cap must reject oversized max payout';
  RAISE NOTICE 'CASINO EXPOSURE CAP OK — oversized max payout rejected';
END;
$$;
ROLLBACK;

-- ── 5. Parity mismatch creates hold and kills only the affected game ──────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_round_id UUID;
  v_bet JSONB;
  v_locked NUMERIC;
  v_flag TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_parity_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', 'parity_seed_value_for_validation')->>'round_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_bet := rpc_place_game_bet(
    v_round_id, 'PHON', '10.000000',
    '{"target":"50.00","direction":"over"}'::JSONB,
    'cs', 'parity_idem_' || v_uid::TEXT,
    '{"roll":0,"won":false}'::JSONB
  );

  ASSERT v_bet->>'status' = 'parity_hold', 'parity mismatch must return parity_hold';
  SELECT phon_locked::NUMERIC INTO v_locked FROM wallets WHERE user_id = v_uid;
  ASSERT v_locked = 10, 'parity_hold must keep stake locked';
  SELECT value INTO v_flag FROM app_config WHERE key = 'feature_game_dice_enabled';
  ASSERT v_flag = 'false', 'parity mismatch must disable affected game';
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs WHERE action = 'parity_mismatch' AND entity_type = 'game_bets'
  ), 'parity mismatch audit row missing';

  RAISE NOTICE 'CASINO PARITY HOLD OK — kill switch, audit, and locked funds retained';
END;
$$;
ROLLBACK;

-- ── 6. Stale sweep cancels non-parity pending bets only ───────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_round_id UUID;
  v_bet_id UUID := gen_random_uuid();
  v_lock_id UUID;
  v_sweep JSONB;
  v_status bet_status;
  v_locked NUMERIC;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_stale_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', 'stale_seed_value_for_validation')->>'round_id')::UUID;

  v_lock_id := _lock_wallet_internal(v_uid, 'PHON', '25.000000', 'game_stale_fixture_lock', 'stale_lock:' || v_bet_id::TEXT);
  INSERT INTO game_bets (
    id, round_id, user_id, game, currency, stake, selection, client_seed, nonce,
    status, idempotency_key, stake_lock_id, created_at
  ) VALUES (
    v_bet_id, v_round_id, v_uid, 'dice', 'PHON', '25.000000',
    '{"target":"50.00","direction":"over"}'::JSONB, 'cs', 1,
    'pending', 'stale_idem_' || v_uid::TEXT, v_lock_id, NOW() - INTERVAL '30 minutes'
  );

  v_sweep := rpc_sweep_stale_game_bets();
  ASSERT (v_sweep->>'cancelled')::INT = 1, 'stale sweep must cancel one pending bet';
  SELECT status INTO v_status FROM game_bets WHERE id = v_bet_id;
  ASSERT v_status = 'cancelled', 'stale bet must be cancelled';
  SELECT phon_locked::NUMERIC INTO v_locked FROM wallets WHERE user_id = v_uid;
  ASSERT v_locked = 0, 'stale sweep must unlock stake';

  RAISE NOTICE 'CASINO STALE SWEEP OK — old non-parity pending bet cancelled and unlocked';
END;
$$;
ROLLBACK;

-- ── 7. Reveal returns seed only after settlement ──────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_round_id UUID;
  v_reveal JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'casino_reveal_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'feature_game_dice_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_round_id := (rpc_create_game_round('dice', 'reveal_seed_value_for_validation')->>'round_id')::UUID;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  PERFORM rpc_place_game_bet(v_round_id, 'PHON', '10.000000',
    '{"target":"50.00","direction":"over"}'::JSONB, 'cs', 'reveal_idem_' || v_uid::TEXT);

  v_reveal := rpc_reveal_game_round(v_round_id);
  ASSERT v_reveal->>'server_seed' = 'reveal_seed_value_for_validation',
    'reveal must return committed server seed after settlement';

  RAISE NOTICE 'CASINO REVEAL OK — seed revealed after terminal settlement';
END;
$$;
ROLLBACK;

-- ── 8. Privilege lock for service/admin-only paths ────────────────────────────
BEGIN;
DO $$
BEGIN
  ASSERT NOT has_function_privilege(
    'authenticated', 'public.rpc_create_game_round(text,text,text)', 'EXECUTE'),
    'authenticated must NOT execute rpc_create_game_round';
  ASSERT has_function_privilege(
    'service_role', 'public.rpc_create_game_round(text,text,text)', 'EXECUTE'),
    'service_role must execute rpc_create_game_round';

  ASSERT NOT has_function_privilege(
    'authenticated', 'public.rpc_settle_game_bet(uuid,text)', 'EXECUTE'),
    'authenticated must NOT execute rpc_settle_game_bet';
  ASSERT has_function_privilege(
    'service_role', 'public.rpc_settle_game_bet(uuid,text)', 'EXECUTE'),
    'service_role must execute rpc_settle_game_bet';

  ASSERT has_function_privilege(
    'authenticated', 'public.rpc_place_game_bet(uuid,text,text,jsonb,text,text,jsonb)', 'EXECUTE'),
    'authenticated must execute rpc_place_game_bet';
  ASSERT NOT has_function_privilege(
    'anon', 'public.rpc_place_game_bet(uuid,text,text,jsonb,text,text,jsonb)', 'EXECUTE'),
    'anon must not execute rpc_place_game_bet';

  ASSERT has_function_privilege(
    'authenticated', 'public.rpc_open_game_round(text)', 'EXECUTE'),
    'authenticated must execute rpc_open_game_round';
  ASSERT NOT has_function_privilege(
    'anon', 'public.rpc_open_game_round(text)', 'EXECUTE'),
    'anon must not execute rpc_open_game_round';

  RAISE NOTICE 'CASINO PRIVILEGE LOCK OK — create/settle locked, open/place authenticated only';
END;
$$;
ROLLBACK;
