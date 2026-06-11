-- ============================================================
-- House exposure alert
-- ============================================================
-- Detection-only guardrail: if per-symbol user net exposure (long notional minus
-- short notional) exceeds the configured threshold, open one ops warning.
-- This does not block trades and does not toggle kill switches.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _record_house_exposure_alert(
  p_symbol TEXT,
  p_threshold TEXT,
  p_long_exposure TEXT,
  p_short_exposure TEXT,
  p_net_exposure TEXT,
  p_abs_net_exposure TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alert ops_alerts%ROWTYPE;
  v_key TEXT := 'house_exposure_breach:' || p_symbol;
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
    'house_exposure_breach',
    'warning',
    'open',
    'House net exposure exceeded threshold for ' || p_symbol,
    'house.exposure_breach',
    jsonb_build_object(
      'symbol', p_symbol,
      'threshold', p_threshold,
      'longExposure', p_long_exposure,
      'shortExposure', p_short_exposure,
      'netExposure', p_net_exposure,
      'absNetExposure', p_abs_net_exposure
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION _record_house_exposure_alert(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _check_house_exposure_alert(p_symbol TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_threshold NUMERIC;
  v_long NUMERIC;
  v_short NUMERIC;
  v_net NUMERIC;
  v_abs_net NUMERIC;
BEGIN
  SELECT value::NUMERIC INTO v_threshold
    FROM app_config
   WHERE key = 'house_exposure_alert_threshold:' || p_symbol;

  IF v_threshold IS NULL OR v_threshold <= 0 THEN
    RETURN;
  END IF;

  SELECT
    COALESCE(SUM(notional::NUMERIC) FILTER (WHERE side = 'long'), 0),
    COALESCE(SUM(notional::NUMERIC) FILTER (WHERE side = 'short'), 0)
  INTO v_long, v_short
  FROM futures_positions
  WHERE market = p_symbol
    AND status = 'open';

  v_net := v_long - v_short;
  v_abs_net := abs(v_net);

  IF v_abs_net > v_threshold THEN
    PERFORM _record_house_exposure_alert(
      p_symbol,
      _fmt6(v_threshold),
      _fmt6(v_long),
      _fmt6(v_short),
      _fmt6(v_net),
      _fmt6(v_abs_net)
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _check_house_exposure_alert(TEXT)
  FROM PUBLIC, anon, authenticated;

INSERT INTO app_config (key, value, description, is_public)
SELECT
  'house_exposure_alert_threshold:' || symbol,
  _fmt6(
    CASE
      WHEN max_open_interest IS NOT NULL THEN max_open_interest::NUMERIC * 0.5
      WHEN symbol = 'PHONUSDT-PERP' THEN 5000
      ELSE 50000
    END
  ),
  'Warning threshold for absolute long-short user futures exposure. Detection only; no trading halt.',
  FALSE
FROM futures_markets
WHERE is_active
ON CONFLICT (key) DO NOTHING;

DO $$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.rpc_open_futures_position(text,text,text,text,text,text,text,text)'::regprocedure);

  IF position('_check_house_exposure_alert(' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_new := replace(
    v_def,
    'RETURN jsonb_build_object(',
    'PERFORM _check_house_exposure_alert(p_market);' || E'\n\n  RETURN jsonb_build_object('
  );

  IF v_new = v_def THEN
    RAISE EXCEPTION 'house exposure alert anchor not found';
  END IF;

  EXECUTE v_new;
END
$$;

REVOKE ALL ON FUNCTION rpc_open_futures_position(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_open_futures_position(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;
