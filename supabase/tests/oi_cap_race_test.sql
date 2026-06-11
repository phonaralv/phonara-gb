-- ============================================================
-- OI cap race guard
-- ============================================================
-- Proves _assert_position_limits takes the per-market advisory transaction lock
-- and remains VOLATILE because the lock is a transaction side effect. The local
-- SQL runner executes one backend per file, so this file anchors the concurrency
-- invariant in pg_get_functiondef/provolatile and still exercises the live cap
-- branch through real futures opens.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_uid UUID := gen_random_uuid();
  v_oi_hit BOOLEAN := FALSE;
  v_count INT;
  v_msg TEXT;
BEGIN
  ASSERT position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef('public._assert_position_limits(uuid,text,numeric)'::regprocedure)
  ) > 0, '_assert_position_limits must take an advisory transaction lock';
  ASSERT EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = '_assert_position_limits'
       AND p.provolatile = 'v'
  ), '_assert_position_limits must be VOLATILE because advisory locks are side effects';

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated', 'oi_race_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE wallets SET usdt_available = '1000000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  UPDATE app_config SET value = 'false' WHERE key IN ('system_halt', 'system_readonly', 'consent_gate_enabled');
  UPDATE app_config SET value = 'true' WHERE key = 'feature_futures_enabled';
  UPDATE futures_markets
     SET is_active = TRUE, max_user_positions = 100, max_open_interest = '20.000000', max_leverage = '20'
   WHERE symbol = 'PHONUSDT-PERP';
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol = 'PHONUSDT-PERP';
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  PERFORM rpc_open_futures_position(
    'PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL,
    'oi-cap-1-' || v_uid::TEXT
  );
  SELECT COUNT(*) INTO v_count FROM futures_positions WHERE user_id = v_uid AND status = 'open';
  ASSERT v_count = 1, 'first open should succeed before OI cap boundary';

  BEGIN
    PERFORM rpc_open_futures_position(
      'PHONUSDT-PERP', 'long', 'USDT', '10.000000', '2', NULL, NULL,
      'oi-cap-2-' || v_uid::TEXT
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      IF v_msg = 'market_oi_cap' THEN v_oi_hit := TRUE; END IF;
  END;

  ASSERT v_oi_hit,
    format('second open should hit market OI cap after first open; got message=%s', COALESCE(v_msg, '<none>'));

  RAISE NOTICE 'OI CAP LOCK OK — advisory lock invariant anchored and live OI cap branch exercised';
END;
$$;

ROLLBACK;
