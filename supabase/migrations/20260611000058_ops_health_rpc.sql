-- ============================================================
-- Observability foundation: admin ops health snapshot
-- ============================================================
-- Purpose: provide one fast admin-only read of existing operational signals.
-- This function does NOT run reconciliation, hash-chain verification, or any
-- heavy checks. It only reads the latest stored results.
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
  v_latest_recon_at TIMESTAMPTZ;
  v_recon_failed BOOLEAN := FALSE;
  v_recon_failed_types TEXT;
  v_liq_cron_last_end TIMESTAMPTZ;
  v_liq_cron_status TEXT;
  v_liq_cron_stale BOOLEAN := TRUE;
  v_liq_error_at TIMESTAMPTZ;
  v_liq_errors INT := 0;
  v_treasury_last_at TIMESTAMPTZ;
  v_treasury_stale BOOLEAN := TRUE;
  v_high_risk_count INT := 0;
  v_high_risk_latest_at TIMESTAMPTZ;
  v_high_risk_actions TEXT;
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT
    MAX(updated_at) FILTER (WHERE key IN ('system_halt', 'system_readonly')),
    MAX(value) FILTER (WHERE key = 'system_halt'),
    MAX(value) FILTER (WHERE key = 'system_readonly')
  INTO v_mode_observed_at, v_halt, v_readonly
  FROM app_config
  WHERE key IN ('system_halt', 'system_readonly');

  v_checks := v_checks || jsonb_build_object(
    'id', 'system_mode',
    'status', CASE WHEN v_halt = 'true' THEN 'critical' WHEN v_readonly = 'true' THEN 'warning' ELSE 'ok' END,
    'summary', CASE
      WHEN v_halt = 'true' THEN 'System halt is active.'
      WHEN v_readonly = 'true' THEN 'System read-only mode is active.'
      ELSE 'System mode is normal.'
    END,
    'observedAt', v_mode_observed_at,
    'runbookKey', CASE WHEN v_halt = 'true' OR v_readonly = 'true' THEN 'system_mode_active' ELSE 'system_mode_normal' END
  );

  SELECT MAX(run_at) INTO v_latest_recon_at FROM reconciliation_log;

  IF v_latest_recon_at IS NULL THEN
    v_checks := v_checks || jsonb_build_object(
      'id', 'reconciliation_latest',
      'status', 'warning',
      'summary', 'No reconciliation result has been recorded yet.',
      'observedAt', NULL,
      'runbookKey', 'reconciliation_missing'
    );
  ELSE
    SELECT
      EXISTS (
        SELECT 1
        FROM reconciliation_log
        WHERE run_at = v_latest_recon_at
          AND (is_match = FALSE OR triggered_halt = TRUE)
      ),
      string_agg(check_type, ', ' ORDER BY check_type)
    INTO v_recon_failed, v_recon_failed_types
    FROM reconciliation_log
    WHERE run_at = v_latest_recon_at
      AND (is_match = FALSE OR triggered_halt = TRUE);

    v_checks := v_checks || jsonb_build_object(
      'id', 'reconciliation_latest',
      'status', CASE WHEN v_recon_failed THEN 'critical' ELSE 'ok' END,
      'summary', CASE
        WHEN v_recon_failed THEN 'Latest reconciliation failed: ' || COALESCE(v_recon_failed_types, 'unknown check')
        ELSE 'Latest reconciliation is clean.'
      END,
      'observedAt', v_latest_recon_at,
      'runbookKey', CASE WHEN v_recon_failed THEN 'reconciliation_mismatch' ELSE 'reconciliation_clean' END
    );
  END IF;

  SELECT end_time, status
    INTO v_liq_cron_last_end, v_liq_cron_status
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'phonara_auto_liquidations'
  ORDER BY d.end_time DESC NULLS LAST, d.start_time DESC NULLS LAST
  LIMIT 1;

  v_liq_cron_stale := v_liq_cron_last_end IS NULL OR v_liq_cron_last_end < v_now - INTERVAL '5 minutes';

  v_checks := v_checks || jsonb_build_object(
    'id', 'cron_liquidation_liveness',
    'status', CASE
      WHEN v_liq_cron_stale THEN 'critical'
      WHEN COALESCE(v_liq_cron_status, '') <> 'succeeded' THEN 'warning'
      ELSE 'ok'
    END,
    'summary', CASE
      WHEN v_liq_cron_stale THEN 'Auto-liquidation cron has no recent successful run.'
      WHEN COALESCE(v_liq_cron_status, '') <> 'succeeded' THEN 'Auto-liquidation cron last run was not successful.'
      ELSE 'Auto-liquidation cron is recent.'
    END,
    'observedAt', v_liq_cron_last_end,
    'runbookKey', CASE
      WHEN v_liq_cron_stale OR COALESCE(v_liq_cron_status, '') <> 'succeeded' THEN 'cron_liquidation_stale'
      ELSE 'cron_liquidation_ok'
    END
  );

  SELECT ran_at, errors
    INTO v_liq_error_at, v_liq_errors
  FROM liquidation_run_log
  WHERE errors > 0
  ORDER BY ran_at DESC
  LIMIT 1;

  v_checks := v_checks || jsonb_build_object(
    'id', 'liquidation_recent_error',
    'status', CASE WHEN COALESCE(v_liq_errors, 0) > 0 AND v_liq_error_at >= v_now - INTERVAL '24 hours' THEN 'warning' ELSE 'ok' END,
    'summary', CASE
      WHEN COALESCE(v_liq_errors, 0) > 0 AND v_liq_error_at >= v_now - INTERVAL '24 hours' THEN 'Recent auto-liquidation sweep recorded errors.'
      ELSE 'No recent auto-liquidation errors recorded.'
    END,
    'observedAt', v_liq_error_at,
    'runbookKey', CASE
      WHEN COALESCE(v_liq_errors, 0) > 0 AND v_liq_error_at >= v_now - INTERVAL '24 hours' THEN 'liquidation_recent_error'
      ELSE 'liquidation_no_recent_error'
    END
  );

  SELECT MIN(updated_at) INTO v_treasury_last_at FROM treasury_reserves;
  v_treasury_stale := v_treasury_last_at IS NULL OR v_treasury_last_at < v_now - INTERVAL '24 hours';

  v_checks := v_checks || jsonb_build_object(
    'id', 'treasury_freshness',
    'status', CASE WHEN v_treasury_stale THEN 'warning' ELSE 'ok' END,
    'summary', CASE
      WHEN v_treasury_stale THEN 'Treasury reserve attestation is stale or missing.'
      ELSE 'Treasury reserve attestation is recent.'
    END,
    'observedAt', v_treasury_last_at,
    'runbookKey', CASE WHEN v_treasury_stale THEN 'treasury_stale' ELSE 'treasury_recent' END
  );

  WITH recent_high_risk AS (
    SELECT action, entity_type, created_at
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
    ORDER BY created_at DESC
    LIMIT 5
  )
  SELECT
    COUNT(*)::INT,
    MAX(created_at),
    string_agg(action || COALESCE(':' || entity_type, ''), ', ' ORDER BY created_at DESC)
  INTO v_high_risk_count, v_high_risk_latest_at, v_high_risk_actions
  FROM recent_high_risk;

  v_checks := v_checks || jsonb_build_object(
    'id', 'operator_high_risk_actions',
    'status', 'ok',
    'summary', CASE
      WHEN v_high_risk_count > 0 THEN 'Recent high-risk operator actions: ' || v_high_risk_actions
      ELSE 'No recent high-risk operator actions.'
    END,
    'observedAt', v_high_risk_latest_at,
    'runbookKey', 'operator_actions_review'
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
