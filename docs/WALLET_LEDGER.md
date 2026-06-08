# Wallet Ledger

The wallet ledger is the financial backbone of PHONARA.

## Principles

- Append-only ledger entries.
- No direct untracked balance mutation.
- Explicit available and locked balances.
- Idempotent operations.
- Rate snapshots for FX-sensitive events.
- Auditability before convenience.

## Currencies

- PHON: platform token and reward currency.
- USDT: stable game/trading currency.
- KRW: Korean bank transfer display and settlement rail.

## Future Operations

- credit
- debit
- lock
- unlock
- reverse
- settle game bet
- settle trading position
- convert KRW deposit to PHON
- process withdrawal

Actual engine implementation must pause for model switch confirmation before coding begins.
