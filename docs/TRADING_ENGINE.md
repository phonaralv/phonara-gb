# Trading Engine

Trading is simulated and internally settled on PHONARA ledger infrastructure.

## Initial Scope

- PHON/USDT spot.
- Simulated long/short positions.
- PnL calculation.
- Liquidation policy draft.
- Fees and funding policy candidates.
- Staking stake/unstake/claim.

## Rules

- Decimal math only.
- No UI-first trading logic.
- Engine tests before trading UI.
- Ledger settlement must be atomic and auditable.

Actual trading engine implementation must pause for model switch confirmation before coding begins.
