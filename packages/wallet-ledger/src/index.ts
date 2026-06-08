import type { Currency, LedgerDirection } from '@phonara/shared-types';
import { add, subtract, isGreaterThanOrEqual, money, zero, isPositive } from '@phonara/money';
import type { MoneyAmount } from '@phonara/money';

// ─── Core Types ──────────────────────────────────────────────────────────────

export interface WalletBalance {
  readonly currency: Currency;
  readonly available: string; // decimal string
  readonly locked: string;    // decimal string
}

export interface WalletSnapshot {
  readonly walletId: string;
  readonly balances: readonly WalletBalance[];
}

/**
 * An immutable ledger entry — never updated, only appended.
 * Mirrors the shape that will be stored in Supabase wallet_ledger.
 */
export interface LedgerEntry {
  readonly id: string;
  readonly walletId: string;
  readonly idempotencyKey: string;
  readonly direction: LedgerDirection;
  readonly currency: Currency;
  readonly amount: string;        // always positive decimal string
  readonly balanceBefore: WalletBalance;
  readonly balanceAfter: WalletBalance;
  readonly reasonCode: string;
  readonly relatedEntityId?: string;
  readonly rateSnapshotId?: string;
  readonly createdAt: string;     // ISO 8601
}

/**
 * Command shape used to request a ledger mutation.
 * Server / RPC validates and applies this atomically.
 */
export interface LedgerCommand {
  readonly walletId: string;
  readonly idempotencyKey: string;
  readonly direction: LedgerDirection;
  readonly currency: Currency;
  readonly amount: string;
  readonly reasonCode: string;
  readonly relatedEntityId?: string;
  readonly rateSnapshotId?: string;
}

// ─── Error types ─────────────────────────────────────────────────────────────

export class LedgerError extends Error {
  constructor(
    message: string,
    public readonly code: LedgerErrorCode,
  ) {
    super(`[ledger] ${message}`);
    this.name = 'LedgerError';
  }
}

export type LedgerErrorCode =
  | 'INSUFFICIENT_AVAILABLE'
  | 'INSUFFICIENT_LOCKED'
  | 'INVALID_AMOUNT'
  | 'CURRENCY_MISMATCH'
  | 'INVALID_DIRECTION';

// ─── Pure Balance Mutation (no I/O) ──────────────────────────────────────────

/**
 * Applies a ledger direction to an in-memory WalletBalance.
 * This is the pure function that Supabase RPC will mirror in SQL.
 *
 * credit:  available += amount
 * debit:   available -= amount  (requires available >= amount)
 * lock:    available -= amount, locked += amount
 * unlock:  locked -= amount, available += amount
 * reverse: available += amount  (reversal of a prior debit)
 */
export function applyLedgerEntry(
  balance: WalletBalance,
  direction: LedgerDirection,
  amount: MoneyAmount,
): WalletBalance {
  if (amount.currency !== balance.currency) {
    throw new LedgerError(
      `currency mismatch: balance is ${balance.currency}, entry is ${amount.currency}`,
      'CURRENCY_MISMATCH',
    );
  }
  if (!isPositive(amount)) {
    throw new LedgerError('amount must be positive', 'INVALID_AMOUNT');
  }

  const available = money(balance.available, balance.currency);
  const locked = money(balance.locked, balance.currency);

  switch (direction) {
    case 'credit': {
      return {
        ...balance,
        available: add(available, amount).amount,
      };
    }
    case 'debit': {
      if (!isGreaterThanOrEqual(available, amount)) {
        throw new LedgerError(
          `insufficient available: have ${balance.available}, need ${amount.amount}`,
          'INSUFFICIENT_AVAILABLE',
        );
      }
      return {
        ...balance,
        available: subtract(available, amount).amount,
      };
    }
    case 'lock': {
      if (!isGreaterThanOrEqual(available, amount)) {
        throw new LedgerError(
          `insufficient available to lock: have ${balance.available}, need ${amount.amount}`,
          'INSUFFICIENT_AVAILABLE',
        );
      }
      return {
        ...balance,
        available: subtract(available, amount).amount,
        locked: add(locked, amount).amount,
      };
    }
    case 'unlock': {
      if (!isGreaterThanOrEqual(locked, amount)) {
        throw new LedgerError(
          `insufficient locked to unlock: have ${balance.locked}, need ${amount.amount}`,
          'INSUFFICIENT_LOCKED',
        );
      }
      return {
        ...balance,
        locked: subtract(locked, amount).amount,
        available: add(available, amount).amount,
      };
    }
    case 'reverse': {
      return {
        ...balance,
        available: add(available, amount).amount,
      };
    }
    default: {
      throw new LedgerError(`unknown direction: ${String(direction)}`, 'INVALID_DIRECTION');
    }
  }
}

// ─── Balance Helpers ─────────────────────────────────────────────────────────

export function totalBalance(balance: WalletBalance): MoneyAmount {
  return add(
    money(balance.available, balance.currency),
    money(balance.locked, balance.currency),
  );
}

export function emptyBalance(currency: Currency): WalletBalance {
  return {
    currency,
    available: zero(currency).amount,
    locked: zero(currency).amount,
  };
}

export function getBalance(snapshot: WalletSnapshot, currency: Currency): WalletBalance {
  return (
    snapshot.balances.find((b) => b.currency === currency) ?? emptyBalance(currency)
  );
}
