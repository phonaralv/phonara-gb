# PHONARA Supabase Access Matrix

> Table × role × base GRANT × RLS scope. Update when migrations change RLS or GRANT.
> Pair every RLS migration with GRANT in the same file (see `.cursor/rules/25-postgres-plpgsql.mdc`).

## Legend

| Scope | Meaning |
|-------|---------|
| **public** | `is_public = TRUE` or intentionally client-readable rows |
| **own** | `auth.uid()` matches row owner |
| **admin** | `_is_admin()` via SECURITY DEFINER check |
| **deny** | No client policy / REVOKE write / RPC-only |
| **rpc** | Mutations only through `rpc_*` SECURITY DEFINER |

## Client-facing tables (inventory)

| Table | anon GRANT | authenticated GRANT | RLS (effective) | Writes |
|-------|------------|---------------------|-----------------|--------|
| `app_config` | SELECT | SELECT | public flags + admin all | admin RPC / service_role |
| `profiles` | none | SELECT, UPDATE | own read/update (no role elevation) | trigger on signup |
| `wallets` | none | SELECT | own read | RPC only |
| `wallet_ledger` | default* | default* | own read | RPC only, append-only RULE |
| `spot_trades` | default* | SELECT | own read | RPC only |
| `price_change_audit` | default* | SELECT | admin read | admin RPC |
| `market_sources` | default* | SELECT | admin read | admin RPC |
| `system_accounts` | SELECT† | SELECT† | admin read | REVOKE INSERT/UPDATE/DELETE |
| `system_account_ledger` | SELECT† | SELECT† | admin read | REVOKE INSERT/UPDATE/DELETE, append-only RULE |
| `audit_logs` | default* | default* | admin read (024) | INSERT via DEFINER RPC; append-only trigger (057 pilot) |
| `treasury_reserves` | default* | default* | admin only (049) | admin RPC |
| `reconciliation_log` | default* | default* | admin only | service_role cron only |

\* Supabase default may grant broad table privileges; RLS is the row filter. Pin critical REVOKEs in migrations and [`grants_rls_inventory_test.sql`](../supabase/tests/grants_rls_inventory_test.sql).

† Explicit REVOKE on INSERT/UPDATE/DELETE/TRUNCATE (000045).

## Internal helpers (never client EXECUTE)

| Function | Role | Notes |
|----------|------|-------|
| `_is_admin()` | anon, authenticated, service_role EXECUTE | SECURITY DEFINER; used in RLS policies |
| `_recon_log_row`, `_recon_apply_halt` | service_role via `rpc_run_reconciliation` only | REVOKE all client roles |
| `rpc_run_reconciliation` | service_role only | Daily cron + admin automation |
| `_ledger_deny_mutations` | trigger only | REVOKE all client roles |

## Migration naming

- File name: `YYYYMMDD` + monotonic 6-digit suffix (e.g. `20260611000056_*`).
- **Do not reuse suffix** across different dates (000054 exists twice: `20260609000054` = `_is_admin`, `20260611000054` = table GRANT fix).
- Apply order follows full filename sort, not suffix alone.

## Checklist — new table with client read

```sql
ALTER TABLE foo ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON foo TO authenticated;  -- same migration file
REVOKE INSERT, UPDATE, DELETE ON foo FROM anon, authenticated;
CREATE POLICY "foo: own read" ON foo FOR SELECT USING (auth.uid() = user_id);
-- Update grants_rls_inventory_test.sql
```

## Related tests

| Test | Guards |
|------|--------|
| [`grants_rls_inventory_test.sql`](../supabase/tests/grants_rls_inventory_test.sql) | Pinned GRANT + RLS enabled |
| [`public_scope_hardening_test.sql`](../supabase/tests/public_scope_hardening_test.sql) | app_config / audit / market_sources row scope |
| [`anon_lockdown_test.sql`](../supabase/tests/anon_lockdown_test.sql) | RPC EXECUTE + `_is_admin` definer |
| [`audit_logs_append_only_test.sql`](../supabase/tests/audit_logs_append_only_test.sql) | Trigger pilot immutability |

## Observability

Reconciliation failures: see [`RUNBOOK.md`](RUNBOOK.md) Scenario 1 — query `reconciliation_log` by `check_type` (`wallet`, `system`, `global_zero`, `hash_chain_wallet`, `hash_chain_system`).
