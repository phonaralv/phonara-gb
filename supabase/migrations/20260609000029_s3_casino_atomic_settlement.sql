-- ============================================================
-- Migration: 20260609000029_s3_casino_atomic_settlement
-- S3: Casino atomic settlement, guards, seed isolation, and ops controls
-- ============================================================

SET search_path = public, pg_temp;

-- ─── Schema hardening ─────────────────────────────────────────────────────────

INSERT INTO system_accounts (code, currency, description) VALUES
  ('game_house_phon', 'PHON', 'Casino house counterparty for PHON bets. May go negative when players win.'),
  ('game_house_usdt', 'USDT', 'Casino house counterparty for USDT bets. May go negative when players win.')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE game_bets DROP CONSTRAINT IF EXISTS game_bets_idempotency_key_key;
CREATE UNIQUE INDEX IF NOT EXISTS gb_user_idem_key ON game_bets (user_id, idempotency_key);

ALTER TABLE game_bets
  ADD COLUMN IF NOT EXISTS parity_hold BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS house_ledger_transfer_id UUID,
  ADD COLUMN IF NOT EXISTS dust_ledger_transfer_id UUID;

DROP POLICY IF EXISTS "admin all game_bets" ON game_bets;
CREATE POLICY "admin read game_bets" ON game_bets
  FOR SELECT USING (_is_admin());

DROP POLICY IF EXISTS "public read open rounds" ON game_rounds;
CREATE POLICY "admin read game_rounds" ON game_rounds
  FOR SELECT USING (_is_admin());

REVOKE SELECT ON game_rounds FROM anon, authenticated;
REVOKE SELECT (server_seed) ON game_rounds FROM anon, authenticated;

CREATE OR REPLACE VIEW v_game_rounds_public
WITH (security_invoker = true)
AS
SELECT
  id,
  game,
  server_seed_hash,
  status,
  result_payload,
  created_at,
  settled_at
FROM game_rounds;

GRANT SELECT ON v_game_rounds_public TO anon, authenticated;

-- ─── Config defaults ──────────────────────────────────────────────────────────

