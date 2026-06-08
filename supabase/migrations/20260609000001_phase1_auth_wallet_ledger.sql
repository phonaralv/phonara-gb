-- ============================================================
-- Migration: 20260609000001_phase1_auth_wallet_ledger
-- Phase 1: Auth + Profile + Wallet + Ledger + Exchange Rates
-- ============================================================
-- CAUTION: Review ALL RLS policies before applying.
-- All monetary columns use TEXT with Decimal-safe constraints.
-- No FLOAT or NUMERIC — TEXT enforces serialised Decimal.js values.
-- ============================================================

-- ─── Extensions ──────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── Enums ───────────────────────────────────────────────────

CREATE TYPE user_role AS ENUM ('user', 'admin');
CREATE TYPE admin_role AS ENUM ('owner', 'finance', 'risk', 'support', 'operator', 'viewer');
CREATE TYPE currency AS ENUM ('PHON', 'USDT', 'KRW');
CREATE TYPE ledger_direction AS ENUM ('credit', 'debit', 'lock', 'unlock', 'reverse');
CREATE TYPE kyc_tier AS ENUM ('anonymous', 'email_verified', 'phone_verified', 'id_verified');
CREATE TYPE deposit_status AS ENUM ('pending', 'matched', 'credited', 'failed', 'expired');
CREATE TYPE withdrawal_status AS ENUM ('pending', 'approved', 'processing', 'completed', 'rejected', 'cancelled');

-- ─── profiles ────────────────────────────────────────────────

CREATE TABLE profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username        TEXT UNIQUE,
  display_name    TEXT,
  avatar_url      TEXT,
  locale          TEXT NOT NULL DEFAULT 'ko',
  role            user_role NOT NULL DEFAULT 'user',
  kyc_tier        kyc_tier NOT NULL DEFAULT 'anonymous',
  referrer_id     UUID REFERENCES profiles(id),
  is_banned       BOOLEAN NOT NULL DEFAULT FALSE,
  ban_reason      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX profiles_username_idx ON profiles (username);
CREATE INDEX profiles_referrer_idx ON profiles (referrer_id);

-- updated_at auto-update trigger
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── wallets ─────────────────────────────────────────────────
-- One wallet per user. Three currency slots.
-- All balance columns store Decimal.js-serialised strings.
-- Balances are DERIVED views of wallet_ledger; never mutated directly.
-- The authoritative mutation path is via RPC only.

