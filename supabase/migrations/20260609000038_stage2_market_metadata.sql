-- ============================================================
-- Stage 2: DB-driven market metadata
-- ============================================================
-- Adds display/order/precision metadata so trading UI can stop hardcoding
-- market labels, leverage ranges, and price formatting.
--
-- No settlement, wallet, ledger, or price-feed behavior changes here.
-- ============================================================

SET search_path = public, pg_temp;

ALTER TABLE futures_markets
  ADD COLUMN IF NOT EXISTS display_name TEXT,
  ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS price_precision INT NOT NULL DEFAULT 6,
  ADD COLUMN IF NOT EXISTS tick_size TEXT,
  ADD COLUMN IF NOT EXISTS min_notional TEXT;

ALTER TABLE spot_markets
  ADD COLUMN IF NOT EXISTS display_name TEXT,
  ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS price_precision INT NOT NULL DEFAULT 6,
  ADD COLUMN IF NOT EXISTS tick_size TEXT,
  ADD COLUMN IF NOT EXISTS min_notional TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fm_price_precision_range'
  ) THEN
    ALTER TABLE futures_markets
      ADD CONSTRAINT fm_price_precision_range CHECK (price_precision BETWEEN 0 AND 12);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fm_tick_size_fmt'
  ) THEN
    ALTER TABLE futures_markets
      ADD CONSTRAINT fm_tick_size_fmt CHECK (tick_size IS NULL OR tick_size ~ '^\d+(\.\d+)?$');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fm_min_notional_fmt'
  ) THEN
    ALTER TABLE futures_markets
      ADD CONSTRAINT fm_min_notional_fmt CHECK (min_notional IS NULL OR min_notional ~ '^\d+(\.\d+)?$');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'sm_price_precision_range'
  ) THEN
    ALTER TABLE spot_markets
      ADD CONSTRAINT sm_price_precision_range CHECK (price_precision BETWEEN 0 AND 12);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'sm_tick_size_fmt'
  ) THEN
    ALTER TABLE spot_markets
      ADD CONSTRAINT sm_tick_size_fmt CHECK (tick_size IS NULL OR tick_size ~ '^\d+(\.\d+)?$');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'sm_min_notional_fmt'
  ) THEN
    ALTER TABLE spot_markets
      ADD CONSTRAINT sm_min_notional_fmt CHECK (min_notional IS NULL OR min_notional ~ '^\d+(\.\d+)?$');
  END IF;
END
$$;

UPDATE futures_markets
   SET display_name = CASE symbol
         WHEN 'PHONUSDT-PERP' THEN 'PHON Perpetual'
         WHEN 'BTCUSDT-SIM'   THEN 'BTC Perpetual'
         WHEN 'ETHUSDT-SIM'   THEN 'ETH Perpetual'
         ELSE COALESCE(display_name, symbol)
       END,
       sort_order = CASE symbol
         WHEN 'PHONUSDT-PERP' THEN 10
         WHEN 'BTCUSDT-SIM'   THEN 20
         WHEN 'ETHUSDT-SIM'   THEN 30
         ELSE sort_order
       END,
       price_precision = CASE symbol
         WHEN 'BTCUSDT-SIM' THEN 2
         WHEN 'ETHUSDT-SIM' THEN 2
         ELSE 6
       END,
       tick_size = CASE symbol
         WHEN 'BTCUSDT-SIM' THEN '0.01'
         WHEN 'ETHUSDT-SIM' THEN '0.01'
         ELSE '0.000001'
       END,
       min_notional = COALESCE(min_notional, '1.000000');

UPDATE spot_markets
   SET display_name = CASE symbol
         WHEN 'PHON_USDT' THEN 'PHON/USDT'
         ELSE COALESCE(display_name, symbol)
       END,
       sort_order = CASE symbol
         WHEN 'PHON_USDT' THEN 10
         ELSE sort_order
       END,
       price_precision = CASE symbol
         WHEN 'PHON_USDT' THEN 6
         ELSE price_precision
       END,
       tick_size = CASE symbol
         WHEN 'PHON_USDT' THEN '0.000001'
         ELSE COALESCE(tick_size, '0.000001')
       END,
       min_notional = COALESCE(min_notional, '1.000000');

UPDATE futures_markets
   SET display_name = symbol
 WHERE display_name IS NULL;

UPDATE spot_markets
   SET display_name = symbol
 WHERE display_name IS NULL;

ALTER TABLE futures_markets
  ALTER COLUMN display_name SET NOT NULL;

ALTER TABLE spot_markets
  ALTER COLUMN display_name SET NOT NULL;
