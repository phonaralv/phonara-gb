-- ============================================================
-- Stage 2: Conservative launch risk limits
-- ============================================================
-- Keeps the existing per-market max_leverage structure, but launches with
-- conservative defaults and requires every active market to have a finite
-- open-interest cap. No settlement math changes.
-- ============================================================

SET search_path = public, pg_temp;

UPDATE futures_markets
   SET max_leverage = CASE symbol
         WHEN 'PHONUSDT-PERP' THEN '10'
         WHEN 'BTCUSDT-SIM'   THEN '20'
         WHEN 'ETHUSDT-SIM'   THEN '20'
         ELSE LEAST(max_leverage::NUMERIC, 10)::TEXT
       END,
       max_open_interest = CASE symbol
         WHEN 'PHONUSDT-PERP' THEN '100000.000000'
         WHEN 'BTCUSDT-SIM'   THEN '500000.000000'
         WHEN 'ETHUSDT-SIM'   THEN '500000.000000'
         ELSE COALESCE(max_open_interest, '50000.000000')
       END
 WHERE is_active;

ALTER TABLE futures_markets
  ALTER COLUMN max_leverage SET DEFAULT '10';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fm_active_oi_required'
  ) THEN
    ALTER TABLE futures_markets
      ADD CONSTRAINT fm_active_oi_required CHECK (NOT is_active OR max_open_interest IS NOT NULL);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fm_max_leverage_range'
  ) THEN
    ALTER TABLE futures_markets
      ADD CONSTRAINT fm_max_leverage_range CHECK (
        max_leverage ~ '^\d+(\.\d+)?$'
        AND max_leverage::NUMERIC >= 1
        AND max_leverage::NUMERIC <= 100
      );
  END IF;
END
$$;

DROP FUNCTION IF EXISTS rpc_set_market_limits(TEXT, INT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION rpc_set_market_limits(
  p_market             TEXT,
  p_max_user_positions INT,
  p_max_open_interest  TEXT,
  p_max_leverage       TEXT,
  p_reason             TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_is_active BOOLEAN;
  v_rows     INT;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;
  IF p_max_user_positions IS NULL OR p_max_user_positions < 1 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'max_user_positions';
  END IF;
  IF p_max_open_interest IS NOT NULL AND p_max_open_interest !~ '^\d+(\.\d+)?$' THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'max_open_interest';
  END IF;
  IF p_max_leverage IS NULL
     OR p_max_leverage !~ '^\d+(\.\d+)?$'
     OR p_max_leverage::NUMERIC < 1
     OR p_max_leverage::NUMERIC > 100 THEN
    RAISE EXCEPTION 'invalid_input' USING HINT = 'max_leverage';
  END IF;

  SELECT is_active INTO v_is_active
    FROM futures_markets
   WHERE symbol = p_market;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'market_not_found' USING HINT = p_market;
  END IF;
  IF v_is_active AND p_max_open_interest IS NULL THEN
    RAISE EXCEPTION 'oi_cap_required' USING HINT = p_market;
  END IF;

  UPDATE futures_markets
     SET max_user_positions = p_max_user_positions,
         max_open_interest   = p_max_open_interest,
         max_leverage        = p_max_leverage
   WHERE symbol = p_market;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'market_not_found' USING HINT = p_market;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_actor, 'market_limits_set', 'futures_markets',
    jsonb_build_object(
      'market', p_market,
      'max_user_positions', p_max_user_positions,
      'max_open_interest', p_max_open_interest,
      'max_leverage', p_max_leverage,
      'reason', p_reason
    ));

  RETURN jsonb_build_object(
    'market', p_market,
    'max_user_positions', p_max_user_positions,
    'max_open_interest', p_max_open_interest,
    'max_leverage', p_max_leverage
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_set_market_limits(TEXT, INT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_set_market_limits(TEXT, INT, TEXT, TEXT, TEXT) TO authenticated, service_role;
