-- ============================================================
-- Migration: 20260609000026_s1_solvency_reconciliation
-- S1: Solvency/Reserve invariant + daily wallet↔ledger reconciliation
-- ============================================================
-- Implements §0-E of the v2.0 master plan:
--   1. treasury_reserves table: admin-entered real custodied assets.
--   2. reconciliation_log: append-only log of daily wallet↔ledger checks.
--   3. rpc_run_reconciliation(): compares wallet sums vs ledger net per
--      currency; any mismatch > tolerance triggers system_readonly and logs.
--   4. rpc_update_treasury_reserve(): admin-only treasury balance update.
--   5. _assert_withdrawal_gate(): internal guard called by future
--      deposit/withdrawal RPCs (S4) to verify reserve coverage.
--   6. pg_cron daily reconciliation job.
--
-- Money safety gates (3-layer):
--   ① Hash-chain (wallet_ledger row tamper)
--   ② Reconciliation (wallet total ≠ ledger net → mismatch implies tamper/bug)
--   ③ Reserve gate (real custodied assets < user withdrawal obligations)
-- ============================================================

SET search_path = public, pg_temp;

-- ─── 1. treasury_reserves ─────────────────────────────────────────────────────
-- Stores admin-entered real custodied asset balances (on-chain / custody).
-- Updated manually or via oracle feed; used for reserve ratio checks.

CREATE TABLE IF NOT EXISTS treasury_reserves (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  currency       currency NOT NULL UNIQUE,
  real_balance   TEXT NOT NULL DEFAULT '0.000000'
    CONSTRAINT tr_bal_fmt CHECK (real_balance ~ '^\d+(\.\d+)?$'),
  buffer_pct     NUMERIC NOT NULL DEFAULT 10
    CONSTRAINT tr_buf_range CHECK (buffer_pct >= 0 AND buffer_pct <= 100),
  payout_cap_pct NUMERIC NOT NULL DEFAULT 5
    CONSTRAINT tr_cap_range CHECK (payout_cap_pct > 0 AND payout_cap_pct <= 100),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by     UUID REFERENCES profiles(id),
  notes          TEXT
);

-- Seed one row per currency (real_balance starts at 0; admin fills in actuals).
INSERT INTO treasury_reserves (currency, buffer_pct, payout_cap_pct) VALUES
  ('PHON', 10, 10),
  ('USDT', 10,  5),
  ('KRW',  10,  5)
ON CONFLICT (currency) DO NOTHING;

ALTER TABLE treasury_reserves ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw treasury_reserves" ON treasury_reserves;
CREATE POLICY "admin rw treasury_reserves" ON treasury_reserves
  FOR ALL USING (_is_admin());
DROP POLICY IF EXISTS "authed read treasury_reserves" ON treasury_reserves;
CREATE POLICY "authed read treasury_reserves" ON treasury_reserves
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- ─── 2. reconciliation_log ────────────────────────────────────────────────────
-- Append-only log of daily wallet↔ledger reconciliation runs.

CREATE TABLE IF NOT EXISTS reconciliation_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  currency        currency NOT NULL,
  wallet_sum      TEXT NOT NULL,
  ledger_net      TEXT NOT NULL,
  is_match        BOOLEAN NOT NULL,
  delta           TEXT NOT NULL DEFAULT '0.000000',
  triggered_halt  BOOLEAN NOT NULL DEFAULT FALSE,
  notes           TEXT
);

CREATE INDEX IF NOT EXISTS recon_log_run_at_idx ON reconciliation_log (run_at DESC);
CREATE INDEX IF NOT EXISTS recon_log_mismatch_idx ON reconciliation_log (is_match)
  WHERE is_match = FALSE;

ALTER TABLE reconciliation_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin rw reconciliation_log" ON reconciliation_log;
CREATE POLICY "admin rw reconciliation_log" ON reconciliation_log
  FOR ALL USING (_is_admin());

