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
  v_entity UUID;
  i INT;
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
  ASSERT jsonb_array_length(v_res->'checks') = 9,
    format('rpc_get_ops_health must return 9 checks, got %s', jsonb_array_length(v_res->'checks'));
  ASSERT NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_res->'checks') c
    WHERE c->>'id' NOT IN (
      'system_mode',
      'reconciliation_latest',
      'cron_liquidation_liveness',
      'liquidation_recent_error',
      'treasury_freshness',
      'operator_high_risk_actions',
      'hash_chain_integrity',
      'pending_exceptions',
      'treasury_solvency'
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
  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details;
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
  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details;
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

  SELECT COALESCE(MAX(runid), 0) + 1 INTO v_next_runid FROM cron.job_run_details;
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

  -- hash_chain_integrity: clean stored rows -> ok
  DELETE FROM reconciliation_log
  WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system');
  v_run_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, is_match, broken_count, delta)
  VALUES
    (v_run_at, 'hash_chain_wallet', TRUE, 0, '0.000000'),
    (v_run_at, 'hash_chain_system', TRUE, 0, '0.000000');
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'hash_chain_integrity';
  ASSERT v_check->>'status' = 'ok',
    format('clean hash-chain rows must be ok, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Hash-chain integrity clean%',
    format('hash-chain ok summary unexpected, got %s', v_check->>'summary');
  ASSERT v_check ? 'lastRunAt' AND v_check ? 'lastSuccessfulAt',
    'hash_chain_integrity must expose lastRunAt and lastSuccessfulAt metadata';

  -- hash_chain_integrity: broken wallet row -> critical
  DELETE FROM reconciliation_log
  WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system');
  v_run_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, is_match, broken_count, delta, triggered_halt)
  VALUES
    (v_run_at, 'hash_chain_wallet', FALSE, 2, '0.000000', TRUE),
    (v_run_at, 'hash_chain_system', TRUE, 0, '0.000000', FALSE);
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'hash_chain_integrity';
  ASSERT v_check->>'status' = 'critical',
    format('broken hash-chain must be critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Hash-chain damage detected (wallet: 2%',
    format('hash-chain critical summary unexpected, got %s', v_check->>'summary');

  -- hash_chain_integrity: stale success -> warning
  DELETE FROM reconciliation_log
  WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system');
  v_success_at := NOW() - INTERVAL '25 hours';
  INSERT INTO reconciliation_log (run_at, check_type, is_match, broken_count, delta)
  VALUES
    (v_success_at, 'hash_chain_wallet', TRUE, 0, '0.000000'),
    (v_success_at, 'hash_chain_system', TRUE, 0, '0.000000');
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'hash_chain_integrity';
  ASSERT v_check->>'status' = 'warning',
    format('stale hash-chain success must be warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Hash-chain check stale%',
    format('hash-chain stale summary unexpected, got %s', v_check->>'summary');

  -- pending_exceptions: none -> ok
  DELETE FROM admin_review_queue;
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'pending_exceptions';
  ASSERT v_check->>'status' = 'ok',
    format('empty exception queue must be ok, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'No pending exceptions%',
    format('pending_exceptions ok summary unexpected, got %s', v_check->>'summary');

  -- pending_exceptions: 2 open -> warning
  DELETE FROM admin_review_queue;
  FOR i IN 1..2 LOOP
    v_entity := gen_random_uuid();
    INSERT INTO admin_review_queue (
      queue_type, entity_type, entity_id, status, reason, sla_due_at
    ) VALUES (
      'deposit_exception', 'test_entity', v_entity, 'pending', 'test_reason',
      NOW() + INTERVAL '2 hours'
    );
  END LOOP;
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'pending_exceptions';
  ASSERT v_check->>'status' = 'warning',
    format('2 pending exceptions must be warning, got %s', v_check);
  ASSERT v_check->>'summary' LIKE '2 pending exceptions require review%',
    format('pending_exceptions warning summary unexpected, got %s', v_check->>'summary');

  -- pending_exceptions: 5 open -> critical
  DELETE FROM admin_review_queue;
  FOR i IN 1..5 LOOP
    v_entity := gen_random_uuid();
    INSERT INTO admin_review_queue (
      queue_type, entity_type, entity_id, status, reason, sla_due_at
    ) VALUES (
      'deposit_exception', 'test_entity', v_entity, 'pending', 'test_reason',
      NOW() + INTERVAL '2 hours'
    );
  END LOOP;
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'pending_exceptions';
  ASSERT v_check->>'status' = 'critical',
    format('5 pending exceptions must be critical, got %s', v_check);

  -- pending_exceptions: overdue forces at least warning (never ok)
  DELETE FROM admin_review_queue;
  v_entity := gen_random_uuid();
  INSERT INTO admin_review_queue (
    queue_type, entity_type, entity_id, status, reason, sla_due_at
  ) VALUES (
    'deposit_exception', 'test_entity', v_entity, 'pending', 'test_reason',
    NOW() - INTERVAL '1 hour'
  );
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'pending_exceptions';
  ASSERT v_check->>'status' = 'warning',
    format('overdue exception must not be ok, got %s', v_check);
  ASSERT v_check->>'summary' LIKE '%(1 overdue)%',
    format('overdue count must appear in summary, got %s', v_check->>'summary');

  -- pending_exceptions: 3 overdue -> critical
  DELETE FROM admin_review_queue;
  FOR i IN 1..3 LOOP
    v_entity := gen_random_uuid();
    INSERT INTO admin_review_queue (
      queue_type, entity_type, entity_id, status, reason, sla_due_at
    ) VALUES (
      'deposit_exception', 'test_entity', v_entity, 'pending', 'test_reason',
      NOW() - INTERVAL '2 hours'
    );
  END LOOP;
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'pending_exceptions';
  ASSERT v_check->>'status' = 'critical',
    format('3 overdue exceptions must be critical, got %s', v_check);

  -- treasury_solvency: configured covered reserves -> ok
  UPDATE treasury_reserves SET
    real_balance = '1000000.000000',
    updated_at = NOW();
  DELETE FROM reconciliation_log;
  v_run_at := NOW();
  INSERT INTO reconciliation_log (run_at, check_type, currency, is_match, delta, wallet_sum, ledger_net)
  VALUES
    (v_run_at, 'wallet', 'PHON', TRUE, '0.000000', '0.000000', '0.000000'),
    (v_run_at, 'wallet', 'USDT', TRUE, '0.000000', '0.000000', '0.000000'),
    (v_run_at, 'wallet', 'KRW', TRUE, '0.000000', '0.000000', '0.000000');
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'treasury_solvency';
  ASSERT v_check->>'status' = 'ok',
    format('covered treasury reserves must be ok, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Treasury solvency healthy%',
    format('treasury_solvency ok summary unexpected, got %s', v_check->>'summary');

  -- treasury_solvency: coverage breach -> critical
  UPDATE treasury_reserves SET real_balance = '100.000000', buffer_pct = 10, updated_at = NOW()
  WHERE currency = 'PHON';
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET phon_available = '95.000000', phon_locked = '0.000000'
  WHERE user_id = v_user;
  ASSERT FOUND, 'test user wallet must exist for treasury solvency breach case';
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'treasury_solvency';
  ASSERT v_check->>'status' = 'critical',
    format('treasury coverage breach must be critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Treasury coverage needs review (PHON)%',
    format('treasury_solvency breach summary unexpected, got %s', v_check->>'summary');

  -- treasury_solvency: unconfigured reserve -> critical
  UPDATE treasury_reserves SET real_balance = '1000000.000000', updated_at = NOW()
  WHERE currency = 'PHON';
  PERFORM set_config('phonara.ledger_write', 'allowed', true);
  UPDATE wallets SET phon_available = '0.000000', phon_locked = '0.000000'
  WHERE user_id = v_user;
  UPDATE treasury_reserves SET real_balance = '0.000000', updated_at = NOW()
  WHERE currency = 'USDT';
  v_res := rpc_get_ops_health();
  SELECT c INTO v_check FROM jsonb_array_elements(v_res->'checks') c WHERE c->>'id' = 'treasury_solvency';
  ASSERT v_check->>'status' = 'critical',
    format('unconfigured treasury reserve must be critical, got %s', v_check);
  ASSERT v_check->>'summary' LIKE 'Treasury reserve needs setup (USDT)%',
    format('treasury_solvency setup summary unexpected, got %s', v_check->>'summary');

  RAISE NOTICE 'OPS HEALTH OK — admin-only RPC, stale boundaries, and summary checks verified';
END;
$$;

ROLLBACK;
