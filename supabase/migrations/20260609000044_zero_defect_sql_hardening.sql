-- ============================================================
-- Zero-defect SQL hardening: candles definer, helper search_path,
-- dead mutator removal, OI cap serialization, cron idempotency, and admin grants.
-- ============================================================
-- A1: Candle volume is global market data. The RPC is SECURITY DEFINER so RLS on
-- spot_trades cannot make volume user-local, but the returned JSON remains
-- strictly limited to aggregate OHLCV fields.
-- A2: Pin search_path on legacy definer/admin helpers flagged in the hardening
-- plan. ALTER FUNCTION is idempotent and preserves existing function bodies.
-- A3: Drop dead public generic wallet mutators after all shipped callers were
-- replaced by internal, guarded ledger helpers.
-- A4: Serialize open-interest cap checks per market with an advisory xact lock.
-- A5: Re-register pg_cron jobs by explicit unschedule + schedule.
-- A7: Align treasury/reserve admin RPC grants with the other admin RPC pattern.
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
SECURITY DEFINER
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

REVOKE ALL ON FUNCTION rpc_get_candles(TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_get_candles(TEXT, TEXT, INT) TO authenticated, service_role;

ALTER FUNCTION _lock_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  SET search_path = public, pg_temp;
ALTER FUNCTION _unlock_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  SET search_path = public, pg_temp;
ALTER FUNCTION _debit_wallet_internal(UUID, currency, TEXT, TEXT, TEXT)
  SET search_path = public, pg_temp;
ALTER FUNCTION _is_admin()
  SET search_path = public, pg_temp;

-- ─── A3: remove dead generic wallet mutators ──────────────────────────────────

DROP FUNCTION IF EXISTS rpc_credit_wallet(currency, TEXT, TEXT, TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS rpc_debit_wallet(currency, TEXT, TEXT, TEXT, UUID, UUID);

-- ─── A4: harden market OI cap against concurrent opens ───────────────────────

CREATE OR REPLACE FUNCTION _assert_position_limits(
  p_user_id      UUID,
  p_market       TEXT,
  p_new_notional NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_global_cap   INT;
  v_user_global  INT;
  v_user_market  INT;
  v_mkt_cap_user INT;
  v_oi_cap       TEXT;
  v_oi_sum       NUMERIC;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('oi:' || p_market));

  SELECT value::INT INTO v_global_cap FROM app_config WHERE key = 'max_open_positions_per_user';
  v_global_cap := COALESCE(v_global_cap, 50);

  SELECT count(*) INTO v_user_global
    FROM futures_positions WHERE user_id = p_user_id AND status = 'open';
  IF v_user_global >= v_global_cap THEN
    RAISE EXCEPTION 'position_limit' USING HINT = 'global';
  END IF;

  SELECT max_user_positions, max_open_interest INTO v_mkt_cap_user, v_oi_cap
    FROM futures_markets WHERE symbol = p_market;

  SELECT count(*) INTO v_user_market
    FROM futures_positions WHERE user_id = p_user_id AND market = p_market AND status = 'open';
  IF v_mkt_cap_user IS NOT NULL AND v_user_market >= v_mkt_cap_user THEN
    RAISE EXCEPTION 'position_limit' USING HINT = p_market;
  END IF;

  IF v_oi_cap IS NOT NULL THEN
    SELECT COALESCE(sum(notional::NUMERIC), 0) INTO v_oi_sum
      FROM futures_positions WHERE market = p_market AND status = 'open';
    IF v_oi_sum + p_new_notional > v_oi_cap::NUMERIC THEN
      RAISE EXCEPTION 'market_oi_cap' USING HINT = p_market;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_position_limits(UUID, TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ─── A5: make cron re-registration explicitly idempotent ─────────────────────

SELECT cron.unschedule(jobname)
  FROM cron.job
 WHERE jobname IN (
   'phonara_auto_liquidations',
   'phonara_daily_reconciliation',
   'phonara_casino_stale_pending_sweep'
 );

SELECT cron.schedule(
  'phonara_auto_liquidations',
  '* * * * *',
  $cron$SELECT public._run_liquidations_logged();$cron$
);

SELECT cron.schedule(
  'phonara_daily_reconciliation',
  '0 2 * * *',
  $cron$SELECT public.rpc_run_reconciliation();$cron$
);

SELECT cron.schedule(
  'phonara_casino_stale_pending_sweep',
  '*/5 * * * *',
  $cron$SELECT public.rpc_sweep_stale_game_bets();$cron$
);

-- ─── A7: treasury/reserve admin RPC grant alignment ──────────────────────────

REVOKE ALL ON FUNCTION rpc_update_treasury_reserve(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_update_treasury_reserve(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION rpc_check_reserve_ratio() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_check_reserve_ratio() TO authenticated, service_role;
