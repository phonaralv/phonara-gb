-- ============================================================
-- Reconciliation internal refactor — extract log + halt helpers
-- ============================================================
-- Behaviour unchanged: single-transaction 5-check rpc_run_reconciliation.
-- Extracts INSERT boilerplate and halt stamping only (no check split).
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _recon_log_row(
  p_run_at       TIMESTAMPTZ,
  p_check_type   TEXT,
  p_is_match     BOOLEAN,
  p_currency     currency DEFAULT NULL,
  p_wallet_sum   TEXT DEFAULT NULL,
  p_ledger_net   TEXT DEFAULT NULL,
  p_delta        TEXT DEFAULT '0.000000',
  p_broken_count INT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO reconciliation_log (
    run_at, check_type, currency, wallet_sum, ledger_net, is_match, delta, broken_count
  ) VALUES (
    p_run_at, p_check_type, p_currency, p_wallet_sum, p_ledger_net, p_is_match, p_delta, p_broken_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION _recon_apply_halt(p_run_at TIMESTAMPTZ)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE app_config SET value = 'true' WHERE key = 'system_readonly';
  UPDATE reconciliation_log SET triggered_halt = TRUE
    WHERE run_at = p_run_at AND is_match = FALSE;
END;
$$;

REVOKE ALL ON FUNCTION _recon_log_row(TIMESTAMPTZ, TEXT, BOOLEAN, currency, TEXT, TEXT, TEXT, INT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _recon_apply_halt(TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION rpc_run_reconciliation()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run_at        TIMESTAMPTZ := NOW();
  v_ccy           currency;
  v_tolerance     NUMERIC := 0.000001;
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
    v_wallet_sum := CASE v_ccy
      WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
      WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
      WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    END;

    v_sys_bal := COALESCE((SELECT SUM(balance::NUMERIC) FROM system_accounts WHERE currency = v_ccy), 0);

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
    PERFORM _recon_log_row(v_run_at, 'wallet', v_is_match, v_ccy, _fmt6(v_wallet_sum), _fmt6(v_wl_net), _fmt6(v_delta));
    v_results := v_results || jsonb_build_object('check','wallet','currency',v_ccy,
      'wallet_sum',_fmt6(v_wallet_sum),'ledger_net',_fmt6(v_wl_net),'delta',_fmt6(v_delta),'is_match',v_is_match);

    v_sys_net := COALESCE((
      SELECT SUM(CASE WHEN direction = 'credit' THEN amount::NUMERIC ELSE -amount::NUMERIC END)
      FROM system_account_ledger WHERE currency = v_ccy
    ), 0);
    v_delta := v_sys_bal - v_sys_net;
    v_is_match := ABS(v_delta) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
    PERFORM _recon_log_row(v_run_at, 'system', v_is_match, v_ccy, _fmt6(v_sys_bal), _fmt6(v_sys_net), _fmt6(v_delta));
    v_results := v_results || jsonb_build_object('check','system','currency',v_ccy,
      'balance_sum',_fmt6(v_sys_bal),'ledger_net',_fmt6(v_sys_net),'delta',_fmt6(v_delta),'is_match',v_is_match);

    v_global := v_wallet_sum + v_sys_bal;
    v_is_match := ABS(v_global) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
    PERFORM _recon_log_row(v_run_at, 'global_zero', v_is_match, v_ccy, _fmt6(v_global), '0.000000', _fmt6(v_global));
    v_results := v_results || jsonb_build_object('check','global_zero','currency',v_ccy,
      'sigma',_fmt6(v_global),'is_match',v_is_match);
  END LOOP;

  SELECT count(*) INTO v_wl_broken FROM verify_ledger_hash_chain();
  v_is_match := (v_wl_broken = 0);
  IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
  PERFORM _recon_log_row(v_run_at, 'hash_chain_wallet', v_is_match, NULL, NULL, NULL, '0.000000', v_wl_broken);
  v_results := v_results || jsonb_build_object('check','hash_chain_wallet','broken',v_wl_broken,'is_match',v_is_match);

  SELECT count(*) INTO v_sal_broken FROM verify_system_account_hash_chain();
  v_is_match := (v_sal_broken = 0);
  IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
  PERFORM _recon_log_row(v_run_at, 'hash_chain_system', v_is_match, NULL, NULL, NULL, '0.000000', v_sal_broken);
  v_results := v_results || jsonb_build_object('check','hash_chain_system','broken',v_sal_broken,'is_match',v_is_match);

  IF v_any_mismatch THEN
    PERFORM _recon_apply_halt(v_run_at);
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

REVOKE ALL ON FUNCTION rpc_run_reconciliation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_run_reconciliation() TO service_role;
