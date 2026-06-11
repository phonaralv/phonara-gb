-- ============================================================
-- Consecutive two-tick liquidation buffer
-- ============================================================
-- SQL execution now requires two consecutive liquidation-breaching price ticks.
-- The TS engine's isLiquidatable remains an instant mark-vs-liq predicate; this
-- migration adds state around SQL settlement execution only.
-- ============================================================

SET search_path = public, pg_temp;

ALTER TABLE futures_positions
  ADD COLUMN IF NOT EXISTS first_breach_tick_id UUID REFERENCES price_ticks(id),
  ADD COLUMN IF NOT EXISTS first_breach_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS fp_first_breach_idx
  ON futures_positions (market, first_breach_at)
  WHERE status = 'open' AND first_breach_at IS NOT NULL;

CREATE OR REPLACE FUNCTION _is_liquidation_breached(
  p_side position_side,
  p_liquidation_price NUMERIC,
  p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_side = 'long'::position_side THEN p_mark <= p_liquidation_price
    ELSE p_mark >= p_liquidation_price
  END
$$;

REVOKE ALL ON FUNCTION _is_liquidation_breached(position_side, NUMERIC, NUMERIC)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _liquidation_buffer_state(
  p_position_id UUID,
  p_mark NUMERIC
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pos futures_positions%ROWTYPE;
  v_tick_id UUID;
  v_tick_at TIMESTAMPTZ;
  v_hit BOOLEAN;
BEGIN
  SELECT * INTO v_pos
  FROM futures_positions
  WHERE id = p_position_id
  FOR UPDATE;

  IF NOT FOUND OR v_pos.status <> 'open' THEN
    RETURN 'closed';
  END IF;

  v_hit := _is_liquidation_breached(
    v_pos.side,
    v_pos.liquidation_price::NUMERIC,
    p_mark
  );

  IF NOT v_hit THEN
    IF v_pos.first_breach_at IS NOT NULL OR v_pos.first_breach_tick_id IS NOT NULL THEN
      UPDATE futures_positions
         SET first_breach_tick_id = NULL,
             first_breach_at = NULL
       WHERE id = p_position_id;
    END IF;
    RETURN 'clear';
  END IF;

  SELECT id, created_at
    INTO v_tick_id, v_tick_at
  FROM price_ticks
  WHERE symbol = v_pos.market
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

  IF v_pos.first_breach_at IS NULL THEN
    UPDATE futures_positions
       SET first_breach_tick_id = v_tick_id,
           first_breach_at = COALESCE(v_tick_at, NOW())
     WHERE id = p_position_id;
    RETURN 'recorded';
  END IF;

  IF v_tick_id IS NULL THEN
    RETURN 'waiting';
  END IF;

  IF v_pos.first_breach_tick_id IS DISTINCT FROM v_tick_id THEN
    RETURN 'ready';
  END IF;

  RETURN 'waiting';
END;
$$;

REVOKE ALL ON FUNCTION _liquidation_buffer_state(UUID, NUMERIC)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _apply_liquidation_buffer(
  p_position_id UUID,
  p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT _liquidation_buffer_state(p_position_id, p_mark) = 'ready'
$$;

REVOKE ALL ON FUNCTION _apply_liquidation_buffer(UUID, NUMERIC)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_run_liquidations()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_symbol      TEXT;
  v_mark        NUMERIC;
  v_pos         futures_positions%ROWTYPE;
  v_should_liq  BOOLEAN;
  v_liquidated  INT := 0;
  v_skipped     INT := 0;
  v_errors      INT := 0;
  v_detail      JSONB := '[]'::JSONB;
  v_err_msg     TEXT;
BEGIN
  IF auth.role() = 'anon' OR (auth.role() = 'authenticated' AND NOT _is_admin()) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  FOR v_symbol IN
    SELECT fm.symbol
    FROM futures_markets fm
    JOIN market_circuit_breakers mcb ON mcb.symbol = fm.symbol
    WHERE fm.is_active AND NOT mcb.is_halted
  LOOP
    BEGIN
      v_mark := _assert_price_fresh(v_symbol);
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END;

    FOR v_pos IN
      SELECT *
      FROM futures_positions
      WHERE market = v_symbol AND status = 'open'
      FOR UPDATE SKIP LOCKED
    LOOP
      v_should_liq := _apply_liquidation_buffer(v_pos.id, v_mark);

      IF NOT v_should_liq THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      BEGIN
        PERFORM _settle_futures_position(v_pos.id, v_mark, 'liquidated', 'auto_liquidate');
        v_liquidated := v_liquidated + 1;
        v_detail := v_detail || jsonb_build_object(
          'position_id', v_pos.id,
          'user_id', v_pos.user_id,
          'market', v_symbol,
          'side', v_pos.side,
          'mark', _fmt6(v_mark)
        );
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
        v_errors := v_errors + 1;
        v_detail := v_detail || jsonb_build_object(
          'position_id', v_pos.id,
          'error', v_err_msg
        );
      END;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'liquidated', v_liquidated,
    'skipped', v_skipped,
    'errors', v_errors,
    'detail', v_detail,
    'ran_at', NOW()
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_run_liquidations() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_run_liquidations() TO service_role;

CREATE OR REPLACE FUNCTION rpc_liquidate_position(p_position_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_mark    NUMERIC;
  v_state   TEXT;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM _enforce_rate_limit(v_user_id, 'rpc_liquidate_position');

  v_mark := _assert_price_fresh(v_pos.market);
  v_state := _liquidation_buffer_state(p_position_id, v_mark);

  IF v_state = 'ready' THEN
    RETURN _settle_futures_position(p_position_id, v_mark, 'liquidated', 'liquidate');
  END IF;

  IF v_state IN ('recorded', 'waiting') THEN
    RETURN jsonb_build_object(
      'ok', FALSE,
      'reason', 'liquidation_buffer_pending',
      'position_id', p_position_id,
      'mark', _fmt6(v_mark)
    );
  END IF;

  IF v_state = 'closed' THEN
    RAISE EXCEPTION 'position_not_open';
  ELSE
    RAISE EXCEPTION 'not_liquidatable';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION rpc_liquidate_position(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_liquidate_position(UUID) TO authenticated;
