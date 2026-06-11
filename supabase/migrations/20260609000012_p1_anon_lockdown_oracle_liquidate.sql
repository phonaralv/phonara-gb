-- ============================================================
-- Migration: 20260609000012_p1_anon_lockdown_oracle_liquidate
-- ============================================================
-- CRITICAL access-control fix (live, exploitable over PostgREST).
--
-- Two SECURITY DEFINER RPCs treat `auth.uid() IS NULL` as a privileged
-- service-role call, but they were never revoked from anon/PUBLIC. Over
-- PostgREST the anonymous role ALSO has auth.uid() = NULL, so an unauthenticated
-- client could:
--
--   * rpc_update_oracle_price (000008): the guard is
--       IF v_actor_id IS NOT NULL AND NOT _is_admin() THEN RAISE 'forbidden'
--     -> anon (actor_id NULL) skips the guard and can move the oracle mark price
--        (within the circuit-breaker band) or repeatedly trip halts (DoS / price
--        manipulation feeding liquidations & settlement).
--
--   * rpc_liquidate_position (000009): the guard is
--       IF v_user_id IS NOT NULL AND v_pos.user_id <> v_user_id AND NOT _is_admin()
--     -> anon (user_id NULL) skips the guard and can force-liquidate ANY position
--        whose mark has crossed its liquidation price.
--
-- Fixes:
--   1. rpc_update_oracle_price: KEEP the NULL-uid path (the price-feed Edge
--      Function legitimately calls it with the service role, auth.uid() NULL),
--      but REVOKE EXECUTE from PUBLIC + anon. Admins call it as `authenticated`
--      (blocked-unless-_is_admin by the in-body guard); the feed calls it as
--      `service_role` (which bypasses GRANTs). anon can no longer reach it.
--   2. rpc_liquidate_position: this is the MANUAL owner/admin path; the automated
--      sweep is rpc_run_liquidations (service role). Require authentication
--      (reject NULL uid) and REVOKE from PUBLIC + anon.
--
-- rpc_resume_market (000008) is already safe: its guard is `IF NOT _is_admin()`,
-- which is FALSE for anon (auth.uid() NULL) -> raises forbidden. Left unchanged.
--
-- Append-only: originals (000008/000009) are untouched; rpc_liquidate_position is
-- redefined via CREATE OR REPLACE.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── 1. rpc_update_oracle_price: lock out anon, keep admin + service_role ─────
REVOKE ALL ON FUNCTION rpc_update_oracle_price(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_update_oracle_price(TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- ─── 2. rpc_liquidate_position: require auth, owner-or-admin only ─────────────

CREATE OR REPLACE FUNCTION rpc_liquidate_position(p_position_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pos     futures_positions%ROWTYPE;
  v_mark    NUMERIC;
  v_liq     NUMERIC;
  v_hit     BOOLEAN;
BEGIN
  -- Manual liquidation is for the position owner or an admin only. The
  -- service-role / cron path is rpc_run_liquidations, NOT this function, so an
  -- anonymous (NULL uid) caller must be rejected outright.
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO v_pos FROM futures_positions WHERE id = p_position_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'position_not_found'; END IF;
  IF v_pos.user_id <> v_user_id AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM _enforce_rate_limit(v_user_id, 'rpc_liquidate_position');

  -- Staleness + circuit-breaker guard
  v_mark := _assert_price_fresh(v_pos.market);

  v_liq := v_pos.liquidation_price::NUMERIC;
  IF v_pos.side = 'long' THEN
    v_hit := v_mark <= v_liq;
  ELSE
    v_hit := v_mark >= v_liq;
  END IF;
  IF NOT v_hit THEN RAISE EXCEPTION 'not_liquidatable'; END IF;

  RETURN _settle_futures_position(p_position_id, v_mark, 'liquidated', 'liquidate');
END;
$$;

REVOKE ALL ON FUNCTION rpc_liquidate_position(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_liquidate_position(UUID) TO authenticated;
