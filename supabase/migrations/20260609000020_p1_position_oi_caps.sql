-- ============================================================
-- P1 (high-risk): Per-user position cap + per-market open-interest cap
-- ============================================================
-- Plan item `oi-cap`.
--
-- Risk limits to bound platform exposure:
--   * global per-user open-position cap (app_config, default 50)
--   * per-market per-user open-position cap (futures_markets.max_user_positions)
--   * per-market total open-interest (notional) cap (futures_markets.max_open_interest,
--     NULL = uncapped)
--
-- Enforced by _assert_position_limits(user, market, new_notional), injected into
-- rpc_open_futures_position right after the notional is computed (live
-- pg_get_functiondef text; idempotent; fails loudly).
--
-- NOTE: these are SOFT risk caps, not conservation invariants. A rare concurrent
-- race could exceed a cap by one position / one notional; the request-idempotency
-- work (double-click guard) further tightens the per-user case. Caps are checked
-- before the wallet lock, so they never block settlement correctness.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Cap configuration ────────────────────────────────────────────────────────
ALTER TABLE futures_markets
  ADD COLUMN IF NOT EXISTS max_user_positions INT NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS max_open_interest  TEXT
    CONSTRAINT fm_max_oi_fmt CHECK (max_open_interest IS NULL OR max_open_interest ~ '^\d+(\.\d+)?$');

INSERT INTO app_config (key, value, description) VALUES
  ('max_open_positions_per_user', '50',
   'Global cap on concurrent open futures positions per user (across all markets).')
ON CONFLICT (key) DO NOTHING;

-- ─── Limit guard ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _assert_position_limits(
  p_user_id      UUID,
  p_market       TEXT,
  p_new_notional NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
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

-- ─── Admin: set per-market caps (reason-required, audited) ────────────────────
CREATE OR REPLACE FUNCTION rpc_set_market_limits(
  p_market             TEXT,
  p_max_user_positions INT,
  p_max_open_interest  TEXT,
  p_reason             TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_rows  INT;
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

  UPDATE futures_markets
     SET max_user_positions = p_max_user_positions,
         max_open_interest   = p_max_open_interest
   WHERE symbol = p_market;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'market_not_found' USING HINT = p_market;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_actor, 'market_limits_set', 'futures_markets',
    jsonb_build_object('market', p_market, 'max_user_positions', p_max_user_positions,
      'max_open_interest', p_max_open_interest, 'reason', p_reason));

  RETURN jsonb_build_object('market', p_market, 'max_user_positions', p_max_user_positions,
    'max_open_interest', p_max_open_interest);
END;
$$;

REVOKE ALL ON FUNCTION rpc_set_market_limits(TEXT, INT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_set_market_limits(TEXT, INT, TEXT, TEXT) TO authenticated, service_role;

-- ─── Inject the limit check into rpc_open_futures_position ─────────────────────
DO $mig$
DECLARE
  v_def TEXT;
  v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.rpc_open_futures_position(text,text,text,text,text,text,text)'::regprocedure);

  IF position('_assert_position_limits(' IN v_def) > 0 THEN
    RETURN;  -- already guarded
  END IF;

  v_new := regexp_replace(
    v_def,
    'v_notional := v_margin \* v_lev;',
    'v_notional := v_margin * v_lev;' || E'\n  PERFORM _assert_position_limits(v_user_id, p_market, v_notional);',
    ''
  );

  IF v_new = v_def THEN
    RAISE EXCEPTION 'position-limit anchor (v_notional assignment) not found';
  END IF;

  EXECUTE v_new;
END
$mig$;
