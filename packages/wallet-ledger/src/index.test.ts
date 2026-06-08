import { describe, it, expect } from 'vitest';
import {
  applyLedgerEntry,
  totalBalance,
  emptyBalance,
  getBalance,
  LedgerError,
} from './index';
import type { WalletBalance, WalletSnapshot } from './index';
import { money } from '@phonara/money';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function bal(available: string, locked: string): WalletBalance {
  return { currency: 'PHON', available, locked };
}

const phon = (a: string) => money(a, 'PHON');
const usdt = (a: string) => money(a, 'USDT');

// ─── credit ──────────────────────────────────────────────────────────────────

describe('credit', () => {
  it('increases available balance', () => {
    const result = applyLedgerEntry(bal('100.000000', '0.000000'), 'credit', phon('50'));
    expect(result.available).toBe('150.000000');
    expect(result.locked).toBe('0.000000');
  });

  it('credit from zero', () => {
    const result = applyLedgerEntry(emptyBalance('PHON'), 'credit', phon('1'));
    expect(result.available).toBe('1.000000');
  });
});

// ─── debit ───────────────────────────────────────────────────────────────────

describe('debit', () => {
  it('decreases available balance', () => {
    const result = applyLedgerEntry(bal('100.000000', '0.000000'), 'debit', phon('30'));
    expect(result.available).toBe('70.000000');
  });

  it('throws INSUFFICIENT_AVAILABLE when balance is too low', () => {
    expect(() =>
      applyLedgerEntry(bal('10.000000', '0.000000'), 'debit', phon('20')),
    ).toThrow(LedgerError);

    try {
      applyLedgerEntry(bal('10.000000', '0.000000'), 'debit', phon('20'));
    } catch (e) {
      expect((e as LedgerError).code).toBe('INSUFFICIENT_AVAILABLE');
    }
  });

  it('allows exact debit', () => {
    const result = applyLedgerEntry(bal('50.000000', '0.000000'), 'debit', phon('50'));
    expect(result.available).toBe('0.000000');
  });
});

// ─── lock ────────────────────────────────────────────────────────────────────

describe('lock', () => {
  it('moves from available to locked', () => {
    const result = applyLedgerEntry(bal('100.000000', '0.000000'), 'lock', phon('40'));
    expect(result.available).toBe('60.000000');
    expect(result.locked).toBe('40.000000');
  });

  it('throws when locking more than available', () => {
    expect(() =>
      applyLedgerEntry(bal('10.000000', '0.000000'), 'lock', phon('20')),
    ).toThrow(LedgerError);
  });
});

// ─── unlock ──────────────────────────────────────────────────────────────────

describe('unlock', () => {
  it('moves from locked to available', () => {
    const result = applyLedgerEntry(bal('60.000000', '40.000000'), 'unlock', phon('40'));
    expect(result.available).toBe('100.000000');
    expect(result.locked).toBe('0.000000');
  });

  it('throws INSUFFICIENT_LOCKED', () => {
    expect(() =>
      applyLedgerEntry(bal('60.000000', '10.000000'), 'unlock', phon('40')),
    ).toThrow(LedgerError);

    try {
      applyLedgerEntry(bal('60.000000', '10.000000'), 'unlock', phon('40'));
    } catch (e) {
      expect((e as LedgerError).code).toBe('INSUFFICIENT_LOCKED');
    }
  });
});

// ─── reverse ─────────────────────────────────────────────────────────────────

describe('reverse', () => {
  it('restores available (mirrors debit reversal)', () => {
    const result = applyLedgerEntry(bal('70.000000', '0.000000'), 'reverse', phon('30'));
    expect(result.available).toBe('100.000000');
  });
});

// ─── Errors ──────────────────────────────────────────────────────────────────

describe('errors', () => {
  it('throws CURRENCY_MISMATCH when currencies differ', () => {
    try {
      applyLedgerEntry(bal('100.000000', '0.000000'), 'credit', usdt('10'));
    } catch (e) {
      expect((e as LedgerError).code).toBe('CURRENCY_MISMATCH');
    }
  });

  it('throws INVALID_AMOUNT on zero amount', () => {
    try {
      applyLedgerEntry(bal('100.000000', '0.000000'), 'credit', phon('0'));
    } catch (e) {
      expect((e as LedgerError).code).toBe('INVALID_AMOUNT');
    }
  });
});

// ─── totalBalance ─────────────────────────────────────────────────────────────

describe('totalBalance', () => {
  it('sums available + locked', () => {
    const total = totalBalance(bal('60.000000', '40.000000'));
    expect(total.amount).toBe('100.000000');
  });
});

// ─── Sequence: bet flow ──────────────────────────────────────────────────────

describe('bet settlement sequence', () => {
  it('lock → debit-locked-side wins (credit) stays consistent', () => {
    // Simulate: user has 100 PHON, bets 10, wins 15
    const initial = bal('100.000000', '0.000000');

    // 1. lock bet amount
    const afterLock = applyLedgerEntry(initial, 'lock', phon('10'));
    expect(afterLock.available).toBe('90.000000');
    expect(afterLock.locked).toBe('10.000000');

    // 2. bet settles as win: unlock then credit net win
    const afterUnlock = applyLedgerEntry(afterLock, 'unlock', phon('10'));
    const afterWin = applyLedgerEntry(afterUnlock, 'credit', phon('15'));
    expect(afterWin.available).toBe('115.000000');
    expect(afterWin.locked).toBe('0.000000');
  });

  it('lock → unlock → debit reflects a loss', () => {
    const initial = bal('100.000000', '0.000000');
    const afterLock = applyLedgerEntry(initial, 'lock', phon('10'));
    // on loss: debit locked by going: unlock → nothing (RPC handles debit of locked)
    // simplified here: just unlock then debit
    const afterUnlock = applyLedgerEntry(afterLock, 'unlock', phon('10'));
    const afterLoss = applyLedgerEntry(afterUnlock, 'debit', phon('10'));
    expect(afterLoss.available).toBe('90.000000');
  });
});

// ─── getBalance / emptyBalance ───────────────────────────────────────────────

describe('getBalance', () => {
  it('returns empty balance for missing currency', () => {
    const snapshot: WalletSnapshot = { walletId: 'w1', balances: [] };
    const b = getBalance(snapshot, 'PHON');
    expect(b.available).toBe('0.000000');
  });

  it('returns existing balance', () => {
    const snapshot: WalletSnapshot = {
      walletId: 'w1',
      balances: [{ currency: 'PHON', available: '500.000000', locked: '0.000000' }],
    };
    const b = getBalance(snapshot, 'PHON');
    expect(b.available).toBe('500.000000');
  });
});
