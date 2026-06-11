-- ============================================================
-- Migration: 20260609000024_admin_audit_rls
-- Purpose: Allow admin users to SELECT from audit_logs via PostgREST.
-- audit_logs has RLS enabled but previously had no SELECT policy, so
-- only service_role could read it. This policy gates reads on _is_admin().
-- ============================================================

-- Admins may read all audit log entries (read-only — no INSERT/UPDATE/DELETE policy).
CREATE POLICY "audit_logs: admin read"
  ON audit_logs FOR SELECT
  USING (_is_admin());
