-- ============================================================
-- GRANT + RLS inventory — drift detection for client roles
-- ============================================================
-- Pins explicit GRANT/REVOKE from migrations 000045, 000053–000055
-- (20260611000054/55). RLS row filters are covered by scope tests;
-- this file guards base table privileges that PostgREST needs before
-- RLS can run. Update this snapshot when any migration changes RLS
-- or table GRANTs on a listed table.
--
-- Runs in one transaction and ROLLS BACK — no residue.
-- ============================================================

BEGIN;

DO $$
DECLARE
  r RECORD;
  v_rls_off TEXT := '';
BEGIN
  -- ── Helper: assert privilege state ───────────────────────────────────────
  -- app_config (000053 RLS + 20260611000054 GRANT)
  ASSERT has_table_privilege('anon', 'public.app_config', 'SELECT'),
    'anon must SELECT app_config (public is_public rows)';

  ASSERT has_table_privilege('authenticated', 'public.app_config', 'SELECT'),
    'authenticated must SELECT app_config';

  -- profiles / wallets (20260611000055)
  ASSERT NOT has_table_privilege('anon', 'public.profiles', 'SELECT'),
    'anon must NOT SELECT profiles';
  ASSERT NOT has_table_privilege('anon', 'public.wallets', 'SELECT'),
    'anon must NOT SELECT wallets';

  ASSERT has_table_privilege('authenticated', 'public.profiles', 'SELECT'),
    'authenticated must SELECT profiles';
  ASSERT has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
    'authenticated must UPDATE profiles';
  ASSERT NOT has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
    'authenticated must NOT INSERT profiles';
  ASSERT NOT has_table_privilege('authenticated', 'public.profiles', 'DELETE'),
    'authenticated must NOT DELETE profiles';

  ASSERT has_table_privilege('authenticated', 'public.wallets', 'SELECT'),
    'authenticated must SELECT wallets';
  ASSERT NOT has_table_privilege('authenticated', 'public.wallets', 'INSERT'),
    'authenticated must NOT INSERT wallets';

  ASSERT has_table_privilege('service_role', 'public.profiles', 'INSERT'),
    'service_role must INSERT profiles (E2E/fixtures)';
  ASSERT has_table_privilege('service_role', 'public.wallets', 'INSERT'),
    'service_role must INSERT wallets (E2E/fixtures)';

  -- scope-hardened reads (000053 + 20260611000054)
  ASSERT has_table_privilege('authenticated', 'public.spot_trades', 'SELECT'),
    'authenticated must SELECT spot_trades (own-row RLS)';
  ASSERT has_table_privilege('authenticated', 'public.price_change_audit', 'SELECT'),
    'authenticated must SELECT price_change_audit (admin RLS)';
  ASSERT has_table_privilege('authenticated', 'public.market_sources', 'SELECT'),
    'authenticated must SELECT market_sources (admin RLS)';

  -- system account belt (000045)
  ASSERT NOT has_table_privilege('anon', 'public.system_accounts', 'INSERT'),
    'anon must NOT INSERT system_accounts';
  ASSERT NOT has_table_privilege('anon', 'public.system_accounts', 'UPDATE'),
    'anon must NOT UPDATE system_accounts';
  ASSERT NOT has_table_privilege('anon', 'public.system_accounts', 'DELETE'),
    'anon must NOT DELETE system_accounts';
  ASSERT NOT has_table_privilege('authenticated', 'public.system_account_ledger', 'INSERT'),
    'authenticated must NOT INSERT system_account_ledger';
  ASSERT NOT has_table_privilege('authenticated', 'public.system_account_ledger', 'UPDATE'),
    'authenticated must NOT UPDATE system_account_ledger';
  ASSERT NOT has_table_privilege('authenticated', 'public.system_account_ledger', 'DELETE'),
    'authenticated must NOT DELETE system_account_ledger';

  -- ── RLS enabled on inventory tables ──────────────────────────────────────
  FOR r IN
    SELECT c.relname AS tbl
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname IN (
        'app_config', 'profiles', 'wallets', 'spot_trades',
        'price_change_audit', 'market_sources',
        'system_accounts', 'system_account_ledger'
      )
      AND NOT c.relrowsecurity
  LOOP
    v_rls_off := v_rls_off || ' ' || r.tbl;
  END LOOP;

  ASSERT v_rls_off = '',
    format('RLS must be enabled on inventory tables:%s', v_rls_off);

  RAISE NOTICE 'GRANTS RLS INVENTORY OK — pinned role/table privileges match migrations 000045/053–055';
END;
$$;

ROLLBACK;
