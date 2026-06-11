# PHONARA Quality Gates

Every implementation task must pass the relevant quality gates before completion.

## Required Gates

- TypeScript strict mode.
- ESLint.
- Prettier format check.
- Unit tests for domain logic.
- Playwright smoke/E2E for critical user flows. E2E is mandatory for auth,
  wallet, rewards, spot/futures, staking, casino, deposits, withdrawals, admin,
  permissions, PWA, i18n mode switching, and mobile-shell flows.
- Env validation.
- i18n hardcoded Korean detection.
- Test artifact cleanup.

## Domain Gates

- Money code: Decimal-based tests.
- Ledger code: idempotency, available/locked balance, reversal tests.
- Supabase code: RLS positive and negative tests.
- Supabase advisor: local/remote security advisor must report **0 ERROR** before
  any DB-facing task is considered complete. `authenticated_security_definer_function_executable`
  WARNs are acceptable only when the function is an intentional client-facing
  `rpc_*` wrapper with an internal `auth.uid()` or `_is_admin()` guard; document
  the WARN count and rationale in the Build Log instead of treating WARNs as
  green by assumption.
- Admin code: permission and audit log tests.
- PWA code: manifest/service worker smoke tests.
- Money E2E: run real browser flows against the local Supabase stack and assert
  database invariants, including per-currency conservation across user wallets
  and system accounts, idempotency, hash-chain integrity when relevant, and no
  durable test residue.
- Security/Admin E2E: prove both positive and negative authorization through the
  server-trusted RPC/RLS path, not only hidden UI controls.
- Casino E2E: prove bet placement, settlement, provably-fair seed reveal/hash
  verification, client-side outcome recomputation, tamper/duplicate rejection,
  and ledger conservation.

## E2E Levels

- Smoke E2E: app boots, auth screen/routes/navigation render.
- Feature E2E: the changed feature's happy path plus one realistic failure path.
- Money E2E: success + failure + database conservation/idempotency assertions.
- Security E2E: allowed role succeeds, unauthorized role fails, audit exists when
  the action is manual or high-risk.
- Full Phase E2E: all critical journeys for the phase. Required before a phase is
  called complete or launch-ready.

## Completion Definition

A task is complete only when code, tests, relevant E2E, security notes, cleanup,
and a concise report are done. Passing unit/SQL/build without the required E2E
is not enough for user-facing, money, security, admin, casino, PWA, or launch
readiness work.
