-- ============================================================
-- Migration: 20260609000030_s4_live_surface_hardening
-- S4: live surface hardening for roulette, referral, reserve, staking, consent
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Consent gate default ON ──────────────────────────────────────────────────

UPDATE app_config
   SET value = 'true', updated_at = NOW()
 WHERE key = 'consent_gate_enabled';

-- ─── Roulette HMAC result path and reveal split ───────────────────────────────

REVOKE SELECT ON roulette_spins FROM anon, authenticated;
GRANT SELECT (
  id, user_id, spun_date, prize_index, phon_awarded,
  server_seed_hash, ledger_entry_id, created_at
) ON roulette_spins TO anon, authenticated;

CREATE OR REPLACE FUNCTION _roulette_weighted_index(p_roll INT)
RETURNS INT
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_weights INT[] := ARRAY[3000,2500,2000,1200,700,300,200,100];
  v_cumulative INT := 0;
BEGIN
  FOR v_idx IN 1..array_length(v_weights, 1) LOOP
    v_cumulative := v_cumulative + v_weights[v_idx];
    IF p_roll < v_cumulative THEN
      RETURN v_idx - 1;
    END IF;
  END LOOP;
  RETURN array_length(v_weights, 1) - 1;
END;
$$;

REVOKE ALL ON FUNCTION _roulette_weighted_index(INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _roulette_roll_from_seed(
  p_server_seed TEXT,
  p_user_id UUID,
  p_spin_date DATE
)
RETURNS INT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sig BYTEA;
  v_f NUMERIC;
BEGIN
  v_sig := extensions.hmac(
    convert_to(p_user_id::TEXT || ':' || p_spin_date::TEXT || ':0', 'UTF8'),
    convert_to(p_server_seed, 'UTF8'),
    'sha256'
  );
  v_f :=
    get_byte(v_sig, 0)::NUMERIC / 256
    + get_byte(v_sig, 1)::NUMERIC / 65536
    + get_byte(v_sig, 2)::NUMERIC / 16777216
    + get_byte(v_sig, 3)::NUMERIC / 4294967296;
  RETURN floor(v_f * 10000)::INT;
END;
$$;

REVOKE ALL ON FUNCTION _roulette_roll_from_seed(TEXT, UUID, DATE) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_spin_roulette()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_today DATE := CURRENT_DATE;
  v_prizes NUMERIC[] := ARRAY[10,20,30,50,100,300,500,1000];
  v_seed TEXT;
  v_seed_hash TEXT;
  v_roll INT;
  v_prize_idx INT;
  v_phon_amount NUMERIC;
  v_phon_text TEXT;
  v_idem_key TEXT;
  v_ledger_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('game');
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_spin_roulette');
  PERFORM _assert_onboarding_consent(v_user_id);

  PERFORM 1 FROM roulette_spins WHERE user_id = v_user_id AND spun_date = v_today;
  IF FOUND THEN
    RETURN (
      SELECT jsonb_build_object(
        'already_spun', TRUE,
        'phon_awarded', phon_awarded,
        'prize_index', prize_index,
        'seed_hash', server_seed_hash
      )
      FROM roulette_spins
      WHERE user_id = v_user_id AND spun_date = v_today
    );
  END IF;

  v_seed := encode(extensions.gen_random_bytes(32), 'hex');
  v_seed_hash := encode(extensions.digest(v_seed, 'sha256'), 'hex');
  v_roll := _roulette_roll_from_seed(v_seed, v_user_id, v_today);
  v_prize_idx := _roulette_weighted_index(v_roll);
  v_phon_amount := v_prizes[v_prize_idx + 1];
  v_phon_text := to_char(v_phon_amount, 'FM9999990.000000');
  v_idem_key := 'roulette:' || v_user_id::TEXT || ':' || v_today::TEXT;

  PERFORM _credit_wallet_internal(v_user_id, 'PHON', v_phon_text, 'roulette_spin', v_idem_key);
  SELECT id INTO v_ledger_id FROM wallet_ledger WHERE idempotency_key = v_idem_key LIMIT 1;

  INSERT INTO roulette_spins (
    user_id, spun_date, prize_index, phon_awarded,
    server_seed_hash, server_seed, ledger_entry_id
  ) VALUES (
    v_user_id, v_today, v_prize_idx, v_phon_text,
    v_seed_hash, v_seed, v_ledger_id
  );

  RETURN jsonb_build_object(
    'already_spun', FALSE,
    'prize_index', v_prize_idx,
    'phon_awarded', v_phon_text,
    'seed_hash', v_seed_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_spin_roulette() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_spin_roulette() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION rpc_reveal_roulette_spin(p_spin_date DATE DEFAULT CURRENT_DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_spin roulette_spins%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO v_spin
  FROM roulette_spins
  WHERE user_id = v_user_id AND spun_date = p_spin_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'spin_not_found'; END IF;

  RETURN jsonb_build_object(
    'spun_date', v_spin.spun_date,
    'prize_index', v_spin.prize_index,
    'phon_awarded', v_spin.phon_awarded,
    'server_seed_hash', v_spin.server_seed_hash,
    'server_seed', v_spin.server_seed,
    'roll', _roulette_roll_from_seed(v_spin.server_seed, v_user_id, v_spin.spun_date)
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_reveal_roulette_spin(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_reveal_roulette_spin(DATE) TO authenticated, service_role;

-- ─── Referral exact match and minimum length ──────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_register_referral(p_referrer_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_referrer UUID;
  v_code TEXT := lower(btrim(p_referrer_code));
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('referral');

  IF v_code IS NULL OR length(v_code) < 8 THEN
    RETURN jsonb_build_object('registered', FALSE, 'reason', 'invalid_code');
  END IF;

  PERFORM 1 FROM referrals WHERE referred_id = v_user_id;
  IF FOUND THEN
    RETURN jsonb_build_object('registered', FALSE, 'reason', 'already_referred');
  END IF;

  SELECT id INTO v_referrer
  FROM profiles
  WHERE lower(username) = v_code
  LIMIT 1;

  IF v_referrer IS NULL THEN
    RETURN jsonb_build_object('registered', FALSE, 'reason', 'invalid_code');
  END IF;
  IF v_referrer = v_user_id THEN
    RETURN jsonb_build_object('registered', FALSE, 'reason', 'self_referral');
  END IF;

  INSERT INTO referrals (referrer_id, referred_id)
  VALUES (v_referrer, v_user_id)
  ON CONFLICT (referred_id) DO NOTHING;

  RETURN jsonb_build_object('registered', TRUE, 'referrer_id', v_referrer);
END;
$$;

REVOKE ALL ON FUNCTION rpc_register_referral(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_register_referral(TEXT) TO authenticated, service_role;

-- ─── Reserve admin wrapping ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_update_treasury_reserve(
  p_currency TEXT,
  p_balance TEXT,
  p_buffer_pct NUMERIC DEFAULT NULL,
  p_cap_pct NUMERIC DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ccy currency;
BEGIN
  IF NOT _is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_notes IS NULL OR length(btrim(p_notes)) = 0 THEN RAISE EXCEPTION 'reason_required'; END IF;

  BEGIN
    v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  PERFORM _assert_amount_text(p_balance);

  UPDATE treasury_reserves SET
    real_balance = p_balance,
    buffer_pct = COALESCE(p_buffer_pct, buffer_pct),
    payout_cap_pct = COALESCE(p_cap_pct, payout_cap_pct),
    updated_at = NOW(),
    updated_by = v_user_id,
    notes = p_notes
  WHERE currency = v_ccy;
  IF NOT FOUND THEN RAISE EXCEPTION 'currency_not_found'; END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, payload)
  VALUES (v_user_id, 'treasury_reserve_update', 'treasury_reserves',
    jsonb_build_object('currency', v_ccy, 'real_balance', p_balance, 'reason', p_notes));

  RETURN jsonb_build_object('ok', TRUE, 'currency', p_currency, 'real_balance', p_balance);
END;
$$;

REVOKE ALL ON FUNCTION rpc_update_treasury_reserve(TEXT, TEXT, NUMERIC, NUMERIC, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_update_treasury_reserve(TEXT, TEXT, NUMERIC, NUMERIC, TEXT)
  TO authenticated, service_role;

-- ─── Staking deterministic idempotency key ────────────────────────────────────

CREATE OR REPLACE FUNCTION _uuid_from_md5(p_value TEXT)
RETURNS UUID
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (
    substr(md5(p_value), 1, 8) || '-' ||
    substr(md5(p_value), 9, 4) || '-' ||
    substr(md5(p_value), 13, 4) || '-' ||
    substr(md5(p_value), 17, 4) || '-' ||
    substr(md5(p_value), 21, 12)
  )::UUID;
$$;

REVOKE ALL ON FUNCTION _uuid_from_md5(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_stake_phon(
  p_term TEXT,
  p_amount TEXT,
  p_client_request_id TEXT DEFAULT NULL::TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_pool staking_pools%ROWTYPE;
  v_amount NUMERIC;
  v_pos_id UUID;
  v_unlock TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _assert_system_live();
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_stake_phon');
  PERFORM _assert_feature_enabled('staking');
  PERFORM _assert_onboarding_consent(v_user_id);

  IF p_client_request_id IS NOT NULL THEN
    INSERT INTO rpc_request_idem (user_id, client_request_id, rpc_name)
    VALUES (v_user_id, p_client_request_id, 'rpc_stake_phon')
    ON CONFLICT (user_id, client_request_id) DO NOTHING;
    IF NOT FOUND THEN RAISE EXCEPTION 'duplicate_request'; END IF;
    v_pos_id := _uuid_from_md5('stake:' || v_user_id::TEXT || ':' || p_client_request_id);
  ELSE
    v_pos_id := gen_random_uuid();
  END IF;

  PERFORM _assert_amount_text(p_amount);
  v_amount := p_amount::NUMERIC;
  IF v_amount <= 0 THEN RAISE EXCEPTION 'invalid_amount'; END IF;

  SELECT * INTO v_pool FROM staking_pools WHERE term = p_term::staking_term AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'pool_not_found'; END IF;

  PERFORM _lock_wallet_internal(v_user_id, 'PHON', _fmt6(v_amount),
    'staking_lock', 'stake_lock:' || v_pos_id::TEXT);

  IF v_pool.lock_days > 0 THEN
    v_unlock := NOW() + (v_pool.lock_days || ' days')::INTERVAL;
  END IF;

  INSERT INTO staking_positions (id, user_id, pool_id, term, principal, apr_snapshot, lock_days, unlock_at)
  VALUES (v_pos_id, v_user_id, v_pool.id, v_pool.term, _fmt6(v_amount), v_pool.estimated_apr, v_pool.lock_days, v_unlock);

  RETURN jsonb_build_object('position_id', v_pos_id, 'term', p_term,
    'principal', _fmt6(v_amount), 'apr', v_pool.estimated_apr, 'unlock_at', v_unlock);
END;
$$;

REVOKE ALL ON FUNCTION rpc_stake_phon(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_stake_phon(TEXT, TEXT, TEXT) TO authenticated, service_role;
