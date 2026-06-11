-- ============================================================
-- E foundation ①-3 (audit A2-3 / A8-3) — reconciliation integrity wiring
-- ============================================================
-- Why: rpc_run_reconciliation (000026, daily 02:00 cron registered in 000044)
-- only compared Σ(user wallet balances) vs wallet_ledger net per currency. It
-- IGNORED the house/insurance/mint system accounts, the global Σ=0 invariant, and
-- BOTH hash-chains — so the daily auto-check had three blind spots (audit A2-3 /
-- A8-2 / A8-3):
--   * a balanced system-account corruption,
--   * an unbalanced leg (counterpart missing) that nets out across the two ledgers,
--   * any sum-preserving row tamper (reason_code / attribution / balance snapshot)
--     that the now-deployed hash-chains (000017 wallet, 000046 system) can detect
--     but a pure sum reconciliation cannot.
--
-- This migration widens rpc_run_reconciliation to FIVE checks per run and wires in
-- the hash-chain verifiers. No new cron is added — the existing
-- phonara_daily_reconciliation job already calls rpc_run_reconciliation, so it
-- inherits all five checks automatically (audit fix: "hook the existing job, do
-- not add another dormant cron").
--
-- Checks (per currency for 1–3; global for 4–5):
--   (1) wallet conservation  Σ wallet balances == wallet_ledger net   (existing)
--   (2) system conservation  Σ system balances == system_account_ledger net (A2-3)
--   (3) global Σ=0           Σ wallets + Σ system == 0                 (A2-3)
--   (4) wallet hash-chain    verify_ledger_hash_chain() == 0 broken    (A8-3)
--   (5) system hash-chain    verify_system_account_hash_chain() == 0   (A8-2 wiring)
--
-- Halt policy (rule 25-postgres): on ANY mismatch we set system_readonly=true and
-- stamp the failing log rows, then RETURN a status object. We NEVER RAISE after
-- those writes — a RAISE would roll back the very log/halt that records the
-- incident. Liquidations stay live (system_readonly does not gate them).
--
-- Global Σ=0 is a true invariant here: every flow is double-entry across
-- wallet_ledger + system_account_ledger (rewards mint via reward_issuance_phon,
-- deposits via deposit_conversion_phon, spot/futures via house/insurance legs), so
-- a clean state is exactly 0 per currency and the check never false-positives.
--
-- Helper extraction (the two verifiers behind one wrapper) is intentionally
-- deferred until a second consumer exists, to avoid a premature abstraction and an
-- extra lockdown/advisor surface. They are inlined here.
--
-- NOT in scope: solvency-gate unification (A1-4/A2-6) and treasury column scoping
-- (A3-3) are separate audit items.
--
-- Local-only until Wave 12. No remote apply in this change.
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Widen reconciliation_log to carry every check type
-- ─────────────────────────────────────────────────────────────────────────────
-- check_type distinguishes the five checks. Hash-chain rows are cross-currency and
-- carry a broken_count instead of sums, so currency/wallet_sum/ledger_net become
-- nullable. Existing wallet rows keep their values (default check_type 'wallet').
ALTER TABLE reconciliation_log
  ADD COLUMN IF NOT EXISTS check_type   TEXT NOT NULL DEFAULT 'wallet',
  ADD COLUMN IF NOT EXISTS broken_count INT;

ALTER TABLE reconciliation_log ALTER COLUMN currency   DROP NOT NULL;
ALTER TABLE reconciliation_log ALTER COLUMN wallet_sum DROP NOT NULL;
ALTER TABLE reconciliation_log ALTER COLUMN ledger_net DROP NOT NULL;

CREATE INDEX IF NOT EXISTS recon_log_check_type_idx
  ON reconciliation_log (check_type, run_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Rebuild rpc_run_reconciliation with the five integrity checks
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_run_reconciliation()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run_at        TIMESTAMPTZ := NOW();  -- stable within this txn; exact halt-stamp key
  v_ccy           currency;
  v_tolerance     NUMERIC := 0.000001;   -- 1e-6, the 6dp quantization floor
  v_wallet_sum    NUMERIC;
  v_wl_net        NUMERIC;
  v_sys_bal       NUMERIC;
  v_sys_net       NUMERIC;
  v_global        NUMERIC;
  v_delta         NUMERIC;
  v_is_match      BOOLEAN;
  v_any_mismatch  BOOLEAN := FALSE;
  v_wl_broken     INT;
  v_sal_broken    INT;
  v_results       JSONB[] := '{}';
  v_halt_applied  BOOLEAN := FALSE;
BEGIN
  FOR v_ccy IN SELECT unnest(ARRAY['PHON'::currency, 'USDT'::currency, 'KRW'::currency]) LOOP

    -- wallet balances for this currency
    v_wallet_sum := CASE v_ccy
      WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
      WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
      WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    END;

    -- system account balances for this currency
    v_sys_bal := COALESCE((SELECT SUM(balance::NUMERIC) FROM system_accounts WHERE currency = v_ccy), 0);

    -- (1) wallet conservation: balances == wallet_ledger net (credit − debit/reverse;
    --     lock/unlock move between slots so they net 0 on the total → excluded)
    v_wl_net := COALESCE((
      SELECT SUM(CASE
        WHEN direction = 'credit'              THEN  amount::NUMERIC
        WHEN direction IN ('debit', 'reverse') THEN -amount::NUMERIC
        ELSE 0
      END)
      FROM wallet_ledger WHERE currency = v_ccy
    ), 0);
    v_delta := v_wallet_sum - v_wl_net;
    v_is_match := ABS(v_delta) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
    INSERT INTO reconciliation_log (run_at, check_type, currency, wallet_sum, ledger_net, is_match, delta)
      VALUES (v_run_at, 'wallet', v_ccy, _fmt6(v_wallet_sum), _fmt6(v_wl_net), v_is_match, _fmt6(v_delta));
    v_results := v_results || jsonb_build_object('check','wallet','currency',v_ccy,
      'wallet_sum',_fmt6(v_wallet_sum),'ledger_net',_fmt6(v_wl_net),'delta',_fmt6(v_delta),'is_match',v_is_match);

    -- (2) system conservation: balances == system_account_ledger net (A2-3)
    v_sys_net := COALESCE((
      SELECT SUM(CASE WHEN direction = 'credit' THEN amount::NUMERIC ELSE -amount::NUMERIC END)
      FROM system_account_ledger WHERE currency = v_ccy
    ), 0);
    v_delta := v_sys_bal - v_sys_net;
    v_is_match := ABS(v_delta) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
    INSERT INTO reconciliation_log (run_at, check_type, currency, wallet_sum, ledger_net, is_match, delta)
      VALUES (v_run_at, 'system', v_ccy, _fmt6(v_sys_bal), _fmt6(v_sys_net), v_is_match, _fmt6(v_delta));
    v_results := v_results || jsonb_build_object('check','system','currency',v_ccy,
      'balance_sum',_fmt6(v_sys_bal),'ledger_net',_fmt6(v_sys_net),'delta',_fmt6(v_delta),'is_match',v_is_match);

    -- (3) global conservation Σ=0: Σ wallets + Σ system == 0 (A2-3)
    v_global := v_wallet_sum + v_sys_bal;
    v_is_match := ABS(v_global) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
    INSERT INTO reconciliation_log (run_at, check_type, currency, wallet_sum, ledger_net, is_match, delta)
      VALUES (v_run_at, 'global_zero', v_ccy, _fmt6(v_global), '0.000000', v_is_match, _fmt6(v_global));
    v_results := v_results || jsonb_build_object('check','global_zero','currency',v_ccy,
      'sigma',_fmt6(v_global),'is_match',v_is_match);
  END LOOP;

  -- (4) wallet hash-chain integrity (A8-3): detects sum-preserving row tampering
  SELECT count(*) INTO v_wl_broken FROM verify_ledger_hash_chain();
  v_is_match := (v_wl_broken = 0);
  IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
  INSERT INTO reconciliation_log (run_at, check_type, is_match, broken_count, delta)
    VALUES (v_run_at, 'hash_chain_wallet', v_is_match, v_wl_broken, '0.000000');
  v_results := v_results || jsonb_build_object('check','hash_chain_wallet','broken',v_wl_broken,'is_match',v_is_match);

  -- (5) system hash-chain integrity (A8-2 wiring)
  SELECT count(*) INTO v_sal_broken FROM verify_system_account_hash_chain();
  v_is_match := (v_sal_broken = 0);
  IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
  INSERT INTO reconciliation_log (run_at, check_type, is_match, broken_count, delta)
    VALUES (v_run_at, 'hash_chain_system', v_is_match, v_sal_broken, '0.000000');
  v_results := v_results || jsonb_build_object('check','hash_chain_system','broken',v_sal_broken,'is_match',v_is_match);

  -- Apply readonly AFTER all logging; never RAISE (would roll back the log + halt).
  IF v_any_mismatch THEN
    UPDATE app_config SET value = 'true' WHERE key = 'system_readonly';
    UPDATE reconciliation_log SET triggered_halt = TRUE
      WHERE run_at = v_run_at AND is_match = FALSE;
    v_halt_applied := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'mismatch', v_any_mismatch,
    'readonly_set', v_halt_applied,
    'wallet_chain_broken', v_wl_broken,
    'system_chain_broken', v_sal_broken,
    'results', v_results
  );
END;
$$;

-- Preserve the 000026/000010 lockdown: cron/service-role only, never client-facing.
REVOKE ALL ON FUNCTION rpc_run_reconciliation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_run_reconciliation() TO service_role;
