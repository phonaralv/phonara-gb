import Decimal from 'decimal.js';

/** Money / payout quantization — 6 decimal places, ROUND_DOWN (matches SQL _fmt6). */
export function quantize6(value: Decimal | string | number): Decimal {
  return new Decimal(value).toDecimalPlaces(6, Decimal.ROUND_DOWN);
}

export function quantize6String(value: Decimal | string | number): string {
  return quantize6(value).toFixed(6);
}
