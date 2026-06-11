import { toDecimal } from '@phonara/money';

// Decimal-safe helpers for UI logic. Per rule 30, monetary values, rates and PnL
// must never be run through JS `Number()`/float arithmetic — even for display or
// sign checks. These wrap decimal.js (via @phonara/money) so the UI stays exact.

const DECIMAL_RE = /^-?\d+(\.\d+)?$/;

/** True when `value` is a well-formed decimal string strictly greater than 0. */
export function isPositiveAmount(value: string): boolean {
  if (!DECIMAL_RE.test(value)) return false;
  return toDecimal(value).greaterThan(0);
}

/** True when `value` is a well-formed decimal string strictly less than 0. */
export function isNegativeAmount(value: string): boolean {
  if (!DECIMAL_RE.test(value)) return false;
  return toDecimal(value).isNegative();
}

/** Exact decimal sum of canonical amount strings; returns a canonical decimal string. */
export function sumAmounts(values: readonly string[]): string {
  return values
    .reduce((acc, v) => (DECIMAL_RE.test(v) ? acc.add(toDecimal(v)) : acc), toDecimal('0'))
    .toFixed();
}

/**
 * Converts a rate decimal string (e.g. "0.12") to a percentage string with `dp`
 * fractional digits (e.g. "12"), without float arithmetic.
 */
export function ratePercent(rate: string, dp = 0): string {
  if (!DECIMAL_RE.test(rate)) return '0';
  return toDecimal(rate).mul(100).toDecimalPlaces(dp).toFixed(dp);
}
