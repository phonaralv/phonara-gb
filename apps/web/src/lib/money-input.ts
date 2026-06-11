import { toDecimal } from '@phonara/money';

const DECIMAL_AMOUNT_RE = /^\d+(\.\d+)?$/;

export interface NormalizeDecimalInputOptions {
  maxFractionDigits?: number;
  allowDecimal?: boolean;
}

/**
 * Normalizes browser text input for decimal amounts at the UI boundary.
 * Exponent notation is intentionally dropped so money never enters the app as
 * a JS-number-shaped string such as `1e6`.
 */
export function normalizeDecimalInput(
  value: string,
  { maxFractionDigits = 7, allowDecimal = true }: NormalizeDecimalInputOptions = {},
): string {
  let next = '';
  let sawDot = false;

  for (const char of value.trim()) {
    if (char >= '0' && char <= '9') {
      next += char;
      continue;
    }
    if (allowDecimal && char === '.' && !sawDot) {
      next += char;
      sawDot = true;
    }
  }

  if (!allowDecimal) return next;
  if (next.startsWith('.')) next = `0${next}`;

  const [intPart = '', fractionPart] = next.split('.');
  if (fractionPart === undefined) return intPart;
  return `${intPart}.${fractionPart.slice(0, maxFractionDigits)}`;
}

export function isPositiveDecimalInput(value: string): boolean {
  if (!DECIMAL_AMOUNT_RE.test(value)) return false;
  return toDecimal(value).greaterThan(0);
}
