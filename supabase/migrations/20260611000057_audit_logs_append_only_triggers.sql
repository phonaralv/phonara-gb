-- ============================================================
-- Append-only pilot: audit_logs RULE → BEFORE UPDATE/DELETE trigger
-- ============================================================
-- Phase A of ledger immutability migration. Raises append_only_violation
-- instead of silent DO INSTEAD NOTHING. Future backfills disable triggers
-- explicitly (ALTER TABLE ... DISABLE TRIGGER).
-- ============================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION _ledger_deny_mutations()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'append_only_violation' USING HINT = TG_TABLE_NAME;
END;
$$;

DROP RULE IF EXISTS audit_logs_no_update ON audit_logs;
DROP RULE IF EXISTS audit_logs_no_delete ON audit_logs;

CREATE TRIGGER trg_audit_logs_deny_update
  BEFORE UPDATE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION _ledger_deny_mutations();

CREATE TRIGGER trg_audit_logs_deny_delete
  BEFORE DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION _ledger_deny_mutations();

REVOKE ALL ON FUNCTION _ledger_deny_mutations() FROM PUBLIC, anon, authenticated;
