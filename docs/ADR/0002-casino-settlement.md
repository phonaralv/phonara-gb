# ADR-0002: Casino Atomic Settlement

## Status

Accepted. Applies to Phase 4 casino settlement from migration `20260609000029_s3_casino_atomic_settlement.sql`.

## Context

Casino betting moves PHON and USDT balances and must preserve provable fairness, ledger conservation, replay safety, and operator controls. The earlier `000028` schema established the tables and a scaffold flow, but a separate settlement path would split authority between application code and SQL.

## Decision

Casino settlement is atomic in SQL. `rpc_place_game_bet` validates, locks, computes the game result from the committed server seed, settles wallet and house legs, writes the result, and closes the round in one transaction.

The fixed ADR set is:

- ADR-001: SQL is settlement authority. TypeScript remains the development, UI, and verification path. If parity input is supplied and mismatches SQL, the bet enters `parity_hold`, the affected `feature_game_<code>_enabled` flag is disabled, and a `parity_mismatch` audit row is written.
- ADR-002: One bet is settled per round for Phase 4 one-shot games. Mines sessions and Live Crash remain Phase 4.5.
- ADR-003: Phase 4 ships six one-shot games; Phase 4.5 adds session/live behavior without blocking launch.
- ADR-004: No Edge casino settlement worker. Settlement happens inside `rpc_place_game_bet`.
- ADR-005: `game_house_phon` and `game_house_usdt` are casino house counterparties. Insurance remains separate. Solvency is enforced at the Wave 9 withdrawal gate, not per bet.
- ADR-006: `_assert_game_exposure_cap` protects max payout, Limbo max target, and game/house exposure before accepting a bet.
- ADR-007: With real users at zero, local casino migrations remain batchable to Wave 12. If any real user appears before Wave 12, live hardening escalates before remote changes.

## Consequences

- `rpc_place_game_bet` has exactly six entry guards: `_assert_amount_text`, `_fmt6` quantization, token-bucket rate limit, min/max stake, global plus per-game feature/consent gates, and `_assert_game_exposure_cap`.
- `server_seed` is stored in protected table columns and exposed only after terminal settlement through `rpc_reveal_game_round`.
- Public round reads use `v_game_rounds_public`; direct `game_rounds` table SELECT is revoked from `anon` and `authenticated`.
- Stale pending bets are swept by pg_cron after `casino_stale_pending_minutes`, excluding `parity_hold`.
- Admin void requires an authenticated admin, a reason, and an audit row.
- User wallets never go negative; system accounts may go negative to preserve settlement liveness.

## Validation

- `supabase db reset` applies through `000029`.
- `bun run test:sql` covers atomic settlement, Σ=0, house leg, idempotency scope, seed hash mismatch, exposure cap rejection, parity hold and kill switch, stale sweep, reveal, and privilege locks.
- `supabase db lint --local` reports no new 000029 lint warnings after cleanup; remaining warnings are pre-existing functions outside this ADR.
