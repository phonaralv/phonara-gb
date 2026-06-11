-- ============================================================
-- Append-only: price_change_audit UPDATE/DELETE trigger
-- ============================================================
-- Mirrors 20260611000057 audit_logs append-only enforcement.
-- price_change_audit records market/oracle decisions and must be immutable.
-- ============================================================

SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_price_change_audit_deny_update ON price_change_audit;
DROP TRIGGER IF EXISTS trg_price_change_audit_deny_delete ON price_change_audit;

CREATE TRIGGER trg_price_change_audit_deny_update
  BEFORE UPDATE ON price_change_audit
  FOR EACH ROW EXECUTE FUNCTION _ledger_deny_mutations();

CREATE TRIGGER trg_price_change_audit_deny_delete
  BEFORE DELETE ON price_change_audit
  FOR EACH ROW EXECUTE FUNCTION _ledger_deny_mutations();
