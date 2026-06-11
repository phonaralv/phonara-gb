-- ============================================================
-- Stage 2: OHLCV candle aggregation
-- ============================================================
-- Read-only candle RPC over append-only price_ticks plus spot_trades volume.
-- Empty buckets are forward-filled with the last close and volume=0, which is
-- a no-trade candle rather than synthetic price movement.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION rpc_get_candles(
  p_symbol   TEXT,
  p_interval TEXT,
  p_limit    INT DEFAULT 200
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sec        INT;
  v_interval   INTERVAL;
  v_limit      INT := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_precision  INT;
  v_has_spot   BOOLEAN;
BEGIN
  v_sec := CASE p_interval
    WHEN '1m' THEN 60
    WHEN '3m' THEN 180
    WHEN '5m' THEN 300
    WHEN '15m' THEN 900
    WHEN '1h' THEN 3600
    WHEN '4h' THEN 14400
    WHEN '1d' THEN 86400
    ELSE NULL
  END;

  IF v_sec IS NULL THEN
    RAISE EXCEPTION 'invalid_interval';
  END IF;

  v_interval := (v_sec || ' seconds')::INTERVAL;

  SELECT COALESCE(
    (SELECT price_precision FROM futures_markets WHERE symbol = p_symbol),
    (SELECT price_precision FROM spot_markets WHERE symbol = p_symbol),
    6
  ) INTO v_precision;

  SELECT EXISTS (SELECT 1 FROM spot_markets WHERE symbol = p_symbol) INTO v_has_spot;

  RETURN (
    WITH tick_buckets AS (
      SELECT
        date_bin(v_interval, created_at, '1970-01-01 00:00:00+00'::TIMESTAMPTZ) AS bucket_at,
        (ARRAY_AGG(price::NUMERIC ORDER BY created_at ASC))[1] AS o,
        MAX(price::NUMERIC) AS h,
        MIN(price::NUMERIC) AS l,
        (ARRAY_AGG(price::NUMERIC ORDER BY created_at DESC))[1] AS c
      FROM price_ticks
      WHERE symbol = p_symbol
      GROUP BY 1
    ),
    bounds AS (
      SELECT MAX(bucket_at) AS max_bucket FROM tick_buckets
    ),
    series AS (
      SELECT generate_series(
        max_bucket - ((v_limit - 1) * v_interval),
        max_bucket,
        v_interval
      ) AS bucket_at
      FROM bounds
      WHERE max_bucket IS NOT NULL
    ),
    spot_volume AS (
      SELECT
        date_bin(v_interval, created_at, '1970-01-01 00:00:00+00'::TIMESTAMPTZ) AS bucket_at,
        SUM(phon_amount::NUMERIC) AS volume
      FROM spot_trades
      WHERE market = p_symbol
      GROUP BY 1
    ),
    filled AS (
      SELECT
        s.bucket_at,
        COALESCE(tb.o, prev.c) AS o,
        COALESCE(tb.h, prev.c) AS h,
        COALESCE(tb.l, prev.c) AS l,
        COALESCE(tb.c, prev.c) AS c,
        CASE
          WHEN v_has_spot THEN COALESCE(sv.volume, 0)
          ELSE NULL
        END AS volume
      FROM series s
      LEFT JOIN tick_buckets tb ON tb.bucket_at = s.bucket_at
      LEFT JOIN spot_volume sv ON sv.bucket_at = s.bucket_at
      LEFT JOIN LATERAL (
        SELECT c
          FROM tick_buckets prior
         WHERE prior.bucket_at < s.bucket_at
         ORDER BY prior.bucket_at DESC
         LIMIT 1
      ) prev ON TRUE
    )
    SELECT COALESCE(
      JSONB_AGG(
        JSONB_BUILD_OBJECT(
          'time', EXTRACT(EPOCH FROM bucket_at)::BIGINT,
          'open', ROUND(o, v_precision)::TEXT,
          'high', ROUND(h, v_precision)::TEXT,
          'low', ROUND(l, v_precision)::TEXT,
          'close', ROUND(c, v_precision)::TEXT,
          'volume', CASE WHEN volume IS NULL THEN NULL ELSE _fmt6(volume) END
        )
        ORDER BY bucket_at
      ),
      '[]'::JSONB
    )
    FROM filled
    WHERE c IS NOT NULL
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_candles(TEXT, TEXT, INT) TO authenticated;
