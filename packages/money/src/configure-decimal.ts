import Decimal from 'decimal.js';

/** Single shared Decimal.js configuration for all @phonara money paths. */
export function configureDecimal(): void {
  Decimal.set({ precision: 28, rounding: Decimal.ROUND_HALF_UP });
}

configureDecimal();

export { Decimal };