CREATE TABLE wallets (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE RESTRICT,

  phon_available  TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT wallets_phon_available_fmt CHECK (phon_available ~ '^-?\d+(\.\d+)?$'),
  phon_locked     TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT wallets_phon_locked_fmt CHECK (phon_locked ~ '^-?\d+(\.\d+)?$'),

  usdt_available  TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT wallets_usdt_available_fmt CHECK (usdt_available ~ '^-?\d+(\.\d+)?$'),
  usdt_locked     TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT wallets_usdt_locked_fmt CHECK (usdt_locked ~ '^-?\d+(\.\d+)?$'),

  krw_available   TEXT NOT NULL DEFAULT '0'
    CONSTRAINT wallets_krw_available_fmt CHECK (krw_available ~ '^-?\d+(\.\d+)?$'),
  krw_locked      TEXT NOT NULL DEFAULT '0'
    CONSTRAINT wallets_krw_locked_fmt CHECK (krw_locked ~ '^-?\d+(\.\d+)?$'),

  version         BIGINT NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX wallets_user_id_idx ON wallets (user_id);

CREATE TRIGGER wallets_updated_at
  BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── wallet_ledger ───────────────────────────────────────────
-- Append-only. Never UPDATE or DELETE.

CREATE TABLE wallet_ledger (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id           UUID NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  user_id             UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  idempotency_key     TEXT NOT NULL UNIQUE,
  direction           ledger_direction NOT NULL,
  currency            currency NOT NULL,
  amount              TEXT NOT NULL
    CONSTRAINT ledger_amount_positive CHECK (amount ~ '^\d+(\.\d+)?$'),

  -- snapshot of balance before/after this entry
  available_before    TEXT NOT NULL,
  locked_before       TEXT NOT NULL,
  available_after     TEXT NOT NULL,
  locked_after        TEXT NOT NULL,

  reason_code         TEXT NOT NULL,
  related_entity_id   UUID,        -- game round id, trade id, etc.
  rate_snapshot_id    UUID,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ledger_wallet_id_idx ON wallet_ledger (wallet_id);
CREATE INDEX ledger_user_id_idx ON wallet_ledger (user_id);
CREATE INDEX ledger_idempotency_key_idx ON wallet_ledger (idempotency_key);
CREATE INDEX ledger_created_at_idx ON wallet_ledger (created_at DESC);
CREATE INDEX ledger_reason_code_idx ON wallet_ledger (reason_code);

-- Prevent any UPDATE or DELETE on ledger rows
CREATE OR REPLACE RULE wallet_ledger_no_update AS
  ON UPDATE TO wallet_ledger DO INSTEAD NOTHING;

CREATE OR REPLACE RULE wallet_ledger_no_delete AS
  ON DELETE TO wallet_ledger DO INSTEAD NOTHING;

-- ─── exchange_rate_snapshots ─────────────────────────────────

CREATE TABLE exchange_rate_snapshots (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  base_currency   currency NOT NULL,
  quote_currency  currency NOT NULL,
  rate            TEXT NOT NULL
    CONSTRAINT rate_positive CHECK (rate ~ '^\d+(\.\d+)?$'),
  source          TEXT NOT NULL DEFAULT 'admin',
  captured_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by      UUID REFERENCES profiles(id),
  is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX rates_base_quote_idx ON exchange_rate_snapshots (base_currency, quote_currency, is_active, captured_at DESC);

-- ─── krw_deposit_requests ────────────────────────────────────

CREATE TABLE krw_deposit_requests (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  wallet_id           UUID NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  reference_code      TEXT NOT NULL UNIQUE,
  amount_krw          TEXT NOT NULL
    CONSTRAINT deposit_amount_positive CHECK (amount_krw ~ '^\d+(\.\d+)?$'),
  expected_phon       TEXT,
  rate_snapshot_id    UUID REFERENCES exchange_rate_snapshots(id),
  status              deposit_status NOT NULL DEFAULT 'pending',
  matched_at          TIMESTAMPTZ,
  credited_at         TIMESTAMPTZ,
  admin_note          TEXT,
  expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX deposits_user_id_idx ON krw_deposit_requests (user_id);
CREATE INDEX deposits_status_idx ON krw_deposit_requests (status);
CREATE INDEX deposits_reference_code_idx ON krw_deposit_requests (reference_code);

CREATE TRIGGER deposits_updated_at
  BEFORE UPDATE ON krw_deposit_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── audit_logs ──────────────────────────────────────────────
-- Append-only admin action log.

CREATE TABLE audit_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id        UUID REFERENCES profiles(id),
  action          TEXT NOT NULL,
  entity_type     TEXT,
  entity_id       UUID,
  payload         JSONB,
  ip_address      INET,
  user_agent      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX audit_actor_idx ON audit_logs (actor_id);
CREATE INDEX audit_action_idx ON audit_logs (action);
CREATE INDEX audit_entity_idx ON audit_logs (entity_type, entity_id);
CREATE INDEX audit_created_at_idx ON audit_logs (created_at DESC);

-- No UPDATE or DELETE on audit_logs
CREATE OR REPLACE RULE audit_logs_no_update AS
  ON UPDATE TO audit_logs DO INSTEAD NOTHING;

CREATE OR REPLACE RULE audit_logs_no_delete AS
  ON DELETE TO audit_logs DO INSTEAD NOTHING;

-- ─── Auto-create wallet on profile insert ────────────────────

CREATE OR REPLACE FUNCTION create_wallet_for_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO wallets (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER auto_create_wallet
  AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION create_wallet_for_profile();

-- Auto-create profile on auth.users insert
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
