-- ============================================================
-- Ops Alert Queue + Ack: persistent inbox materialized from ops health
-- ============================================================
-- Extracts _ops_build_health_snapshot() from rpc_get_ops_health() without
-- changing the public RPC response shape. Adds ops_alerts lifecycle + ack.
-- ============================================================

SET search_path = public, pg_temp;

-- ─── ops_alerts table ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ops_alerts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dedupe_key       TEXT NOT NULL,
  source_check_id  TEXT NOT NULL,
  severity         TEXT NOT NULL CHECK (severity IN ('warning', 'critical')),
  status           TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved')),
  summary          TEXT NOT NULL,
  runbook_key      TEXT NOT NULL,
  first_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  occurrence_count INT NOT NULL DEFAULT 1 CHECK (occurrence_count >= 1),
  acknowledged_at  TIMESTAMPTZ,
  acknowledged_by  UUID REFERENCES profiles(id),
  ack_reason       TEXT,
  resolved_at      TIMESTAMPTZ,
  resolved_by      UUID REFERENCES profiles(id),
  resolve_reason   TEXT,
  metadata         JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ops_alerts_dedupe_active_uidx
  ON ops_alerts (dedupe_key)
  WHERE status IN ('open', 'acknowledged');

CREATE INDEX IF NOT EXISTS ops_alerts_active_list_idx
  ON ops_alerts (severity DESC, last_seen_at DESC)
  WHERE status IN ('open', 'acknowledged');

CREATE INDEX IF NOT EXISTS ops_alerts_resolved_at_idx
  ON ops_alerts (resolved_at DESC)
  WHERE status = 'resolved';

ALTER TABLE ops_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ops_alerts: admin read" ON ops_alerts;
CREATE POLICY "ops_alerts: admin read"
  ON ops_alerts FOR SELECT
  USING (_is_admin());

REVOKE ALL ON TABLE ops_alerts FROM PUBLIC, anon;
GRANT SELECT ON TABLE ops_alerts TO authenticated;

-- ─── Internal health snapshot (no auth guard) ────────────────────────────────
CREATE OR REPLACE FUNCTION _ops_build_health_snapshot()
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

  v_exc_open INT := 0;
  v_exc_overdue INT := 0;
  v_exc_oldest_open TIMESTAMPTZ;
  v_exc_oldest_overdue_at TIMESTAMPTZ;
  v_exc_status TEXT;
  v_exc_summary TEXT;
  v_exc_runbook TEXT;

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

REVOKE ALL ON FUNCTION _ops_build_health_snapshot() FROM PUBLIC, anon, authenticated;

-- ─── Public health RPC wrapper (unchanged auth + response shape) ───────────────
CREATE OR REPLACE FUNCTION rpc_get_ops_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT _is_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN _ops_build_health_snapshot();
END;
$$;

REVOKE ALL ON FUNCTION rpc_get_ops_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_get_ops_health() TO authenticated, service_role;

-- ─── Materialize alerts from health snapshot ─────────────────────────────────
CREATE OR REPLACE FUNCTION _sync_ops_alerts_from_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_snapshot JSONB;
  v_check JSONB;
  v_dedupe_key TEXT;
  v_check_id TEXT;
  v_check_status TEXT;
  v_severity TEXT;
  v_alert ops_alerts%ROWTYPE;
  v_now TIMESTAMPTZ := NOW();
  v_opened INT := 0;
  v_updated INT := 0;
  v_resolved INT := 0;
  v_metadata JSONB;
BEGIN
  v_snapshot := _ops_build_health_snapshot();

  FOR v_check IN SELECT value FROM jsonb_array_elements(v_snapshot->'checks')
  LOOP
    v_check_id := v_check->>'id';
    v_check_status := v_check->>'status';
    v_dedupe_key := v_check_id;
    v_metadata := v_check - 'id' - 'status' - 'summary' - 'runbookKey';

    IF v_check_status IN ('warning', 'critical') THEN
      v_severity := v_check_status;

      SELECT * INTO v_alert
      FROM ops_alerts
      WHERE dedupe_key = v_dedupe_key
        AND status IN ('open', 'acknowledged')
      FOR UPDATE;

      IF FOUND THEN
        UPDATE ops_alerts
           SET severity = v_severity,
               summary = v_check->>'summary',
               runbook_key = COALESCE(v_check->>'runbookKey', runbook_key),
               last_seen_at = v_now,
               occurrence_count = occurrence_count + 1,
               metadata = v_metadata,
               updated_at = v_now
         WHERE id = v_alert.id;
        v_updated := v_updated + 1;
      ELSE
        INSERT INTO ops_alerts (
          dedupe_key, source_check_id, severity, status,
          summary, runbook_key, first_seen_at, last_seen_at,
          occurrence_count, metadata
        ) VALUES (
          v_dedupe_key,
          v_check_id,
          v_severity,
          'open',
          v_check->>'summary',
          COALESCE(v_check->>'runbookKey', 'unknown'),
          v_now,
          v_now,
          1,
          v_metadata
        );
        v_opened := v_opened + 1;
      END IF;
    ELSIF v_check_status = 'ok' THEN
      FOR v_alert IN
        SELECT *
        FROM ops_alerts
        WHERE dedupe_key = v_dedupe_key
          AND status IN ('open', 'acknowledged')
        FOR UPDATE
      LOOP
        UPDATE ops_alerts
           SET status = 'resolved',
               resolved_at = v_now,
               resolve_reason = 'auto_resolved',
               updated_at = v_now
         WHERE id = v_alert.id;

        INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
        VALUES (
          NULL,
          'ops_alert_auto_resolved',
          'ops_alert',
          v_alert.id,
          jsonb_build_object(
            'source_check_id', v_check_id,
            'dedupe_key', v_dedupe_key,
            'previous_status', v_alert.status
          )
        );

        v_resolved := v_resolved + 1;
      END LOOP;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'opened', v_opened,
    'updated', v_updated,
    'resolved', v_resolved,
    'syncedAt', v_now
  );
