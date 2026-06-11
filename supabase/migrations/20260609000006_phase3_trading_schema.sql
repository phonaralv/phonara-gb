-- ============================================================
-- Migration: 20260609000006_phase3_trading_schema
-- Phase 3: Trading — Spot, Futures (simulated perpetual), Staking
-- ============================================================
-- All monetary values stored as TEXT (Decimal-safe), validated by regex.
-- All settlement happens via Atomic RPCs that mirror @phonara/trading-engine.
-- position_ledger / spot_trades / staking_* are append-only history.
-- ============================================================

-- ─── Enums ───────────────────────────────────────────────────

CREATE TYPE position_side    AS ENUM ('long', 'short');
CREATE TYPE position_status  AS ENUM ('open', 'closed', 'liquidated');
CREATE TYPE spot_side        AS ENUM ('buy', 'sell');
CREATE TYPE staking_term     AS ENUM ('flexible', 'days_7', 'days_30', 'days_90');
CREATE TYPE staking_status   AS ENUM ('active', 'unstaked');

-- Money / price regex helpers reused inline below.

-- ─── futures_markets ─────────────────────────────────────────

CREATE TABLE futures_markets (
  symbol            TEXT PRIMARY KEY,                       -- e.g. 'PHONUSDT-PERP'
  base_label        TEXT NOT NULL,                          -- 'PHON', 'BTC', 'ETH'
  max_leverage      TEXT NOT NULL DEFAULT '50'
    CONSTRAINT fm_maxlev_fmt CHECK (max_leverage ~ '^\d+(\.\d+)?$'),
  open_fee_rate     TEXT NOT NULL DEFAULT '0.0006'
    CONSTRAINT fm_openfee_fmt CHECK (open_fee_rate ~ '^\d+(\.\d+)?$'),
  close_fee_rate    TEXT NOT NULL DEFAULT '0.0006'
    CONSTRAINT fm_closefee_fmt CHECK (close_fee_rate ~ '^\d+(\.\d+)?$'),
  maintenance_margin_rate TEXT NOT NULL DEFAULT '0.005'
    CONSTRAINT fm_mmr_fmt CHECK (maintenance_margin_rate ~ '^\d+(\.\d+)?$'),
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── spot_markets ────────────────────────────────────────────

CREATE TABLE spot_markets (
  symbol        TEXT PRIMARY KEY,                            -- 'PHON_USDT'
  fee_rate      TEXT NOT NULL DEFAULT '0.001'
    CONSTRAINT sm_fee_fmt CHECK (fee_rate ~ '^\d+(\.\d+)?$'),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── oracle_prices ───────────────────────────────────────────
-- Current mark price per market symbol (spot or futures).
-- Updated by admin/system. All trades snapshot this value.

CREATE TABLE oracle_prices (
  symbol        TEXT PRIMARY KEY,
  price         TEXT NOT NULL
    CONSTRAINT op_price_fmt CHECK (price ~ '^\d+(\.\d+)?$'),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Append-only price history (for charts)
CREATE TABLE price_ticks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol      TEXT NOT NULL,
  price       TEXT NOT NULL
    CONSTRAINT pt_price_fmt CHECK (price ~ '^\d+(\.\d+)?$'),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX price_ticks_symbol_idx ON price_ticks (symbol, created_at DESC);

-- ─── futures_positions ───────────────────────────────────────

CREATE TABLE futures_positions (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  market             TEXT NOT NULL REFERENCES futures_markets(symbol),
  side               position_side NOT NULL,
  margin_currency    currency NOT NULL
    CONSTRAINT fp_margin_ccy CHECK (margin_currency IN ('PHON','USDT')),
  margin_amount      TEXT NOT NULL CONSTRAINT fp_margin_fmt CHECK (margin_amount ~ '^\d+(\.\d+)?$'),
  leverage           TEXT NOT NULL CONSTRAINT fp_lev_fmt CHECK (leverage ~ '^\d+(\.\d+)?$'),
  entry_price        TEXT NOT NULL CONSTRAINT fp_entry_fmt CHECK (entry_price ~ '^\d+(\.\d+)?$'),
  quantity           TEXT NOT NULL CONSTRAINT fp_qty_fmt CHECK (quantity ~ '^\d+(\.\d+)?$'),
  notional           TEXT NOT NULL,
  open_fee           TEXT NOT NULL,
  liquidation_price  TEXT NOT NULL,
  stop_loss          TEXT,
  take_profit        TEXT,

  status             position_status NOT NULL DEFAULT 'open',
  exit_price         TEXT,
  realized_pnl       TEXT,                                  -- signed
  close_fee          TEXT,
  equity_returned    TEXT,

  opened_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  closed_at          TIMESTAMPTZ,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX fp_user_idx        ON futures_positions (user_id, status);
CREATE INDEX fp_market_idx      ON futures_positions (market, status);
CREATE INDEX fp_open_status_idx ON futures_positions (status) WHERE status = 'open';

CREATE TRIGGER fp_updated_at
  BEFORE UPDATE ON futures_positions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── position_ledger ─────────────────────────────────────────
-- Append-only events: open / close / liquidate / sltp_update.

CREATE TABLE position_ledger (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id   UUID NOT NULL REFERENCES futures_positions(id) ON DELETE RESTRICT,
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  event         TEXT NOT NULL,                              -- 'open','close','liquidate','sltp'
  price         TEXT,
  realized_pnl  TEXT,
  fee           TEXT,
  payload       JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX pl_position_idx ON position_ledger (position_id, created_at);
CREATE INDEX pl_user_idx     ON position_ledger (user_id, created_at DESC);

CREATE OR REPLACE RULE position_ledger_no_update AS
  ON UPDATE TO position_ledger DO INSTEAD NOTHING;
CREATE OR REPLACE RULE position_ledger_no_delete AS
  ON DELETE TO position_ledger DO INSTEAD NOTHING;

-- ─── spot_trades ─────────────────────────────────────────────

CREATE TABLE spot_trades (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  market        TEXT NOT NULL REFERENCES spot_markets(symbol),
  side          spot_side NOT NULL,
  price         TEXT NOT NULL,
  -- buy:  usdt_amount spent, phon_amount received (net)
  -- sell: phon_amount spent, usdt_amount received (net)
  phon_amount   TEXT NOT NULL,
  usdt_amount   TEXT NOT NULL,
  fee_currency  currency NOT NULL,
  fee_amount    TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX st_user_idx   ON spot_trades (user_id, created_at DESC);
CREATE INDEX st_market_idx ON spot_trades (market, created_at DESC);

CREATE OR REPLACE RULE spot_trades_no_update AS
  ON UPDATE TO spot_trades DO INSTEAD NOTHING;
CREATE OR REPLACE RULE spot_trades_no_delete AS
  ON DELETE TO spot_trades DO INSTEAD NOTHING;

-- ─── staking_pools ───────────────────────────────────────────

CREATE TABLE staking_pools (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  term           staking_term NOT NULL UNIQUE,
  lock_days      INT NOT NULL DEFAULT 0,
  estimated_apr  TEXT NOT NULL CONSTRAINT sp_apr_fmt CHECK (estimated_apr ~ '^\d+(\.\d+)?$'),
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── staking_positions ───────────────────────────────────────

CREATE TABLE staking_positions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  pool_id         UUID NOT NULL REFERENCES staking_pools(id),
  term            staking_term NOT NULL,
  principal       TEXT NOT NULL CONSTRAINT stp_principal_fmt CHECK (principal ~ '^\d+(\.\d+)?$'),
  apr_snapshot    TEXT NOT NULL,
  lock_days       INT NOT NULL DEFAULT 0,
  status          staking_status NOT NULL DEFAULT 'active',
  reward_claimed  TEXT NOT NULL DEFAULT '0.000000',
  staked_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  unlock_at       TIMESTAMPTZ,
  unstaked_at     TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX stp_user_idx ON staking_positions (user_id, status);

CREATE TRIGGER stp_updated_at
  BEFORE UPDATE ON staking_positions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── staking_rewards ─────────────────────────────────────────
-- Append-only reward claim history.

CREATE TABLE staking_rewards (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  staking_position_id UUID NOT NULL REFERENCES staking_positions(id) ON DELETE RESTRICT,
  user_id             UUID NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  reward_amount       TEXT NOT NULL,
  ledger_entry_id     UUID REFERENCES wallet_ledger(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sr_user_idx     ON staking_rewards (user_id, created_at DESC);
CREATE INDEX sr_position_idx ON staking_rewards (staking_position_id);

CREATE OR REPLACE RULE staking_rewards_no_update AS
  ON UPDATE TO staking_rewards DO INSTEAD NOTHING;
CREATE OR REPLACE RULE staking_rewards_no_delete AS
  ON DELETE TO staking_rewards DO INSTEAD NOTHING;

-- ─── RLS ─────────────────────────────────────────────────────

ALTER TABLE futures_markets    ENABLE ROW LEVEL SECURITY;
ALTER TABLE spot_markets       ENABLE ROW LEVEL SECURITY;
ALTER TABLE oracle_prices      ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_ticks        ENABLE ROW LEVEL SECURITY;
ALTER TABLE futures_positions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE position_ledger    ENABLE ROW LEVEL SECURITY;
ALTER TABLE spot_trades        ENABLE ROW LEVEL SECURITY;
ALTER TABLE staking_pools      ENABLE ROW LEVEL SECURITY;
ALTER TABLE staking_positions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE staking_rewards    ENABLE ROW LEVEL SECURITY;

-- Public market data: anyone authenticated can read
CREATE POLICY "futures_markets: read" ON futures_markets FOR SELECT USING (TRUE);
CREATE POLICY "spot_markets: read"    ON spot_markets    FOR SELECT USING (TRUE);
CREATE POLICY "oracle_prices: read"   ON oracle_prices   FOR SELECT USING (TRUE);
CREATE POLICY "price_ticks: read"     ON price_ticks     FOR SELECT USING (TRUE);
CREATE POLICY "staking_pools: read"   ON staking_pools   FOR SELECT USING (TRUE);

-- Private: own data only
CREATE POLICY "futures_positions: own read" ON futures_positions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "position_ledger: own read"   ON position_ledger   FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "spot_trades: own read"       ON spot_trades       FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "staking_positions: own read" ON staking_positions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "staking_rewards: own read"   ON staking_rewards   FOR SELECT USING (auth.uid() = user_id);

-- ─── Seed data ───────────────────────────────────────────────

INSERT INTO futures_markets (symbol, base_label, max_leverage) VALUES
  ('PHONUSDT-PERP', 'PHON', '50'),
  ('BTCUSDT-SIM',   'BTC',  '100'),
  ('ETHUSDT-SIM',   'ETH',  '100');

INSERT INTO spot_markets (symbol, fee_rate) VALUES
  ('PHON_USDT', '0.001');

INSERT INTO oracle_prices (symbol, price) VALUES
  ('PHONUSDT-PERP', '0.010000'),
  ('BTCUSDT-SIM',   '68000.000000'),
  ('ETHUSDT-SIM',   '3500.000000'),
  ('PHON_USDT',     '0.010000');

INSERT INTO staking_pools (term, lock_days, estimated_apr) VALUES
  ('flexible', 0,  '0.03'),
  ('days_7',   7,  '0.06'),
  ('days_30',  30, '0.12'),
  ('days_90',  90, '0.20');
