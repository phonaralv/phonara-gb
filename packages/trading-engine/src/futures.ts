import { toFixed } from '@phonara/money';
import {
  Decimal,
  dec,
  fmt6,
  assertPositive,
  TradingError,
  DEFAULT_FEES,
  type FeeSchedule,
  type MarginCurrency,
  type PositionSide,
} from './shared';

// ─── Inputs / Outputs ──────────────────────────────────────────────────────

export interface OpenPositionParams {
  readonly side: PositionSide;
  readonly marginCurrency: MarginCurrency;
  /** collateral the user posts, in marginCurrency */
  readonly marginAmount: string;
  /** leverage multiplier, e.g. "10" */
  readonly leverage: string;
  /** entry mark price: marginCurrency units per 1 underlying unit */
  readonly entryPrice: string;
  /** maximum leverage permitted by the market */
  readonly maxLeverage: string;
  readonly fees?: FeeSchedule;
}

/**
 * A fully-computed position. All amounts are canonical decimal strings
 * in the position's margin currency, except `quantity` and prices which
 * keep full precision (they are derived, not settled balances).
 */
export interface ComputedPosition {
  readonly side: PositionSide;
  readonly marginCurrency: MarginCurrency;
  readonly marginAmount: string;
  readonly leverage: string;
  readonly entryPrice: string;
  /** notional = margin × leverage (margin currency) */
  readonly notional: string;
  /** quantity of underlying = notional / entryPrice */
  readonly quantity: string;
  /** fee charged at open (margin currency) */
  readonly openFee: string;
  /** price at which the position is liquidated */
  readonly liquidationPrice: string;
}

export interface ClosePositionParams {
  readonly position: ComputedPosition;
  /** mark price at close */
  readonly exitPrice: string;
  readonly fees?: FeeSchedule;
}

export interface PositionSettlement {
  readonly exitPrice: string;
  /** signed realized PnL before close fee (margin currency, may be negative) */
  readonly realizedPnl: string;
  /** fee charged at close (margin currency) */
  readonly closeFee: string;
  /**
   * equity returned to the wallet = margin + pnl − closeFee, floored at 0.
   * This is what gets credited back from the locked margin.
   */
  readonly equityReturned: string;
  /** true when equityReturned hit the zero floor (effectively liquidated) */
  readonly isWipeout: boolean;
  /** roi on margin = (equityReturned − margin) / margin, signed decimal string */
  readonly roi: string;
}

// ─── Open ────────────────────────────────────────────────────────────────────

/**
 * Computes a futures position from open parameters.
 *
 * notional      = margin × leverage
 * quantity      = notional / entryPrice
 * openFee       = notional × openFeeRate
 * liqPrice long  = entry × (1 − 1/leverage + mmr)
 * liqPrice short = entry × (1 + 1/leverage − mmr)
 */
export function computeOpenPosition(params: OpenPositionParams): ComputedPosition {
  const fees = params.fees ?? DEFAULT_FEES;

  if (params.side !== 'long' && params.side !== 'short') {
    throw new TradingError(`invalid side: ${String(params.side)}`, 'INVALID_SIDE');
  }

  const margin = dec(params.marginAmount, 'marginAmount');
  const leverage = dec(params.leverage, 'leverage');
  const entryPrice = dec(params.entryPrice, 'entryPrice');
  const maxLeverage = dec(params.maxLeverage, 'maxLeverage');
  const mmr = dec(fees.maintenanceMarginRate, 'maintenanceMarginRate');
  const openFeeRate = dec(fees.openFeeRate, 'openFeeRate');

  assertPositive(margin, 'marginAmount', 'INVALID_MARGIN');
  assertPositive(entryPrice, 'entryPrice', 'INVALID_PRICE');
  assertPositive(leverage, 'leverage', 'INVALID_LEVERAGE');

  if (leverage.lessThan(1)) {
    throw new TradingError('leverage must be >= 1', 'INVALID_LEVERAGE');
  }
  if (leverage.greaterThan(maxLeverage)) {
    throw new TradingError(
      `leverage ${params.leverage} exceeds market max ${params.maxLeverage}`,
      'LEVERAGE_TOO_HIGH',
    );
  }

  const notional = margin.mul(leverage);
  const quantity = notional.div(entryPrice);
  const openFee = notional.mul(openFeeRate);

  const invLev = new Decimal(1).div(leverage);
  const liqRaw =
    params.side === 'long'
      ? entryPrice.mul(new Decimal(1).minus(invLev).plus(mmr))
      : entryPrice.mul(new Decimal(1).plus(invLev).minus(mmr));
  // a short can never be liquidated below 0; clamp for safety
  const liquidationPrice = liqRaw.isNegative() ? new Decimal(0) : liqRaw;

  // quantity / entryPrice / liquidationPrice are NOT currency balances, but the
  // database persists them via `_fmt6` (trunc to 6dp). Quantize them here with the
  // SQL-mirroring `fmt6` so the engine open/settle math operates on the EXACT same
  // values the DB stores — otherwise TS settlement (full-precision qty) diverges
  // from SQL settlement (6dp stored qty). leverage is stored as-is in SQL (v_lev::TEXT).
  return {
    side: params.side,
    marginCurrency: params.marginCurrency,
    marginAmount: toFixed(margin, params.marginCurrency),
    leverage: leverage.toFixed(),
    entryPrice: fmt6(entryPrice),
    notional: toFixed(notional, params.marginCurrency),
    quantity: fmt6(quantity),
    openFee: toFixed(openFee, params.marginCurrency),
    liquidationPrice: fmt6(liquidationPrice),
  };
}

