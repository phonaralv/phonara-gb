-- ============================================================
-- Candle volume security boundary test
-- ============================================================
-- Proves rpc_get_candles returns global aggregate volume while exposing only the
-- fixed OHLCV JSON schema. Direct spot_trades reads remain own-row scoped by RLS.
-- Runs in one transaction and ROLLS BACK.
-- ============================================================

BEGIN;

CREATE TEMP TABLE candle_test_actor (
  id UUID PRIMARY KEY
) ON COMMIT DROP;

DO $$
DECLARE
  v_user_a UUID := gen_random_uuid();
  v_user_b UUID := gen_random_uuid();
  v_candles JSONB;
  v_first JSONB;
  v_keys TEXT[];
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_user_a, 'authenticated', 'authenticated', 'candles_a_' || v_user_a::TEXT || '@test.local', NOW(), NOW()),
    (v_user_b, 'authenticated', 'authenticated', 'candles_b_' || v_user_b::TEXT || '@test.local', NOW(), NOW());
  INSERT INTO candle_test_actor (id) VALUES (v_user_a);

  INSERT INTO spot_markets (symbol, fee_rate, display_name, sort_order, price_precision, tick_size, min_notional)
  VALUES ('CANDLE_USDT', '0.001', 'CANDLE/USDT', 998, 2, '0.01', '1.000000');

  INSERT INTO price_ticks (symbol, price, created_at) VALUES
    ('CANDLE_USDT', '10.000000', '2026-06-11 00:00:05+00'),
    ('CANDLE_USDT', '12.000000', '2026-06-11 00:00:30+00');

  INSERT INTO spot_trades (user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount, created_at)
  VALUES
    (v_user_a, 'CANDLE_USDT', 'buy',  '10.000000', '7.000000',  '70.000000', 'PHON', '0.007000', '2026-06-11 00:00:20+00'),
    (v_user_b, 'CANDLE_USDT', 'sell', '12.000000', '5.000000',  '60.000000', 'USDT', '0.060000', '2026-06-11 00:00:40+00');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::TEXT)::TEXT, true);
  v_candles := rpc_get_candles('CANDLE_USDT', '1m', 1);
  ASSERT jsonb_array_length(v_candles) = 1, 'expected one candle for isolated test market';

  v_first := v_candles->0;
  ASSERT v_first->>'open' = '10.00'
     AND v_first->>'high' = '12.00'
     AND v_first->>'low' = '10.00'
     AND v_first->>'close' = '12.00'
     AND v_first->>'volume' = '12.000000',
    'candle must include global volume from both users without user-local RLS truncation';

  SELECT ARRAY_AGG(key ORDER BY key)
    INTO v_keys
    FROM jsonb_object_keys(v_first) AS key;
  ASSERT v_keys = ARRAY['close','high','low','open','time','volume'],
    format('candle returned unexpected JSON keys: %s', array_to_string(v_keys, ','));

  ASSERT NOT (v_first ? 'user_id')
     AND NOT (v_first ? 'side')
     AND NOT (v_first ? 'price')
     AND NOT (v_first ? 'phon_amount')
     AND NOT (v_first ? 'usdt_amount')
     AND NOT (v_first ? 'created_at'),
    'candle response must not expose individual spot_trades fields';

  ASSERT EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'rpc_get_candles'
       AND p.prosecdef
       AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c = 'search_path=public, pg_temp')
  ), 'rpc_get_candles must be SECURITY DEFINER with pinned search_path';

  RAISE NOTICE 'CANDLE GLOBAL VOLUME OK — aggregate-only definer response is bounded';
END;
$$;

-- Direct table reads remain RLS-scoped for authenticated users. This block does
-- not call SECURITY DEFINER functions under SET ROLE, avoiding the local Docker
-- backend issue documented in anon_lockdown_test.sql.
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub',
    (SELECT id::TEXT FROM candle_test_actor LIMIT 1)
  )::TEXT,
  true
);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_visible_rows INT;
  v_visible_volume NUMERIC;
BEGIN
  SELECT COUNT(*), COALESCE(SUM(phon_amount::NUMERIC), 0)
    INTO v_visible_rows, v_visible_volume
    FROM spot_trades
   WHERE market = 'CANDLE_USDT';

  ASSERT v_visible_rows = 1, format('authenticated user saw %s spot_trades rows, expected own row only', v_visible_rows);
  ASSERT v_visible_volume = 7.000000,
    format('authenticated direct spot_trades volume should be own-row only, got %s', v_visible_volume);
END;
$$;
RESET ROLE;

ROLLBACK;
