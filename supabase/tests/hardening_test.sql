-- ============================================================
-- P0 Hardening — SQL integration tests (DB-level, real RPCs)
-- ============================================================
-- Complements conservation_test.sql. Each feature is verified against the live
-- database with the ACTUAL functions/RPCs. Every sub-test runs in its own
-- transaction and ROLLBACKs, so the script leaves no residue.
--
-- HOW TO RUN (Postgres with all migrations applied):
--   Get-Content supabase/tests/hardening_test.sql -Raw |
--     docker exec -i <supabase_db_container> psql -U postgres -d postgres -v ON_ERROR_STOP=1
--
-- Covered: A2 auto-liquidation + bad-debt conservation, A3 circuit-breaker
-- persistence, A4 hash-chain tamper detection, A5 rate limit, B1 consent gate.
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: Circuit breaker triggers AND persists the halt (no RAISE rollback)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_res    JSONB;
  v_halted BOOLEAN;
  v_price  TEXT;
  v_audit  INT;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);  -- service role (auth.uid() = NULL)

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol = 'PHONUSDT-PERP';

  -- +20% move exceeds the 10% max_tick → must halt
  v_res := rpc_update_oracle_price('PHONUSDT-PERP', '0.012000', 'test', 'cron');

  ASSERT (v_res->>'circuit_breaker_triggered')::BOOLEAN, 'CB flag not set in result';

  SELECT is_halted INTO v_halted FROM market_circuit_breakers WHERE symbol = 'PHONUSDT-PERP';
  ASSERT v_halted, 'halt was NOT persisted (RAISE rollback regression)';

  SELECT price INTO v_price FROM oracle_prices WHERE symbol = 'PHONUSDT-PERP';
  ASSERT v_price = '0.010000', 'rejected price WAS applied: ' || v_price;

  SELECT count(*) INTO v_audit FROM price_change_audit
  WHERE symbol = 'PHONUSDT-PERP' AND circuit_breaker_triggered;
  ASSERT v_audit >= 1, 'CB audit row missing';

  RAISE NOTICE 'A3 CIRCUIT BREAKER OK — halt persisted, price rejected, audit logged';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4: Hash-chain tamper detection
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_lid    UUID;
  v_broken INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'h_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  PERFORM rpc_spot_market_buy('100.000000');  -- creates hash-chained ledger rows

  ASSERT NOT EXISTS (SELECT 1 FROM verify_ledger_hash_chain(v_uid)),
    'chain reported broken BEFORE tamper';

  -- Tamper with an amount (append-only rule must be bypassed for the attack sim)
  ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
  SELECT id INTO v_lid FROM wallet_ledger WHERE user_id = v_uid ORDER BY seq LIMIT 1;
  UPDATE wallet_ledger SET amount = (amount::NUMERIC + 1)::TEXT WHERE id = v_lid;
  ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

  SELECT count(*) INTO v_broken FROM verify_ledger_hash_chain(v_uid);
  ASSERT v_broken >= 1, 'tamper was NOT detected';

  RAISE NOTICE 'A4 HASH-CHAIN TAMPER DETECTED OK — broken rows=%', v_broken;
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b: v2 payload binds balance snapshot + reason_code (not just amount)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_lid    UUID;
  v_broken INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'h2_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  PERFORM rpc_spot_market_buy('100.000000');

  ASSERT NOT EXISTS (SELECT 1 FROM verify_ledger_hash_chain(v_uid)),
    'chain reported broken BEFORE tamper';

  -- (1) Tamper ONLY the balance snapshot. Under v1 this was unsigned and would
  -- have passed; under v2 it must break the chain.
  ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
  SELECT id INTO v_lid FROM wallet_ledger WHERE user_id = v_uid ORDER BY seq LIMIT 1;
  UPDATE wallet_ledger SET available_after = (available_after::NUMERIC + 1)::TEXT WHERE id = v_lid;
  ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

  SELECT count(*) INTO v_broken FROM verify_ledger_hash_chain(v_uid);
  ASSERT v_broken >= 1, 'available_after tamper was NOT detected (v2 payload regression)';
  RAISE NOTICE 'A4b balance-snapshot tamper detected OK — broken rows=%', v_broken;
