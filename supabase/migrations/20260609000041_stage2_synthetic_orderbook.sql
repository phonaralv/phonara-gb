-- ============================================================
-- Stage 2: Synthetic house-provided reference liquidity
-- ============================================================
-- Display-only book around oracle mid price. It never settles trades and never
-- writes wallet, ledger, or position rows. Actual fills remain oracle-priced.
-- ============================================================

SET search_path = public, pg_temp;

INSERT INTO app_config (key, value, description) VALUES
  ('synthetic_book_spread_bps', '8',
   'Half-spread in basis points around oracle mid for display-only reference liquidity.'),
  ('synthetic_book_level_step_bps', '6',
   'Additional basis points between synthetic order-book levels.'),
  ('synthetic_book_depth_levels', '10',
   'Default number of display-only synthetic order-book levels per side.'),
  ('synthetic_book_base_size', '100.000000',
   'Base display size for synthetic order-book levels.')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION rpc_get_synthetic_book(
  p_symbol TEXT,
  p_levels INT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mid       NUMERIC;
  v_spread   NUMERIC;
  v_step     NUMERIC;
  v_base     NUMERIC;
  v_levels   INT;
  v_precision INT;
  v_asks     JSONB := '[]'::JSONB;
  v_bids     JSONB := '[]'::JSONB;
  v_price    NUMERIC;
  v_size     NUMERIC;
  i          INT;
BEGIN
  SELECT price::NUMERIC INTO v_mid
    FROM oracle_prices
   WHERE symbol = p_symbol;
  IF v_mid IS NULL OR v_mid <= 0 THEN
    RAISE EXCEPTION 'no_price';
  END IF;

  SELECT COALESCE(
    (SELECT price_precision FROM futures_markets WHERE symbol = p_symbol),
    (SELECT price_precision FROM spot_markets WHERE symbol = p_symbol),
    6
  ) INTO v_precision;

  SELECT value::NUMERIC INTO v_spread FROM app_config WHERE key = 'synthetic_book_spread_bps';
  SELECT value::NUMERIC INTO v_step   FROM app_config WHERE key = 'synthetic_book_level_step_bps';
  SELECT value::NUMERIC INTO v_base   FROM app_config WHERE key = 'synthetic_book_base_size';
  SELECT COALESCE(p_levels, value::INT) INTO v_levels FROM app_config WHERE key = 'synthetic_book_depth_levels';

  v_spread := COALESCE(v_spread, 8);
  v_step := COALESCE(v_step, 6);
  v_base := COALESCE(v_base, 100);
  v_levels := LEAST(GREATEST(COALESCE(v_levels, 10), 1), 50);

  FOR i IN 0..(v_levels - 1) LOOP
    v_size := v_base * (1 + (i * 0.15));

    v_price := v_mid * (1 + ((v_spread + (i * v_step)) / 10000));
    v_asks := v_asks || JSONB_BUILD_OBJECT(
      'price', ROUND(v_price, v_precision)::TEXT,
      'size', _fmt6(v_size)
    );

    v_price := v_mid * (1 - ((v_spread + (i * v_step)) / 10000));
    v_bids := v_bids || JSONB_BUILD_OBJECT(
      'price', ROUND(v_price, v_precision)::TEXT,
      'size', _fmt6(v_size)
    );
  END LOOP;

  RETURN JSONB_BUILD_OBJECT(
    'symbol', p_symbol,
    'mid', ROUND(v_mid, v_precision)::TEXT,
    'asks', v_asks,
    'bids', v_bids,
    'disclosure', 'house_reference_liquidity'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_synthetic_book(TEXT, INT) TO authenticated;
