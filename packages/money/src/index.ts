import Decimal from 'decimal.js';
import type { Currency } from '@phonara/shared-types';
import './configure-decimal';

// ─── Core Types ──────────────────────────────────────────────────────────────

export interface MoneyAmount {
  readonly currency: Currency;
  readonly amount: string; // always a valid decimal string, never float
}

export interface RateSnapshot {
  readonly baseCurrency: Currency;
  readonly quoteCurrency: Currency;
  readonly rate: string; // decimal string
  readonly capturedAt: string; // ISO 8601
  readonly source: 'admin' | 'market' | 'system';
}

export interface ConvertResult {
  readonly input: MoneyAmount;
  readonly output: MoneyAmount;
  readonly rateSnapshot: RateSnapshot;
  readonly fee: MoneyAmount;
}

// ─── Decimal Places Per Currency ─────────────────────────────────────────────

const DECIMALS: Record<Currency, number> = {
  PHON: 6,
  USDT: 6,
  KRW: 0,
};

// ─── Guards ──────────────────────────────────────────────────────────────────

function assertValidDecimalString(value: string, label: string): void {
  if (!/^-?\d+(\.\d+)?$/.test(value)) {
    throw new Error(`[money] ${label} is not a valid decimal string: "${value}"`);
  }
}

function assertNonNegative(d: Decimal, label: string): void {
  if (d.isNegative()) {
    throw new Error(`[money] ${label} must not be negative`);
  }
}

// ─── Core Helpers ────────────────────────────────────────────────────────────

export function toDecimal(amount: string, label = 'amount'): Decimal {
  assertValidDecimalString(amount, label);
  return new Decimal(amount);
}

/**
 * Returns a canonical decimal string for the given currency,
 * truncated (not rounded) to the allowed decimal places.
 */
export function toFixed(amount: Decimal | string, currency: Currency): string {
  const d = typeof amount === 'string' ? toDecimal(amount) : amount;
  return d.toDecimalPlaces(DECIMALS[currency], Decimal.ROUND_DOWN).toFixed(DECIMALS[currency]);
}

export function money(amount: Decimal | string, currency: Currency): MoneyAmount {
  return { currency, amount: toFixed(amount, currency) };
}

// ─── Arithmetic ──────────────────────────────────────────────────────────────

export function add(a: MoneyAmount, b: MoneyAmount): MoneyAmount {
  if (a.currency !== b.currency) {
    throw new Error(`[money] add: currency mismatch (${a.currency} vs ${b.currency})`);
  }
  const result = toDecimal(a.amount).add(toDecimal(b.amount));
  return money(result, a.currency);
}

export function subtract(a: MoneyAmount, b: MoneyAmount): MoneyAmount {
  if (a.currency !== b.currency) {
    throw new Error(`[money] subtract: currency mismatch (${a.currency} vs ${b.currency})`);
  }
  const result = toDecimal(a.amount).sub(toDecimal(b.amount));
  return money(result, a.currency);
}

export function multiply(a: MoneyAmount, factor: string): MoneyAmount {
  assertValidDecimalString(factor, 'factor');
  const result = toDecimal(a.amount).mul(toDecimal(factor));
  return money(result, a.currency);
}

export function isGreaterThan(a: MoneyAmount, b: MoneyAmount): boolean {
  if (a.currency !== b.currency) {
    throw new Error(`[money] compare: currency mismatch`);
  }
  return toDecimal(a.amount).greaterThan(toDecimal(b.amount));
}

export function isGreaterThanOrEqual(a: MoneyAmount, b: MoneyAmount): boolean {
  if (a.currency !== b.currency) {
    throw new Error(`[money] compare: currency mismatch`);
  }
  return toDecimal(a.amount).greaterThanOrEqualTo(toDecimal(b.amount));
}

export function isZero(a: MoneyAmount): boolean {
  return toDecimal(a.amount).isZero();
}

export function isPositive(a: MoneyAmount): boolean {
  return toDecimal(a.amount).greaterThan(0);
}

export function zero(currency: Currency): MoneyAmount {
  return money('0', currency);
}

// ─── Fee Calculation ─────────────────────────────────────────────────────────

/**
 * Applies a percentage fee (e.g., "0.001" = 0.1%).
 * Fee is truncated (floor) to the amount's currency decimal places.
 * Returns both the fee and the net amount after deduction.
 */
export function applyFeeRate(
  amount: MoneyAmount,
  feeRateDecimal: string,
): { fee: MoneyAmount; net: MoneyAmount } {
  assertValidDecimalString(feeRateDecimal, 'feeRate');
  const rate = toDecimal(feeRateDecimal);
  assertNonNegative(rate, 'feeRate');

  const feeRaw = toDecimal(amount.amount).mul(rate);
  const fee = money(feeRaw, amount.currency);
  const net = subtract(amount, fee);
  return { fee, net };
}

// ─── FX Conversion ───────────────────────────────────────────────────────────

/**
 * Converts amount from one currency to another using a RateSnapshot.
 * rate = quoteCurrency per 1 baseCurrency  (e.g., PHON→USDT: "0.01")
 */
export function convert(amount: MoneyAmount, snapshot: RateSnapshot): ConvertResult {
  if (amount.currency !== snapshot.baseCurrency) {
    throw new Error(
      `[money] convert: amount currency (${amount.currency}) does not match snapshot base (${snapshot.baseCurrency})`,
    );
  }
  const rate = toDecimal(snapshot.rate);
  assertNonNegative(rate, 'rate');

  const outputRaw = toDecimal(amount.amount).mul(rate);
  const output = money(outputRaw, snapshot.quoteCurrency);
  const fee = zero(snapshot.quoteCurrency);

  return { input: amount, output, rateSnapshot: snapshot, fee };
}

/**
 * Converts amount with a fee applied to the output.
 */
export function convertWithFee(
  amount: MoneyAmount,
  snapshot: RateSnapshot,
  feeRateDecimal: string,
): ConvertResult {
  const base = convert(amount, snapshot);
  const { fee, net } = applyFeeRate(base.output, feeRateDecimal);
  return { ...base, output: net, fee };
}

// ─── Display Helpers ─────────────────────────────────────────────────────────

/**
 * Returns a human-readable decimal string without trailing zeros,
 * capped at the currency's maximum precision.
 */
export function format(amount: MoneyAmount): string {
  return toDecimal(amount.amount)
    .toDecimalPlaces(DECIMALS[amount.currency], Decimal.ROUND_DOWN)
    .toFixed();
}

export { configureDecimal, Decimal } from './configure-decimal';
export { DECIMALS };