END;
$$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_lid    UUID;
  v_broken INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'h3_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  PERFORM rpc_spot_market_buy('100.000000');

  -- (2) Tamper ONLY the reason_code.
  ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
  SELECT id INTO v_lid FROM wallet_ledger WHERE user_id = v_uid ORDER BY seq LIMIT 1;
  UPDATE wallet_ledger SET reason_code = reason_code || '_tampered' WHERE id = v_lid;
  ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

  SELECT count(*) INTO v_broken FROM verify_ledger_hash_chain(v_uid);
  ASSERT v_broken >= 1, 'reason_code tamper was NOT detected (v2 payload regression)';
  RAISE NOTICE 'A4b reason_code tamper detected OK — broken rows=%', v_broken;
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4c: Global system-live guard (halt / read-only) blocks balance-moving RPCs
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_halted  BOOLEAN := FALSE;
  v_ro      BOOLEAN := FALSE;
  v_ok      BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'live_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  -- (1) Hard halt → system_halted
  UPDATE app_config SET value = 'true' WHERE key = 'system_halt';
  BEGIN
    PERFORM rpc_spot_market_buy('10.000000');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%system_halted%' THEN v_halted := TRUE; END IF;
  END;
  ASSERT v_halted, 'system_halt did NOT block rpc_spot_market_buy';

  -- (2) Read-only (halt off) → system_readonly
  UPDATE app_config SET value = 'false' WHERE key = 'system_halt';
  UPDATE app_config SET value = 'true'  WHERE key = 'system_readonly';
  BEGIN
    PERFORM rpc_spot_market_buy('10.000000');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%system_readonly%' THEN v_ro := TRUE; END IF;
  END;
  ASSERT v_ro, 'system_readonly did NOT block rpc_spot_market_buy';

  -- (3) Both off → trade succeeds again
  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';
  BEGIN
    PERFORM rpc_spot_market_buy('10.000000');
    v_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := FALSE;
  END;
  ASSERT v_ok, 'trade failed even though system is live';

  RAISE NOTICE 'A4c SYSTEM-LIVE GUARD OK — halt blocks, readonly blocks, live passes';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4d: Per-feature kill switch blocks only its own surface
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid       UUID := gen_random_uuid();
  v_blocked   BOOLEAN := FALSE;
  v_spot_ok   BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'feat_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000.000000', phon_available = '1000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  -- Disable futures only
  UPDATE app_config SET value = 'false' WHERE key = 'feature_futures_enabled';

  BEGIN
    PERFORM rpc_open_futures_position('PHON_USDT', 'long', 'USDT', '10.000000', '2', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%feature_disabled%' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'futures kill switch did NOT block rpc_open_futures_position';

  -- Spot must still work (different feature flag)
  BEGIN
    PERFORM rpc_spot_market_buy('10.000000');
    v_spot_ok := TRUE;
  EXCEPTION WHEN OTHERS THEN
    v_spot_ok := FALSE;
  END;
  ASSERT v_spot_ok, 'spot was blocked even though only futures kill switch was set';

  RAISE NOTICE 'A4d FEATURE KILL SWITCH OK — futures off blocks futures, spot still live';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4e: Position count cap + market open-interest cap
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_capped  BOOLEAN := FALSE;
  v_oi_hit  BOOLEAN := FALSE;
  v_null_oi_rejected BOOLEAN := FALSE;
  v_count   INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'cap_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  -- (0) Active markets must never have an unbounded OI cap.
  BEGIN
    UPDATE futures_markets SET max_open_interest = NULL WHERE symbol = 'PHONUSDT-PERP';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%fm_active_oi_required%' THEN v_null_oi_rejected := TRUE; END IF;
  END;
  ASSERT v_null_oi_rejected, 'active market accepted NULL max_open_interest';

  -- (1) Per-user count cap: set market user cap to 1, second open must fail.
  UPDATE futures_markets SET max_user_positions = 1, max_open_interest = '1000000.000000' WHERE symbol = 'PHONUSDT-PERP';
  PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL);
  BEGIN
    PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%position_limit%' THEN v_capped := TRUE; END IF;
  END;
  ASSERT v_capped, 'per-user position cap did NOT block the 2nd open';

  -- (2) Market OI cap boundary: exactly at cap is allowed; crossing cap fails.
  UPDATE futures_markets SET max_user_positions = 100, max_open_interest = '40.000000' WHERE symbol = 'PHONUSDT-PERP';
  PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL);
  SELECT COUNT(*) INTO v_count FROM futures_positions WHERE user_id = v_uid;
  ASSERT v_count = 2, 'position at exact OI cap should be allowed';

  BEGIN
    PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%market_oi_cap%' THEN v_oi_hit := TRUE; END IF;
  END;
  ASSERT v_oi_hit, 'market OI cap did NOT block an over-cap open';

  RAISE NOTICE 'A4e POSITION/OI CAP OK — user cap blocks, active NULL rejected, OI boundary holds';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4f: Request idempotency — same client_request_id blocks the 2nd entry
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_req    TEXT := 'idem-' || gen_random_uuid()::TEXT;
  v_dup    BOOLEAN := FALSE;
  v_count  INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'idem_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();
  UPDATE futures_markets SET max_user_positions = 100, max_open_interest = '1000000.000000' WHERE symbol = 'PHONUSDT-PERP';

  -- First call with a request id succeeds (8th arg = p_client_request_id).
  PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL, v_req);
  -- Second call reusing the SAME request id must be rejected.
  BEGIN
    PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL, v_req);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%duplicate_request%' THEN v_dup := TRUE; END IF;
  END;
  ASSERT v_dup, 'duplicate client_request_id did NOT block the 2nd open';

  SELECT COUNT(*) INTO v_count FROM futures_positions WHERE user_id = v_uid;
  ASSERT v_count = 1, 'expected exactly 1 position after duplicate submit, got ' || v_count;

  -- A fresh request id is a distinct intent and is allowed.
  PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL, 'idem-' || gen_random_uuid()::TEXT);
  SELECT COUNT(*) INTO v_count FROM futures_positions WHERE user_id = v_uid;
  ASSERT v_count = 2, 'fresh request id should open a new position, got ' || v_count;

  RAISE NOTICE 'A4f REQUEST IDEMPOTENCY OK — duplicate id blocked, fresh id allowed';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4g: Market min_notional is enforced on futures and spot entry RPCs
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_blocked BOOLEAN;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'min_notional_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '1000000.000000', phon_available = '1000000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';
  UPDATE app_config SET value = 'true' WHERE key IN ('feature_futures_enabled', 'feature_spot_enabled');

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES
    ('PHONUSDT-PERP', '1.000000', NOW()),
    ('PHON_USDT', '1.000000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = EXCLUDED.price, updated_at = NOW();
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol IN ('PHONUSDT-PERP', 'PHON_USDT');
  UPDATE futures_markets
     SET is_active = TRUE,
         max_user_positions = 100,
         max_open_interest = '1000000.000000',
         max_leverage = '10',
         min_notional = '10.000000'
   WHERE symbol = 'PHONUSDT-PERP';
  UPDATE spot_markets
     SET is_active = TRUE,
         min_notional = '10.000000'
   WHERE symbol = 'PHON_USDT';

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_open_futures_position(
      'PHONUSDT-PERP', 'long', 'USDT', '4.000000', '2', NULL, NULL,
      'below-min-futures-' || v_uid::TEXT
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'below_min_notional' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked,
    format('futures open below min_notional must raise below_min_notional, got %s', COALESCE(v_msg, '<none>'));

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_spot_market_buy('5.000000', 'below-min-spot-buy-' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'below_min_notional' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked,
    format('spot buy below min_notional must raise below_min_notional, got %s', COALESCE(v_msg, '<none>'));

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_spot_market_sell('5.000000', 'below-min-spot-sell-' || v_uid::TEXT);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg = 'below_min_notional' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked,
    format('spot sell below min_notional must raise below_min_notional, got %s', COALESCE(v_msg, '<none>'));

  PERFORM rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '5.000000', '2', NULL, NULL,
    'at-min-futures-' || v_uid::TEXT);
  PERFORM rpc_spot_market_buy('10.000000', 'at-min-spot-buy-' || v_uid::TEXT);
  PERFORM rpc_spot_market_sell('10.000000', 'at-min-spot-sell-' || v_uid::TEXT);

  RAISE NOTICE 'MIN NOTIONAL OK — futures and spot reject below min_notional and allow exact boundary';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5: Rate limit blocks after capacity is exhausted
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  i        INT;
  v_cap    INT;
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'r_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  SELECT capacity INTO v_cap FROM rpc_rate_limit_configs WHERE rpc_name = 'rpc_open_futures_position';

  FOR i IN 1..v_cap LOOP
    PERFORM _enforce_rate_limit(v_uid, 'rpc_open_futures_position');  -- consume all tokens
  END LOOP;

  BEGIN
    PERFORM _enforce_rate_limit(v_uid, 'rpc_open_futures_position');  -- one over capacity
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%rate_limit_exceeded%' THEN v_raised := TRUE; END IF;
  END;

  ASSERT v_raised, 'rate limit did not trigger after capacity';
  RAISE NOTICE 'A5 RATE LIMIT OK — blocked after % calls', v_cap;
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1: Consent gate blocks entry without consent, allows after consent (flag on)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'c_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  UPDATE app_config SET value = 'true' WHERE key = 'consent_gate_enabled';

  BEGIN
    PERFORM _assert_onboarding_consent(v_uid);  -- no consents → blocked
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%consent_required%' THEN v_raised := TRUE; END IF;
  END;
  ASSERT v_raised, 'consent gate did NOT block without consent';

  INSERT INTO user_consents (user_id, doc_type, accepted) VALUES
    (v_uid, 'terms_of_service', TRUE),
    (v_uid, 'privacy_policy',   TRUE),
    (v_uid, 'risk_disclosure',  TRUE),
    (v_uid, 'age_verification', TRUE);

  PERFORM _assert_onboarding_consent(v_uid);  -- now allowed (no exception)

  RAISE NOTICE 'B1 CONSENT GATE OK — blocked then allowed';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2: Auto-liquidation of an underwater position + bad-debt conservation
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_pos    JSONB;
  v_pid    UUID;
  v_before NUMERIC;
  v_after  NUMERIC;
  v_status position_status;
  v_baddebt NUMERIC;
  v_res    JSONB;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'l_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '100000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol = 'PHONUSDT-PERP';
  UPDATE futures_markets SET is_active = TRUE WHERE symbol = 'PHONUSDT-PERP';

  SELECT (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
       + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
    INTO v_before;

  v_pos := rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '1000.000000', '10');
  v_pid := (v_pos->>'position_id')::UUID;

  -- Gap-down crash below the liquidation price (direct update simulates a gap that
  -- bypasses the per-tick circuit breaker). Equity goes negative → bad debt path.
  UPDATE oracle_prices SET price = '0.009000', updated_at = NOW() WHERE symbol = 'PHONUSDT-PERP';

  -- Service-role sweep
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := rpc_run_liquidations();

  SELECT status INTO v_status FROM futures_positions WHERE id = v_pid;
  ASSERT v_status = 'liquidated', 'position not liquidated: ' || v_status::TEXT;

  SELECT (payload->>'bad_debt')::NUMERIC INTO v_baddebt
  FROM position_ledger WHERE position_id = v_pid AND event = 'auto_liquidate' LIMIT 1;
  ASSERT v_baddebt > 0, 'expected bad debt > 0 on gap liquidation';

  SELECT (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
       + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
    INTO v_after;
  ASSERT v_after = v_before,
    format('USDT not conserved through bad-debt liquidation: %s -> %s', v_before, v_after);

  RAISE NOTICE 'A2 AUTO-LIQUIDATION + BAD-DEBT CONSERVATION OK — liquidated=%, bad_debt=%',
    v_res->>'liquidated', v_baddebt;
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2b: Liquidation cron runner is scheduled + logged wrapper writes on activity
-- (migration 000015)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid     UUID := gen_random_uuid();
  v_pos     JSONB;
  v_pid     UUID;
  v_status  position_status;
  v_logged  INT;
  v_jobs    INT;
BEGIN
  -- The cron jobs must be registered exactly once after explicit unschedule +
  -- schedule re-registration in the final hardening migration.
  SELECT count(*) INTO v_jobs FROM cron.job WHERE jobname = 'phonara_auto_liquidations';
  ASSERT v_jobs = 1, 'pg_cron liquidation job not scheduled';
  SELECT count(*) INTO v_jobs FROM cron.job WHERE jobname = 'phonara_daily_reconciliation';
  ASSERT v_jobs = 1, 'pg_cron reconciliation job not scheduled exactly once';
  SELECT count(*) INTO v_jobs FROM cron.job WHERE jobname = 'phonara_casino_stale_pending_sweep';
  ASSERT v_jobs = 1, 'pg_cron stale casino bet sweep not scheduled exactly once';

  -- Drive a real gap-liquidation through the LOGGED wrapper (the exact path the
  -- cron job invokes) and assert it persists an actionable log row.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'lc_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '100000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol = 'PHONUSDT-PERP';
  UPDATE futures_markets SET is_active = TRUE WHERE symbol = 'PHONUSDT-PERP';

  v_pos := rpc_open_futures_position('PHONUSDT-PERP', 'long', 'USDT', '1000.000000', '10');
  v_pid := (v_pos->>'position_id')::UUID;

  UPDATE oracle_prices SET price = '0.009000', updated_at = NOW() WHERE symbol = 'PHONUSDT-PERP';

  -- Service-role context (auth.uid() = NULL), exactly like the cron session.
  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM _run_liquidations_logged();

  SELECT status INTO v_status FROM futures_positions WHERE id = v_pid;
  ASSERT v_status = 'liquidated', 'logged wrapper did not liquidate: ' || v_status::TEXT;

  SELECT count(*) INTO v_logged FROM liquidation_run_log WHERE liquidated >= 1;
  ASSERT v_logged >= 1, 'liquidation_run_log did not record the actionable sweep';

  RAISE NOTICE 'A2b CRON RUNNER OK — job scheduled, logged wrapper liquidated + logged';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL HELPER AMOUNT GUARDS: direct helper calls reject <= 0 amounts
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid        UUID := gen_random_uuid();
  v_before     NUMERIC;
  v_after      NUMERIC;
  v_msg        TEXT;
  v_blocked    BOOLEAN := FALSE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'helper_guard_' || v_uid::TEXT || '@t.local', NOW(), NOW());

  PERFORM set_config('request.jwt.claims', '{}', true);
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET phon_available = '100.000000' WHERE user_id = v_uid;
  SELECT phon_available::NUMERIC INTO v_before FROM wallets WHERE user_id = v_uid;

  BEGIN
    PERFORM _debit_wallet_internal(
      v_uid,
      'PHON',
      '-1.000000',
      'helper_negative_probe',
      'helper-negative-debit:' || v_uid::TEXT
    );
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
    IF v_msg = 'invalid_amount' THEN
      v_blocked := TRUE;
    END IF;
  END;

  SELECT phon_available::NUMERIC INTO v_after FROM wallets WHERE user_id = v_uid;

  ASSERT v_blocked,
    format('negative _debit_wallet_internal must raise invalid_amount, got %s', COALESCE(v_msg, '<none>'));
  ASSERT v_after = v_before,
    format('negative _debit_wallet_internal changed balance from %s to %s', v_before, v_after);

  RAISE NOTICE 'INTERNAL HELPER AMOUNT GUARD OK — negative direct debit blocked with invalid_amount';
END;
$$;
ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- INPUT GUARD: entry RPCs reject NaN/Infinity/garbage amounts (migration 000016)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;
DO $$
DECLARE
  v_uid    UUID := gen_random_uuid();
  v_cases  TEXT[] := ARRAY['NaN','Infinity','-Infinity','1e5','-5','abc',''];
  v_c      TEXT;
  v_raised BOOLEAN;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'ig_' || v_uid::TEXT || '@t.local', NOW(), NOW());
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET usdt_available = '100000.000000', phon_available = '100000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);
  UPDATE app_config SET value = 'false' WHERE key = 'consent_gate_enabled';

  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHON_USDT', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();
  UPDATE spot_markets SET is_active = TRUE WHERE symbol = 'PHON_USDT';

  -- Spot buy must reject every malformed amount (NaN/Infinity must NOT bypass <=0).
  FOREACH v_c IN ARRAY v_cases LOOP
    v_raised := FALSE;
    BEGIN
      PERFORM rpc_spot_market_buy(v_c);
    EXCEPTION WHEN OTHERS THEN
      v_raised := TRUE;  -- invalid_amount (or numeric syntax error) — both reject
    END;
    ASSERT v_raised, format('spot buy accepted malformed amount %L', v_c);
  END LOOP;

  -- The direct text guard rejects the dangerous finite-bypass values.
  v_raised := FALSE;
  BEGIN PERFORM _assert_amount_text('NaN'); EXCEPTION WHEN OTHERS THEN v_raised := TRUE; END;
  ASSERT v_raised, '_assert_amount_text accepted NaN';

  -- ...and accepts well-formed decimals.
  PERFORM _assert_amount_text('1000.000000');
  PERFORM _assert_amount_text('10');

  RAISE NOTICE 'INPUT GUARD OK — NaN/Infinity/sci-notation/garbage rejected, decimals pass';
END;
$$;
ROLLBACK;
