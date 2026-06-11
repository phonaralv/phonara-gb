import { configureDecimal, Decimal } from '@phonara/money';
import type { Currency } from '@phonara/shared-types';

configureDecimal();

// ─── Shared types ──────────────────────────────────────────────────────────

export type MarginCurrency = Extract<Currency, 'PHON' | 'USDT'>;
export type PositionSide = 'long' | 'short';

export interface FeeSchedule {
  /** taker fee on opening notional, decimal string e.g. "0.0006" = 0.06% */
  readonly openFeeRate: string;
  /** taker fee on closing notional, decimal string */
  readonly closeFeeRate: string;
  /** maintenance margin rate, decimal string e.g. "0.005" = 0.5% */
  readonly maintenanceMarginRate: string;
}

export const DEFAULT_FEES: FeeSchedule = {
  openFeeRate: '0.0006',
  closeFeeRate: '0.0006',
  maintenanceMarginRate: '0.005',
};

export class TradingError extends Error {
  constructor(
    message: string,
    public readonly code: TradingErrorCode,
  ) {
    super(`[trading] ${message}`);
    this.name = 'TradingError';
  }
}

export type TradingErrorCode =
  | 'INVALID_PRICE'
  | 'INVALID_MARGIN'
  | 'INVALID_LEVERAGE'
  | 'LEVERAGE_TOO_HIGH'
  | 'INVALID_SIDE'
  | 'INVALID_AMOUNT';

// ─── Internal guards ─────────────────────────────────────────────────────────

const DECIMAL_RE = /^-?\d+(\.\d+)?$/;

export function dec(value: string, label: string): Decimal {
  if (!DECIMAL_RE.test(value)) {
    throw new TradingError(`${label} is not a valid decimal string: "${value}"`, 'INVALID_AMOUNT');
  }
  return new Decimal(value);
}

export function assertPositive(d: Decimal, label: string, code: TradingErrorCode): void {
  if (!d.isFinite() || d.lessThanOrEqualTo(0)) {
    throw new TradingError(`${label} must be a positive finite number`, code);
  }
}

/**
 * Quantize to exactly 6 decimal places, truncated (ROUND_DOWN), with 6 fixed
 * fractional digits. This MIRRORS the SQL `_fmt6` helper
 * (`to_char(trunc(v, 6), 'FM999999999990.000000')`) byte-for-byte, so non-currency
 * engine outputs (quantity, prices, liquidation price) are stored and settled with
 * the SAME value the database persists. Currency amounts use `toFixed(_, currency)`
 * which is numerically identical for the 6dp PHON/USDT currencies.
 */
export function fmt6(value: Decimal | string): string {
  const d = typeof value === 'string' ? new Decimal(value) : value;
  return d.toDecimalPlaces(6, Decimal.ROUND_DOWN).toFixed(6);
}

export { Decimal };
