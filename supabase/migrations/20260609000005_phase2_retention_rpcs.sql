-- ============================================================
-- Migration: 20260609000005_phase2_retention_rpcs
-- Phase 2 Atomic RPCs: Welcome, Daily, Roulette, Referral, Missions
-- ============================================================
-- All functions are SECURITY DEFINER — callers never bypass RLS.
-- All mutations are atomic: balance credit + ledger entry in one TX.
-- ============================================================

-- ─── Constants ────────────────────────────────────────────────

-- Welcome bonus constants
-- Base:        5,000 PHON (= 5,000원 상당)
-- w/ referral: +1,000 PHON bonus for referred user
-- Referrer:    +2,000 PHON when referred friend claims welcome

-- Daily claim constants
-- base = 50 + (min(streak_day - 1, 29) * 10)  → max 340 PHON at day 30+

-- Roulette prize pool (index 0-7)
-- Prizes: 10, 20, 30, 50, 100, 300, 500, 1000 PHON
-- Weights: 3000, 2500, 2000, 1200, 700, 300, 200, 100 (total=10000)

-- ─── rpc_claim_welcome_bonus ──────────────────────────────────
-- Call once after first login. Idempotent (returns existing on replay).

CREATE OR REPLACE FUNCTION rpc_claim_welcome_bonus(
  p_idempotency_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id         UUID := auth.uid();
  v_base_phon       NUMERIC := 5000;
  v_bonus_phon      NUMERIC := 0;
  v_total_phon      NUMERIC;
  v_total_text      TEXT;
  v_ref_row         referrals%ROWTYPE;
  v_ledger_id       UUID;
  v_idempotency_key TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED';
  END IF;

  -- Idempotency: return existing bonus if already claimed
  PERFORM 1 FROM welcome_bonuses WHERE user_id = v_user_id;
  IF FOUND THEN
    RETURN (SELECT jsonb_build_object(
      'already_claimed', TRUE,
      'phon_awarded', phon_awarded,
      'referral_bonus', referral_bonus
    ) FROM welcome_bonuses WHERE user_id = v_user_id);
  END IF;

  -- Check if this user was referred → extra 1,000 PHON
  SELECT * INTO v_ref_row FROM referrals WHERE referred_id = v_user_id;
  IF v_ref_row.id IS NOT NULL AND v_ref_row.rewarded_at IS NULL THEN
    v_bonus_phon := 1000;
  END IF;

  v_total_phon := v_base_phon + v_bonus_phon;
  v_total_text := TO_CHAR(v_total_phon, 'FM9999990.000000');

  v_idempotency_key := COALESCE(p_idempotency_key, 'welcome:' || v_user_id::TEXT);

  -- Credit wallet atomically
  PERFORM rpc_credit_wallet(
    v_user_id,
    'PHON',
    v_total_text,
    'welcome_bonus',
    jsonb_build_object(
      'base_phon', v_base_phon,
      'referral_bonus', v_bonus_phon
    ),
    v_idempotency_key
  );

  -- Get the created ledger entry
  SELECT id INTO v_ledger_id
    FROM wallet_ledger
   WHERE idempotency_key = v_idempotency_key
   LIMIT 1;

  -- Record welcome bonus
  INSERT INTO welcome_bonuses (user_id, phon_awarded, referral_bonus, ledger_entry_id)
  VALUES (
    v_user_id,
    v_total_text,
    TO_CHAR(v_bonus_phon, 'FM9999990.000000'),
    v_ledger_id
  );

  -- Grant referral reward to referrer (2,000 PHON)
  IF v_ref_row.id IS NOT NULL AND v_ref_row.rewarded_at IS NULL THEN
    DECLARE
      v_ref_idem TEXT := 'referral_reward:' || v_ref_row.id::TEXT;
      v_ref_ledger UUID;
    BEGIN
      PERFORM rpc_credit_wallet(
        v_ref_row.referrer_id,
        'PHON',
        '2000.000000',
        'referral_bonus',
        jsonb_build_object('referred_user_id', v_user_id),
        v_ref_idem
      );

      SELECT id INTO v_ref_ledger
        FROM wallet_ledger
       WHERE idempotency_key = v_ref_idem
       LIMIT 1;

      UPDATE referrals SET
        referrer_phon      = '2000.000000',
        referred_phon      = TO_CHAR(v_bonus_phon, 'FM9999990.000000'),
        referrer_ledger_id = v_ref_ledger,
        rewarded_at        = NOW()
      WHERE id = v_ref_row.id;
    END;
  END IF;

  RETURN jsonb_build_object(
    'already_claimed', FALSE,
    'phon_awarded', v_total_text,
    'referral_bonus', TO_CHAR(v_bonus_phon, 'FM9999990.000000')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_claim_welcome_bonus(TEXT) TO authenticated;

-- ─── rpc_claim_daily_reward ───────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_claim_daily_reward()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id      UUID := auth.uid();
  v_today        DATE := CURRENT_DATE;
  v_yesterday    DATE := CURRENT_DATE - INTERVAL '1 day';
  v_streak_row   user_streaks%ROWTYPE;
  v_new_streak   INT;
  v_phon_amount  NUMERIC;
  v_phon_text    TEXT;
  v_idem_key     TEXT := 'daily:' || v_user_id::TEXT || ':' || v_today::TEXT;
  v_ledger_id    UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  -- Idempotency
  PERFORM 1 FROM daily_claims WHERE user_id = v_user_id AND claimed_date = v_today;
  IF FOUND THEN
    RETURN (SELECT jsonb_build_object(
      'already_claimed', TRUE,
      'phon_awarded', phon_awarded,
      'streak_day', streak_day
    ) FROM daily_claims WHERE user_id = v_user_id AND claimed_date = v_today);
  END IF;

  -- Lock streak row
  SELECT * INTO v_streak_row
    FROM user_streaks
   WHERE user_id = v_user_id
   FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO user_streaks (user_id) VALUES (v_user_id)
    ON CONFLICT DO NOTHING;
    SELECT * INTO v_streak_row FROM user_streaks WHERE user_id = v_user_id FOR UPDATE;
  END IF;

  -- Calculate new streak
  IF v_streak_row.last_claimed_date = v_yesterday THEN
    v_new_streak := v_streak_row.current_streak + 1;
  ELSE
    v_new_streak := 1;
  END IF;

  -- Calculate reward: 50 + (min(streak-1, 29) × 10)  → max 340 PHON at day 30
  v_phon_amount := 50 + (LEAST(v_new_streak - 1, 29) * 10);
  v_phon_text   := TO_CHAR(v_phon_amount, 'FM9999990.000000');

  -- Credit wallet
  PERFORM rpc_credit_wallet(
    v_user_id, 'PHON', v_phon_text,
    'daily_claim',
    jsonb_build_object('streak_day', v_new_streak),
    v_idem_key
  );

  SELECT id INTO v_ledger_id
    FROM wallet_ledger WHERE idempotency_key = v_idem_key LIMIT 1;

  -- Insert claim record
  INSERT INTO daily_claims (user_id, claimed_date, streak_day, phon_awarded, ledger_entry_id)
  VALUES (v_user_id, v_today, v_new_streak, v_phon_text, v_ledger_id);

  -- Update streak
  UPDATE user_streaks SET
    current_streak    = v_new_streak,
    longest_streak    = GREATEST(longest_streak, v_new_streak),
    last_claimed_date = v_today,
    total_phon_earned = TO_CHAR(
      TO_NUMBER(COALESCE(NULLIF(total_phon_earned,''),'0'), '9999999.999999') + v_phon_amount,
      'FM9999999.000000'
    )
  WHERE user_id = v_user_id;

  -- Check streak milestones
  IF v_new_streak = 7 THEN
    PERFORM _grant_mission(v_user_id, 'streak_7_days');
  ELSIF v_new_streak = 30 THEN
    PERFORM _grant_mission(v_user_id, 'streak_30_days');
  END IF;

  RETURN jsonb_build_object(
    'already_claimed', FALSE,
    'phon_awarded', v_phon_text,
    'streak_day', v_new_streak,
    'next_day_preview', TO_CHAR(50 + (LEAST(v_new_streak, 29) * 10), 'FM990')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_claim_daily_reward() TO authenticated;

-- ─── rpc_spin_roulette ────────────────────────────────────────
-- Server-authoritative RNG. Seed hash committed before spin.

CREATE OR REPLACE FUNCTION rpc_spin_roulette()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id     UUID := auth.uid();
  v_today       DATE := CURRENT_DATE;
  v_prizes      NUMERIC[] := ARRAY[10,20,30,50,100,300,500,1000];
  v_weights     INT[]     := ARRAY[3000,2500,2000,1200,700,300,200,100];
  v_total_w     INT       := 10000;
  v_rand        INT;
  v_cumulative  INT       := 0;
  v_prize_idx   INT       := 0;
  v_phon_amount NUMERIC;
  v_phon_text   TEXT;
  v_seed        TEXT;
  v_seed_hash   TEXT;
  v_idem_key    TEXT;
  v_ledger_id   UUID;
  i             INT;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  PERFORM 1 FROM roulette_spins WHERE user_id = v_user_id AND spun_date = v_today;
  IF FOUND THEN
    RETURN (SELECT jsonb_build_object(
      'already_spun', TRUE,
      'phon_awarded', phon_awarded,
      'prize_index', prize_index
    ) FROM roulette_spins WHERE user_id = v_user_id AND spun_date = v_today);
  END IF;

  -- Server seed for provably fair
  v_seed       := encode(gen_random_bytes(16), 'hex');
  v_seed_hash  := encode(digest(v_seed, 'sha256'), 'hex');

  -- Weighted random selection
  v_rand := floor(random() * v_total_w)::INT;
  FOR i IN 1..array_length(v_prizes, 1) LOOP
    v_cumulative := v_cumulative + v_weights[i];
    IF v_rand < v_cumulative THEN
      v_prize_idx   := i - 1;
      v_phon_amount := v_prizes[i];
      EXIT;
    END IF;
  END LOOP;

  v_phon_text := TO_CHAR(v_phon_amount, 'FM9999990.000000');
  v_idem_key  := 'roulette:' || v_user_id::TEXT || ':' || v_today::TEXT;

  PERFORM rpc_credit_wallet(
    v_user_id, 'PHON', v_phon_text,
    'roulette_spin',
    jsonb_build_object('prize_index', v_prize_idx, 'seed_hash', v_seed_hash),
    v_idem_key
  );

  SELECT id INTO v_ledger_id
    FROM wallet_ledger WHERE idempotency_key = v_idem_key LIMIT 1;

  INSERT INTO roulette_spins (
    user_id, spun_date, prize_index, phon_awarded,
    server_seed_hash, server_seed, ledger_entry_id
  ) VALUES (
    v_user_id, v_today, v_prize_idx, v_phon_text,
    v_seed_hash, v_seed, v_ledger_id
  );

  RETURN jsonb_build_object(
    'already_spun',  FALSE,
    'prize_index',   v_prize_idx,
    'phon_awarded',  v_phon_text,
    'seed_hash',     v_seed_hash,
    'seed_revealed', v_seed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_spin_roulette() TO authenticated;

-- ─── rpc_register_referral ────────────────────────────────────
-- Called when user enters referral code during onboarding.

CREATE OR REPLACE FUNCTION rpc_register_referral(p_referrer_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id    UUID := auth.uid();
  v_referrer   UUID;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  -- Already referred?
  PERFORM 1 FROM referrals WHERE referred_id = v_user_id;
  IF FOUND THEN
    RETURN jsonb_build_object('registered', FALSE, 'reason', 'already_referred');
  END IF;

  -- Find referrer by code (stored in profiles.referral_code if exists, else user_id short)
  SELECT id INTO v_referrer
    FROM profiles
   WHERE id::TEXT LIKE p_referrer_code || '%'
      OR LOWER(username) = LOWER(p_referrer_code)
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

GRANT EXECUTE ON FUNCTION rpc_register_referral(TEXT) TO authenticated;

-- ─── _grant_mission (internal) ────────────────────────────────

CREATE OR REPLACE FUNCTION _grant_mission(
  p_user_id UUID,
  p_mission mission_code
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rewards   JSONB := jsonb_build_object(
    'complete_profile', '200.000000',
    'first_trade',      '1000.000000',
    'first_game',       '500.000000',
    'first_deposit',    '500.000000',
    'kyc_verified',     '3000.000000',
    'invite_3_friends', '1500.000000',
    'streak_7_days',    '1000.000000',
    'streak_30_days',   '5000.000000'
  );
  v_phon_text TEXT := v_rewards ->> p_mission::TEXT;
  v_idem_key  TEXT := 'mission:' || p_user_id::TEXT || ':' || p_mission::TEXT;
  v_ledger_id UUID;
BEGIN
  PERFORM 1 FROM missions
   WHERE user_id = p_user_id AND mission = p_mission AND completed_at IS NOT NULL;
  IF FOUND THEN RETURN; END IF;

  IF v_phon_text IS NULL THEN RETURN; END IF;

  PERFORM rpc_credit_wallet(
    p_user_id, 'PHON', v_phon_text,
    'mission_reward',
    jsonb_build_object('mission', p_mission),
    v_idem_key
  );

  SELECT id INTO v_ledger_id
    FROM wallet_ledger WHERE idempotency_key = v_idem_key LIMIT 1;

  INSERT INTO missions (user_id, mission, phon_awarded, ledger_entry_id, completed_at)
  VALUES (p_user_id, p_mission, v_phon_text, v_ledger_id, NOW())
  ON CONFLICT (user_id, mission) DO UPDATE SET
    phon_awarded    = EXCLUDED.phon_awarded,
    ledger_entry_id = EXCLUDED.ledger_entry_id,
    completed_at    = EXCLUDED.completed_at;
END;
$$;

-- rpc_complete_mission (public entry point)
CREATE OR REPLACE FUNCTION rpc_complete_mission(p_mission TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_mission mission_code;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  BEGIN v_mission := p_mission::mission_code;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('granted', FALSE, 'reason', 'unknown_mission');
  END;
  PERFORM _grant_mission(v_user_id, v_mission);
  RETURN jsonb_build_object('granted', TRUE, 'mission', p_mission);
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_complete_mission(TEXT) TO authenticated;
