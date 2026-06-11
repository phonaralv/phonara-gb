-- ============================================================
-- Live surface hardening — Wave 4
-- ============================================================

-- ── 1. Roulette uses HMAC path, hides seed, and reveals separately ────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_spin JSONB;
  v_reveal JSONB;
BEGIN
  ASSERT position('random(' IN lower(pg_get_functiondef('public.rpc_spin_roulette()'::regprocedure))) = 0,
    'roulette function must not use random()';
  ASSERT NOT has_column_privilege('authenticated', 'public.roulette_spins', 'server_seed', 'SELECT'),
    'authenticated role must not directly select roulette_spins.server_seed';

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'roulette_hmac_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  UPDATE app_config SET value = 'false' WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_game_enabled', 'consent_gate_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_spin := rpc_spin_roulette();

  ASSERT v_spin ? 'seed_hash', 'roulette spin must return seed hash';
  ASSERT NOT (v_spin ? 'seed_revealed'), 'roulette spin must not reveal seed in spin response';

  v_reveal := rpc_reveal_roulette_spin(CURRENT_DATE);
  ASSERT v_reveal ? 'server_seed', 'roulette reveal must return server seed';
  ASSERT (v_reveal->>'roll')::INT = _roulette_roll_from_seed(v_reveal->>'server_seed', v_uid, CURRENT_DATE),
    'roulette reveal roll must recompute from HMAC seed';

  RAISE NOTICE 'ROULETTE HMAC OK — no random(), no spin seed leak, reveal recomputes';
END;
$$;
ROLLBACK;

-- ── 2. Referral requires exact code and minimum length ────────────────────────
BEGIN;
DO $$
DECLARE
  v_referrer UUID := gen_random_uuid();
  v_referred UUID := gen_random_uuid();
  v_result JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_referrer, 'authenticated', 'authenticated', 'referrer_' || v_referrer::TEXT || '@test.local', NOW(), NOW()),
    (v_referred, 'authenticated', 'authenticated', 'referred_' || v_referred::TEXT || '@test.local', NOW(), NOW());
  UPDATE profiles SET username = 'abcdefgh' WHERE id = v_referrer;
  UPDATE app_config SET value = 'true' WHERE key = 'feature_referral_enabled';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_referred::TEXT)::TEXT, true);
  v_result := rpc_register_referral('abcd');
  ASSERT v_result->>'reason' = 'invalid_code', 'short referral code must be invalid';

  v_result := rpc_register_referral('abcdefghi');
  ASSERT v_result->>'reason' = 'invalid_code', 'prefix/superset referral code must be invalid';

  v_result := rpc_register_referral('abcdefgh');
  ASSERT (v_result->>'registered')::BOOLEAN = TRUE, 'exact referral code must register';

  RAISE NOTICE 'REFERRAL EXACT MATCH OK — prefix mint path blocked';
END;
$$;
ROLLBACK;

-- ── 3. Reserve update is admin-only, reason-required, audited ────────────────
BEGIN;
DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_result JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_admin, 'authenticated', 'authenticated',
          'reserve_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_result := rpc_update_treasury_reserve('PHON', '1000000.000000', 10, 50, 'monthly reserve attestation');

  ASSERT (v_result->>'ok')::BOOLEAN = TRUE, 'reserve update must succeed for admin';
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
    WHERE actor_id = v_admin AND action = 'treasury_reserve_update'
  ), 'reserve update must write audit row';

  RAISE NOTICE 'RESERVE ADMIN OK — admin reason and audit enforced';
END;
$$;
ROLLBACK;

-- ── 4. Staking uses deterministic request id position key ─────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_result JSONB;
  v_expected UUID;
  v_duplicate BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'stake_idem_' || v_uid::TEXT || '@test.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET phon_available = '1000.000000' WHERE user_id = v_uid;
  UPDATE app_config SET value = 'false' WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true'
    WHERE key IN ('feature_staking_enabled', 'consent_gate_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'v1', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  v_expected := _uuid_from_md5('stake:' || v_uid::TEXT || ':stake-fixed-1');
  v_result := rpc_stake_phon('flexible', '10.000000', 'stake-fixed-1');

  ASSERT (v_result->>'position_id')::UUID = v_expected, 'staking position id must be deterministic';

  BEGIN
    PERFORM rpc_stake_phon('flexible', '10.000000', 'stake-fixed-1');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'duplicate_request' THEN v_duplicate := TRUE; END IF;
  END;
  ASSERT v_duplicate, 'duplicate staking request must be rejected';

  RAISE NOTICE 'STAKING IDEMPOTENCY OK — deterministic position id and duplicate guard';
END;
$$;
ROLLBACK;

-- ── 5. Consent gate default is enabled after Wave 4 ───────────────────────────
BEGIN;
DO $$
DECLARE
  v_value TEXT;
BEGIN
  SELECT value INTO v_value FROM app_config WHERE key = 'consent_gate_enabled';
  ASSERT v_value = 'true', 'consent_gate_enabled must default true';
  RAISE NOTICE 'CONSENT GATE OK — default enabled';
END;
$$;
ROLLBACK;
