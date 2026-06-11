-- E foundation (audit A1-1 + A2-1): system_account ledger append-only + REVOKE belt.
-- Local-only until Wave 12. No remote apply in this change.

-- A1-1: match wallet_ledger append-only semantics (DO INSTEAD NOTHING).
CREATE OR REPLACE RULE system_account_ledger_no_update AS
  ON UPDATE TO system_account_ledger DO INSTEAD NOTHING;

CREATE OR REPLACE RULE system_account_ledger_no_delete AS
  ON DELETE TO system_account_ledger DO INSTEAD NOTHING;

-- A2-1: belt-and-suspenders — block direct client writes even if RLS policy leaks.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON system_accounts, system_account_ledger
  FROM anon, authenticated;
