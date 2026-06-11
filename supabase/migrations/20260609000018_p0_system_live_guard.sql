-- ============================================================
-- P0 (high-risk): Global system-live guard (halt / read-only)
-- ============================================================
-- Plan item `readonly-guard`.
--
-- PROBLEM
-- There was no platform-wide kill switch. The only halt was per-market
-- (market_circuit_breakers). An operator could not freeze ALL balance-moving
-- activity during an incident (oracle compromise, exploit, insolvency scare).
--
-- FIX
--  * Two app_config flags: `system_halt` (hard freeze) and `system_readonly`
--    (maintenance). Both default 'false'.
--  * `_assert_system_live()` — STABLE SECURITY DEFINER helper that raises the
--    stable codes `system_halted` / `system_readonly` (already mapped client-side
--    to error.SYSTEM_HALTED). Internal-only (revoked from anon/authenticated).
--  * The guard is injected as the FIRST statement of every user-initiated
--    balance-moving RPC, using the live pg_get_functiondef text so no body drifts
--    from its canonical definition. Injection is idempotent and fails loudly if
--    the anchor is missing.
--  * `rpc_set_system_mode(halt, readonly, reason)` — admin-only (auth.uid() +
--    _is_admin), reason-required, audit-logged toggle.
--
-- DELIBERATELY NOT GUARDED
--  * The liquidation runner (rpc_run_liquidations / _run_liquidations_logged) and
--    rpc_liquidate_position: liquidations are solvency-protecting de-risk actions
--    and must keep running so the book cannot drift insolvent while users are
--    frozen. (On a true emergency the operator also stops oracle updates, so the
--    mark price is static and no spurious liquidations fire.)
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Flags ────────────────────────────────────────────────────────────────────
INSERT INTO app_config (key, value, description) VALUES
  ('system_halt', 'false',
   'Global emergency halt. When true, every user balance-moving RPC raises system_halted.'),
  ('system_readonly', 'false',
   'Maintenance read-only. When true, every user balance-moving RPC raises system_readonly. Liquidations still run.')
ON CONFLICT (key) DO NOTHING;

-- ─── Guard helper ───────────────────────────────────────────────────────────--
CREATE OR REPLACE FUNCTION _assert_system_live()
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_halt TEXT;
  v_ro   TEXT;
BEGIN
  SELECT value INTO v_halt FROM app_config WHERE key = 'system_halt';
  IF v_halt = 'true' THEN
    RAISE EXCEPTION 'system_halted';
  END IF;

  SELECT value INTO v_ro FROM app_config WHERE key = 'system_readonly';
  IF v_ro = 'true' THEN
    RAISE EXCEPTION 'system_readonly';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_system_live() FROM PUBLIC, anon, authenticated;

-- ─── Admin toggle (reason-required, audited) ──────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_set_system_mode(
  p_halt     BOOLEAN,
  p_readonly BOOLEAN,
  p_reason   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  UPDATE app_config
     SET value = CASE WHEN p_halt THEN 'true' ELSE 'false' END, updated_at = NOW()
   WHERE key = 'system_halt';
  UPDATE app_config
     SET value = CASE WHEN p_readonly THEN 'true' ELSE 'false' END, updated_at = NOW()
   WHERE key = 'system_readonly';

  -- Audit row is the durable record of the action; no RAISE follows it.
  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_actor, 'system_mode_set', 'app_config',
    jsonb_build_object('system_halt', p_halt, 'system_readonly', p_readonly, 'reason', p_reason));

  RETURN jsonb_build_object('system_halt', p_halt, 'system_readonly', p_readonly);
END;
$$;

REVOKE ALL ON FUNCTION rpc_set_system_mode(BOOLEAN, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_set_system_mode(BOOLEAN, BOOLEAN, TEXT) TO authenticated, service_role;

-- ─── Inject the guard into every user balance-moving RPC ──────────────────────
-- Uses the live definition (pg_get_functiondef) and inserts the guard as the
-- first statement after the outermost BEGIN. Idempotent + fails loudly.
DO $mig$
DECLARE
  v_sig  TEXT;
  v_def  TEXT;
  v_new  TEXT;
  v_sigs TEXT[] := ARRAY[
    'public.rpc_open_futures_position(text,text,text,text,text,text,text)',
    'public.rpc_close_futures_position(uuid)',
    'public.rpc_spot_market_buy(text)',
    'public.rpc_spot_market_sell(text)',
    'public.rpc_stake_phon(text,text)',
    'public.rpc_unstake_phon(uuid)',
    'public.rpc_claim_staking_reward(uuid)',
    'public.rpc_claim_daily_reward()',
    'public.rpc_spin_roulette()',
    'public.rpc_complete_mission(text)',
    'public.rpc_register_referral(text)',
    'public.rpc_claim_welcome_bonus(text)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_sigs LOOP
    v_def := pg_get_functiondef(v_sig::regprocedure);

    -- Idempotent: already guarded → skip
    IF position('_assert_system_live(' IN v_def) > 0 THEN
      CONTINUE;
    END IF;

    v_new := regexp_replace(
      v_def,
      E'\nBEGIN\n',
      E'\nBEGIN\n  PERFORM _assert_system_live();\n',
      ''  -- first match only
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'system_live guard anchor (BEGIN) not found in %', v_sig;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
$mig$;
