# Observability & CI Secret Policy

PHONARA observability must help diagnose production incidents without exposing
user identity, balances, KYC data, wallet addresses, payment references, access
tokens, or admin notes.

## Runtime Telemetry Policy

- Sentry/PostHog runtime SDK wiring is deferred until operator approval because
  both integrations require external services and new runtime dependencies.
- When approved, initialize telemetry only in production builds and only with
  public browser DSNs/keys. Never expose `SUPABASE_SERVICE_ROLE_KEY`, SQL URLs,
  Management API tokens, or any secret through `VITE_` variables.
- Before sending events, drop or hash:
  - email, username, legal name, document fields, bank account text;
  - wallet balances, transfer amounts, order sizes, PnL, fees, rates;
  - Supabase JWTs, refresh tokens, API keys, request headers;
  - admin reason text and free-form support notes.
- Keep event names operational, not personal: `withdrawal_request_failed`,
  `casino_settlement_mismatch`, `pwa_offline_fallback_shown`.
- Use aggregated counters for product analytics. Do not record full URLs when
  they can contain identifiers.

## CI Secret Policy

- CI may read only the secrets required by the specific gate. Current allowed
  GitHub Actions secrets:
  - `SUPABASE_ACCESS_TOKEN` for the advisor gate.
  - `SUPABASE_PROJECT_ID`, which must equal `yocjhjsdwoijfdrehzoq`.
- Fork PRs without secrets must skip remote advisor checks and still run local
  typecheck, lint, tests, build, PWA checks, SQL reset, and Playwright gates.
- No CI job may deploy, push migrations, or launch remote Edge Functions before
  Wave 12 operator approval.

## Current Local Gates

- `bun run check:env`
- `bun run check:i18n`
- `bun run check:release`
- `bun run typecheck`
- `bun run lint`
- `bun run test`
- `bun run build`
- `bun run check:pwa`
- `supabase db reset`
- `bun run test:sql`
- `bun run test:e2e`
