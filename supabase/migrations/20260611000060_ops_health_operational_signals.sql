-- ============================================================
-- Ops health RPC: operational risk signals (hash-chain, exceptions, solvency)
-- ============================================================
-- Extends rpc_get_ops_health() with three lightweight stored-signal checks.
-- Does NOT run verify_ledger_hash_chain() or full reconciliation inline.
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION rpc_get_ops_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_checks JSONB[] := '{}';
  v_status TEXT := 'ok';

  v_halt TEXT;
  v_readonly TEXT;
  v_mode_observed_at TIMESTAMPTZ;
  v_mode_status TEXT;
  v_mode_summary TEXT;
  v_mode_runbook TEXT;

  v_latest_recon_at TIMESTAMPTZ;
  v_last_success_recon_at TIMESTAMPTZ;
  v_recon_latest_failed BOOLEAN := FALSE;
  v_recon_failed_types TEXT;
  v_recon_success_fresh BOOLEAN := FALSE;
  v_recon_status TEXT;
  v_recon_summary TEXT;
  v_recon_runbook TEXT;

  v_liq_cron_last_end TIMESTAMPTZ;
  v_liq_cron_last_status TEXT;
  v_liq_cron_last_success TIMESTAMPTZ;
  v_liq_cron_success_fresh BOOLEAN := FALSE;
  v_liq_cron_status TEXT;
  v_liq_cron_summary TEXT;
  v_liq_cron_runbook TEXT;

  v_liq_error_at TIMESTAMPTZ;
  v_liq_errors INT := 0;
  v_liq_error_recent BOOLEAN := FALSE;
  v_liq_error_summary TEXT;
  v_liq_error_runbook TEXT;

  v_treasury_last_at TIMESTAMPTZ;
  v_treasury_stale BOOLEAN := TRUE;
  v_treasury_stale_currencies TEXT;
  v_treasury_summary TEXT;
  v_treasury_runbook TEXT;

  v_high_risk_count INT := 0;
  v_high_risk_latest_at TIMESTAMPTZ;
  v_high_risk_latest_action TEXT;
  v_high_risk_summary TEXT;

  -- hash_chain_integrity
  v_hc_latest_at TIMESTAMPTZ;
  v_hc_last_success_at TIMESTAMPTZ;
  v_hc_last_error_at TIMESTAMPTZ;
  v_hc_wallet_broken INT := 0;
  v_hc_system_broken INT := 0;
  v_hc_total_broken INT := 0;
  v_hc_latest_damaged BOOLEAN := FALSE;
  v_hc_success_fresh BOOLEAN := FALSE;
  v_hc_status TEXT;
  v_hc_summary TEXT;
  v_hc_runbook TEXT;

  -- pending_exceptions
  v_exc_open INT := 0;
  v_exc_overdue INT := 0;
  v_exc_oldest_open TIMESTAMPTZ;
  v_exc_oldest_overdue_at TIMESTAMPTZ;
  v_exc_status TEXT;
  v_exc_summary TEXT;
  v_exc_runbook TEXT;

  -- treasury_solvency
  v_ccy currency;
  v_tr treasury_reserves%ROWTYPE;
  v_user_total NUMERIC;
  v_real NUMERIC;
  v_max_oblig NUMERIC;
  v_fresh_recon BOOLEAN;
  v_sol_setup TEXT[] := '{}';
  v_sol_breach TEXT[] := '{}';
  v_sol_warning TEXT[] := '{}';
  v_sol_status TEXT;
  v_sol_summary TEXT;
  v_sol_runbook TEXT;
  v_sol_oldest_attest TIMESTAMPTZ;
  v_sol_last_recon TIMESTAMPTZ;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- ─── system_mode ───────────────────────────────────────────────────────────
  SELECT
    MAX(updated_at) FILTER (WHERE key IN ('system_halt', 'system_readonly')),
    MAX(value) FILTER (WHERE key = 'system_halt'),
    MAX(value) FILTER (WHERE key = 'system_readonly')
  INTO v_mode_observed_at, v_halt, v_readonly
  FROM app_config
  WHERE key IN ('system_halt', 'system_readonly');

  IF v_halt = 'true' THEN
    v_mode_status := 'critical';
    v_mode_summary := 'System halt active - changed ' || _ops_relative_age(v_mode_observed_at, v_now);
    v_mode_runbook := 'system_mode_active';
  ELSIF v_readonly = 'true' THEN
    v_mode_status := 'warning';
    v_mode_summary := 'System read-only active - changed ' || _ops_relative_age(v_mode_observed_at, v_now);
    v_mode_runbook := 'system_mode_active';
  ELSE
    v_mode_status := 'ok';
    v_mode_summary := 'System mode normal - checked ' || _ops_relative_age(v_mode_observed_at, v_now);
    v_mode_runbook := 'system_mode_normal';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'system_mode',
    'status', v_mode_status,
    'summary', v_mode_summary,
    'observedAt', v_mode_observed_at,
    'runbookKey', v_mode_runbook
  );

  -- ─── reconciliation_latest (fresh success <= 2 hours) ────────────────────────
  SELECT MAX(run_at) INTO v_latest_recon_at FROM reconciliation_log;

  SELECT MAX(s.run_at)
    INTO v_last_success_recon_at
  FROM (
    SELECT run_at
    FROM reconciliation_log
    GROUP BY run_at
    HAVING BOOL_AND(is_match) AND NOT COALESCE(BOOL_OR(triggered_halt), FALSE)
  ) s;

  v_recon_success_fresh := v_last_success_recon_at IS NOT NULL
    AND v_last_success_recon_at >= v_now - INTERVAL '2 hours';

  IF v_latest_recon_at IS NULL THEN
    v_recon_status := 'warning';
    v_recon_summary := 'No reconciliation recorded yet.';
    v_recon_runbook := 'reconciliation_missing';
  ELSE
    SELECT
      EXISTS (
        SELECT 1
        FROM reconciliation_log
        WHERE run_at = v_latest_recon_at
          AND (is_match = FALSE OR triggered_halt = TRUE)
      ),
      string_agg(check_type, ', ' ORDER BY check_type)
    INTO v_recon_latest_failed, v_recon_failed_types
    FROM reconciliation_log
    WHERE run_at = v_latest_recon_at
      AND (is_match = FALSE OR triggered_halt = TRUE);

    IF v_recon_latest_failed AND NOT v_recon_success_fresh THEN
      v_recon_status := 'critical';
      v_recon_summary := 'Reconciliation failed (' || COALESCE(v_recon_failed_types, 'unknown check') || ')'
        || CASE
          WHEN v_last_success_recon_at IS NULL THEN ' - no prior success recorded'
          ELSE ' - last success ' || _ops_relative_age(v_last_success_recon_at, v_now)
        END;
      v_recon_runbook := 'reconciliation_mismatch';
    ELSIF v_recon_latest_failed AND v_recon_success_fresh THEN
      v_recon_status := 'warning';
      v_recon_summary := 'Reconciliation failed (' || COALESCE(v_recon_failed_types, 'unknown check') || ')'
        || ' - last success ' || _ops_relative_age(v_last_success_recon_at, v_now);
      v_recon_runbook := 'reconciliation_mismatch';
    ELSIF NOT v_recon_success_fresh THEN
      v_recon_status := 'warning';
      v_recon_summary := 'Reconciliation stale - last success '
        || CASE
          WHEN v_last_success_recon_at IS NULL THEN 'never recorded'
          ELSE _ops_relative_age(v_last_success_recon_at, v_now)
        END;
      v_recon_runbook := 'reconciliation_missing';
    ELSE
      v_recon_status := 'ok';
      v_recon_summary := 'Reconciliation clean - last run ' || _ops_relative_age(v_latest_recon_at, v_now);
      v_recon_runbook := 'reconciliation_clean';
    END IF;
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'reconciliation_latest',
    'status', v_recon_status,
    'summary', v_recon_summary,
    'observedAt', v_latest_recon_at,
    'lastRunAt', v_latest_recon_at,
    'lastSuccessfulAt', v_last_success_recon_at,
    'runbookKey', v_recon_runbook
  );

  -- ─── cron_liquidation_liveness (fresh success <= 30 minutes) ─────────────────
  SELECT d.end_time, d.status
    INTO v_liq_cron_last_end, v_liq_cron_last_status
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'phonara_auto_liquidations'
  ORDER BY d.end_time DESC NULLS LAST, d.start_time DESC NULLS LAST
  LIMIT 1;

  SELECT d.end_time
    INTO v_liq_cron_last_success
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'phonara_auto_liquidations'
    AND d.status = 'succeeded'
  ORDER BY d.end_time DESC NULLS LAST, d.start_time DESC NULLS LAST
  LIMIT 1;

  v_liq_cron_success_fresh := v_liq_cron_last_success IS NOT NULL
    AND v_liq_cron_last_success >= v_now - INTERVAL '30 minutes';

  IF NOT v_liq_cron_success_fresh THEN
    v_liq_cron_status := 'critical';
    v_liq_cron_summary := 'Auto-liquidation cron stale - no success for '
      || CASE
        WHEN v_liq_cron_last_success IS NULL THEN 'never recorded'
        ELSE _ops_relative_age(v_liq_cron_last_success, v_now)
      END;
    v_liq_cron_runbook := 'cron_liquidation_stale';
  ELSIF COALESCE(v_liq_cron_last_status, '') <> 'succeeded' THEN
    v_liq_cron_status := 'warning';
    v_liq_cron_summary := 'Auto-liquidation cron failed last run - last success '
      || _ops_relative_age(v_liq_cron_last_success, v_now);
    v_liq_cron_runbook := 'cron_liquidation_stale';
  ELSE
    v_liq_cron_status := 'ok';
    v_liq_cron_summary := 'Auto-liquidation cron healthy - last success '
      || _ops_relative_age(v_liq_cron_last_success, v_now);
    v_liq_cron_runbook := 'cron_liquidation_ok';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'cron_liquidation_liveness',
    'status', v_liq_cron_status,
    'summary', v_liq_cron_summary,
    'observedAt', v_liq_cron_last_success,
    'lastRunAt', v_liq_cron_last_end,
    'lastSuccessfulAt', v_liq_cron_last_success,
    'runbookKey', v_liq_cron_runbook
  );

  -- ─── liquidation_recent_error (24 hour window) ───────────────────────────────
  SELECT ran_at, errors
    INTO v_liq_error_at, v_liq_errors
  FROM liquidation_run_log
  WHERE errors > 0
  ORDER BY ran_at DESC
  LIMIT 1;

  v_liq_error_recent := COALESCE(v_liq_errors, 0) > 0
    AND v_liq_error_at >= v_now - INTERVAL '24 hours';

  IF v_liq_error_recent THEN
    v_liq_error_summary := 'Auto-liquidation errors recorded '
      || _ops_relative_age(v_liq_error_at, v_now)
      || ' (' || v_liq_errors::TEXT || ' error'
      || CASE WHEN v_liq_errors = 1 THEN '' ELSE 's' END || ')';
    v_liq_error_runbook := 'liquidation_recent_error';
  ELSE
    v_liq_error_summary := 'No liquidation errors in the last 24 hours';
    v_liq_error_runbook := 'liquidation_no_recent_error';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'liquidation_recent_error',
    'status', CASE WHEN v_liq_error_recent THEN 'warning' ELSE 'ok' END,
    'summary', v_liq_error_summary,
    'observedAt', v_liq_error_at,
    'lastErrorAt', v_liq_error_at,
    'runbookKey', v_liq_error_runbook
  );

  -- ─── treasury_freshness (24 hour window) ──────────────────────────────────────
  SELECT MIN(updated_at) INTO v_treasury_last_at FROM treasury_reserves;
  v_treasury_stale := v_treasury_last_at IS NULL OR v_treasury_last_at < v_now - INTERVAL '24 hours';

  SELECT string_agg(currency::TEXT, ', ' ORDER BY currency)
    INTO v_treasury_stale_currencies
  FROM treasury_reserves
  WHERE updated_at IS NULL OR updated_at < v_now - INTERVAL '24 hours';

  IF v_treasury_stale THEN
    v_treasury_summary := 'Treasury attestation stale'
      || CASE
        WHEN v_treasury_stale_currencies IS NOT NULL THEN ' (' || v_treasury_stale_currencies || ')'
        ELSE ''
      END
      || ' - oldest update '
      || CASE
        WHEN v_treasury_last_at IS NULL THEN 'never recorded'
        ELSE _ops_relative_age(v_treasury_last_at, v_now)
      END;
    v_treasury_runbook := 'treasury_stale';
  ELSE
    v_treasury_summary := 'Treasury attestations fresh - oldest update '
      || _ops_relative_age(v_treasury_last_at, v_now);
    v_treasury_runbook := 'treasury_recent';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'treasury_freshness',
    'status', CASE WHEN v_treasury_stale THEN 'warning' ELSE 'ok' END,
    'summary', v_treasury_summary,
    'observedAt', v_treasury_last_at,
    'runbookKey', v_treasury_runbook
  );

  -- ─── operator_high_risk_actions (24 hour window) ─────────────────────────────
  WITH recent_high_risk AS (
    SELECT action, created_at
    FROM audit_logs
    WHERE action IN (
      'system_mode_set',
      'feature_toggle',
      'treasury_reserve_update',
      'market_limits_set',
      'withdrawal_approved',
      'withdrawal_rejected',
      'withdrawal_sent',
      'str_case_status_update',
      'risk_flag_cleared',
      'casino_bet_voided'
    )
      AND created_at >= v_now - INTERVAL '24 hours'
    ORDER BY created_at DESC
    LIMIT 5
  )
  SELECT
    COUNT(*)::INT,
    MAX(created_at),
    (SELECT action FROM recent_high_risk ORDER BY created_at DESC LIMIT 1)
  INTO v_high_risk_count, v_high_risk_latest_at, v_high_risk_latest_action
  FROM recent_high_risk;

  IF v_high_risk_count > 0 THEN
    v_high_risk_summary := v_high_risk_count::TEXT || ' high-risk operator action'
      || CASE WHEN v_high_risk_count = 1 THEN '' ELSE 's' END
      || ' in the last 24 hours - latest ' || v_high_risk_latest_action;
  ELSE
    v_high_risk_summary := 'No high-risk operator actions in the last 24 hours';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'operator_high_risk_actions',
    'status', 'ok',
    'summary', v_high_risk_summary,
    'observedAt', v_high_risk_latest_at,
    'runbookKey', 'operator_actions_review'
  );

  -- ─── hash_chain_integrity (stored reconciliation_log only) ───────────────────
  SELECT MAX(run_at)
    INTO v_hc_latest_at
  FROM reconciliation_log
  WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system');

  SELECT MAX(s.run_at)
    INTO v_hc_last_success_at
  FROM (
    SELECT run_at
    FROM reconciliation_log
    WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system')
    GROUP BY run_at
    HAVING BOOL_AND(is_match) AND BOOL_AND(COALESCE(broken_count, 0) = 0)
  ) s;

  SELECT MAX(run_at)
    INTO v_hc_last_error_at
  FROM reconciliation_log
  WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system')
    AND (is_match = FALSE OR COALESCE(broken_count, 0) > 0);

  IF v_hc_latest_at IS NULL THEN
    v_hc_status := 'warning';
    v_hc_summary := 'No hash-chain reconciliation recorded yet.';
    v_hc_runbook := 'hash_chain_missing';
  ELSE
    SELECT
      COALESCE(MAX(broken_count) FILTER (WHERE check_type = 'hash_chain_wallet'), 0),
      COALESCE(MAX(broken_count) FILTER (WHERE check_type = 'hash_chain_system'), 0),
      BOOL_OR(NOT is_match OR COALESCE(broken_count, 0) > 0)
    INTO v_hc_wallet_broken, v_hc_system_broken, v_hc_latest_damaged
    FROM reconciliation_log
    WHERE run_at = v_hc_latest_at
      AND check_type IN ('hash_chain_wallet', 'hash_chain_system');

    v_hc_total_broken := v_hc_wallet_broken + v_hc_system_broken;
    v_hc_success_fresh := v_hc_last_success_at IS NOT NULL
      AND v_hc_last_success_at >= v_now - INTERVAL '24 hours';

    IF v_hc_latest_damaged OR v_hc_total_broken > 0 THEN
      v_hc_status := 'critical';
      v_hc_summary := 'Hash-chain damage detected (wallet: ' || v_hc_wallet_broken::TEXT
        || ', system: ' || v_hc_system_broken::TEXT || ') - immediate action required';
      v_hc_runbook := 'hash_chain_damage';
    ELSIF NOT v_hc_success_fresh THEN
      v_hc_status := 'warning';
      v_hc_summary := 'Hash-chain check stale - last success '
        || CASE
          WHEN v_hc_last_success_at IS NULL THEN 'never recorded'
          ELSE _ops_relative_age(v_hc_last_success_at, v_now)
        END;
      v_hc_runbook := 'hash_chain_stale';
    ELSE
      v_hc_status := 'ok';
      v_hc_summary := 'Hash-chain integrity clean - last run '
        || _ops_relative_age(v_hc_latest_at, v_now);
      v_hc_runbook := 'hash_chain_clean';
    END IF;
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'hash_chain_integrity',
    'status', v_hc_status,
    'summary', v_hc_summary,
    'observedAt', v_hc_latest_at,
    'lastRunAt', v_hc_latest_at,
    'lastSuccessfulAt', v_hc_last_success_at,
    'lastErrorAt', v_hc_last_error_at,
    'runbookKey', v_hc_runbook
  );

  -- ─── pending_exceptions ──────────────────────────────────────────────────────
  SELECT
    COUNT(*)::INT,
    COUNT(*) FILTER (WHERE sla_due_at < v_now)::INT,
    MIN(created_at),
    MIN(sla_due_at) FILTER (WHERE sla_due_at < v_now)
  INTO v_exc_open, v_exc_overdue, v_exc_oldest_open, v_exc_oldest_overdue_at
  FROM admin_review_queue
  WHERE status IN ('pending', 'in_review');

  IF v_exc_open = 0 THEN
    v_exc_status := 'ok';
    v_exc_summary := 'No pending exceptions in the queue';
    v_exc_runbook := 'exceptions_clear';
  ELSE
    IF v_exc_open >= 5
       OR v_exc_overdue >= 3
       OR (v_exc_overdue > 0 AND v_exc_oldest_overdue_at < v_now - INTERVAL '24 hours') THEN
      v_exc_status := 'critical';
      v_exc_runbook := 'exceptions_critical';
    ELSE
      v_exc_status := 'warning';
      v_exc_runbook := 'exceptions_review';
    END IF;

    v_exc_summary := v_exc_open::TEXT || ' pending exception'
      || CASE WHEN v_exc_open = 1 THEN '' ELSE 's' END
      || ' require review';
    IF v_exc_overdue > 0 THEN
      v_exc_summary := v_exc_summary || ' (' || v_exc_overdue::TEXT || ' overdue)';
    END IF;
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'pending_exceptions',
    'status', v_exc_status,
    'summary', v_exc_summary,
    'observedAt', v_exc_oldest_open,
    'lastRunAt', v_exc_oldest_open,
    'lastErrorAt', v_exc_oldest_overdue_at,
    'runbookKey', v_exc_runbook
  );

  -- ─── treasury_solvency (gate-aligned, no inline amounts) ─────────────────────
  SELECT MIN(updated_at) INTO v_sol_oldest_attest FROM treasury_reserves;

  SELECT MAX(run_at)
    INTO v_sol_last_recon
  FROM reconciliation_log
  WHERE is_match = TRUE
    AND check_type IN ('wallet', 'system', 'global_zero')
    AND run_at >= v_now - INTERVAL '24 hours';

  FOR v_ccy IN SELECT unnest(ARRAY['PHON'::currency, 'USDT'::currency, 'KRW'::currency]) LOOP
    SELECT * INTO v_tr FROM treasury_reserves WHERE currency = v_ccy;
    IF NOT FOUND OR v_tr.real_balance::NUMERIC <= 0 THEN
      v_sol_setup := array_append(v_sol_setup, v_ccy::TEXT);
      CONTINUE;
    END IF;

    v_real := v_tr.real_balance::NUMERIC;

    SELECT EXISTS (
      SELECT 1 FROM reconciliation_log
       WHERE currency = v_ccy
         AND is_match = TRUE
         AND run_at >= v_now - INTERVAL '24 hours'
    ) INTO v_fresh_recon;

    IF NOT v_fresh_recon THEN
      v_sol_warning := array_append(v_sol_warning, v_ccy::TEXT);
    END IF;

    v_user_total := CASE v_ccy
      WHEN 'PHON' THEN COALESCE((SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets), 0)
      WHEN 'USDT' THEN COALESCE((SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets), 0)
      WHEN 'KRW'  THEN COALESCE((SELECT SUM(krw_available::NUMERIC  + krw_locked::NUMERIC)  FROM wallets), 0)
    END;

    v_max_oblig := v_real * (1.0 - v_tr.buffer_pct / 100.0);

    IF v_user_total > v_max_oblig THEN
      v_sol_breach := array_append(v_sol_breach, v_ccy::TEXT);
    END IF;
  END LOOP;

  v_sol_setup := ARRAY(SELECT DISTINCT unnest(v_sol_setup) ORDER BY 1);
  v_sol_breach := ARRAY(SELECT DISTINCT unnest(v_sol_breach) ORDER BY 1);
  v_sol_warning := ARRAY(
    SELECT DISTINCT w
    FROM unnest(v_sol_warning) w
    WHERE NOT (w = ANY (v_sol_setup)) AND NOT (w = ANY (v_sol_breach))
    ORDER BY 1
  );

  IF array_length(v_sol_setup, 1) > 0 OR array_length(v_sol_breach, 1) > 0 THEN
    v_sol_status := 'critical';
    IF array_length(v_sol_breach, 1) > 0 AND array_length(v_sol_setup, 1) > 0 THEN
      v_sol_summary := 'Treasury solvency needs review ('
        || array_to_string(v_sol_setup || v_sol_breach, ', ') || ')';
      v_sol_runbook := 'treasury_solvency_breach';
    ELSIF array_length(v_sol_breach, 1) > 0 THEN
      v_sol_summary := 'Treasury coverage needs review ('
        || array_to_string(v_sol_breach, ', ') || ')';
      v_sol_runbook := 'treasury_solvency_breach';
    ELSE
      v_sol_summary := 'Treasury reserve needs setup ('
        || array_to_string(v_sol_setup, ', ') || ')';
      v_sol_runbook := 'treasury_solvency_setup';
    END IF;
  ELSIF array_length(v_sol_warning, 1) > 0 THEN
    v_sol_status := 'warning';
    v_sol_summary := 'Treasury solvency review needed - stale reconciliation ('
      || array_to_string(v_sol_warning, ', ') || ')';
    v_sol_runbook := 'treasury_solvency_stale_recon';
  ELSE
    v_sol_status := 'ok';
    v_sol_summary := 'Treasury solvency healthy across all currencies';
    v_sol_runbook := 'treasury_solvency_ok';
  END IF;

  v_checks := v_checks || jsonb_build_object(
    'id', 'treasury_solvency',
    'status', v_sol_status,
    'summary', v_sol_summary,
    'observedAt', v_sol_oldest_attest,
    'lastSuccessfulAt', v_sol_last_recon,
    'runbookKey', v_sol_runbook
  );

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(to_jsonb(v_checks)) c WHERE c->>'status' = 'critical') THEN 'critical'
    WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(to_jsonb(v_checks)) c WHERE c->>'status' = 'warning') THEN 'warning'
    ELSE 'ok'
  END INTO v_status;

  RETURN jsonb_build_object(
    'status', v_status,
    'lastUpdatedAt', v_now,
    'checks', to_jsonb(v_checks)
  );
END;
$$;

REVOKE ALL ON FUNCTION rpc_get_ops_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_get_ops_health() TO authenticated, service_role;
