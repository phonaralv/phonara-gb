-- ============================================================
-- Admin authorization SQL integration test
-- ============================================================
-- Guards admin-only RPC grants and in-body _is_admin checks. Runs in one
-- transaction and ROLLBACKs.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user  UUID := gen_random_uuid();
  v_ok    JSONB;
  v_blocked BOOLEAN;
  v_msg TEXT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'admin_authz_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user,  'authenticated', 'authenticated', 'user_authz_'  || v_user::TEXT  || '@test.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  ASSERT has_function_privilege('authenticated',
    'public.rpc_update_treasury_reserve(text,text,numeric,numeric,text,boolean)', 'EXECUTE'),
    'authenticated admins must be able to execute rpc_update_treasury_reserve';
  ASSERT has_function_privilege('service_role',
    'public.rpc_update_treasury_reserve(text,text,numeric,numeric,text,boolean)', 'EXECUTE'),
    'service_role must have EXECUTE grant on rpc_update_treasury_reserve';
  ASSERT NOT has_function_privilege('anon',
    'public.rpc_update_treasury_reserve(text,text,numeric,numeric,text,boolean)', 'EXECUTE'),
    'anon must not execute rpc_update_treasury_reserve';

  ASSERT has_function_privilege('authenticated',
    'public.rpc_check_reserve_ratio()', 'EXECUTE'),
    'authenticated admins must be able to execute rpc_check_reserve_ratio';
  ASSERT has_function_privilege('service_role',
    'public.rpc_check_reserve_ratio()', 'EXECUTE'),
    'service_role must have EXECUTE grant on rpc_check_reserve_ratio';
  ASSERT NOT has_function_privilege('anon',
    'public.rpc_check_reserve_ratio()', 'EXECUTE'),
    'anon must not execute rpc_check_reserve_ratio';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);

  v_ok := rpc_set_system_mode(FALSE, FALSE, 'admin authz regression check');
  ASSERT v_ok ? 'system_halt', 'rpc_set_system_mode did not return status';

  v_ok := rpc_set_feature_enabled('spot', TRUE, 'admin authz regression check');
  ASSERT v_ok->>'feature' = 'spot', 'rpc_set_feature_enabled did not return feature';

  v_ok := rpc_update_treasury_reserve(
    'PHON', '1000000.000000', 10, 50, 'admin authz regression check', TRUE
  );
  ASSERT (v_ok->>'ok')::BOOLEAN, 'admin treasury reserve update failed';

  v_ok := rpc_check_reserve_ratio();
  ASSERT (v_ok->>'ok')::BOOLEAN AND jsonb_array_length(v_ok->'reserves') = 3,
    'admin reserve ratio check failed';

  v_ok := rpc_set_market_limits(
    'PHONUSDT-PERP', 20, '100000.000000', '10', 'admin authz regression check'
  );
  ASSERT v_ok->>'market' = 'PHONUSDT-PERP', 'admin market limit update failed';

  ASSERT EXISTS (
    SELECT 1 FROM audit_logs
     WHERE actor_id = v_admin
       AND action IN ('system_mode_set', 'feature_toggle', 'treasury_reserve_update', 'market_limits_set')
     GROUP BY actor_id
    HAVING COUNT(DISTINCT action) = 4
  ), 'admin actions did not write the expected audit rows';

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::TEXT)::TEXT, true);

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_set_system_mode(FALSE, FALSE, 'non-admin should fail');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin executed rpc_set_system_mode';

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_set_feature_enabled('spot', TRUE, 'non-admin should fail');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin executed rpc_set_feature_enabled';

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_update_treasury_reserve('PHON', '1.000000', 10, 50, 'non-admin should fail', TRUE);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin executed rpc_update_treasury_reserve';

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_check_reserve_ratio();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin executed rpc_check_reserve_ratio';

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_set_market_limits('PHONUSDT-PERP', 20, '100000.000000', '10', 'non-admin should fail');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'non-admin executed rpc_set_market_limits';

  PERFORM set_config('request.jwt.claims', '{}', true);

  v_blocked := FALSE;
  BEGIN
    PERFORM rpc_check_reserve_ratio();
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF lower(v_msg) = 'forbidden' THEN v_blocked := TRUE; END IF;
  END;
  ASSERT v_blocked, 'NULL-uid caller executed rpc_check_reserve_ratio';

  RAISE NOTICE 'ADMIN AUTHZ OK — admin succeeds; non-admin/anon fail; grants and audit rows verified';
END;
$$;

ROLLBACK;
