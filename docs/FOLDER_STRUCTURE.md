# Folder Structure

```text
apps/
  web/      User-facing PHONARA app
  admin/    Admin operations app
packages/
  shared-types/
  money/
  wallet-ledger/
  trading-engine/
  game-engine/
  i18n/
scripts/
tests/
supabase/
```

## Rules

- `apps/web` cannot import Admin-only code.
- `apps/admin` can consume shared packages but cannot bypass audit requirements.
- Domain logic belongs in `packages/*`, not in UI components.
- Supabase migrations require approval before remote application.
