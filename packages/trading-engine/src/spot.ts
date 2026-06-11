import { toFixed } from '@phonara/money';
import {
  type Decimal,
  dec,
  assertPositive,
  TradingError,
} from './shared';

// ─── Spot market: PHON/USDT ──────────────────────────────────────────────────
// Convention: price = USDT per 1 PHON.
// Buy:  spend USDT  → receive PHON
// Sell: spend PHON  → receive USDT
// Fee is charged on the OUTPUT asset.

export interface SpotQuoteParams {
  /** USDT per 1 PHON */
  readonly price: string;
  /** fee rate on output, decimal string e.g. "0.001" = 0.1% */
  readonly feeRate: string;
}

export interface SpotBuyParams extends SpotQuoteParams {
  /** USDT the user spends */
  readonly usdtSpent: string;
}

export interface SpotSellParams extends SpotQuoteParams {
  /** PHON the user sells */
  readonly phonSold: string;
}

export interface SpotBuyResult {
  readonly usdtSpent: string;
  readonly price: string;
  /** PHON before fee */
  readonly grossPhon: string;
  /** fee in PHON */
  readonly feePhon: string;
  /** PHON credited to wallet after fee */
  readonly netPhon: string;
}

export interface SpotSellResult {
  readonly phonSold: string;
  readonly price: string;
  /** USDT before fee */
  readonly grossUsdt: string;
  /** fee in USDT */
  readonly feeUsdt: string;
  /** USDT credited to wallet after fee */
  readonly netUsdt: string;
}

const DEFAULT_SPOT_FEE = '0.001';

function validate(price: Decimal, feeRate: Decimal): void {
  assertPositive(price, 'price', 'INVALID_PRICE');
  if (feeRate.isNegative() || feeRate.greaterThanOrEqualTo(1)) {
    throw new TradingError('feeRate must be in [0, 1)', 'INVALID_AMOUNT');
  }
}

/** Market buy: spend USDT, receive PHON (fee deducted from PHON). */
export function computeSpotBuy(params: SpotBuyParams): SpotBuyResult {
  const price = dec(params.price, 'price');
  const feeRate = dec(params.feeRate || DEFAULT_SPOT_FEE, 'feeRate');
  const usdt = dec(params.usdtSpent, 'usdtSpent');
  assertPositive(usdt, 'usdtSpent', 'INVALID_AMOUNT');
  validate(price, feeRate);

  const grossPhon = usdt.div(price);
  const feePhon = grossPhon.mul(feeRate);
  const netPhon = grossPhon.minus(feePhon);

  return {
    usdtSpent: toFixed(usdt, 'USDT'),
    price: price.toFixed(),
    grossPhon: toFixed(grossPhon, 'PHON'),
    feePhon: toFixed(feePhon, 'PHON'),
    netPhon: toFixed(netPhon, 'PHON'),
  };
}

/** Market sell: spend PHON, receive USDT (fee deducted from USDT). */
export function computeSpotSell(params: SpotSellParams): SpotSellResult {
  const price = dec(params.price, 'price');
  const feeRate = dec(params.feeRate || DEFAULT_SPOT_FEE, 'feeRate');
  const phon = dec(params.phonSold, 'phonSold');
  assertPositive(phon, 'phonSold', 'INVALID_AMOUNT');
  validate(price, feeRate);

  const grossUsdt = phon.mul(price);
  const feeUsdt = grossUsdt.mul(feeRate);
  const netUsdt = grossUsdt.minus(feeUsdt);

  return {
    phonSold: toFixed(phon, 'PHON'),
    price: price.toFixed(),
    grossUsdt: toFixed(grossUsdt, 'USDT'),
    feeUsdt: toFixed(feeUsdt, 'USDT'),
    netUsdt: toFixed(netUsdt, 'USDT'),
  };
}

export { DEFAULT_SPOT_FEE };
