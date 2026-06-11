-- ============================================================
-- Ops alerts queue + ack SQL integration test
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user UUID := gen_random_uuid();
  v_res JSONB;
  v_alerts JSONB;
  v_alert JSONB;
  v_alert_id UUID;
  v_blocked BOOLEAN;
  v_msg TEXT;
  v_count INT;
  v_success_at TIMESTAMPTZ;
  v_single_symbol TEXT := 'OPS_SINGLE_SOURCE';
  v_fallback_symbol TEXT := 'OPS_GLOBAL_FALLBACK';
  v_price TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'ops_alerts_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user, 'authenticated', 'authenticated', 'ops_alerts_user_' || v_user::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  -- Health snapshot refactor must remain admin-only and unchanged shape.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_res := rpc_get_ops_health();
  ASSERT v_res ? 'status' AND v_res ? 'lastUpdatedAt' AND v_res ? 'checks',
    'rpc_get_ops_health must remain unchanged after snapshot extraction';
  ASSERT jsonb_array_length(v_res->'checks') = 9,
    format('rpc_get_ops_health must still return 9 checks, got %s', jsonb_array_length(v_res->'checks'));

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::TEXT)::TEXT, true);
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_sync_ops_alerts_from_health();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin must not sync ops alerts';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);

  -- Materialize warning from missing reconciliation.
  DELETE FROM reconciliation_log;
  v_res := rpc_sync_ops_alerts_from_health();
  ASSERT (v_res->>'opened')::INT >= 1, 'sync must open at least one alert when reconciliation missing';

  v_res := rpc_get_ops_alerts();
  v_alerts := v_res->'alerts';
  ASSERT jsonb_array_length(v_alerts) >= 1, 'get ops alerts must return active alerts';

  SELECT a INTO v_alert
  FROM jsonb_array_elements(v_alerts) a
  WHERE a->>'source_check_id' = 'reconciliation_latest'
  LIMIT 1;
  ASSERT v_alert IS NOT NULL, 'reconciliation_latest alert must exist';
  ASSERT v_alert->>'status' = 'open', 'new alert must start open';
  v_alert_id := (v_alert->>'id')::UUID;

  -- Dedupe / occurrence_count increment on second sync.
  v_res := rpc_sync_ops_alerts_from_health();
  ASSERT (v_res->>'updated')::INT >= 1, 'second sync must update existing alert';

  SELECT occurrence_count INTO v_count
  FROM ops_alerts
  WHERE id = v_alert_id;
  ASSERT v_count = 2, format('occurrence_count must increment to 2, got %s', v_count);

  -- Ack requires reason and writes audit.
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_ack_ops_alert(v_alert_id, 'no');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'reason_required' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'ack without sufficient reason must fail';

  v_res := rpc_ack_ops_alert(v_alert_id, 'Investigating reconciliation gap');
  ASSERT v_res->>'status' = 'acknowledged', 'ack must move alert to acknowledged';

  SELECT COUNT(*)::INT INTO v_count
  FROM audit_logs
  WHERE action = 'ops_alert_acknowledged' AND entity_id = v_alert_id;
  ASSERT v_count = 1, 'ack must create exactly one audit row';

  v_res := rpc_ack_ops_alert(v_alert_id, 'Duplicate ack should be idempotent');
  ASSERT (v_res->>'idempotent')::BOOLEAN = TRUE, 'duplicate ack must be idempotent';

  -- Auto-resolve when health returns to ok.
  v_success_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES (v_success_at, 'wallet', TRUE, '0.000000', FALSE);

  v_res := rpc_sync_ops_alerts_from_health();
  ASSERT (v_res->>'resolved')::INT >= 1, 'sync must auto-resolve cleared alerts';

  SELECT status INTO v_msg
  FROM ops_alerts
  WHERE id = v_alert_id;
  ASSERT v_msg = 'resolved', 'alert must be resolved after health recovers';

  SELECT COUNT(*)::INT INTO v_count
  FROM audit_logs
  WHERE action = 'ops_alert_auto_resolved' AND entity_id = v_alert_id;
  ASSERT v_count = 1, 'auto-resolve must create audit row';

  -- Manual resolve on a fresh critical alert.
  UPDATE app_config SET value = 'true' WHERE key = 'system_halt';
  v_res := rpc_sync_ops_alerts_from_health();
  SELECT id INTO v_alert_id
  FROM ops_alerts
  WHERE source_check_id = 'system_mode' AND status IN ('open', 'acknowledged')
  ORDER BY created_at DESC
  LIMIT 1;
  ASSERT v_alert_id IS NOT NULL, 'system halt must materialize a critical alert';

  v_res := rpc_resolve_ops_alert(v_alert_id, 'Manual clear after maintenance window');
  ASSERT v_res->>'status' = 'resolved', 'manual resolve must succeed';

  SELECT COUNT(*)::INT INTO v_count
  FROM audit_logs
  WHERE action = 'ops_alert_resolved' AND entity_id = v_alert_id;
  ASSERT v_count = 1, 'manual resolve must create audit row';

  -- Oracle median path should warn once when only one valid source remains.
  PERFORM set_config('request.jwt.claims', '{}', true);
  DELETE FROM oracle_source_prices WHERE symbol = v_single_symbol;
  DELETE FROM ops_alerts WHERE dedupe_key = 'oracle_single_source:' || v_single_symbol;
  INSERT INTO market_circuit_breakers (symbol, is_halted, max_tick_pct, staleness_seconds)
  VALUES (v_single_symbol, FALSE, 10.0, 300)
  ON CONFLICT (symbol) DO UPDATE
    SET is_halted = FALSE, max_tick_pct = 10.0, staleness_seconds = 300, updated_at = NOW();
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES (v_single_symbol, '1.000000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '1.000000', updated_at = NOW();
  UPDATE app_config SET value = '1' WHERE key = 'oracle_min_sources';
  UPDATE app_config SET value = '120' WHERE key = 'oracle_staleness_seconds';
  UPDATE app_config SET value = '5' WHERE key = 'oracle_outlier_pct';

  PERFORM rpc_submit_oracle_source_price(v_single_symbol, '1.000001', 'ops-single-feed');
  SELECT COUNT(*)::INT INTO v_count
  FROM ops_alerts
  WHERE dedupe_key = 'oracle_single_source:' || v_single_symbol
    AND source_check_id = 'oracle_single_source'
    AND status = 'open'
    AND severity = 'warning';
  ASSERT v_count = 1, format('single-source oracle alert must open once, got %s', v_count);

  PERFORM rpc_submit_oracle_source_price(v_single_symbol, '1.000002', 'ops-single-feed');
  SELECT COUNT(*)::INT INTO v_count
  FROM ops_alerts
  WHERE dedupe_key = 'oracle_single_source:' || v_single_symbol
    AND status IN ('open', 'acknowledged');
  ASSERT v_count = 1, format('single-source oracle alert must dedupe active rows, got %s', v_count);

  -- Per-symbol oracle_min_sources: external symbols require two valid sources,
  -- while managed PHON and keyless symbols continue to use the global default.
  UPDATE app_config SET value = '1' WHERE key = 'oracle_min_sources';

  INSERT INTO app_config (key, value, description, is_public)
  VALUES (
    'oracle_min_sources:BTCUSDT-SIM',
    '2',
    'Minimum non-stale oracle sources required for BTCUSDT-SIM.',
    FALSE
  )
  ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        description = EXCLUDED.description,
        is_public = FALSE,
        updated_at = NOW();

  DELETE FROM oracle_source_prices WHERE symbol = 'BTCUSDT-SIM';
  UPDATE market_circuit_breakers
     SET is_halted = FALSE, max_tick_pct = 10.0, staleness_seconds = 300, updated_at = NOW()
   WHERE symbol = 'BTCUSDT-SIM';
  UPDATE oracle_prices SET price = '68000.000000', updated_at = NOW()
   WHERE symbol = 'BTCUSDT-SIM';

  v_res := rpc_submit_oracle_source_price('BTCUSDT-SIM', '68000.100000', 'ops-btc-feed-a');
  ASSERT (v_res->>'ok')::BOOLEAN = FALSE AND v_res->>'reason' = 'insufficient_sources',
    format('BTCUSDT-SIM single source must be rejected by per-symbol min_sources=2, got %s', v_res);
  SELECT price INTO v_price FROM oracle_prices WHERE symbol = 'BTCUSDT-SIM';
  ASSERT v_price = '68000.000000',
    format('BTCUSDT-SIM oracle price must remain unchanged with one source, got %s', v_price);

  DELETE FROM app_config WHERE key = 'oracle_min_sources:PHON_USDT';
  DELETE FROM oracle_source_prices WHERE symbol = 'PHON_USDT';
  UPDATE market_circuit_breakers
     SET is_halted = FALSE, max_tick_pct = 10.0, staleness_seconds = 300, updated_at = NOW()
   WHERE symbol = 'PHON_USDT';
  UPDATE spot_markets SET is_active = TRUE WHERE symbol = 'PHON_USDT';
  UPDATE oracle_prices SET price = '0.010000', updated_at = NOW()
   WHERE symbol = 'PHON_USDT';

  v_res := rpc_submit_oracle_source_price('PHON_USDT', '0.010001', 'ops-phon-admin-price');
  ASSERT COALESCE((v_res->>'circuit_breaker_triggered')::BOOLEAN, FALSE) = FALSE,
    format('PHON_USDT managed price single source must update through global fallback, got %s', v_res);
  SELECT price INTO v_price FROM oracle_prices WHERE symbol = 'PHON_USDT';
  ASSERT v_price = '0.010001',
    format('PHON_USDT single-source managed price must update, got %s', v_price);

  DELETE FROM app_config WHERE key = 'oracle_min_sources:' || v_fallback_symbol;
  DELETE FROM oracle_source_prices WHERE symbol = v_fallback_symbol;
  INSERT INTO market_circuit_breakers (symbol, is_halted, max_tick_pct, staleness_seconds)
  VALUES (v_fallback_symbol, FALSE, 10.0, 300)
  ON CONFLICT (symbol) DO UPDATE
    SET is_halted = FALSE, max_tick_pct = 10.0, staleness_seconds = 300, updated_at = NOW();
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES (v_fallback_symbol, '10.000000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '10.000000', updated_at = NOW();

  v_res := rpc_submit_oracle_source_price(v_fallback_symbol, '10.000001', 'ops-fallback-feed');
  SELECT price INTO v_price FROM oracle_prices WHERE symbol = v_fallback_symbol;
  ASSERT v_price = '10.000001',
    format('symbol without per-symbol min_sources key must fall back to global=1, got price=%s result=%s', v_price, v_res);

  RAISE NOTICE 'OPS ALERTS OK — snapshot refactor, sync dedupe, ack, resolve, oracle single-source alert, and per-symbol min_sources verified';
END;
$$;

ROLLBACK;