INSERT INTO app_config (key, value, description) VALUES
  ('feature_game_crash_enabled', 'true', 'Per-game kill switch for Crash.'),
  ('feature_game_limbo_enabled', 'true', 'Per-game kill switch for Limbo.'),
  ('feature_game_dice_enabled', 'true', 'Per-game kill switch for Dice.'),
  ('feature_game_mines_enabled', 'true', 'Per-game kill switch for Mines.'),
  ('feature_game_hilo_enabled', 'true', 'Per-game kill switch for HiLo.'),
  ('feature_game_plinko_enabled', 'true', 'Per-game kill switch for Plinko.'),
  ('casino_min_stake_phon', '1.000000', 'Minimum PHON casino stake.'),
  ('casino_max_stake_phon', '100000.000000', 'Maximum PHON casino stake.'),
  ('casino_min_stake_usdt', '0.010000', 'Minimum USDT casino stake.'),
  ('casino_max_stake_usdt', '10000.000000', 'Maximum USDT casino stake.'),
  ('casino_max_payout_phon', '1000000.000000', 'Maximum PHON payout per bet.'),
  ('casino_max_payout_usdt', '100000.000000', 'Maximum USDT payout per bet.'),
  ('casino_house_exposure_cap_phon', '5000000.000000', 'Total PHON casino house exposure cap.'),
  ('casino_house_exposure_cap_usdt', '500000.000000', 'Total USDT casino house exposure cap.'),
  ('casino_limbo_max_target', '1000000.000000', 'Maximum Limbo target multiplier.'),
  ('casino_stale_pending_minutes', '10', 'Minutes before non-parity pending casino bets are swept.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO rpc_rate_limit_configs (rpc_name, capacity, refill_rate, cost, window_sec) VALUES
  ('rpc_place_game_bet', 20, 0.333, 1, 60),
  ('rpc_cancel_game_bet', 10, 0.167, 1, 60)
ON CONFLICT (rpc_name) DO UPDATE
  SET capacity = EXCLUDED.capacity,
      refill_rate = EXCLUDED.refill_rate,
      cost = EXCLUDED.cost,
      window_sec = EXCLUDED.window_sec,
      is_active = TRUE;

-- ─── Guard helpers ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _assert_game_feature_enabled(p_game game_code)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_val TEXT;
  v_key TEXT := 'feature_game_' || p_game::TEXT || '_enabled';
BEGIN
  SELECT value INTO v_val FROM app_config WHERE key = v_key;
  IF v_val = 'false' THEN
    RAISE EXCEPTION 'feature_disabled' USING HINT = v_key;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_game_feature_enabled(game_code) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _app_config_numeric(p_key TEXT, p_default NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_value TEXT;
BEGIN
  SELECT value INTO v_value FROM app_config WHERE key = p_key;
  IF v_value IS NULL OR v_value !~ '^-?\d+(\.\d+)?$' THEN
    RETURN p_default;
  END IF;
  RETURN v_value::NUMERIC;
END;
$$;

REVOKE ALL ON FUNCTION _app_config_numeric(TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _assert_game_stake_limits(
  p_game game_code,
  p_currency currency,
  p_stake NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_suffix TEXT := lower(p_currency::TEXT);
  v_min NUMERIC;
  v_max NUMERIC;
BEGIN
  v_min := _app_config_numeric('casino_' || p_game::TEXT || '_min_stake_' || v_suffix,
           _app_config_numeric('casino_min_stake_' || v_suffix, 0));
  v_max := _app_config_numeric('casino_' || p_game::TEXT || '_max_stake_' || v_suffix,
           _app_config_numeric('casino_max_stake_' || v_suffix, 999999999));

  IF p_stake < v_min OR p_stake > v_max THEN
    RAISE EXCEPTION 'stake_out_of_range' USING HINT = p_game::TEXT || ':' || p_currency::TEXT;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_game_stake_limits(game_code, currency, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ─── Provably fair SQL primitives ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _game_float_stream(
  p_server_seed TEXT,
  p_client_seed TEXT,
  p_nonce INT,
  p_count INT
)
RETURNS NUMERIC[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_out NUMERIC[] := ARRAY[]::NUMERIC[];
  v_cursor INT := 0;
  v_sig BYTEA;
  v_i INT;
  v_f NUMERIC;
BEGIN
  IF p_count < 0 OR p_count > 64 THEN
    RAISE EXCEPTION 'invalid_float_count';
  END IF;

  WHILE cardinality(v_out) < p_count LOOP
    v_sig := extensions.hmac(
      convert_to(p_client_seed || ':' || p_nonce::TEXT || ':' || v_cursor::TEXT, 'UTF8'),
      convert_to(p_server_seed, 'UTF8'),
      'sha256'
    );

    v_i := 0;
    WHILE v_i + 3 < length(v_sig) AND cardinality(v_out) < p_count LOOP
      v_f :=
        get_byte(v_sig, v_i)::NUMERIC / 256
        + get_byte(v_sig, v_i + 1)::NUMERIC / 65536
        + get_byte(v_sig, v_i + 2)::NUMERIC / 16777216
        + get_byte(v_sig, v_i + 3)::NUMERIC / 4294967296;
      v_out := array_append(v_out, v_f);
      v_i := v_i + 4;
    END LOOP;

    v_cursor := v_cursor + 1;
  END LOOP;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION _game_float_stream(TEXT, TEXT, INT, INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _require_game_float(p_floats NUMERIC[], p_index INT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_index < 1 OR p_index > cardinality(p_floats) OR p_floats[p_index] IS NULL THEN
    RAISE EXCEPTION 'float_stream_exhausted' USING HINT = p_index::TEXT;
  END IF;
  RETURN p_floats[p_index];
END;
$$;

REVOKE ALL ON FUNCTION _require_game_float(NUMERIC[], INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _plinko_multiplier(p_rows INT, p_risk TEXT, p_bucket INT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_table NUMERIC[];
BEGIN
  IF p_rows = 8 AND p_risk = 'low' THEN v_table := ARRAY[6.5,1.6,1,0.9,0.9,0.9,1,1.6,6.5];
  ELSIF p_rows = 8 AND p_risk = 'medium' THEN v_table := ARRAY[15.9,2.4,1,0.7,0.7,0.7,1,2.4,15.9];
  ELSIF p_rows = 8 AND p_risk = 'high' THEN v_table := ARRAY[28.4,3.5,1,0.5,0.4,0.5,1,3.5,28.4];
  ELSIF p_rows = 12 AND p_risk = 'low' THEN v_table := ARRAY[63.9,6.3,1.8,1.1,0.9,0.9,0.8,0.9,0.9,1.1,1.8,6.3,63.9];
  ELSIF p_rows = 12 AND p_risk = 'medium' THEN v_table := ARRAY[168.9,14.5,3,1.2,0.8,0.7,0.6,0.7,0.8,1.2,3,14.5,168.9];
  ELSIF p_rows = 12 AND p_risk = 'high' THEN v_table := ARRAY[319,26.6,4.8,1.5,0.6,0.4,0.3,0.4,0.6,1.5,4.8,26.6,319];
  ELSIF p_rows = 16 AND p_risk = 'low' THEN v_table := ARRAY[788,51.8,7.9,2.4,1.3,1,0.9,0.8,0.8,0.8,0.9,1,1.3,2.4,7.9,51.8,788];
  ELSIF p_rows = 16 AND p_risk = 'medium' THEN v_table := ARRAY[2153.8,135,18.4,4.3,1.6,0.9,0.7,0.6,0.6,0.6,0.7,0.9,1.6,4.3,18.4,135,2153.8];
  ELSIF p_rows = 16 AND p_risk = 'high' THEN v_table := ARRAY[3836,239.7,32,6.8,2.1,0.9,0.5,0.3,0.3,0.3,0.5,0.9,2.1,6.8,32,239.7,3836];
  ELSE
    RAISE EXCEPTION 'invalid_plinko_selection';
  END IF;

  IF p_bucket < 0 OR p_bucket > p_rows THEN
    RAISE EXCEPTION 'invalid_plinko_bucket';
  END IF;
  RETURN v_table[p_bucket + 1];
END;
$$;

REVOKE ALL ON FUNCTION _plinko_multiplier(INT, TEXT, INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _mines_multiplier(p_mine_count INT, p_reveal_count INT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mult NUMERIC := 1;
  v_safe NUMERIC;
  v_total NUMERIC;
BEGIN
  IF p_reveal_count <= 0 THEN
    RETURN 1;
  END IF;
  FOR v_k IN 0..(p_reveal_count - 1) LOOP
    v_safe := 25 - p_mine_count - v_k;
    v_total := 25 - v_k;
    IF v_safe <= 0 OR v_total <= 0 THEN
      EXIT;
    END IF;
    v_mult := v_mult * v_total / v_safe;
  END LOOP;
  RETURN floor(v_mult * 99) / 100;
END;
$$;

REVOKE ALL ON FUNCTION _mines_multiplier(INT, INT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _hilo_step_multiplier(p_card INT, p_guess TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_winning_cards NUMERIC;
BEGIN
  IF p_guess = 'skip' THEN
    RETURN 1;
  END IF;
  v_winning_cards := CASE WHEN p_guess = 'higher' THEN 13 - p_card ELSE p_card - 1 END;
  IF v_winning_cards <= 0 THEN
    RETURN 0;
  END IF;
  RETURN floor(99 * 13 / v_winning_cards) / 100;
END;
$$;

REVOKE ALL ON FUNCTION _hilo_step_multiplier(INT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _game_max_payout_multiplier(p_game game_code, p_selection JSONB)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target NUMERIC;
  v_target_cents INT;
  v_probability NUMERIC;
  v_guess TEXT;
  v_current INT;
  v_mult NUMERIC := 1;
  v_rows INT;
  v_risk TEXT;
  v_max NUMERIC := 0;
BEGIN
  CASE p_game
    WHEN 'crash' THEN
      v_target := (p_selection->>'autoCashout')::NUMERIC;
      RETURN v_target;
    WHEN 'limbo' THEN
      v_target := (p_selection->>'target')::NUMERIC;
      IF v_target > _app_config_numeric('casino_limbo_max_target', 1000000) THEN
        RAISE EXCEPTION 'limbo_target_too_high';
      END IF;
      RETURN v_target;
    WHEN 'dice' THEN
      v_target := (p_selection->>'target')::NUMERIC;
      v_target_cents := floor(v_target * 100);
      IF p_selection->>'direction' = 'over' THEN
        v_probability := (9999 - v_target_cents)::NUMERIC / 10000;
      ELSE
        v_probability := v_target_cents::NUMERIC / 10000;
      END IF;
      IF v_probability <= 0 THEN RAISE EXCEPTION 'invalid_dice_target'; END IF;
      RETURN floor(99 / v_probability) / 100;
    WHEN 'mines' THEN
      RETURN _mines_multiplier((p_selection->>'mineCount')::INT, jsonb_array_length(p_selection->'revealedCells'));
    WHEN 'hilo' THEN
      v_current := COALESCE((p_selection->>'startCard')::INT, 7);
      FOR v_guess IN SELECT jsonb_array_elements_text(p_selection->'guesses') LOOP
        v_mult := floor(v_mult * _hilo_step_multiplier(v_current, v_guess) * 100) / 100;
      END LOOP;
      RETURN v_mult;
    WHEN 'plinko' THEN
      v_rows := (p_selection->>'rows')::INT;
      v_risk := p_selection->>'risk';
      FOR v_bucket_idx IN 0..v_rows LOOP
        v_max := GREATEST(v_max, _plinko_multiplier(v_rows, v_risk, v_bucket_idx));
      END LOOP;
      RETURN v_max;
    ELSE
      RAISE EXCEPTION 'invalid_game_code';
  END CASE;
END;
$$;

REVOKE ALL ON FUNCTION _game_max_payout_multiplier(game_code, JSONB) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _assert_game_exposure_cap(
  p_game game_code,
  p_currency currency,
  p_stake NUMERIC,
  p_selection JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_suffix TEXT := lower(p_currency::TEXT);
  v_max_mult NUMERIC;
  v_max_payout NUMERIC;
  v_payout_cap NUMERIC;
  v_total_cap NUMERIC;
  v_game_cap NUMERIC;
BEGIN
  v_max_mult := _game_max_payout_multiplier(p_game, p_selection);
  v_max_payout := p_stake * v_max_mult;
  v_payout_cap := _app_config_numeric('casino_max_payout_' || v_suffix, 999999999);
  v_total_cap := _app_config_numeric('casino_house_exposure_cap_' || v_suffix, 999999999);
  v_game_cap := _app_config_numeric('casino_' || p_game::TEXT || '_house_exposure_cap_' || v_suffix, v_total_cap);

  IF v_max_payout > v_payout_cap OR v_max_payout > v_total_cap OR v_max_payout > v_game_cap THEN
    RAISE EXCEPTION 'house_exposure_cap' USING HINT = p_game::TEXT || ':' || p_currency::TEXT;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_game_exposure_cap(game_code, currency, NUMERIC, JSONB) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _game_result(
  p_game game_code,
  p_server_seed TEXT,
  p_client_seed TEXT,
  p_nonce INT,
  p_selection JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_floats NUMERIC[];
  v_f NUMERIC;
  v_roll NUMERIC;
  v_target NUMERIC;
  v_probability NUMERIC;
  v_multiplier NUMERIC := 0;
  v_won BOOLEAN := FALSE;
  v_result JSONB;
  v_rows INT;
  v_risk TEXT;
  v_path JSONB := '[]'::JSONB;
  v_bucket INT := 0;
  v_dir INT;
  v_mine_count INT;
  v_revealed INT[];
  v_positions INT[] := ARRAY[]::INT[];
  v_cells INT[] := ARRAY[]::INT[];
  v_j INT;
  v_tmp INT;
  v_hit BOOLEAN := FALSE;
  v_guess TEXT;
  v_current_card INT;
  v_next_card INT;
  v_float_idx INT;
  v_cards JSONB := '[]'::JSONB;
  v_rounds JSONB := '[]'::JSONB;
  v_correct BOOLEAN;
BEGIN
  CASE p_game
    WHEN 'dice' THEN
      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, 1);
      v_roll := floor(_require_game_float(v_floats, 1) * 10000) / 100;
      v_target := (p_selection->>'target')::NUMERIC;
      IF p_selection->>'direction' = 'over' THEN
        v_won := v_roll > v_target;
        v_probability := (9999 - floor(v_target * 100))::NUMERIC / 10000;
      ELSIF p_selection->>'direction' = 'under' THEN
        v_won := v_roll < v_target;
        v_probability := floor(v_target * 100)::NUMERIC / 10000;
      ELSE
        RAISE EXCEPTION 'invalid_dice_direction';
      END IF;
      IF v_probability <= 0 THEN RAISE EXCEPTION 'invalid_dice_target'; END IF;
      v_multiplier := CASE WHEN v_won THEN floor(99 / v_probability) / 100 ELSE 0 END;
      v_result := jsonb_build_object('roll', v_roll, 'won', v_won);

    WHEN 'limbo' THEN
      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, 1);
      v_f := _require_game_float(v_floats, 1);
      v_roll := LEAST(1000000, GREATEST(1, floor(99 / (1 - v_f)) / 100));
      v_target := (p_selection->>'target')::NUMERIC;
      IF v_target > _app_config_numeric('casino_limbo_max_target', 1000000) THEN
        RAISE EXCEPTION 'limbo_target_too_high';
      END IF;
      v_won := v_roll >= v_target;
      v_multiplier := CASE WHEN v_won THEN v_target ELSE 0 END;
      v_result := jsonb_build_object('resultMultiplier', v_roll, 'won', v_won);

    WHEN 'crash' THEN
      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, 1);
      v_f := _require_game_float(v_floats, 1);
      v_roll := GREATEST(1, floor(99 / (1 - v_f)) / 100);
      v_target := (p_selection->>'autoCashout')::NUMERIC;
      v_won := v_target <= v_roll AND v_target >= 1.01;
      v_multiplier := CASE WHEN v_won THEN v_target ELSE 0 END;
      v_result := jsonb_build_object('crashMultiplier', v_roll, 'cashedOut', v_won, 'cashoutMultiplier', v_multiplier);

    WHEN 'plinko' THEN
      v_rows := (p_selection->>'rows')::INT;
      v_risk := p_selection->>'risk';
      IF v_rows NOT IN (8, 12, 16) THEN RAISE EXCEPTION 'invalid_plinko_selection'; END IF;
      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, v_rows);
      FOR v_row_idx IN 1..v_rows LOOP
        v_dir := CASE WHEN _require_game_float(v_floats, v_row_idx) < 0.5 THEN 0 ELSE 1 END;
        v_path := v_path || to_jsonb(v_dir);
        v_bucket := v_bucket + v_dir;
      END LOOP;
      v_multiplier := _plinko_multiplier(v_rows, v_risk, v_bucket);
      v_result := jsonb_build_object('path', v_path, 'bucket', v_bucket, 'bucketMultiplier', to_char(v_multiplier, 'FM999999999990.0'));

    WHEN 'mines' THEN
      v_mine_count := (p_selection->>'mineCount')::INT;
      SELECT array_agg((value)::INT) INTO v_revealed FROM jsonb_array_elements_text(p_selection->'revealedCells');
      IF v_mine_count < 1 OR v_mine_count > 24 THEN RAISE EXCEPTION 'invalid_mines_selection'; END IF;
      IF COALESCE(cardinality(v_revealed), 0) > 25 - v_mine_count THEN RAISE EXCEPTION 'revealed_cells_exceed_safe'; END IF;
      IF EXISTS (SELECT 1 FROM unnest(COALESCE(v_revealed, ARRAY[]::INT[])) c GROUP BY c HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'revealed_cells_not_distinct';
      END IF;

      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, 25);
      v_cells := ARRAY(SELECT generate_series(0, 24));
      FOR v_shuffle_idx IN REVERSE 25..2 LOOP
        v_j := floor(_require_game_float(v_floats, v_shuffle_idx - 1) * v_shuffle_idx)::INT + 1;
        v_tmp := v_cells[v_shuffle_idx];
        v_cells[v_shuffle_idx] := v_cells[v_j];
        v_cells[v_j] := v_tmp;
      END LOOP;
      v_positions := v_cells[1:v_mine_count];
      v_hit := EXISTS (
        SELECT 1 FROM unnest(COALESCE(v_revealed, ARRAY[]::INT[])) r
        WHERE r = ANY(v_positions)
      );
      v_multiplier := CASE
        WHEN v_hit OR COALESCE(cardinality(v_revealed), 0) = 0 THEN 0
        ELSE _mines_multiplier(v_mine_count, cardinality(v_revealed))
      END;
      v_result := jsonb_build_object('minePositions', to_jsonb(v_positions), 'hitMine', v_hit);

    WHEN 'hilo' THEN
      IF jsonb_array_length(p_selection->'guesses') > 10 THEN RAISE EXCEPTION 'hilo_too_many_guesses'; END IF;
      v_floats := _game_float_stream(p_server_seed, p_client_seed, p_nonce, 11);
      v_float_idx := 1;
      IF p_selection ? 'startCard' AND p_selection->>'startCard' IS NOT NULL THEN
        v_current_card := (p_selection->>'startCard')::INT;
      ELSE
        v_current_card := floor(_require_game_float(v_floats, v_float_idx) * 13)::INT + 1;
        v_float_idx := v_float_idx + 1;
      END IF;
      v_cards := v_cards || to_jsonb(v_current_card);
      v_won := jsonb_array_length(p_selection->'guesses') > 0;
      v_multiplier := 1;
      FOR v_guess IN SELECT jsonb_array_elements_text(p_selection->'guesses') LOOP
        v_next_card := floor(_require_game_float(v_floats, v_float_idx) * 13)::INT + 1;
        v_float_idx := v_float_idx + 1;
        v_cards := v_cards || to_jsonb(v_next_card);
        IF v_guess = 'skip' THEN
          v_correct := TRUE;
        ELSIF v_guess = 'higher' THEN
          v_correct := v_next_card > v_current_card;
        ELSIF v_guess = 'lower' THEN
          v_correct := v_next_card < v_current_card;
        ELSE
          RAISE EXCEPTION 'invalid_hilo_guess';
        END IF;
        IF v_guess <> 'skip' THEN
          v_multiplier := CASE WHEN v_correct THEN floor(v_multiplier * _hilo_step_multiplier(v_current_card, v_guess) * 100) / 100 ELSE 0 END;
        END IF;
        v_rounds := v_rounds || jsonb_build_object('card', v_current_card, 'guess', v_guess, 'correct', v_correct, 'multiplier', v_multiplier);
        v_current_card := v_next_card;
        IF NOT v_correct THEN
          v_won := FALSE;
          EXIT;
        END IF;
      END LOOP;
      IF NOT v_won OR jsonb_array_length(v_rounds) = 0 THEN
        v_multiplier := 0;
      END IF;
      v_result := jsonb_build_object('cards', v_cards, 'rounds', v_rounds, 'won', v_won);

    ELSE
      RAISE EXCEPTION 'invalid_game_code';
  END CASE;

  RETURN jsonb_build_object(
    'result', v_result,
    'payout_multiplier', _fmt6(v_multiplier),
    'won', v_multiplier > 0
  );
END;
$$;

REVOKE ALL ON FUNCTION _game_result(game_code, TEXT, TEXT, INT, JSONB) FROM PUBLIC, anon, authenticated;

-- ─── Round creation and atomic place+settle ───────────────────────────────────

DROP FUNCTION IF EXISTS rpc_create_game_round(TEXT, TEXT);

CREATE OR REPLACE FUNCTION rpc_create_game_round(
  p_game TEXT,
  p_server_seed TEXT,
  p_server_seed_hash TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_game game_code;
  v_round_id UUID := gen_random_uuid();
  v_hash TEXT;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_server_seed IS NULL OR length(p_server_seed) < 16 THEN
    RAISE EXCEPTION 'invalid_server_seed';
  END IF;

  BEGIN
    v_game := p_game::game_code;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_game_code';
  END;

  v_hash := encode(extensions.digest(p_server_seed, 'sha256'), 'hex');
  IF p_server_seed_hash IS NOT NULL AND p_server_seed_hash <> v_hash THEN
    RAISE EXCEPTION 'seed_hash_mismatch';
  END IF;

  INSERT INTO game_rounds (id, game, server_seed_hash, server_seed)
  VALUES (v_round_id, v_game, v_hash, p_server_seed);

  RETURN jsonb_build_object('round_id', v_round_id, 'game', v_game, 'server_seed_hash', v_hash);
END;
$$;

REVOKE ALL ON FUNCTION rpc_create_game_round(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_create_game_round(TEXT, TEXT, TEXT) TO service_role;

DROP FUNCTION IF EXISTS rpc_place_game_bet(UUID, TEXT, TEXT, JSONB, TEXT, TEXT);

CREATE OR REPLACE FUNCTION rpc_place_game_bet(
  p_round_id UUID,
  p_currency TEXT,
  p_stake TEXT,
  p_selection JSONB,
  p_client_seed TEXT,
  p_idempotency_key TEXT,
  p_expected_result JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_round game_rounds%ROWTYPE;
  v_ccy currency;
  v_stake NUMERIC;
  v_bet_id UUID := gen_random_uuid();
  v_existing game_bets%ROWTYPE;
  v_resolution JSONB;
  v_result JSONB;
  v_multiplier NUMERIC;
  v_raw_payout NUMERIC;
  v_payout NUMERIC;
  v_house NUMERIC;
  v_dust NUMERIC;
  v_status bet_status;
  v_lock_id UUID;
  v_debit_id UUID;
  v_credit_id UUID;
  v_transfer_id UUID := gen_random_uuid();
  v_house_account TEXT;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 THEN
    RAISE EXCEPTION 'invalid_idempotency_key';
  END IF;
  IF p_client_seed IS NULL OR length(btrim(p_client_seed)) = 0 THEN
    RAISE EXCEPTION 'invalid_client_seed';
  END IF;

  SELECT * INTO v_existing
  FROM game_bets
  WHERE user_id = v_user_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'bet_id', v_existing.id,
      'round_id', v_existing.round_id,
      'status', v_existing.status,
      'already_placed', TRUE,
      'payout', v_existing.payout,
      'result', v_existing.result_payload
    );
  END IF;

  PERFORM _enforce_rate_limit(v_user_id, 'rpc_place_game_bet');
  PERFORM _assert_system_live();
  PERFORM _assert_feature_enabled('game');
  PERFORM _assert_onboarding_consent(v_user_id);
  PERFORM _assert_amount_text(p_stake);

  BEGIN
    v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;
  IF v_ccy NOT IN ('PHON', 'USDT') THEN
    RAISE EXCEPTION 'invalid_currency';
  END IF;

  SELECT * INTO v_round FROM game_rounds WHERE id = p_round_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'round_not_found'; END IF;
  IF v_round.status <> 'open' THEN RAISE EXCEPTION 'round_not_open'; END IF;
  IF v_round.server_seed IS NULL THEN RAISE EXCEPTION 'server_seed_unavailable'; END IF;

  v_stake := p_stake::NUMERIC;
  IF v_stake <= 0 THEN RAISE EXCEPTION 'invalid_stake'; END IF;
  PERFORM _assert_game_feature_enabled(v_round.game);
  PERFORM _assert_game_stake_limits(v_round.game, v_ccy, v_stake);
  PERFORM _assert_game_exposure_cap(v_round.game, v_ccy, v_stake, p_selection);

  v_resolution := _game_result(v_round.game, v_round.server_seed, p_client_seed, 1, p_selection);
  v_result := v_resolution->'result';
  v_multiplier := (v_resolution->>'payout_multiplier')::NUMERIC;
  v_raw_payout := v_stake * v_multiplier;
  v_payout := trunc(v_raw_payout, 6);
  v_dust := trunc(v_raw_payout - v_payout, 6);
  v_house := v_stake - v_payout - v_dust;
  v_status := CASE WHEN v_payout > 0 THEN 'won'::bet_status ELSE 'lost'::bet_status END;
  v_house_account := CASE WHEN v_ccy = 'PHON' THEN 'game_house_phon' ELSE 'game_house_usdt' END;

  v_lock_id := _lock_wallet_internal(
    v_user_id,
    v_ccy,
    _fmt6(v_stake),
    'game_stake_lock',
    'gbet_lock:' || v_user_id::TEXT || ':' || p_idempotency_key
  );

  INSERT INTO game_bets (
    id, round_id, user_id, game, currency, stake, selection,
    client_seed, nonce, result_payload, payout, status, idempotency_key, stake_lock_id
  ) VALUES (
    v_bet_id, p_round_id, v_user_id, v_round.game, v_ccy, _fmt6(v_stake), p_selection,
    p_client_seed, 1, v_result, _fmt6(v_payout), v_status, p_idempotency_key, v_lock_id
  );

  IF p_expected_result IS NOT NULL AND p_expected_result <> v_result THEN
    UPDATE game_bets SET parity_hold = TRUE, status = 'pending' WHERE id = v_bet_id;
    UPDATE app_config SET value = 'false', updated_at = NOW()
      WHERE key = 'feature_game_' || v_round.game::TEXT || '_enabled';
    INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
    VALUES (v_user_id, 'parity_mismatch', 'game_bets', v_bet_id,
      jsonb_build_object('game', v_round.game, 'expected', p_expected_result, 'computed', v_result));
    RETURN jsonb_build_object('bet_id', v_bet_id, 'status', 'parity_hold', 'already_placed', FALSE);
  END IF;

  PERFORM _unlock_wallet_internal(v_user_id, v_ccy, _fmt6(v_stake), 'game_stake_unlock', 'gbet_unlock:' || v_bet_id::TEXT);
  v_debit_id := _debit_wallet_internal(v_user_id, v_ccy, _fmt6(v_stake), 'game_stake_settle', 'gbet_debit:' || v_bet_id::TEXT);
  IF v_payout > 0 THEN
    v_credit_id := _credit_wallet_internal(v_user_id, v_ccy, _fmt6(v_payout), 'game_payout', 'gbet_pay:' || v_bet_id::TEXT);
  END IF;

  IF v_house >= 0 THEN
    PERFORM _credit_system_account(v_house_account, _fmt6(v_house), 'game_house_settle', v_user_id, v_bet_id::TEXT, v_transfer_id);
  ELSE
    PERFORM _debit_system_account(v_house_account, _fmt6(abs(v_house)), 'game_house_settle', v_user_id, v_bet_id::TEXT, v_transfer_id);
  END IF;
  IF v_dust > 0 THEN
    PERFORM _credit_system_account(CASE WHEN v_ccy = 'PHON' THEN 'dust_phon' ELSE 'dust_usdt' END,
      _fmt6(v_dust), 'game_rounding_dust', v_user_id, v_bet_id::TEXT, v_transfer_id);
  END IF;

  UPDATE game_rounds SET
    status = 'settled',
    result_payload = v_result,
    settled_at = NOW()
  WHERE id = p_round_id;

  UPDATE game_bets SET
    payout_ledger_id = COALESCE(v_credit_id, v_debit_id),
    house_ledger_transfer_id = v_transfer_id,
    settled_at = NOW()
  WHERE id = v_bet_id;

  BEGIN
    PERFORM _grant_mission(v_user_id, 'first_game');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'bet_id', v_bet_id,
    'round_id', p_round_id,
    'game', v_round.game,
    'status', v_status,
    'server_seed_hash', v_round.server_seed_hash,
    'result', v_result,
    'payout', _fmt6(v_payout),
    'already_placed', FALSE
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_place_game_bet(UUID, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_place_game_bet(UUID, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB) TO authenticated, service_role;

-- Keep the old settle entry blocked; atomic settlement happens inside rpc_place_game_bet.
CREATE OR REPLACE FUNCTION rpc_settle_game_bet(p_bet_id UUID, p_server_seed TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  RAISE EXCEPTION 'atomic_settlement_required'
    USING HINT = COALESCE(p_bet_id::TEXT, 'null') || ':' || COALESCE(length(p_server_seed)::TEXT, 'null');
END;
$$;

REVOKE ALL ON FUNCTION rpc_settle_game_bet(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_settle_game_bet(UUID, TEXT) TO service_role;

-- ─── Reveal, cancel, void, and stale sweep ────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_reveal_game_round(p_round_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_round game_rounds%ROWTYPE;
BEGIN
  SELECT * INTO v_round FROM game_rounds WHERE id = p_round_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'round_not_found'; END IF;
  IF v_round.status <> 'settled' THEN RAISE EXCEPTION 'round_not_settled'; END IF;
  IF v_round.server_seed IS NULL THEN RAISE EXCEPTION 'server_seed_unavailable'; END IF;

  INSERT INTO game_seed_reveals (round_id, server_seed)
  VALUES (p_round_id, v_round.server_seed)
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'round_id', p_round_id,
    'server_seed', v_round.server_seed,
    'server_seed_hash', v_round.server_seed_hash,
    'result', v_round.result_payload
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_reveal_game_round(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_reveal_game_round(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION rpc_cancel_game_bet(p_bet_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_bet game_bets%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  PERFORM _enforce_rate_limit(v_user_id, 'rpc_cancel_game_bet');

  SELECT * INTO v_bet FROM game_bets WHERE id = p_bet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'bet_not_found'; END IF;
  IF v_bet.user_id <> v_user_id THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF v_bet.status <> 'pending' OR v_bet.parity_hold THEN RAISE EXCEPTION 'bet_not_cancellable'; END IF;

  PERFORM _unlock_wallet_internal(v_bet.user_id, v_bet.currency, v_bet.stake, 'game_bet_cancel', 'gbet_cancel:' || p_bet_id::TEXT);
  UPDATE game_bets SET status = 'cancelled', settled_at = NOW() WHERE id = p_bet_id;
  UPDATE game_rounds SET status = 'cancelled', settled_at = NOW() WHERE id = v_bet.round_id;

  RETURN jsonb_build_object('bet_id', p_bet_id, 'status', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION rpc_cancel_game_bet(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_cancel_game_bet(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION rpc_admin_void_game_bet(p_bet_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_bet game_bets%ROWTYPE;
BEGIN
  IF NOT _is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN RAISE EXCEPTION 'reason_required'; END IF;

  SELECT * INTO v_bet FROM game_bets WHERE id = p_bet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'bet_not_found'; END IF;
  IF v_bet.status <> 'pending' THEN RAISE EXCEPTION 'bet_not_voidable'; END IF;

  PERFORM _unlock_wallet_internal(v_bet.user_id, v_bet.currency, v_bet.stake, 'game_admin_void', 'gbet_admin_void:' || p_bet_id::TEXT);
  UPDATE game_bets SET status = 'cancelled', parity_hold = FALSE, settled_at = NOW() WHERE id = p_bet_id;
  UPDATE game_rounds SET status = 'cancelled', settled_at = NOW() WHERE id = v_bet.round_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (v_actor, 'admin_void_game_bet', 'game_bets', p_bet_id,
    jsonb_build_object('reason', p_reason, 'user_id', v_bet.user_id));

  RETURN jsonb_build_object('bet_id', p_bet_id, 'status', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION rpc_admin_void_game_bet(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rpc_admin_void_game_bet(UUID, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION rpc_sweep_stale_game_bets()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_minutes INT := _app_config_numeric('casino_stale_pending_minutes', 10)::INT;
  v_count INT := 0;
  v_bet game_bets%ROWTYPE;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  FOR v_bet IN
    SELECT * FROM game_bets
    WHERE status = 'pending'
      AND parity_hold = FALSE
      AND created_at < NOW() - make_interval(mins => v_minutes)
    FOR UPDATE
  LOOP
    PERFORM _unlock_wallet_internal(v_bet.user_id, v_bet.currency, v_bet.stake, 'game_stale_sweep', 'gbet_stale:' || v_bet.id::TEXT);
    UPDATE game_bets SET status = 'cancelled', settled_at = NOW() WHERE id = v_bet.id;
    UPDATE game_rounds SET status = 'cancelled', settled_at = NOW() WHERE id = v_bet.round_id;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('cancelled', v_count);
END;
$$;

REVOKE ALL ON FUNCTION rpc_sweep_stale_game_bets() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_sweep_stale_game_bets() TO service_role;

SELECT cron.schedule(
  'phonara_casino_stale_pending_sweep',
  '*/5 * * * *',
  $cron$SELECT public.rpc_sweep_stale_game_bets();$cron$
);