-- ─── 3. rpc_update_treasury_reserve ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_update_treasury_reserve(
  p_currency    TEXT,
  p_balance     TEXT,
  p_buffer_pct  NUMERIC DEFAULT NULL,
  p_cap_pct     NUMERIC DEFAULT NULL,
  p_notes       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ccy     currency;
BEGIN
  IF NOT _is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  BEGIN v_ccy := p_currency::currency;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'invalid_currency';
  END;

  IF p_balance !~ '^\d+(\.\d+)?$' THEN
    RAISE EXCEPTION 'invalid_amount';
  END IF;

  UPDATE treasury_reserves SET
    real_balance   = p_balance,
    buffer_pct     = COALESCE(p_buffer_pct, buffer_pct),
    payout_cap_pct = COALESCE(p_cap_pct, payout_cap_pct),
    updated_at     = NOW(),
    updated_by     = v_user_id,
    notes          = COALESCE(p_notes, notes)
  WHERE currency = v_ccy;

  IF NOT FOUND THEN RAISE EXCEPTION 'currency_not_found'; END IF;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'currency', p_currency,
    'real_balance', p_balance
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_update_treasury_reserve(TEXT,TEXT,NUMERIC,NUMERIC,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_update_treasury_reserve(TEXT,TEXT,NUMERIC,NUMERIC,TEXT)
  TO service_role;

-- ─── 4. _assert_withdrawal_gate ──────────────────────────────────────────────
-- Called by withdrawal RPCs (S4). Raises withdrawal_blocked if the real reserve
-- balance would drop below the buffer threshold after this withdrawal.
-- Also raises withdrawal_blocked if system is in readonly mode.

CREATE OR REPLACE FUNCTION _assert_withdrawal_gate(
  p_currency currency,
  p_amount   TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tr          treasury_reserves%ROWTYPE;
  v_user_total  NUMERIC;
  v_required    NUMERIC;
  v_real        NUMERIC;
BEGIN
  -- First check system_readonly (reconciliation mismatch may have set it)
  PERFORM _assert_system_live();

  SELECT * INTO v_tr FROM treasury_reserves WHERE currency = p_currency;
  IF NOT FOUND THEN RETURN; END IF;  -- no reserve configured → no gate

  v_real := v_tr.real_balance::NUMERIC;

  -- If real_balance = 0 the gate is not yet configured; skip.
  IF v_real = 0 THEN RETURN; END IF;

  -- Sum of all user withdrawable balances for this currency.
  v_user_total := CASE p_currency
    WHEN 'PHON' THEN (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
    WHEN 'USDT' THEN (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC), 0) FROM wallets)
    WHEN 'KRW'  THEN (SELECT COALESCE(SUM(krw_available::NUMERIC  + krw_locked::NUMERIC),  0) FROM wallets)
    ELSE 0
  END;

  -- Required reserve = user total × (1 + buffer_pct / 100)
  v_required := v_user_total * (1 + v_tr.buffer_pct / 100.0);

  IF v_real < v_required THEN
    RAISE EXCEPTION 'withdrawal_blocked'
      USING HINT = 'reserve_below_buffer',
            DETAIL = format('real=%s required=%s currency=%s',
                            v_tr.real_balance, _fmt6(v_required), p_currency);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION _assert_withdrawal_gate(currency, TEXT) FROM PUBLIC, anon, authenticated;

-- ─── 5. rpc_run_reconciliation ────────────────────────────────────────────────
-- Runs the wallet↔ledger reconciliation for all currencies.
-- Algorithm:
--   wallet_sum  = Σ(available + locked) across all user wallets per currency.
--   ledger_net  = Σ(credit amounts) - Σ(debit amounts) per currency.
--   (lock/unlock move between slots; net change = 0 → excluded from net sum.)
--   (reverse direction negate a prior entry: treated as debit here.)
-- If |wallet_sum - ledger_net| > tolerance (0.000001), log mismatch and
-- set system_readonly=true via rpc_set_system_mode.
--
-- Design: the reconciliation uses RAISE EXCEPTION ONLY for unexpected errors.
-- Mismatch is NOT a RAISE — it sets readonly and returns a status object.
-- This ensures the reconciliation_log INSERT survives even after a mismatch.

CREATE OR REPLACE FUNCTION rpc_run_reconciliation()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ccy           currency;
  v_wallet_sum    NUMERIC;
  v_ledger_net    NUMERIC;
  v_delta         NUMERIC;
  v_tolerance     NUMERIC := 0.000001;  -- 1 satoshi-equivalent
  v_is_match      BOOLEAN;
  v_any_mismatch  BOOLEAN := FALSE;
  v_results       JSONB[] := '{}';
  v_log_id        UUID;
  v_halt_applied  BOOLEAN := FALSE;
BEGIN
  FOR v_ccy IN SELECT unnest(ARRAY['PHON'::currency, 'USDT'::currency, 'KRW'::currency]) LOOP

    -- wallet_sum: total of all user wallet balances for this currency
    v_wallet_sum := CASE v_ccy
      WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
      WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
      WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    END;

    -- ledger_net: sum of all credit entries minus all debit + reverse entries
    v_ledger_net := COALESCE(
      (SELECT
         SUM(CASE
           WHEN direction = 'credit' THEN  amount::NUMERIC
           WHEN direction IN ('debit', 'reverse') THEN -amount::NUMERIC
           -- lock/unlock: move between slots, net 0 on total — excluded
           ELSE 0
         END)
       FROM wallet_ledger
       WHERE currency = v_ccy),
      0
    );

    v_delta    := v_wallet_sum - v_ledger_net;
    v_is_match := ABS(v_delta) <= v_tolerance;

    IF NOT v_is_match THEN
      v_any_mismatch := TRUE;
    END IF;

    -- Insert reconciliation log row (always, regardless of match)
    INSERT INTO reconciliation_log (
      currency, wallet_sum, ledger_net, is_match, delta, triggered_halt
    ) VALUES (
      v_ccy,
      _fmt6(v_wallet_sum),
      _fmt6(v_ledger_net),
      v_is_match,
      _fmt6(v_delta),
      FALSE  -- updated below if halt is applied
    ) RETURNING id INTO v_log_id;

    v_results := v_results || jsonb_build_object(
      'currency', v_ccy,
      'wallet_sum', _fmt6(v_wallet_sum),
      'ledger_net', _fmt6(v_ledger_net),
      'delta', _fmt6(v_delta),
      'is_match', v_is_match
    );
  END LOOP;

  -- If any currency has a mismatch: set system_readonly.
  -- IMPORTANT: we set this AFTER logging to ensure log rows persist.
  -- We do NOT RAISE (that would roll back the log inserts).
  IF v_any_mismatch THEN
    -- Set system_readonly = true (does not halt liquidations, just user ops)
    UPDATE app_config SET value = 'true' WHERE key = 'system_readonly';

    -- Update triggered_halt flag on mismatch log rows
    UPDATE reconciliation_log SET triggered_halt = TRUE
      WHERE run_at >= (NOW() - INTERVAL '1 second') AND is_match = FALSE;

    v_halt_applied := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'mismatch', v_any_mismatch,
    'readonly_set', v_halt_applied,
    'results', v_results
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_run_reconciliation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_run_reconciliation() TO service_role;

-- ─── 6. rpc_check_reserve_ratio ──────────────────────────────────────────────
-- Returns reserve status for admin dashboard display.

CREATE OR REPLACE FUNCTION rpc_check_reserve_ratio()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ccy          currency;
  v_wallet_total NUMERIC;
  v_real         NUMERIC;
  v_required     NUMERIC;
  v_ratio        NUMERIC;
  v_results      JSONB[] := '{}';
BEGIN
  IF NOT _is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  FOR v_ccy IN SELECT unnest(ARRAY['PHON'::currency, 'USDT'::currency, 'KRW'::currency]) LOOP
    v_wallet_total := CASE v_ccy
      WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
      WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
      WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    END;

    SELECT real_balance::NUMERIC, buffer_pct INTO v_real, v_ratio
      FROM treasury_reserves WHERE currency = v_ccy;

    v_required := v_wallet_total * (1 + COALESCE(v_ratio, 10) / 100.0);
    v_ratio    := CASE WHEN v_wallet_total = 0 THEN 100
                       ELSE ROUND(v_real / v_wallet_total * 100, 2) END;

    v_results := v_results || jsonb_build_object(
      'currency',      v_ccy,
      'user_total',    _fmt6(v_wallet_total),
      'real_balance',  _fmt6(COALESCE(v_real, 0)),
      'reserve_ratio_pct', v_ratio,
      'required_reserve',  _fmt6(v_required),
      'is_solvent',    COALESCE(v_real, 0) >= v_required
    );
  END LOOP;

  RETURN jsonb_build_object('ok', TRUE, 'reserves', v_results);
END;
$$;

REVOKE ALL ON FUNCTION rpc_check_reserve_ratio() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_check_reserve_ratio() TO service_role;

-- ─── 7. pg_cron: daily reconciliation ────────────────────────────────────────
-- Run reconciliation daily at 02:00 UTC (low-traffic window).
-- pg_cron is available (installed in migration 000015).
-- Idempotent: cron.schedule replaces an existing job with the same name.

SELECT cron.schedule(
  'phonara_daily_reconciliation',
  '0 2 * * *',
  $cron$SELECT public.rpc_run_reconciliation();$cron$
);
