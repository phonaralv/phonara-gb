import { describe, it, expect } from 'vitest';
import {
  money,
  add,
  subtract,
  multiply,
  applyFeeRate,
  convert,
  convertWithFee,
  isGreaterThan,
  isGreaterThanOrEqual,
  isZero,
  isPositive,
  zero,
  format,
  toFixed,
  toDecimal,
} from './index';
import type { RateSnapshot } from './index';

// ─── Helpers ─────────────────────────────────────────────────────────────────

const phon = (a: string) => money(a, 'PHON');
const usdt = (a: string) => money(a, 'USDT');
const krw = (a: string) => money(a, 'KRW');

const phonUsdtRate = (rate: string): RateSnapshot => ({
  baseCurrency: 'PHON',
  quoteCurrency: 'USDT',
  rate,
  capturedAt: '2026-06-09T00:00:00Z',
  source: 'admin',
});

const usdtKrwRate = (rate: string): RateSnapshot => ({
  baseCurrency: 'USDT',
  quoteCurrency: 'KRW',
  rate,
  capturedAt: '2026-06-09T00:00:00Z',
  source: 'market',
});

// ─── money() / toFixed() ─────────────────────────────────────────────────────

describe('money construction', () => {
  it('normalises PHON to 6 decimal places', () => {
    expect(phon('1').amount).toBe('1.000000');
  });

  it('normalises KRW to 0 decimal places', () => {
    expect(krw('1300.9').amount).toBe('1300');
  });

  it('truncates (does not round up) excess precision', () => {
    // 1.9999999 truncated to 6 dp = 1.999999 (not 2.000000)
    expect(phon('1.9999999').amount).toBe('1.999999');
  });

  it('throws on non-numeric string', () => {
    expect(() => money('abc', 'PHON')).toThrow('[money]');
  });
});

// ─── Arithmetic ──────────────────────────────────────────────────────────────

describe('add', () => {
  it('adds two PHON amounts', () => {
    expect(add(phon('1.5'), phon('2.5')).amount).toBe('4.000000');
  });

  it('throws on currency mismatch', () => {
    expect(() => add(phon('1'), usdt('1'))).toThrow('mismatch');
  });
});

describe('subtract', () => {
  it('subtracts correctly', () => {
    expect(subtract(phon('10'), phon('3.5')).amount).toBe('6.500000');
  });

  it('produces negative result (caller must guard)', () => {
    const result = subtract(phon('1'), phon('2'));
    expect(result.amount).toBe('-1.000000');
  });
});

describe('multiply', () => {
  it('multiplies PHON by a factor', () => {
    expect(multiply(phon('100'), '0.5').amount).toBe('50.000000');
  });

  it('throws on invalid factor', () => {
    expect(() => multiply(phon('1'), 'x')).toThrow('[money]');
  });
});

// ─── Comparisons ─────────────────────────────────────────────────────────────

describe('comparisons', () => {
  it('isGreaterThan returns true when a > b', () => {
    expect(isGreaterThan(phon('2'), phon('1'))).toBe(true);
  });

  it('isGreaterThan returns false when a === b', () => {
    expect(isGreaterThan(phon('1'), phon('1'))).toBe(false);
  });

  it('isGreaterThanOrEqual returns true when equal', () => {
    expect(isGreaterThanOrEqual(phon('1'), phon('1'))).toBe(true);
  });

  it('isZero detects zero', () => {
    expect(isZero(phon('0'))).toBe(true);
    expect(isZero(phon('0.000001'))).toBe(false);
  });

  it('isPositive', () => {
    expect(isPositive(phon('0.000001'))).toBe(true);
    expect(isPositive(phon('0'))).toBe(false);
  });

  it('zero() returns canonical zero', () => {
    expect(zero('PHON').amount).toBe('0.000000');
    expect(zero('KRW').amount).toBe('0');
  });
});

// ─── Fee Calculation ─────────────────────────────────────────────────────────

describe('applyFeeRate', () => {
  it('calculates 0.1% fee on 1000 PHON', () => {
    const { fee, net } = applyFeeRate(phon('1000'), '0.001');
    expect(fee.amount).toBe('1.000000');
    expect(net.amount).toBe('999.000000');
  });

  it('fee + net equals original (within truncation)', () => {
    const original = phon('100.123456');
    const { fee, net } = applyFeeRate(original, '0.003');
    // fee = 100.123456 * 0.003 = 0.300370368 → truncated = 0.300370
    // net = 100.123456 - 0.300370 = 99.823086
    const reconstructed = add(fee, net);
    // they sum back to original (minus truncation dust — net is also truncated)
    expect(toDecimal(reconstructed.amount).lessThanOrEqualTo(toDecimal(original.amount))).toBe(true);
  });

  it('throws on negative fee rate', () => {
    expect(() => applyFeeRate(phon('100'), '-0.001')).toThrow('[money]');
  });
});

// ─── FX Conversion ───────────────────────────────────────────────────────────

describe('convert', () => {
  it('converts 1000 PHON to USDT at 0.01 rate', () => {
    const result = convert(phon('1000'), phonUsdtRate('0.01'));
    // 1000 * 0.01 = 10.000000 USDT
    expect(result.output.currency).toBe('USDT');
    expect(result.output.amount).toBe('10.000000');
    expect(isZero(result.fee)).toBe(true);
  });

  it('converts USDT to KRW at 1300 rate', () => {
    const result = convert(usdt('10'), usdtKrwRate('1300'));
    // 10 * 1300 = 13000 KRW
    expect(result.output.currency).toBe('KRW');
    expect(result.output.amount).toBe('13000');
  });

  it('throws when amount currency mismatches snapshot base', () => {
    expect(() => convert(usdt('100'), phonUsdtRate('0.01'))).toThrow('[money] convert');
  });
});

describe('convertWithFee', () => {
  it('deducts 0.5% fee from output', () => {
    const result = convertWithFee(phon('1000'), phonUsdtRate('0.01'), '0.005');
    // gross output: 10 USDT; fee: 0.050000 USDT; net: 9.950000 USDT
    expect(result.output.amount).toBe('9.950000');
    expect(result.fee.amount).toBe('0.050000');
  });
});

// ─── Display ─────────────────────────────────────────────────────────────────

describe('format', () => {
  it('strips trailing zeros for display', () => {
    expect(format(phon('10.500000'))).toBe('10.5');
    expect(format(krw('1300'))).toBe('1300');
  });
});

// ─── Float safety ────────────────────────────────────────────────────────────

describe('float safety', () => {
  it('0.1 + 0.2 equals 0.3 exactly (no float drift)', () => {
    const result = add(phon('0.1'), phon('0.2'));
    expect(result.amount).toBe('0.300000');
  });

  it('large numbers do not lose precision', () => {
    const a = phon('999999.999999');
    const b = phon('0.000001');
    expect(add(a, b).amount).toBe('1000000.000000');
  });
});
