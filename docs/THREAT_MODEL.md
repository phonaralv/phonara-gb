# Threat Model

PHONARA handles rewards, wallets, trading, games, withdrawals, and admin operations. The system must assume adversarial behavior.

## Protected Assets

- User identity and sessions.
- PHON, USDT, and KRW balances.
- Wallet ledger history.
- Game fairness data.
- Trading positions and settlements.
- Admin privileges and audit logs.
- Support messages and attachments.

## High-Risk Areas

- Balance mutation.
- Withdrawal approval.
- Admin role escalation.
- RLS bypass.
- Service role key leakage.
- Game RNG manipulation.
- Replayed requests without idempotency.
- i18n or validation gaps causing user confusion in money flows.

## Baseline Controls

- RLS everywhere user data is involved.
- Atomic RPC for balance mutations.
- Append-only ledger.
- Idempotency keys.
- Audit logs for Admin and automation actions.
- Kill switches for money, trading, games, and rewards.
