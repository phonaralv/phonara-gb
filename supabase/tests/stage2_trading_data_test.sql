-- ============================================================
-- Stage 2 trading data pipeline tests
-- ============================================================
-- Verifies DB-driven market metadata, finite OI caps, OHLCV gap-fill,
-- synthetic display-only book, and market source admin registry.
-- Entire file is transactional and leaves no residue.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user  UUID := gen_random_uuid();
  v_candles JSONB;
  v_book JSONB;
  v_book_again JSONB;
  v_bad_interval BOOLEAN := FALSE;
  v_oi_required BOOLEAN := FALSE;
  v_ledger_before INT;
  v_ledger_after INT;
  v_source JSONB;
  v_disabled JSONB;
  v_audit_count INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'stage2_admin_' || v_admin::TEXT || '@t.local', NOW(), NOW()),
    (v_user,  'authenticated', 'authenticated', 'stage2_user_' || v_user::TEXT || '@t.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;
  UPDATE wallets SET usdt_available = '1000000.000000', phon_available = '1000000.000000'
   WHERE user_id = v_user;

  -- Market metadata should be DB-driven and finite for active markets.
  ASSERT EXISTS (
    SELECT 1 FROM futures_markets
     WHERE symbol = 'BTCUSDT-SIM'
       AND display_name IS NOT NULL
       AND price_precision = 2
       AND max_leverage = '20'
       AND max_open_interest IS NOT NULL
  ), 'BTC futures metadata/backfill missing';

  BEGIN
    UPDATE futures_markets SET max_open_interest = NULL WHERE symbol = 'BTCUSDT-SIM';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%fm_active_oi_required%' THEN v_oi_required := TRUE; END IF;
  END;
  ASSERT v_oi_required, 'active futures market accepted NULL OI cap';

  -- Admin market-limit RPC requires reason, writes audit, and updates leverage.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  PERFORM rpc_set_market_limits('BTCUSDT-SIM', 25, '250000.000000', '25', 'stage2 boundary test');
  ASSERT EXISTS (
    SELECT 1 FROM futures_markets
     WHERE symbol = 'BTCUSDT-SIM'
       AND max_user_positions = 25
       AND max_open_interest = '250000.000000'
       AND max_leverage = '25'
  ), 'rpc_set_market_limits did not update all risk fields';

  SELECT COUNT(*) INTO v_audit_count
    FROM audit_logs
   WHERE action = 'market_limits_set'
     AND payload->>'reason' = 'stage2 boundary test';
  ASSERT v_audit_count = 1, 'market limits audit row missing';

  -- OHLCV candles over isolated test market.
  INSERT INTO spot_markets (symbol, fee_rate, display_name, sort_order, price_precision, tick_size, min_notional)
  VALUES ('TEST_USDT', '0.001', 'TEST/USDT', 999, 2, '0.01', '1.000000');

  INSERT INTO price_ticks (symbol, price, created_at) VALUES
    ('TEST_USDT', '1.000000', '2026-06-10 00:00:05+00'),
    ('TEST_USDT', '2.000000', '2026-06-10 00:00:30+00'),
    ('TEST_USDT', '4.000000', '2026-06-10 00:02:10+00');

  INSERT INTO spot_trades (user_id, market, side, price, phon_amount, usdt_amount, fee_currency, fee_amount, created_at)
  VALUES
    (v_user, 'TEST_USDT', 'buy',  '2.000000', '10.000000', '20.000000', 'PHON', '0.010000', '2026-06-10 00:00:40+00'),
    (v_user, 'TEST_USDT', 'sell', '4.000000', '5.000000',  '20.000000', 'USDT', '0.020000', '2026-06-10 00:02:20+00');

  v_candles := rpc_get_candles('TEST_USDT', '1m', 3);
  ASSERT jsonb_array_length(v_candles) = 3, 'expected 3 candles including gap-fill';
  ASSERT v_candles->0->>'open' = '1.00' AND v_candles->0->>'high' = '2.00'
     AND v_candles->0->>'low' = '1.00' AND v_candles->0->>'close' = '2.00'
     AND v_candles->0->>'volume' = '10.000000', 'first candle OHLCV mismatch';
  ASSERT v_candles->1->>'open' = '2.00' AND v_candles->1->>'high' = '2.00'
     AND v_candles->1->>'low' = '2.00' AND v_candles->1->>'close' = '2.00'
     AND v_candles->1->>'volume' = '0.000000', 'gap candle must be flat with zero volume';
  ASSERT v_candles->2->>'open' = '4.00' AND v_candles->2->>'volume' = '5.000000',
    'third candle OHLCV mismatch';

  BEGIN
    PERFORM rpc_get_candles('TEST_USDT', '2m', 3);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%invalid_interval%' THEN v_bad_interval := TRUE; END IF;
  END;
  ASSERT v_bad_interval, 'invalid candle interval was not rejected';

  INSERT INTO price_ticks (symbol, price, created_at)
  SELECT 'LIMIT_USDT', '1.000000', '2026-06-10 01:00:00+00'::TIMESTAMPTZ + (i || ' minutes')::INTERVAL
    FROM generate_series(1, 510) AS i;
  ASSERT jsonb_array_length(rpc_get_candles('LIMIT_USDT', '1m', 999)) = 500,
    'candle limit was not clamped to 500';

  -- Synthetic book is deterministic and display-only.
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES ('TEST_USDT', '100.000000', NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = '100.000000', updated_at = NOW();
  UPDATE app_config SET value = '10' WHERE key = 'synthetic_book_spread_bps';
  UPDATE app_config SET value = '5' WHERE key = 'synthetic_book_level_step_bps';
  UPDATE app_config SET value = '3' WHERE key = 'synthetic_book_depth_levels';
  UPDATE app_config SET value = '100.000000' WHERE key = 'synthetic_book_base_size';

  SELECT COUNT(*) INTO v_ledger_before FROM wallet_ledger;
  v_book := rpc_get_synthetic_book('TEST_USDT', NULL);
  v_book_again := rpc_get_synthetic_book('TEST_USDT', NULL);
  SELECT COUNT(*) INTO v_ledger_after FROM wallet_ledger;
  ASSERT v_book = v_book_again, 'synthetic book must be deterministic';
  ASSERT jsonb_array_length(v_book->'asks') = 3 AND jsonb_array_length(v_book->'bids') = 3,
    'synthetic book level count mismatch';
  ASSERT (v_book->'asks'->0->>'price')::NUMERIC > (v_book->>'mid')::NUMERIC
     AND (v_book->'bids'->0->>'price')::NUMERIC < (v_book->>'mid')::NUMERIC,
    'synthetic book must straddle mid';
  ASSERT v_ledger_before = v_ledger_after, 'synthetic book wrote ledger rows';

  -- Source registry admin RPCs.
  v_source := rpc_set_market_source('BTCUSDT-SIM', 'Binance', 'BTCUSDT', '1', TRUE, 'stage2 source setup');
  ASSERT (v_source->>'provider') = 'binance', 'market source provider should be normalized';
  v_disabled := rpc_disable_market_source('BTCUSDT-SIM', 'Binance', 'stage2 disable');
  ASSERT (v_disabled->>'enabled')::BOOLEAN = FALSE, 'market source disable failed';
  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
     WHERE action IN ('market_source_set', 'market_source_disabled')
       AND entity_type = 'market_sources'
  ), 'market source audit rows missing';

  RAISE NOTICE 'STAGE2 TRADING DATA OK — metadata, risk, candles, book, sources';
END;
$$;

ROLLBACK;
