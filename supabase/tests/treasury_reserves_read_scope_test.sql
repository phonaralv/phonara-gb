-- ============================================================
-- Test: treasury_reserves read scope (audit A3-3)
-- ============================================================
-- Proves that migration 000049 closes the broad authed-read leak: the
-- "authed read treasury_reserves" policy (USING auth.uid() IS NOT NULL), which
-- let EVERY logged-in user read all columns incl. `notes`/`updated_by`, is gone,
-- leaving the admin-only "admin rw" policy (USING _is_admin()) as the sole client
-- access path.
--
-- Verified at the catalog level (pg_policies), NOT via runtime SET LOCAL ROLE:
-- treasury_reserves' surviving policy calls _is_admin(), and evaluating a function
-- inside an RLS policy under SET ROLE crashes the Supabase local Docker backend
-- (documented in anon_lockdown_test.sql / mission_security_test.sql). Reads by the
-- solvency gate / reconciliation go through SECURITY DEFINER (owner) and bypass
-- RLS regardless. Each test wraps BEGIN..ROLLBACK (no residue).
-- RED before 000049: Test 1 fails (the broad authed-read policy still exists).
-- ============================================================

-- ── Test 1: broad authed-read policy is removed (core) ────────────────────────
BEGIN;
DO $$
DECLARE
  v_broad INT;
BEGIN
  SELECT count(*) INTO v_broad
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename  = 'treasury_reserves'
     AND policyname = 'authed read treasury_reserves';

  ASSERT v_broad = 0,
    'broad "authed read treasury_reserves" policy must be removed (A3-3 notes/updated_by leak)';

  RAISE NOTICE 'A3-3 Test1 OK — broad authed-read policy removed';
END;
$$;
ROLLBACK;

-- ── Test 2: admin-only read path intact (positive) ───────────────────────────
BEGIN;
DO $$
DECLARE
  v_admin INT;
BEGIN
  SELECT count(*) INTO v_admin
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename  = 'treasury_reserves'
     AND policyname = 'admin rw treasury_reserves'
     AND qual ILIKE '%_is_admin()%';

  ASSERT v_admin = 1,
    'admin rw treasury_reserves policy (USING _is_admin()) must remain the sole client read path';

  RAISE NOTICE 'A3-3 Test2 OK — admin-only read path intact';
END;
$$;
ROLLBACK;

-- ── Test 3: no remaining policy grants a non-admin read (no leak) ─────────────
BEGIN;
DO $$
DECLARE
  v_leak INT;
BEGIN
  -- Any surviving SELECT/ALL policy whose qual does NOT gate on _is_admin() would
  -- re-open the table to non-admins. There must be none.
  SELECT count(*) INTO v_leak
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename  = 'treasury_reserves'
     AND cmd IN ('SELECT', 'ALL')
     AND COALESCE(qual, '') NOT ILIKE '%_is_admin()%';

  ASSERT v_leak = 0,
    format('treasury_reserves must have no non-admin read policy, found %s', v_leak);

  RAISE NOTICE 'A3-3 Test3 OK — no non-admin read policy remains';
END;
$$;
ROLLBACK;
