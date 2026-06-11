-- ============================================================
-- Migration: 20260609000022_p1_liquidation_guard_and_history_closeout
-- ============================================================
-- Closeout hardening for the liquidation sweep.
--
-- The function was already safe at the privilege boundary because EXECUTE is
-- revoked from anon/authenticated and granted only to service_role. This
-- rewrite removes the nullable-role ambiguity in the body guard as a defense in
-- depth measure while preserving the pg_cron/postgres NULL-JWT path.
-- ============================================================

SET search_path = public, pg_temp;

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
  v_liq         NUMERIC;
  v_should_liq  BOOLEAN;
  v_liquidated  INT := 0;
  v_skipped     INT := 0;
  v_errors      INT := 0;
  v_detail      JSONB := '[]'::JSONB;
  v_err_msg     TEXT;
BEGIN
  -- service_role and pg_cron/postgres (NULL JWT role) may run the sweep.
  -- Signed-in users must be admins; anon must never reach the body even if a
  -- future GRANT accidentally exposes the function.
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
      v_liq := v_pos.liquidation_price::NUMERIC;
      v_should_liq :=
        (v_pos.side = 'long'  AND v_mark <= v_liq) OR
        (v_pos.side = 'short' AND v_mark >= v_liq);

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
