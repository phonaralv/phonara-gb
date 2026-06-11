-- ============================================================
-- Observability foundation SQL integration test
-- ============================================================
-- Verifies rpc_get_ops_health is admin-only and reads stored operational
-- signals without running heavy reconciliation/hash-chain checks.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user UUID := gen_random_uuid();
  v_res JSONB;
  v_check JSONB;
  v_blocked BOOLEAN;
  v_msg TEXT;
  v_run_at TIMESTAMPTZ;
  v_success_at TIMESTAMPTZ;
  v_cron_jobid BIGINT;
  v_next_runid BIGINT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'ops_health_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user, 'authenticated', 'authenticated', 'ops_health_user_' || v_user::TEXT || '@test.local', NOW(), NOW());

  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  ASSERT has_function_privilege('authenticated', 'public.rpc_get_ops_health()', 'EXECUTE'),
    'authenticated admin sessions need EXECUTE on rpc_get_ops_health';
  ASSERT NOT has_function_privilege('anon', 'public.rpc_get_ops_health()', 'EXECUTE'),
    'anon must not have EXECUTE on rpc_get_ops_health';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::TEXT)::TEXT, true);
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_get_ops_health();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin authenticated user executed rpc_get_ops_health';

  PERFORM set_config('request.jwt.claims', '{}', true);
  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_get_ops_health();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' OR lower(v_msg) LIKE '%permission denied%' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'anon/null-uid caller executed rpc_get_ops_health';

  UPDATE app_config SET value = 'false' WHERE key IN ('system_halt', 'system_readonly');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  v_res := rpc_get_ops_health();
  ASSERT v_res ? 'status' AND v_res ? 'lastUpdatedAt' AND v_res ? 'checks',
    'rpc_get_ops_health must return status, lastUpdatedAt, checks';
  ASSERT jsonb_array_length(v_res->'checks') = 6,
    format('rpc_get_ops_health must return 6 checks, got %s', jsonb_array_length(v_res->'checks'));
  ASSERT NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_res->'checks') c
    WHERE c->>'id' NOT IN (
      'system_mode',
      'reconciliation_latest',
      'cron_liquidation_liveness',
      'liquidation_recent_error',
      'treasury_freshness',
      'operator_high_risk_actions'
    )
  ), 'rpc_get_ops_health returned an unknown check id';

  UPDATE app_config SET value = 'true' WHERE key = 'system_halt';
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'system_mode';
  ASSERT v_check->>'status' = 'critical',
    format('system_halt=true must make system_mode critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'System halt active%',
    format('system_mode summary must describe halt, got %s', v_check->>'summary');
  ASSERT v_res->>'status' = 'critical', 'any critical check must make overall status critical';

  UPDATE app_config SET value = 'false' WHERE key = 'system_halt';
  UPDATE app_config SET value = 'true' WHERE key = 'system_readonly';
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'system_mode';
  ASSERT v_check->>'status' = 'warning',
    format('system_readonly=true must make system_mode warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'System read-only active%',
    format('system_mode summary must describe read-only, got %s', v_check->>'summary');

  UPDATE app_config SET value = 'false' WHERE key = 'system_readonly';

  -- reconciliation: isolated failed run with no fresh success -> critical
  DELETE FROM reconciliation_log;
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES (NOW(), 'wallet', FALSE, '1.000000', TRUE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'reconciliation_latest';
  ASSERT v_check->>'status' = 'critical',
    format('failed reconciliation with no fresh success must be critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Reconciliation failed (wallet)%',
    format('reconciliation summary must name failed check, got %s', v_check->>'summary');

  -- reconciliation: latest failed but fresh earlier success -> warning
  DELETE FROM reconciliation_log;
  v_success_at := NOW() - INTERVAL '45 minutes';
  v_run_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES
    (v_success_at, 'wallet', TRUE, '0.000000', FALSE),
    (v_run_at, 'global_zero', FALSE, '1.000000', TRUE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'reconciliation_latest';
  ASSERT v_check->>'status' = 'warning',
    format('failed latest run with fresh success must be warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Reconciliation failed (global_zero)%last success%',
    format('reconciliation warning summary missing context, got %s', v_check->>'summary');
  ASSERT v_check ? 'lastSuccessfulAt',
    'reconciliation check must expose lastSuccessfulAt metadata';

  -- reconciliation: latest failed and stale success -> critical
  DELETE FROM reconciliation_log;
  v_success_at := NOW() - INTERVAL '3 hours';
  v_run_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES
    (v_success_at, 'wallet', TRUE, '0.000000', FALSE),
    (v_run_at, 'wallet', FALSE, '1.000000', TRUE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'reconciliation_latest';
  ASSERT v_check->>'status' = 'critical',
    format('failed latest run with stale success must be critical, got %s', v_check);

  -- reconciliation stale boundary: exactly 2 hours is still fresh
  DELETE FROM reconciliation_log;
  v_success_at := NOW() - INTERVAL '2 hours';
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES (v_success_at, 'wallet', TRUE, '0.000000', FALSE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'reconciliation_latest';
  ASSERT v_check->>'status' = 'ok',
    format('reconciliation success at exactly 2 hours must stay ok, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Reconciliation clean%',
    format('fresh reconciliation summary unexpected, got %s', v_check->>'summary');

  -- reconciliation stale boundary: just over 2 hours -> warning
  DELETE FROM reconciliation_log;
  v_success_at := NOW() - INTERVAL '2 hours 1 second';
  INSERT INTO reconciliation_log (run_at, check_type, is_match, delta, triggered_halt)
  VALUES (v_success_at, 'wallet', TRUE, '0.000000', FALSE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'reconciliation_latest';
  ASSERT v_check->>'status' = 'warning',
    format('reconciliation success older than 2 hours must be warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Reconciliation stale%',
    format('stale reconciliation summary unexpected, got %s', v_check->>'summary');

  INSERT INTO liquidation_run_log (ran_at, liquidated, skipped, errors, duration_ms, detail)
  VALUES (NOW(), 0, 0, 1, 10, '[]'::JSONB);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'liquidation_recent_error';
  ASSERT v_check->>'status' = 'warning',
    format('recent liquidation errors must make liquidation_recent_error warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Auto-liquidation errors recorded%',
    format('liquidation error summary unexpected, got %s', v_check->>'summary');
  ASSERT v_check ? 'lastErrorAt',
    'liquidation_recent_error must expose lastErrorAt metadata';

  -- cron: stale success beyond 30 minutes -> critical
  SELECT jobid INTO v_cron_jobid FROM cron.job WHERE jobname = 'phonara_auto_liquidations';
  ASSERT v_cron_jobid IS NOT NULL, 'phonara_auto_liquidations cron job must exist for ops health tests';

  DELETE FROM cron.job_run_details WHERE jobid = v_cron_jobid;
  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details WHERE jobid = v_cron_jobid;
  INSERT INTO cron.job_run_details (
    jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time
  )
  SELECT
    j.jobid,
    v_next_runid,
    1,
    current_database(),
    current_user,
    j.command,
    'succeeded',
    '',
    NOW() - INTERVAL '45 minutes',
    NOW() - INTERVAL '45 minutes'
  FROM cron.job j
  WHERE j.jobid = v_cron_jobid;

  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'cron_liquidation_liveness';
  ASSERT v_check->>'status' = 'critical',
    format('cron success older than 30 minutes must be critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Auto-liquidation cron stale%',
    format('stale cron summary unexpected, got %s', v_check->>'summary');

  -- cron: latest failed but recent success -> warning
  DELETE FROM cron.job_run_details WHERE jobid = v_cron_jobid;
  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details WHERE jobid = v_cron_jobid;
  INSERT INTO cron.job_run_details (
    jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time
  )
  SELECT
    j.jobid,
    v_next_runid,
    1,
    current_database(),
    current_user,
    j.command,
    'succeeded',
    '',
    NOW() - INTERVAL '8 minutes',
    NOW() - INTERVAL '8 minutes'
  FROM cron.job j
  WHERE j.jobid = v_cron_jobid;

  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details WHERE jobid = v_cron_jobid;
  INSERT INTO cron.job_run_details (
    jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time
  )
  SELECT
    j.jobid,
    v_next_runid,
    1,
    current_database(),
    current_user,
    j.command,
    'failed',
    'test failure',
    NOW() - INTERVAL '1 minute',
    NOW() - INTERVAL '1 minute'
  FROM cron.job j
  WHERE j.jobid = v_cron_jobid;

  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'cron_liquidation_liveness';
  ASSERT v_check->>'status' = 'warning',
    format('cron failed last run with fresh success must be warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Auto-liquidation cron failed last run%',
    format('cron warning summary unexpected, got %s', v_check->>'summary');
  ASSERT v_check ? 'lastSuccessfulAt' AND v_check ? 'lastRunAt',
    'cron check must expose lastSuccessfulAt and lastRunAt metadata';

  -- operator actions: count and latest action category only (no sensitive payload)
  INSERT INTO audit_logs (actor_id, action, entity_type, payload, created_at)
  VALUES
    (v_admin, 'withdrawal_approved', 'withdrawal_requests', jsonb_build_object('amount', '100.000000', 'user_id', v_user), NOW() - INTERVAL '2 hours'),
    (v_admin, 'feature_toggle', 'app_config', jsonb_build_object('feature', 'withdrawal'), NOW() - INTERVAL '5 minutes');

  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'operator_high_risk_actions';
  ASSERT v_check->>'summary' LIKE '2 high-risk operator actions%',
    format('operator summary must include action count, got %s', v_check->>'summary');
  ASSERT v_check->>'summary' LIKE '%latest feature_toggle%',
    format('operator summary must include latest action category, got %s', v_check->>'summary');
  ASSERT v_check->>'summary' NOT LIKE '%' || v_user::TEXT || '%',
    'operator summary must not expose user ids';

  RAISE NOTICE 'OPS HEALTH OK — admin-only RPC, stale boundaries, and summary checks verified';
END;
$$;

ROLLBACK;
