-- ============================================================
-- Migration: 20260609000008_p0_hardening_schema
-- P0 Hardening: Conservation Invariant, Hash-chain Ledger,
--               Price Circuit Breaker, Rate Limits, Consent Gate
-- ============================================================
-- Covers: A1, A3, A4, A5, B1 from the master plan appendix.
-- A2 (auto-liquidation worker RPC) is in migration 009.
-- ============================================================

SET search_path = public, pg_temp;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1: System accounts (house / fee / insurance / dust)
-- ─────────────────────────────────────────────────────────────────────────────
-- Each monetary RPC must balance: Σ(all account deltas) == 0
-- These internal accounts absorb fees, PnL, rounding dust, and bad debt.

CREATE TABLE system_accounts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code         TEXT UNIQUE NOT NULL,  -- 'house_fee_phon', 'house_fee_usdt', etc.
  currency     currency NOT NULL,
  balance      TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT sa_bal_fmt   CHECK (balance ~ '^-?\d+(\.\d+)?$'),
  description  TEXT NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the mandatory system accounts.
-- IMPORTANT: internal system accounts MAY hold NEGATIVE balances. They represent
-- the house side of a two-sided ledger (counterparty, liquidity, mint). A negative
-- balance is a house liability, not an error. Only USER wallets must stay >= 0.
INSERT INTO system_accounts (code, currency, description) VALUES
  ('house_fee_phon',        'PHON', 'Fee revenue collected in PHON (>= 0 in practice)'),
  ('house_fee_usdt',        'USDT', 'Fee revenue collected in USDT (>= 0 in practice)'),
  ('insurance_fund_phon',   'PHON', 'Futures counterparty/insurance in PHON (may be negative = house paid out)'),
  ('insurance_fund_usdt',   'USDT', 'Futures counterparty/insurance in USDT (may be negative = house paid out)'),
  ('house_liquidity_phon',  'PHON', 'Spot principal counterparty / liquidity in PHON (may be negative)'),
  ('house_liquidity_usdt',  'USDT', 'Spot principal counterparty / liquidity in USDT (may be negative)'),
  ('dust_phon',             'PHON', 'Rounding dust accumulator (PHON) — captures 6dp truncation residue'),
  ('dust_usdt',             'USDT', 'Rounding dust accumulator (USDT) — captures 6dp truncation residue'),
  ('reward_issuance_phon',  'PHON', 'Mint account for issued PHON (bonuses/rewards). Goes NEGATIVE = total emitted.');