END;
$$;

REVOKE ALL ON FUNCTION _sync_ops_alerts_from_health() FROM PUBLIC, anon, authenticated;

-- ─── Admin RPCs ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_sync_ops_alerts_from_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;

  RETURN _sync_ops_alerts_from_health();
END;
$$;

CREATE OR REPLACE FUNCTION rpc_get_ops_alerts(
  p_statuses TEXT[] DEFAULT NULL,
  p_resolved_days INT DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;

  IF p_resolved_days IS NULL OR p_resolved_days < 0 THEN
    RAISE EXCEPTION 'invalid_resolved_days';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(a)::JSONB ORDER BY
    CASE a.severity WHEN 'critical' THEN 0 ELSE 1 END,
    a.last_seen_at DESC
  ), '[]'::JSONB)
  INTO v_rows
  FROM (
    SELECT
      id,
      dedupe_key,
      source_check_id,
      severity,
      status,
      summary,
      runbook_key,
      first_seen_at,
      last_seen_at,
      occurrence_count,
      acknowledged_at,
      acknowledged_by,
      ack_reason,
      resolved_at,
      resolved_by,
      resolve_reason,
      metadata,
      created_at,
      updated_at
    FROM ops_alerts
    WHERE
      CASE
        WHEN p_statuses IS NOT NULL THEN status = ANY (p_statuses)
        ELSE status IN ('open', 'acknowledged')
          OR (status = 'resolved' AND resolved_at >= v_now - make_interval(days => p_resolved_days))
      END
    ORDER BY
      CASE severity WHEN 'critical' THEN 0 ELSE 1 END,
      last_seen_at DESC
    LIMIT 200
  ) a;

  RETURN jsonb_build_object(
    'alerts', v_rows,
    'fetchedAt', v_now
  );
END;
$$;

CREATE OR REPLACE FUNCTION rpc_ack_ops_alert(
  p_alert_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row ops_alerts%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_row FROM ops_alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ops_alert_not_found'; END IF;

  IF v_row.status = 'resolved' THEN
    RETURN jsonb_build_object('ok', TRUE, 'alert_id', p_alert_id, 'status', 'resolved', 'idempotent', TRUE);
  END IF;

  IF v_row.status = 'acknowledged' THEN
    RETURN jsonb_build_object('ok', TRUE, 'alert_id', p_alert_id, 'status', 'acknowledged', 'idempotent', TRUE);
  END IF;

  UPDATE ops_alerts
     SET status = 'acknowledged',
         acknowledged_at = NOW(),
         acknowledged_by = v_actor,
         ack_reason = p_reason,
         updated_at = NOW()
   WHERE id = p_alert_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor,
    'ops_alert_acknowledged',
    'ops_alert',
    p_alert_id,
    jsonb_build_object(
      'reason', p_reason,
      'source_check_id', v_row.source_check_id,
      'dedupe_key', v_row.dedupe_key,
      'severity', v_row.severity,
      'occurrence_count', v_row.occurrence_count
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'alert_id', p_alert_id, 'status', 'acknowledged');
END;
$$;

CREATE OR REPLACE FUNCTION rpc_resolve_ops_alert(
  p_alert_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row ops_alerts%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated'; END IF;
  IF NOT _is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO v_row FROM ops_alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ops_alert_not_found'; END IF;

  IF v_row.status = 'resolved' THEN
    RETURN jsonb_build_object('ok', TRUE, 'alert_id', p_alert_id, 'status', 'resolved', 'idempotent', TRUE);
  END IF;

  UPDATE ops_alerts
     SET status = 'resolved',
         resolved_at = NOW(),
         resolved_by = v_actor,
         resolve_reason = p_reason,
         updated_at = NOW()
   WHERE id = p_alert_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, payload)
  VALUES (
    v_actor,
    'ops_alert_resolved',
    'ops_alert',
    p_alert_id,
    jsonb_build_object(
      'reason', p_reason,
      'source_check_id', v_row.source_check_id,
      'dedupe_key', v_row.dedupe_key,
      'severity', v_row.severity,
      'previous_status', v_row.status,
      'occurrence_count', v_row.occurrence_count
    )
  );

  RETURN jsonb_build_object('ok', TRUE, 'alert_id', p_alert_id, 'status', 'resolved');
END;
$$;

REVOKE ALL ON FUNCTION rpc_sync_ops_alerts_from_health() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION rpc_get_ops_alerts(TEXT[], INT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION rpc_ack_ops_alert(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION rpc_resolve_ops_alert(UUID, TEXT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION rpc_sync_ops_alerts_from_health() TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_get_ops_alerts(TEXT[], INT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_ack_ops_alert(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_resolve_ops_alert(UUID, TEXT) TO authenticated;
