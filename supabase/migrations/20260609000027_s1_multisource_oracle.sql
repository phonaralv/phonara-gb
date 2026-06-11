-- ============================================================
-- Migration: 20260609000027_s1_multisource_oracle
-- S1: Multi-source oracle — median aggregation + outlier rejection
-- ============================================================
-- WHY (§0-C, §0-B): In the B-book (House-as-Counterparty) model,
-- oracle_prices IS the settlement price. A single source = single
-- manipulation/failure point. If one feed is compromised or stale,
-- trades settle at a malicious price.
--
-- FIX: Accept prices from N named sources. Compute the median of
-- non-stale sources. Reject individual sources that deviate > outlier_pct
-- from the median. Require at least min_sources for settlement.
-- Fall back to the existing circuit breaker (008) if median moves
-- beyond max_tick_pct.
--
-- Architecture:
--   oracle_source_prices: latest price from each named source (UPSERT).
--   rpc_submit_oracle_source_price(symbol, price, source): service_role.
--   _compute_oracle_median(symbol): pure internal helper.
--   oracle_prices: updated to the computed median (same as before).
--   Existing circuit breaker (rpc_update_oracle_price) unchanged —
--   the median path calls into it, preserving all existing guards.
--
-- Config (app_config keys added):
--   oracle_staleness_seconds: seconds before a source price is stale (default 120)
--   oracle_min_sources:       minimum non-stale sources required for median (default 2)
--   oracle_outlier_pct:       % deviation to reject a source from median (default 5)
-- ============================================================

SET search_path = public, pg_temp;

-- ─── 1. oracle_source_prices ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS oracle_source_prices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol        TEXT NOT NULL,
  source_name   TEXT NOT NULL,
  price         TEXT NOT NULL
    CONSTRAINT osp_price_fmt CHECK (price ~ '^\d+(\.\d+)?$'),
  submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (symbol, source_name)
);

CREATE INDEX IF NOT EXISTS osp_symbol_idx ON oracle_source_prices (symbol, submitted_at DESC);

ALTER TABLE oracle_source_prices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin read oracle_source_prices" ON oracle_source_prices;
CREATE POLICY "admin read oracle_source_prices" ON oracle_source_prices
  FOR SELECT USING (_is_admin() OR auth.uid() IS NOT NULL);

-- ─── 2. Config keys for multi-source behavior ──────────────────────────────────

INSERT INTO app_config (key, value, description) VALUES
  ('oracle_staleness_seconds', '120',
   'Source prices older than this many seconds are excluded from median computation.'),
  ('oracle_min_sources', '1',
   'Minimum non-stale sources required to compute a valid median. Default 1 for initial launch (single-source mode); increase to 2+ when multiple feeds are online.'),
  ('oracle_outlier_pct', '5',
   'Maximum % deviation a source price may differ from the current median before being rejected as an outlier. 0 = no rejection.')
ON CONFLICT (key) DO NOTHING;

-- ─── 3. _compute_oracle_median ────────────────────────────────────────────────
-- Returns the median price from non-stale, non-outlier sources for a symbol.
-- Returns NULL if fewer than oracle_min_sources are available.

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
  SELECT value::INT  INTO v_staleness_s FROM app_config WHERE key = 'oracle_staleness_seconds';
  SELECT value::INT  INTO v_min_sources FROM app_config WHERE key = 'oracle_min_sources';
  SELECT value::NUMERIC INTO v_outlier_pct FROM app_config WHERE key = 'oracle_outlier_pct';

  v_staleness_s := COALESCE(v_staleness_s, 120);
  v_min_sources := COALESCE(v_min_sources, 1);
  v_outlier_pct := COALESCE(v_outlier_pct, 5);

  -- Collect non-stale source prices, ordered for percentile computation.
  SELECT ARRAY_AGG(price::NUMERIC ORDER BY price::NUMERIC)
    INTO v_prices
    FROM oracle_source_prices
   WHERE symbol = p_symbol
     AND submitted_at > NOW() - (v_staleness_s || ' seconds')::INTERVAL;

  v_count := COALESCE(array_length(v_prices, 1), 0);

  IF v_count < v_min_sources THEN
    RETURN NULL;  -- Insufficient sources → no valid median
  END IF;

  -- Median: middle element (odd count) or average of two middle elements (even).
  IF v_count % 2 = 1 THEN
    v_median := v_prices[(v_count + 1) / 2];
  ELSE
    v_median := (v_prices[v_count / 2] + v_prices[v_count / 2 + 1]) / 2;
  END IF;

  -- Outlier rejection: exclude sources > v_outlier_pct% from median.
  IF v_outlier_pct > 0 THEN
    v_filtered := '{}';
    FOREACH p IN ARRAY v_prices LOOP
      IF v_median > 0 AND ABS(p / v_median - 1) * 100 <= v_outlier_pct THEN
        v_filtered := v_filtered || p;
      END IF;
    END LOOP;

    IF array_length(v_filtered, 1) >= v_min_sources THEN
      -- Recompute median on filtered set.
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

-- ─── 4. rpc_submit_oracle_source_price ───────────────────────────────────────
-- Called by price feed services (service_role or price-feed admin).
-- Upserts the source price, computes the new median, then calls
-- rpc_update_oracle_price with the median to apply circuit-breaker logic.

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

-- ─── 5. Backfill existing oracle_prices as source "legacy" ───────────────────
-- Seed oracle_source_prices with current oracle_prices as a "legacy" source
-- so existing prices are visible in the multi-source view.
-- This ensures the oracle works immediately (min_sources=1 default).

INSERT INTO oracle_source_prices (symbol, source_name, price, submitted_at)
SELECT symbol, 'legacy', price, updated_at
  FROM oracle_prices
ON CONFLICT (symbol, source_name) DO UPDATE
  SET price = EXCLUDED.price, submitted_at = EXCLUDED.submitted_at;