-- Append-only system account ledger (mirrors wallet_ledger for internal accounts)
CREATE TABLE system_account_ledger (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_code     TEXT NOT NULL REFERENCES system_accounts(code),
  direction        TEXT NOT NULL CHECK (direction IN ('credit','debit')),
  currency         currency NOT NULL,
  amount           TEXT NOT NULL CHECK (amount ~ '^\d+(\.\d+)?$'),
  balance_before   TEXT NOT NULL,
  balance_after    TEXT NOT NULL,
  reason_code      TEXT NOT NULL,
  related_user_id  UUID REFERENCES profiles(id),
  related_tx_id    TEXT,
  transfer_id      UUID,  -- pairs this entry with its counter-entry
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sal_account_idx ON system_account_ledger (account_code, created_at DESC);
CREATE INDEX sal_transfer_idx ON system_account_ledger (transfer_id) WHERE transfer_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1: Double-entry transfer_id on wallet_ledger
-- ─────────────────────────────────────────────────────────────────────────────
-- Every wallet_ledger entry must be paired with a counter-entry in either
-- another wallet_ledger row or a system_account_ledger row.
-- We add transfer_id as a nullable column (will be made NOT NULL in a future
-- migration once backfill is complete).

ALTER TABLE wallet_ledger ADD COLUMN IF NOT EXISTS transfer_id UUID;
CREATE INDEX wl_transfer_idx ON wallet_ledger (transfer_id) WHERE transfer_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1: Non-negative USER wallet balances (DB CHECK — second half of the double guard)
-- ─────────────────────────────────────────────────────────────────────────────
-- The Phase 1 format checks allow a leading '-'. USER wallets must never go
-- negative; the RPC guards already enforce this, but we add DB CHECKs so even a
-- buggy/compromised code path cannot persist a negative user balance. (System
-- accounts intentionally MAY be negative; that is a separate table.)
ALTER TABLE wallets
  ADD CONSTRAINT wallets_phon_available_nonneg CHECK (phon_available::NUMERIC >= 0),
  ADD CONSTRAINT wallets_phon_locked_nonneg    CHECK (phon_locked::NUMERIC    >= 0),
  ADD CONSTRAINT wallets_usdt_available_nonneg CHECK (usdt_available::NUMERIC >= 0),
  ADD CONSTRAINT wallets_usdt_locked_nonneg    CHECK (usdt_locked::NUMERIC    >= 0),
  ADD CONSTRAINT wallets_krw_available_nonneg  CHECK (krw_available::NUMERIC  >= 0),
  ADD CONSTRAINT wallets_krw_locked_nonneg     CHECK (krw_locked::NUMERIC     >= 0);

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: Price change audit log (append-only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE price_change_audit (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol       TEXT NOT NULL,
  price_before TEXT,
  price_after  TEXT NOT NULL,
  change_pct   NUMERIC,        -- (after/before - 1) × 100
  source       TEXT NOT NULL DEFAULT 'admin',  -- 'admin' | 'cron' | 'external'
  actor_id     UUID REFERENCES profiles(id),
  reason       TEXT,           -- required when source='admin'
  circuit_breaker_triggered BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX pca_symbol_idx ON price_change_audit (symbol, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: Circuit breaker state per market
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE market_circuit_breakers (
  symbol            TEXT PRIMARY KEY,
  is_halted         BOOLEAN NOT NULL DEFAULT FALSE,
  halt_reason       TEXT,
  halted_at         TIMESTAMPTZ,
  price_at_halt     TEXT,
  resumed_at        TIMESTAMPTZ,
  max_tick_pct      NUMERIC NOT NULL DEFAULT 10.0, -- ±% per tick
  staleness_seconds INT     NOT NULL DEFAULT 300,  -- price older than N sec = halt
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed one row per market
INSERT INTO market_circuit_breakers (symbol, max_tick_pct, staleness_seconds) VALUES
  ('PHONUSDT-PERP', 10.0, 300),
  ('BTCUSDT-SIM',   10.0, 300),
  ('ETHUSDT-SIM',   10.0, 300),
  ('PHON_USDT',     10.0, 300);

-- ─────────────────────────────────────────────────────────────────────────────
-- A4: Hash-chain columns on wallet_ledger
-- ─────────────────────────────────────────────────────────────────────────────
-- seq:       monotonic per-row sequence (global). Chain order = per-user ascending seq.
--            Using a strictly-increasing seq (instead of created_at) removes the
--            ambiguity where multiple rows in one transaction share created_at=NOW().
-- prev_hash: row_hash of the previous row for this user (NULL = first/genesis).
-- row_hash:  SHA-256(prev_hash || id || direction || currency || amount || seq)
-- The insert trigger populates prev_hash/row_hash automatically.

ALTER TABLE wallet_ledger
  ADD COLUMN IF NOT EXISTS seq       BIGINT GENERATED BY DEFAULT AS IDENTITY,
  ADD COLUMN IF NOT EXISTS prev_hash TEXT,
  ADD COLUMN IF NOT EXISTS row_hash  TEXT;

-- Walk the chain per user in deterministic order
CREATE INDEX wl_hash_chain_idx ON wallet_ledger (user_id, seq);

-- ─────────────────────────────────────────────────────────────────────────────
-- A4: Trigger to compute hash chain on wallet_ledger INSERT
-- ─────────────────────────────────────────────────────────────────────────────
-- seq is assigned by the IDENTITY default BEFORE this BEFORE-INSERT trigger runs,
-- so NEW.seq is available here. We chain to the previous row of the same user
-- (largest seq < NEW.seq). Concurrent inserts for the SAME user are serialized
-- by the wallet FOR UPDATE lock held in the calling RPC, so no chain fork occurs.

CREATE OR REPLACE FUNCTION _wl_compute_hash()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_prev_hash TEXT;
  v_payload   TEXT;
BEGIN
  SELECT row_hash INTO v_prev_hash
  FROM wallet_ledger
  WHERE user_id = NEW.user_id
    AND seq < NEW.seq
  ORDER BY seq DESC
  LIMIT 1;

  NEW.prev_hash := v_prev_hash;   -- NULL if first row for this user

  v_payload := coalesce(v_prev_hash, 'GENESIS')
    || '|' || NEW.id::TEXT
    || '|' || NEW.direction
    || '|' || NEW.currency::TEXT
    || '|' || NEW.amount
    || '|' || NEW.seq::TEXT;

  NEW.row_hash := encode(extensions.digest(v_payload, 'sha256'), 'hex');
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_wl_hash_chain
BEFORE INSERT ON wallet_ledger
FOR EACH ROW EXECUTE FUNCTION _wl_compute_hash();

-- Backfill hash chain for any pre-existing rows (Phase 1-3 ledger entries) so the
-- verifier is clean from day one. New rows are hashed by the trigger above.
-- The Phase 1 append-only RULE (DO INSTEAD NOTHING on UPDATE) must be disabled for
-- this one-time backfill, then re-enabled.
ALTER TABLE wallet_ledger DISABLE RULE wallet_ledger_no_update;
DO $$
DECLARE
  r           wallet_ledger%ROWTYPE;
  v_last_user UUID := NULL;
  v_prev_hash TEXT := NULL;
  v_payload   TEXT;
  v_hash      TEXT;
BEGIN
  FOR r IN SELECT * FROM wallet_ledger ORDER BY user_id, seq LOOP
    IF v_last_user IS NULL OR r.user_id <> v_last_user THEN
      v_prev_hash := NULL;
      v_last_user := r.user_id;
    END IF;

    v_payload := coalesce(v_prev_hash, 'GENESIS')
      || '|' || r.id::TEXT
      || '|' || r.direction
      || '|' || r.currency::TEXT
      || '|' || r.amount
      || '|' || r.seq::TEXT;
    v_hash := encode(extensions.digest(v_payload, 'sha256'), 'hex');

    UPDATE wallet_ledger SET prev_hash = v_prev_hash, row_hash = v_hash WHERE id = r.id;

    v_prev_hash := v_hash;
  END LOOP;
END;
$$;
ALTER TABLE wallet_ledger ENABLE RULE wallet_ledger_no_update;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4: Hash-chain integrity verification function
-- ─────────────────────────────────────────────────────────────────────────────
-- Called by reconciliation cron. Returns broken rows; empty result = clean.
-- Iterates in (user_id, seq) order. prev_hash resets at each user boundary,
-- which is detected by tracking the previous loop iteration's user_id.

CREATE OR REPLACE FUNCTION verify_ledger_hash_chain(p_user_id UUID DEFAULT NULL)
RETURNS TABLE (
  broken_user_id UUID,
  entry_id       UUID,
  entry_seq      BIGINT,
  expected       TEXT,
  actual         TEXT
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r           wallet_ledger%ROWTYPE;
  v_last_user UUID := NULL;
  v_prev_hash TEXT := NULL;
  v_payload   TEXT;
  v_expected  TEXT;
BEGIN
  SET search_path = public, pg_temp;

  FOR r IN
    SELECT * FROM wallet_ledger
    WHERE (p_user_id IS NULL OR wallet_ledger.user_id = p_user_id)
    ORDER BY wallet_ledger.user_id, wallet_ledger.seq
  LOOP
    -- Reset chain when we cross into a new user's first row
    IF v_last_user IS NULL OR r.user_id <> v_last_user THEN
      v_prev_hash := NULL;
      v_last_user := r.user_id;
    END IF;

    v_payload := coalesce(v_prev_hash, 'GENESIS')
      || '|' || r.id::TEXT
      || '|' || r.direction
      || '|' || r.currency::TEXT
      || '|' || r.amount
      || '|' || r.seq::TEXT;

    v_expected := encode(extensions.digest(v_payload, 'sha256'), 'hex');

    -- Detect both tampered fields (hash mismatch) and a broken prev_hash link
    IF v_expected <> coalesce(r.row_hash, '')
       OR coalesce(r.prev_hash, '') <> coalesce(v_prev_hash, '') THEN
      broken_user_id := r.user_id;
      entry_id       := r.id;
      entry_seq      := r.seq;
      expected       := v_expected;
      actual         := r.row_hash;
      RETURN NEXT;
    END IF;

    v_prev_hash := r.row_hash;
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5: RPC rate limits (token bucket)
-- ─────────────────────────────────────────────────────────────────────────────
-- Each high-risk RPC has a per-user bucket. The bucket refills at `refill_rate`
-- tokens per second up to `capacity`. Each call costs `cost` tokens.

CREATE TABLE rpc_rate_limit_configs (
  rpc_name      TEXT PRIMARY KEY,
  capacity      INT NOT NULL DEFAULT 10,       -- max burst
  refill_rate   NUMERIC NOT NULL DEFAULT 1.0,  -- tokens/second
  cost          INT NOT NULL DEFAULT 1,         -- tokens per call
  window_sec    INT NOT NULL DEFAULT 60,        -- for fixed-window fallback display
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

-- Seed rate limits for high-risk RPCs
INSERT INTO rpc_rate_limit_configs (rpc_name, capacity, refill_rate, cost, window_sec) VALUES
  ('rpc_open_futures_position',   5,  0.083, 1, 60),   -- 5/min burst, ~5/min steady
  ('rpc_close_futures_position',  10, 0.167, 1, 60),   -- 10/min burst
  ('rpc_liquidate_position',      20, 0.333, 1, 60),   -- liquidations (cron)
  ('rpc_spot_market_buy',         10, 0.167, 1, 60),
  ('rpc_spot_market_sell',        10, 0.167, 1, 60),
  ('rpc_stake_phon',              5,  0.083, 1, 60),
  ('rpc_claim_staking_reward',    5,  0.083, 1, 60),
  ('rpc_unstake_phon',            5,  0.083, 1, 60),
  ('rpc_claim_welcome_bonus',     2,  0.033, 1, 60),
  ('rpc_spin_roulette',           1,  0.0,   1, 86400), -- 1/day
  ('rpc_claim_daily_reward',      1,  0.0,   1, 86400); -- 1/day

-- Per-user token bucket state
CREATE TABLE rpc_rate_limit_buckets (
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  rpc_name      TEXT NOT NULL REFERENCES rpc_rate_limit_configs(rpc_name),
  tokens        NUMERIC NOT NULL DEFAULT 10,
  last_refill   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY   (user_id, rpc_name)
);

CREATE INDEX rlb_user_idx ON rpc_rate_limit_buckets (user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- A5: Rate limit enforcement function
-- ─────────────────────────────────────────────────────────────────────────────
-- Call this at the top of every high-risk RPC. Raises 'rate_limit_exceeded'
-- if the bucket is empty.

CREATE OR REPLACE FUNCTION _enforce_rate_limit(p_user_id UUID, p_rpc_name TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cfg  rpc_rate_limit_configs%ROWTYPE;
  v_bkt  rpc_rate_limit_buckets%ROWTYPE;
  v_now  TIMESTAMPTZ := NOW();
  v_elapsed NUMERIC;
  v_new_tokens NUMERIC;
BEGIN
  SELECT * INTO v_cfg FROM rpc_rate_limit_configs WHERE rpc_name = p_rpc_name AND is_active;
  IF NOT FOUND THEN RETURN; END IF;  -- no config = no limit

  -- Upsert bucket with FOR UPDATE
  INSERT INTO rpc_rate_limit_buckets (user_id, rpc_name, tokens, last_refill)
  VALUES (p_user_id, p_rpc_name, v_cfg.capacity, v_now)
  ON CONFLICT (user_id, rpc_name) DO NOTHING;

  SELECT * INTO v_bkt FROM rpc_rate_limit_buckets
  WHERE user_id = p_user_id AND rpc_name = p_rpc_name
  FOR UPDATE;

  -- Refill tokens based on elapsed time
  v_elapsed := EXTRACT(EPOCH FROM (v_now - v_bkt.last_refill));
  v_new_tokens := LEAST(v_cfg.capacity, v_bkt.tokens + (v_elapsed * v_cfg.refill_rate));

  IF v_new_tokens < v_cfg.cost THEN
    RAISE EXCEPTION 'rate_limit_exceeded' USING HINT = p_rpc_name;
  END IF;

  UPDATE rpc_rate_limit_buckets
  SET tokens = v_new_tokens - v_cfg.cost,
      last_refill = v_now
  WHERE user_id = p_user_id AND rpc_name = p_rpc_name;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1: User consents (versioned, append-only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TYPE consent_doc_type AS ENUM (
  'terms_of_service',
  'privacy_policy',
  'risk_disclosure',
  'age_verification',
  'marketing_opt_in',
  'push_notification',
  'trading_risk_acknowledgement',
  'game_risk_acknowledgement',
  'withdrawal_policy_acknowledgement'
);

CREATE TABLE user_consents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  doc_type    consent_doc_type NOT NULL,
  doc_version TEXT NOT NULL DEFAULT '1.0',
  accepted    BOOLEAN NOT NULL,           -- false = explicit reject (opt-out for optional)
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address  TEXT,
  user_agent  TEXT,
  locale      TEXT NOT NULL DEFAULT 'ko'
);

-- Append-only: no UPDATE/DELETE
CREATE INDEX uc_user_idx   ON user_consents (user_id, doc_type, accepted_at DESC);
CREATE INDEX uc_type_idx   ON user_consents (doc_type, doc_version);

-- Latest accepted version per user + doc (for quick gate checks)
CREATE VIEW v_user_consent_latest AS
SELECT DISTINCT ON (user_id, doc_type)
  user_id, doc_type, doc_version, accepted, accepted_at
FROM user_consents
ORDER BY user_id, doc_type, accepted_at DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1: RPC to record consent (client calls this during onboarding)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_record_consent(
  p_doc_type    TEXT,
  p_doc_version TEXT,
  p_accepted    BOOLEAN,
  p_ip_address  TEXT DEFAULT NULL,
  p_user_agent  TEXT DEFAULT NULL,
  p_locale      TEXT DEFAULT 'ko'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_id      UUID;
BEGIN
  SET search_path = public, pg_temp;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  INSERT INTO user_consents (user_id, doc_type, doc_version, accepted, ip_address, user_agent, locale)
  VALUES (v_user_id, p_doc_type::consent_doc_type, p_doc_version, p_accepted, p_ip_address, p_user_agent, p_locale)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('consent_id', v_id, 'doc_type', p_doc_type,
    'accepted', p_accepted, 'recorded_at', NOW());
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_record_consent(TEXT,TEXT,BOOLEAN,TEXT,TEXT,TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1: Gate check — returns TRUE if user has accepted all mandatory docs
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_check_onboarding_consent()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_missing TEXT[];
  v_doc     TEXT;
BEGIN
  SET search_path = public, pg_temp;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  v_missing := '{}';
  FOREACH v_doc IN ARRAY ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM v_user_consent_latest
      WHERE user_id = v_user_id AND doc_type = v_doc::consent_doc_type AND accepted = TRUE
    ) THEN
      v_missing := v_missing || v_doc;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'complete', array_length(v_missing, 1) IS NULL,
    'missing', v_missing
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_check_onboarding_consent() TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1: Server-side consent gate (feature-flagged)
-- ─────────────────────────────────────────────────────────────────────────────
-- High-risk ENTRY RPCs (open position, spot buy/sell, stake) call
-- _assert_onboarding_consent(user_id). It is a NO-OP until the operator flips
-- 'consent_gate_enabled' to true (done once the B1 onboarding UI ships), so it
-- cannot break the current app. EXIT paths (close/liquidate/claim/unstake) are
-- intentionally never gated — a user must always be able to get out.

CREATE TABLE app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO app_config (key, value, description) VALUES
  ('consent_gate_enabled', 'false', 'When true, high-risk entry RPCs require onboarding consent. Flip on after B1 UI ships.');

ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public read app_config" ON app_config FOR SELECT USING (TRUE);

CREATE OR REPLACE FUNCTION _assert_onboarding_consent(p_user_id UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_enabled TEXT;
  v_doc     TEXT;
BEGIN
  SELECT value INTO v_enabled FROM app_config WHERE key = 'consent_gate_enabled';
  IF v_enabled IS DISTINCT FROM 'true' THEN
    RETURN;  -- gate disabled → no-op (safe default before UI ships)
  END IF;

  FOREACH v_doc IN ARRAY ARRAY['terms_of_service','privacy_policy','risk_disclosure','age_verification']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM v_user_consent_latest
      WHERE user_id = p_user_id AND doc_type = v_doc::consent_doc_type AND accepted = TRUE
    ) THEN
      RAISE EXCEPTION 'consent_required' USING HINT = v_doc;
    END IF;
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS for new tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE system_accounts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_account_ledger   ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_change_audit      ENABLE ROW LEVEL SECURITY;
ALTER TABLE market_circuit_breakers ENABLE ROW LEVEL SECURITY;
ALTER TABLE rpc_rate_limit_configs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rpc_rate_limit_buckets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_consents           ENABLE ROW LEVEL SECURITY;

-- System accounts: only admins read; RPCs write via SECURITY DEFINER
CREATE POLICY "admin read system_accounts"   ON system_accounts
  FOR SELECT USING (_is_admin());
CREATE POLICY "admin read sal"               ON system_account_ledger
  FOR SELECT USING (_is_admin());

-- Price audit: public read (transparency)
CREATE POLICY "public read price_change_audit" ON price_change_audit
  FOR SELECT USING (TRUE);

-- Circuit breakers: public read
CREATE POLICY "public read circuit_breakers" ON market_circuit_breakers
  FOR SELECT USING (TRUE);

-- Rate limit config: public read
CREATE POLICY "public read rl_configs" ON rpc_rate_limit_configs
  FOR SELECT USING (TRUE);

-- Rate limit buckets: users see own
CREATE POLICY "own rl_buckets" ON rpc_rate_limit_buckets
  FOR SELECT USING (user_id = auth.uid());

-- Consents: users read own
CREATE POLICY "own consents"   ON user_consents
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "admin consents" ON user_consents
  FOR SELECT USING (_is_admin());

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: rpc_update_oracle_price (replaces direct table update)
-- ─────────────────────────────────────────────────────────────────────────────
-- Admin-only. Enforces circuit breaker (±max_tick_pct) and writes audit log.

CREATE OR REPLACE FUNCTION rpc_update_oracle_price(
  p_symbol TEXT,
  p_price  TEXT,
  p_reason TEXT DEFAULT NULL,
  p_source TEXT DEFAULT 'admin'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_actor_id    UUID := auth.uid();
  v_old_price   NUMERIC;
  v_new_price   NUMERIC := p_price::NUMERIC;
  v_change_pct  NUMERIC;
  v_cb          market_circuit_breakers%ROWTYPE;
  v_halted      BOOLEAN := FALSE;
  v_staleness   INTERVAL;
BEGIN
  SET search_path = public, pg_temp;

  -- Only admin or service-role (actor_id NULL) can update prices
  IF v_actor_id IS NOT NULL AND NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF v_new_price <= 0 THEN RAISE EXCEPTION 'invalid_price'; END IF;
  IF p_source = 'admin' AND p_reason IS NULL THEN
    RAISE EXCEPTION 'admin_price_update_requires_reason';
  END IF;

  -- Lock circuit breaker row
  SELECT * INTO v_cb FROM market_circuit_breakers WHERE symbol = p_symbol FOR UPDATE;
  IF v_cb.is_halted THEN
    RAISE EXCEPTION 'market_halted' USING HINT = p_symbol;
  END IF;

  -- Get current price
  SELECT price::NUMERIC INTO v_old_price FROM oracle_prices WHERE symbol = p_symbol;

  -- Circuit breaker check
  IF v_old_price IS NOT NULL AND v_old_price > 0 THEN
    v_change_pct := abs((v_new_price / v_old_price - 1) * 100);
    IF v_change_pct > v_cb.max_tick_pct THEN
      -- Trigger circuit breaker: halt the market. These writes MUST persist, so we
      -- DO NOT RAISE afterwards (a RAISE would roll the whole transaction back and
      -- silently undo the halt + audit row). The rejected price is simply NOT applied.
      UPDATE market_circuit_breakers SET
        is_halted = TRUE,
        halt_reason = 'price_move_' || round(v_change_pct, 4)::TEXT || 'pct_exceeds_limit_'
                      || round(v_cb.max_tick_pct, 2)::TEXT || 'pct',
        halted_at = NOW(),
        price_at_halt = v_old_price::TEXT,
        updated_at = NOW()
      WHERE symbol = p_symbol;

      -- Deactivate the market for trading
      UPDATE futures_markets SET is_active = FALSE WHERE symbol = p_symbol;
      UPDATE spot_markets     SET is_active = FALSE WHERE symbol = p_symbol;

      INSERT INTO price_change_audit (symbol, price_before, price_after, change_pct, source, actor_id, reason, circuit_breaker_triggered)
      VALUES (p_symbol, v_old_price::TEXT, p_price, v_change_pct, p_source, v_actor_id, p_reason, TRUE);

      -- Return a normal result describing the halt (committed), price NOT updated.
      RETURN jsonb_build_object(
        'symbol', p_symbol,
        'price', v_old_price::TEXT,          -- unchanged
        'rejected_price', p_price,
        'change_pct', v_change_pct,
        'circuit_breaker_triggered', TRUE,
        'market_halted', TRUE
      );
    END IF;
  END IF;

  -- Normal price update
  INSERT INTO oracle_prices (symbol, price, updated_at)
  VALUES (p_symbol, p_price, NOW())
  ON CONFLICT (symbol) DO UPDATE SET price = EXCLUDED.price, updated_at = NOW();

  INSERT INTO price_ticks (symbol, price) VALUES (p_symbol, p_price);

  INSERT INTO price_change_audit (symbol, price_before, price_after, change_pct, source, actor_id, reason, circuit_breaker_triggered)
  VALUES (p_symbol, v_old_price::TEXT, p_price, v_change_pct, p_source, v_actor_id, p_reason, FALSE);

  RETURN jsonb_build_object(
    'symbol', p_symbol, 'price', p_price,
    'change_pct', v_change_pct, 'circuit_breaker_triggered', FALSE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_update_oracle_price(TEXT,TEXT,TEXT,TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: Admin circuit breaker resume
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_resume_market(p_symbol TEXT, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET search_path = public, pg_temp;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;

  UPDATE market_circuit_breakers SET
    is_halted = FALSE, halt_reason = NULL, resumed_at = NOW(), updated_at = NOW()
  WHERE symbol = p_symbol;

  -- Re-activate markets
  UPDATE futures_markets SET is_active = TRUE WHERE symbol = p_symbol;
  UPDATE spot_markets     SET is_active = TRUE WHERE symbol = p_symbol;

  INSERT INTO price_change_audit (symbol, price_before, price_after, change_pct, source, actor_id, reason)
  SELECT p_symbol, price, price, 0, 'admin_resume', auth.uid(), p_reason
  FROM oracle_prices WHERE symbol = p_symbol;

  RETURN jsonb_build_object('symbol', p_symbol, 'resumed', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_resume_market(TEXT,TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3: Staleness guard helper (used inside trading RPCs)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _assert_price_fresh(p_symbol TEXT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_price      NUMERIC;
  v_updated_at TIMESTAMPTZ;
  v_staleness  INT;
BEGIN
  SELECT price::NUMERIC, updated_at INTO v_price, v_updated_at
  FROM oracle_prices WHERE symbol = p_symbol;

  IF v_price IS NULL OR v_price <= 0 THEN RAISE EXCEPTION 'no_price' USING HINT = p_symbol; END IF;

  SELECT staleness_seconds INTO v_staleness
  FROM market_circuit_breakers WHERE symbol = p_symbol;

  IF v_staleness IS NOT NULL AND EXTRACT(EPOCH FROM (NOW() - v_updated_at)) > v_staleness THEN
    RAISE EXCEPTION 'stale_price' USING HINT = p_symbol;
  END IF;

  -- Check if market is halted
  IF EXISTS (SELECT 1 FROM market_circuit_breakers WHERE symbol = p_symbol AND is_halted) THEN
    RAISE EXCEPTION 'market_halted' USING HINT = p_symbol;
  END IF;

  RETURN v_price;
END;
$$;
