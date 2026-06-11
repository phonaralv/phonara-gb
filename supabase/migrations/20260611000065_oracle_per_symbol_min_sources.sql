-- ============================================================
-- Oracle per-symbol min_sources configuration
-- ============================================================
-- Keep the existing app_config-based oracle model:
--   oracle_min_sources:<symbol> overrides oracle_min_sources.
--   Missing per-symbol key falls back to the global value.
-- No new tables or RPCs are introduced.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _compute_oracle_median(p_symbol TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staleness_s  INT;
  v_min_sources  INT;
  v_outlier_pct  NUMERIC;
  v_prices       NUMERIC[];
  v_count        INT;
  v_median       NUMERIC;
  v_filtered     NUMERIC[];
  p              NUMERIC;
BEGIN
  SELECT value::INT
    INTO v_staleness_s
    FROM app_config
   WHERE key = 'oracle_staleness_seconds';

  SELECT COALESCE(
           (SELECT value::INT FROM app_config WHERE key = 'oracle_min_sources:' || p_symbol),
           (SELECT value::INT FROM app_config WHERE key = 'oracle_min_sources')
         )
    INTO v_min_sources;

  SELECT value::NUMERIC
    INTO v_outlier_pct
    FROM app_config
   WHERE key = 'oracle_outlier_pct';

  v_staleness_s := COALESCE(v_staleness_s, 120);
  v_min_sources := COALESCE(v_min_sources, 1);
  v_outlier_pct := COALESCE(v_outlier_pct, 5);

  SELECT ARRAY_AGG(price::NUMERIC ORDER BY price::NUMERIC)
    INTO v_prices
    FROM oracle_source_prices
   WHERE symbol = p_symbol
     AND submitted_at > NOW() - (v_staleness_s || ' seconds')::INTERVAL;

  v_count := COALESCE(array_length(v_prices, 1), 0);

  IF v_count < v_min_sources THEN
    RETURN NULL;
  END IF;

  IF v_count % 2 = 1 THEN
    v_median := v_prices[(v_count + 1) / 2];
  ELSE
    v_median := (v_prices[v_count / 2] + v_prices[v_count / 2 + 1]) / 2;
  END IF;

  IF v_outlier_pct > 0 THEN
    v_filtered := '{}';
    FOREACH p IN ARRAY v_prices LOOP
      IF v_median > 0 AND ABS(p / v_median - 1) * 100 <= v_outlier_pct THEN
        v_filtered := v_filtered || p;
      END IF;
    END LOOP;

    IF array_length(v_filtered, 1) >= v_min_sources THEN
      SELECT ARRAY_AGG(x ORDER BY x) INTO v_prices FROM unnest(v_filtered) x;
      v_count := array_length(v_prices, 1);
      IF v_count % 2 = 1 THEN
        v_median := v_prices[(v_count + 1) / 2];
      ELSE
        v_median := (v_prices[v_count / 2] + v_prices[v_count / 2 + 1]) / 2;
      END IF;
    END IF;
  END IF;

  RETURN v_median;
END;
$$;

REVOKE ALL ON FUNCTION _compute_oracle_median(TEXT) FROM PUBLIC, anon, authenticated;

INSERT INTO app_config (key, value, description, is_public)
VALUES
  (
    'oracle_min_sources:BTCUSDT-SIM',
    '2',
    'Minimum non-stale oracle sources required for BTCUSDT-SIM median updates.',
    FALSE
  ),
  (
    'oracle_min_sources:ETHUSDT-SIM',
    '2',
    'Minimum non-stale oracle sources required for ETHUSDT-SIM median updates.',
    FALSE
  )
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value,
      description = EXCLUDED.description,
      is_public = FALSE,
      updated_at = NOW();
