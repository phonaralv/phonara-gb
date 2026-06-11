-- ============================================================
-- PART E: public read-scope hardening for non-money config/audit tables
-- ============================================================
-- RED before 000053:
--   * anon can read sensitive app_config AML thresholds.
--   * authenticated non-admin can read price_change_audit and market_sources.
-- GREEN after 000053:
--   * only explicitly public app_config keys remain client-readable.
--   * admin users can still read operational config/audit/source rows.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin UUID := gen_random_uuid();
  v_user  UUID := gen_random_uuid();
  v_anon_sensitive INT;
  v_anon_public INT;
  v_user_sensitive INT;
  v_user_public INT;
  v_admin_sensitive INT;
  v_user_price_audit INT;
  v_admin_price_audit INT;
  v_user_sources INT;
  v_admin_sources INT;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
  VALUES
    (v_admin, 'authenticated', 'authenticated', 'scope_admin_' || v_admin::TEXT || '@test.local', NOW(), NOW()),
    (v_user,  'authenticated', 'authenticated', 'scope_user_'  || v_user::TEXT  || '@test.local', NOW(), NOW());
  UPDATE profiles SET role = 'admin' WHERE id = v_admin;

  INSERT INTO price_change_audit (
    symbol, price_before, price_after, change_pct, source, actor_id, reason, circuit_breaker_triggered
  ) VALUES (
    'SCOPE_TEST', '1.000000', '1.100000', 10, 'admin', v_admin, 'scope hardening check', FALSE
  );

  INSERT INTO market_sources (internal_symbol, provider, provider_symbol, weight, enabled)
  VALUES ('SCOPE_TEST', 'scope-provider', 'SCOPEUSD', '1', TRUE)
  ON CONFLICT (internal_symbol, provider) DO UPDATE
    SET provider_symbol = EXCLUDED.provider_symbol,
        weight = EXCLUDED.weight,
        enabled = EXCLUDED.enabled;

  PERFORM set_config('request.jwt.claims', '{}', true);
  SET ROLE anon;
  SELECT COUNT(*) INTO v_anon_sensitive
    FROM app_config
   WHERE key IN ('screening_deposit_single_krw_threshold', 'str_withdrawal_krw_threshold');
  SELECT COUNT(*) INTO v_anon_public
    FROM app_config
   WHERE key = 'feature_withdrawal_enabled';
  RESET ROLE;

  ASSERT v_anon_sensitive = 0,
    format('anon must not read AML/STR app_config thresholds, got %s rows', v_anon_sensitive);
  ASSERT v_anon_public = 1,
    format('anon must still read public withdrawal feature flag, got %s rows', v_anon_public);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::TEXT)::TEXT, true);
  SET ROLE authenticated;
  SELECT COUNT(*) INTO v_user_sensitive
    FROM app_config
   WHERE key IN ('screening_deposit_single_krw_threshold', 'str_withdrawal_krw_threshold');
  SELECT COUNT(*) INTO v_user_public
    FROM app_config
   WHERE key = 'feature_withdrawal_enabled';
  SELECT COUNT(*) INTO v_user_price_audit
    FROM price_change_audit
   WHERE symbol = 'SCOPE_TEST';
  SELECT COUNT(*) INTO v_user_sources
    FROM market_sources
   WHERE internal_symbol = 'SCOPE_TEST';
  RESET ROLE;

  ASSERT v_user_sensitive = 0,
    format('non-admin must not read AML/STR app_config thresholds, got %s rows', v_user_sensitive);
  ASSERT v_user_public = 1,
    format('non-admin must still read public withdrawal feature flag, got %s rows', v_user_public);
  ASSERT v_user_price_audit = 0,
    format('non-admin must not read price_change_audit UUID-bearing rows, got %s rows', v_user_price_audit);
  ASSERT v_user_sources = 0,
    format('non-admin must not read market_sources provider mapping, got %s rows', v_user_sources);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::TEXT)::TEXT, true);
  SET ROLE authenticated;
  SELECT COUNT(*) INTO v_admin_sensitive
    FROM app_config
   WHERE key IN ('screening_deposit_single_krw_threshold', 'str_withdrawal_krw_threshold');
  SELECT COUNT(*) INTO v_admin_price_audit
    FROM price_change_audit
   WHERE symbol = 'SCOPE_TEST';
  SELECT COUNT(*) INTO v_admin_sources
    FROM market_sources
   WHERE internal_symbol = 'SCOPE_TEST';
  RESET ROLE;

  ASSERT v_admin_sensitive = 2,
    format('admin must read sensitive app_config thresholds, got %s rows', v_admin_sensitive);
  ASSERT v_admin_price_audit = 1,
    format('admin must read price_change_audit rows, got %s rows', v_admin_price_audit);
  ASSERT v_admin_sources = 1,
    format('admin must read market_sources rows, got %s rows', v_admin_sources);

  RAISE NOTICE 'PART E PUBLIC SCOPE OK — sensitive config/audit/source rows are admin-only while public config keys remain readable';
END;
$$;

ROLLBACK;
