-- ============================================================
-- Trading min_notional enforcement + oracle single-source alert
-- ============================================================
-- Scope is intentionally mechanical:
--   * enforce existing futures_markets/spot_markets.min_notional metadata;
--   * record an ops alert when the oracle median path has exactly one valid source.
--
-- No TWAP, AMM, or house exposure-cap behavior is introduced here.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── 1. min_notional enforcement on entry RPCs ────────────────────────────────
DO $$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.rpc_open_futures_position(text,text,text,text,text,text,text,text)'::regprocedure);

  IF position('below_min_notional' IN v_def) = 0 THEN
    v_new := regexp_replace(
      v_def,
      'v_notional := v_margin \* v_lev;',
      'v_notional := v_margin * v_lev;' || E'\n  IF v_mkt.min_notional IS NOT NULL AND v_notional < v_mkt.min_notional::NUMERIC THEN\n    RAISE EXCEPTION ''below_min_notional'' USING HINT = p_market;\n  END IF;',
      ''
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'min_notional futures anchor not found';
    END IF;

    EXECUTE v_new;
  END IF;

  v_def := pg_get_functiondef('public.rpc_spot_market_buy(text,text)'::regprocedure);

  IF position('below_min_notional' IN v_def) = 0 THEN
    v_new := replace(
      v_def,
      'IF NOT FOUND THEN RAISE EXCEPTION ''market_not_found''; END IF;',
      'IF NOT FOUND THEN RAISE EXCEPTION ''market_not_found''; END IF;'
        || E'\n\n  IF v_mkt.min_notional IS NOT NULL AND v_usdt < v_mkt.min_notional::NUMERIC THEN\n    RAISE EXCEPTION ''below_min_notional'' USING HINT = ''PHON_USDT'';\n  END IF;'
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'min_notional spot buy anchor not found';
    END IF;

    EXECUTE v_new;
  END IF;

  v_def := pg_get_functiondef('public.rpc_spot_market_sell(text,text)'::regprocedure);

  IF position('below_min_notional' IN v_def) = 0 THEN
    v_new := regexp_replace(
      v_def,
      'v_gross\s*:= v_phon \* v_price;',
      'v_gross    := v_phon * v_price;' || E'\n  IF v_mkt.min_notional IS NOT NULL AND v_gross < v_mkt.min_notional::NUMERIC THEN\n    RAISE EXCEPTION ''below_min_notional'' USING HINT = ''PHON_USDT'';\n  END IF;',
      ''
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'min_notional spot sell anchor not found';
    END IF;

    EXECUTE v_new;
  END IF;
END
$$;

REVOKE ALL ON FUNCTION rpc_open_futures_position(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_open_futures_position(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION rpc_spot_market_buy(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_spot_market_buy(TEXT, TEXT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION rpc_spot_market_sell(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_spot_market_sell(TEXT, TEXT) TO authenticated, service_role;

-- ─── 2. Oracle single-source ops alert ────────────────────────────────────────
CREATE OR REPLACE FUNCTION _record_oracle_single_source_alert(
  p_symbol TEXT,
  p_source_count INT,
  p_source_name TEXT,
  p_median TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alert ops_alerts%ROWTYPE;
  v_key TEXT := 'oracle_single_source:' || p_symbol;
BEGIN
  SELECT * INTO v_alert
  FROM ops_alerts
  WHERE dedupe_key = v_key
    AND status IN ('open', 'acknowledged')
  FOR UPDATE;

  IF FOUND THEN
    RETURN;
  END IF;

  INSERT INTO ops_alerts (
    dedupe_key,
    source_check_id,
    severity,
    status,
    summary,
    runbook_key,
    metadata
  ) VALUES (
    v_key,
    'oracle_single_source',
    'warning',
    'open',
    'Oracle median has exactly one valid source for ' || p_symbol,
    'oracle.single_source',
    jsonb_build_object(
      'symbol', p_symbol,
      'validSourceCount', p_source_count,
      'sourceName', p_source_name,
      'median', p_median
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION _record_oracle_single_source_alert(TEXT, INT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_submit_oracle_source_price(
  p_symbol      TEXT,
  p_price       TEXT,
  p_source_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_new_price NUMERIC := p_price::NUMERIC;
  v_median    NUMERIC;
  v_result    JSONB;
  v_sources   INT;
  v_staleness_s INT;
  v_outlier_pct NUMERIC;
  v_effective_sources INT;
BEGIN
  -- Only admin or service-role (actor_id NULL) can submit prices.
  IF v_actor_id IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF v_new_price <= 0 THEN RAISE EXCEPTION 'invalid_price'; END IF;
  IF p_source_name = '' OR p_source_name IS NULL THEN
    RAISE EXCEPTION 'invalid_source_name';
  END IF;

  -- Upsert this source's price.
  INSERT INTO oracle_source_prices (symbol, source_name, price, submitted_at)
  VALUES (p_symbol, p_source_name, p_price, NOW())
  ON CONFLICT (symbol, source_name) DO UPDATE
    SET price = EXCLUDED.price, submitted_at = EXCLUDED.submitted_at;

  -- Compute multi-source median.
  v_median := _compute_oracle_median(p_symbol);

  IF v_median IS NULL THEN
    -- Insufficient sources: store price but don't update oracle_prices.
    SELECT COUNT(*) INTO v_sources
      FROM oracle_source_prices
     WHERE symbol = p_symbol;

    RETURN jsonb_build_object(
      'ok', FALSE,
      'reason', 'insufficient_sources',
      'source_stored', TRUE,
      'source_count', v_sources
    );
  END IF;

  SELECT value::INT INTO v_staleness_s FROM app_config WHERE key = 'oracle_staleness_seconds';
  SELECT value::NUMERIC INTO v_outlier_pct FROM app_config WHERE key = 'oracle_outlier_pct';
  v_staleness_s := COALESCE(v_staleness_s, 120);
  v_outlier_pct := COALESCE(v_outlier_pct, 5);

  SELECT COUNT(*) INTO v_effective_sources
    FROM oracle_source_prices
   WHERE symbol = p_symbol
     AND submitted_at > NOW() - (v_staleness_s || ' seconds')::INTERVAL
     AND (
       v_outlier_pct <= 0
       OR v_median <= 0
       OR ABS(price::NUMERIC / v_median - 1) * 100 <= v_outlier_pct
     );

  IF v_effective_sources = 1 THEN
    PERFORM _record_oracle_single_source_alert(
      p_symbol,
      v_effective_sources,
      p_source_name,
      _fmt6(v_median)
    );
  END IF;

  -- Apply median to oracle_prices via the existing circuit-breaker RPC.
  -- Use source='feed' + null reason → bypasses admin_reason requirement.
  v_result := rpc_update_oracle_price(p_symbol, _fmt6(v_median), NULL, 'feed:' || p_source_name);

  RETURN v_result || jsonb_build_object(
    'source_name', p_source_name,
    'source_price', p_price,
    'computed_median', _fmt6(v_median)
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_submit_oracle_source_price(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_submit_oracle_source_price(TEXT, TEXT, TEXT) TO service_role;