// ─── PnL ───────────────────────────────────────────────────────────────────

/**
 * Signed PnL in margin currency for a given exit price.
 * long:  quantity × (exit − entry)
 * short: quantity × (entry − exit)
 */
export function computePnl(
  side: PositionSide,
  quantity: string,
  entryPrice: string,
  exitPrice: string,
  marginCurrency: MarginCurrency,
): string {
  const qty = dec(quantity, 'quantity');
  const entry = dec(entryPrice, 'entryPrice');
  const exit = dec(exitPrice, 'exitPrice');

  const priceDelta = side === 'long' ? exit.minus(entry) : entry.minus(exit);
  const pnl = qty.mul(priceDelta);
  return toFixed(pnl, marginCurrency);
}

// ─── Close / Settlement ──────────────────────────────────────────────────────

/**
 * Settles a position at exitPrice. Returns the equity that should be
 * credited back to the wallet (margin + pnl − closeFee, floored at 0).
 */
export function computeCloseSettlement(params: ClosePositionParams): PositionSettlement {
  const fees = params.fees ?? DEFAULT_FEES;
  const { position } = params;

  const exitPrice = dec(params.exitPrice, 'exitPrice');
  assertPositive(exitPrice, 'exitPrice', 'INVALID_PRICE');

  const margin = dec(position.marginAmount, 'marginAmount');
  const qty = dec(position.quantity, 'quantity');
  const closeFeeRate = dec(fees.closeFeeRate, 'closeFeeRate');

  const realizedPnlRaw = (() => {
    const entry = dec(position.entryPrice, 'entryPrice');
    const priceDelta =
      position.side === 'long' ? exitPrice.minus(entry) : entry.minus(exitPrice);
    return qty.mul(priceDelta);
  })();

  const exitNotional = qty.mul(exitPrice);
  const closeFeeRaw = exitNotional.mul(closeFeeRate);

  const equityRaw = margin.plus(realizedPnlRaw).minus(closeFeeRaw);
  const isWipeout = equityRaw.lessThanOrEqualTo(0);
  const equity = isWipeout ? new Decimal(0) : equityRaw;

  const roiRaw = margin.isZero()
    ? new Decimal(0)
    : equity.minus(margin).div(margin);

  return {
    exitPrice: exitPrice.toFixed(),
    realizedPnl: toFixed(realizedPnlRaw, position.marginCurrency),
    closeFee: toFixed(closeFeeRaw, position.marginCurrency),
    equityReturned: toFixed(equity, position.marginCurrency),
    isWipeout,
    roi: roiRaw.toDecimalPlaces(6, Decimal.ROUND_DOWN).toFixed(),
  };
}

// ─── Liquidation check ───────────────────────────────────────────────────────

/**
 * Returns true when the mark price has reached/breached the liquidation price.
 * long:  markPrice <= liqPrice
 * short: markPrice >= liqPrice
 */
export function isLiquidatable(
  side: PositionSide,
  liquidationPrice: string,
  markPrice: string,
): boolean {
  const liq = dec(liquidationPrice, 'liquidationPrice');
  const mark = dec(markPrice, 'markPrice');
  return side === 'long' ? mark.lessThanOrEqualTo(liq) : mark.greaterThanOrEqualTo(liq);
}
