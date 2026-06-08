# PHONARA Quality Gates

Every implementation task must pass the relevant quality gates before completion.

## Required Gates

- TypeScript strict mode.
- ESLint.
- Prettier format check.
- Unit tests for domain logic.
- Playwright smoke/E2E for critical user flows.
- Env validation.
- i18n hardcoded Korean detection.
- Test artifact cleanup.

## Domain Gates

- Money code: Decimal-based tests.
- Ledger code: idempotency, available/locked balance, reversal tests.
- Supabase code: RLS positive and negative tests.
- Admin code: permission and audit log tests.
- PWA code: manifest/service worker smoke tests.

## Completion Definition

A task is complete only when code, tests, security notes, cleanup, and a concise report are done.
