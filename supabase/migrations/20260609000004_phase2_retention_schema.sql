-- ============================================================
-- Migration: 20260609000004_phase2_retention_schema
-- Phase 2: PHON Retention - Daily Claims, Roulette, Referrals
-- ============================================================
-- All PHON rewards are credited via rpc_credit_wallet (atomic).
-- All tables are append-only; status transitions via RPC only.
-- ============================================================

-- ─── user_streaks ─────────────────────────────────────────────
-- Denormalized for fast dashboard reads. Source of truth is daily_claims.

CREATE TABLE user_streaks (
  user_id           UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  current_streak    INT NOT NULL DEFAULT 0,
  longest_streak    INT NOT NULL DEFAULT 0,
  last_claimed_date DATE,
  total_phon_earned TEXT NOT NULL DEFAULT '0.000000',
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER user_streaks_updated_at
  BEFORE UPDATE ON user_streaks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── daily_claims ─────────────────────────────────────────────
-- One row per user per UTC date. Append-only.

CREATE TABLE daily_claims (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  claimed_date     DATE NOT NULL,
  streak_day       INT NOT NULL DEFAULT 1,
  phon_awarded     TEXT NOT NULL,
  ledger_entry_id  UUID REFERENCES wallet_ledger(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, claimed_date)
);

CREATE INDEX daily_claims_user_date_idx ON daily_claims (user_id, claimed_date DESC);

-- ─── roulette_spins ───────────────────────────────────────────
-- One spin per user per UTC date.

CREATE TABLE roulette_spins (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  spun_date         DATE NOT NULL,
  prize_index       INT NOT NULL,
  phon_awarded      TEXT NOT NULL,
  server_seed_hash  TEXT NOT NULL,
  server_seed       TEXT,         -- revealed after spin
  ledger_entry_id   UUID REFERENCES wallet_ledger(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, spun_date)
);

CREATE INDEX roulette_user_date_idx ON roulette_spins (user_id, spun_date DESC);

-- ─── referrals ────────────────────────────────────────────────
-- Each user can only be referred once.

CREATE TABLE referrals (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  referred_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  referrer_phon       TEXT NOT NULL DEFAULT '0.000000',
  referred_phon       TEXT NOT NULL DEFAULT '0.000000',
  referrer_ledger_id  UUID REFERENCES wallet_ledger(id),
  referred_ledger_id  UUID REFERENCES wallet_ledger(id),
  rewarded_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (referred_id)
);

CREATE INDEX referrals_referrer_idx ON referrals (referrer_id);

-- ─── welcome_bonuses ──────────────────────────────────────────
-- Track one-time welcome bonus per user.

CREATE TABLE welcome_bonuses (
  user_id          UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  phon_awarded     TEXT NOT NULL,
  referral_bonus   TEXT NOT NULL DEFAULT '0.000000',
  ledger_entry_id  UUID REFERENCES wallet_ledger(id),
  claimed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── missions ─────────────────────────────────────────────────
-- One row per (user, mission_code). Completed = phon_awarded > 0.

CREATE TYPE mission_code AS ENUM (
  'complete_profile',
  'first_trade',
  'first_game',
  'first_deposit',
  'kyc_verified',
  'invite_3_friends',
  'streak_7_days',
  'streak_30_days'
);

CREATE TABLE missions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  mission          mission_code NOT NULL,
  phon_awarded     TEXT NOT NULL DEFAULT '0.000000',
  ledger_entry_id  UUID REFERENCES wallet_ledger(id),
  completed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, mission)
);

CREATE INDEX missions_user_idx ON missions (user_id);

-- ─── RLS ──────────────────────────────────────────────────────

ALTER TABLE user_streaks    ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_claims    ENABLE ROW LEVEL SECURITY;
ALTER TABLE roulette_spins  ENABLE ROW LEVEL SECURITY;
ALTER TABLE referrals       ENABLE ROW LEVEL SECURITY;
ALTER TABLE welcome_bonuses ENABLE ROW LEVEL SECURITY;
ALTER TABLE missions        ENABLE ROW LEVEL SECURITY;

CREATE POLICY "streaks: own read"       ON user_streaks    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "daily_claims: own read"  ON daily_claims    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "roulette: own read"      ON roulette_spins  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "referrals: own read"     ON referrals       FOR SELECT USING (auth.uid() = referrer_id OR auth.uid() = referred_id);
CREATE POLICY "welcome: own read"       ON welcome_bonuses FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "missions: own read"      ON missions        FOR SELECT USING (auth.uid() = user_id);

-- Auto-create user_streaks row when profile is created
CREATE OR REPLACE FUNCTION init_user_streak()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO user_streaks (user_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER auto_init_streak
  AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION init_user_streak();
