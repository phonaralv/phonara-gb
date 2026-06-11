-- ============================================================
-- P0 (high-risk): Per-feature kill switches
-- ============================================================
-- Plan item `kill-switch`.
--
-- Complements the global halt/read-only guard (000018) with surgical, per-
-- feature switches so an operator can disable exactly one product surface
-- (e.g. futures) during an incident without freezing the whole platform.
--
--   feature_<name>_enabled app_config flags (default 'true').
--   _assert_feature_enabled(name) raises `feature_disabled` (HINT=name) ONLY when
--   the flag is explicitly 'false' (missing/NULL/'true' = enabled → no accidental
--   lockout). Client maps `feature_disabled` → error.FEATURE_DISABLED.
--
-- Enforcement is injected right AFTER the existing _assert_system_live() guard,
-- using the live pg_get_functiondef text (idempotent, fails loudly, no drift):
--   futures  → rpc_open_futures_position, rpc_close_futures_position
--   spot     → rpc_spot_market_buy, rpc_spot_market_sell
--   staking  → rpc_stake_phon, rpc_unstake_phon, rpc_claim_staking_reward
--   game     → rpc_spin_roulette
--   referral → rpc_register_referral
--
-- The `deposit` / `withdrawal` flags are created now (operator-ready) but have no
-- RPC to guard yet; the guard call will be added to those RPCs when they ship.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Flags (default enabled) ──────────────────────────────────────────────────
INSERT INTO app_config (key, value, description) VALUES
  ('feature_spot_enabled',       'true', 'Spot trading kill switch. false disables rpc_spot_market_buy/sell.'),
  ('feature_futures_enabled',    'true', 'Futures kill switch. false disables rpc_open/close_futures_position.'),
  ('feature_staking_enabled',    'true', 'Staking kill switch. false disables rpc_stake/unstake/claim_staking_reward.'),
  ('feature_game_enabled',       'true', 'Game kill switch. false disables rpc_spin_roulette.'),
  ('feature_referral_enabled',   'true', 'Referral kill switch. false disables rpc_register_referral.'),
  ('feature_deposit_enabled',    'true', 'Deposit kill switch (reserved; wired when deposit RPC ships).'),
  ('feature_withdrawal_enabled', 'true', 'Withdrawal kill switch (reserved; wired when withdrawal RPC ships).')
ON CONFLICT (key) DO NOTHING;

-- ─── Guard helper ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _assert_feature_enabled(p_feature TEXT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_val TEXT;
BEGIN
  SELECT value INTO v_val FROM app_config WHERE key = 'feature_' || p_feature || '_enabled';
  -- Fail-safe: only an explicit 'false' disables; missing/NULL/'true' = enabled.
  IF v_val = 'false' THEN
    RAISE EXCEPTION 'feature_disabled' USING HINT = p_feature;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_feature_enabled(TEXT) FROM PUBLIC, anon, authenticated;

-- ─── Admin toggle (whitelisted feature, reason-required, audited) ─────────────
CREATE OR REPLACE FUNCTION rpc_set_feature_enabled(
  p_feature TEXT,
  p_enabled BOOLEAN,
  p_reason  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_key   TEXT;
  v_rows  INT;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;
  IF p_feature NOT IN ('spot','futures','staking','game','referral','deposit','withdrawal') THEN
    RAISE EXCEPTION 'invalid_feature' USING HINT = p_feature;
  END IF;

  v_key := 'feature_' || p_feature || '_enabled';
  UPDATE app_config
     SET value = CASE WHEN p_enabled THEN 'true' ELSE 'false' END, updated_at = NOW()
   WHERE key = v_key;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'invalid_feature' USING HINT = p_feature;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_actor, 'feature_toggle', 'app_config',
    jsonb_build_object('feature', p_feature, 'enabled', p_enabled, 'reason', p_reason));

  RETURN jsonb_build_object('feature', p_feature, 'enabled', p_enabled);
END;
$$;

REVOKE ALL ON FUNCTION rpc_set_feature_enabled(TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_set_feature_enabled(TEXT, BOOLEAN, TEXT) TO authenticated, service_role;

-- ─── Inject per-feature guard after the system-live guard ─────────────────────
DO $mig$
DECLARE
  v_sig  TEXT;
  v_feat TEXT;
  v_def  TEXT;
  v_new  TEXT;
  i      INT;
  v_sigs TEXT[] := ARRAY[
    'public.rpc_open_futures_position(text,text,text,text,text,text,text)',
    'public.rpc_close_futures_position(uuid)',
    'public.rpc_spot_market_buy(text)',
    'public.rpc_spot_market_sell(text)',
    'public.rpc_stake_phon(text,text)',
    'public.rpc_unstake_phon(uuid)',
    'public.rpc_claim_staking_reward(uuid)',
    'public.rpc_spin_roulette()',
    'public.rpc_register_referral(text)'
  ];
  v_feats TEXT[] := ARRAY[
    'futures',
    'futures',
    'spot',
    'spot',
    'staking',
    'staking',
    'staking',
    'game',
    'referral'
  ];
BEGIN
  FOR i IN 1..array_length(v_sigs, 1) LOOP
    v_sig  := v_sigs[i];
    v_feat := v_feats[i];
    v_def  := pg_get_functiondef(v_sig::regprocedure);

    -- Idempotent: already feature-guarded → skip
    IF position('_assert_feature_enabled(' IN v_def) > 0 THEN
      CONTINUE;
    END IF;

    v_new := regexp_replace(
      v_def,
      'PERFORM _assert_system_live\(\);',
      'PERFORM _assert_system_live();' || E'\n  PERFORM _assert_feature_enabled(''' || v_feat || ''');',
      ''  -- first match only
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'feature guard anchor (_assert_system_live) not found in %', v_sig;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
$mig$;
