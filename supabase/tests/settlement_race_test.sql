-- ============================================================
-- Settlement race guard — close vs auto-liquidation
-- ============================================================
-- Simulates a close followed by an auto-liquidation sweep after the mark crosses
-- liquidation. The sweep must not settle the already-closed position again, and
-- the global USDT invariant must remain unchanged.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_uid          UUID := gen_random_uuid();
  v_pos          JSONB;
  v_pos_id       UUID;
  v_sweep        JSONB;
  v_events       INT;
  v_before       NUMERIC;
  v_after_close  NUMERIC;
  v_after_sweep  NUMERIC;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES (v_uid, 'authenticated', 'authenticated',
          'race_' || v_uid::TEXT || '@test.local', NOW(), NOW());

  UPDATE wallets SET usdt_available = '1000000.000000' WHERE user_id = v_uid;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid::TEXT)::TEXT, true);

  UPDATE app_config SET value = 'false' WHERE key IN ('system_halt', 'system_readonly');
  UPDATE app_config SET value = 'true' WHERE key IN ('feature_futures_enabled', 'consent_gate_enabled');
  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted)
  SELECT v_uid, doc_type::consent_doc_type, 'test', TRUE
  FROM unnest(ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']) AS doc_type
  ON CONFLICT DO NOTHING;

  UPDATE futures_markets
     SET is_active = TRUE, max_leverage = 100, max_user_positions = 100, max_open_interest = '1000000.000000'
   WHERE symbol = 'PHONUSDT-PERP';
  UPDATE market_circuit_breakers SET is_halted = FALSE WHERE symbol = 'PHONUSDT-PERP';
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('PHONUSDT-PERP', '0.010000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '0.010000', updated_at = NOW();

  SELECT
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
  INTO v_before;

  v_pos := rpc_open_futures_position(
    'PHONUSDT-PERP', 'long', 'USDT', '1000.000000', '10', NULL, NULL, 'race-' || v_uid::TEXT
  );
  v_pos_id := (v_pos->>'position_id')::UUID;

  UPDATE oracle_prices SET price = '0.010500', updated_at = NOW()
   WHERE symbol = 'PHONUSDT-PERP';
  PERFORM rpc_close_futures_position(v_pos_id);

  SELECT
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
  INTO v_after_close;

  ASSERT v_after_close = v_before,
    format('USDT not conserved after close: before=%s after=%s', v_before, v_after_close);

  -- Now move the mark beyond liquidation and run the service/cron sweep. Because
  -- the position is already closed, it must not be settled a second time.
  UPDATE oracle_prices SET price = '0.009000', updated_at = NOW()
   WHERE symbol = 'PHONUSDT-PERP';
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_sweep := rpc_run_liquidations();

  SELECT COUNT(*) INTO v_events FROM position_ledger
   WHERE position_id = v_pos_id AND event IN ('close', 'liquidate', 'auto_liquidate');

  ASSERT (v_sweep->>'liquidated')::INT = 0,
    'auto-liquidation sweep settled an already-closed position: ' || v_sweep::TEXT;
  ASSERT v_events = 1, 'expected exactly one settlement event, got ' || v_events;

  SELECT
    (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC),0) FROM wallets)
    + (SELECT COALESCE(SUM(balance::NUMERIC),0) FROM system_accounts WHERE currency='USDT')
  INTO v_after_sweep;

  ASSERT v_after_sweep = v_after_close,
    format('USDT changed after post-close sweep: after_close=%s after_sweep=%s',
           v_after_close, v_after_sweep);
  ASSERT NOT EXISTS (SELECT 1 FROM verify_ledger_hash_chain(v_uid)),
    'wallet ledger hash chain broken after close/sweep race simulation';

  RAISE NOTICE 'SETTLEMENT RACE OK — close then auto-liquidation did not double-settle';
END;
$$;

ROLLBACK;
