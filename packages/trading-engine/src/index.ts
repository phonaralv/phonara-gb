// ─── PHONARA Trading Engine ──────────────────────────────────────────────────
// Pure, side-effect-free financial math for Spot, Futures and Staking.
// All settlement boundaries return canonical decimal strings via @phonara/money.
// Supabase Atomic RPCs mirror this logic in SQL.

export {
  TradingError,
  DEFAULT_FEES,
  type FeeSchedule,
  type MarginCurrency,
  type PositionSide,
  type TradingErrorCode,
} from './shared';

export {
  computeOpenPosition,
  computePnl,
  computeCloseSettlement,
  isLiquidatable,
  type OpenPositionParams,
  type ComputedPosition,
  type ClosePositionParams,
  type PositionSettlement,
} from './futures';

export {
  computeSpotBuy,
  computeSpotSell,
  DEFAULT_SPOT_FEE,
  type SpotQuoteParams,
  type SpotBuyParams,
  type SpotSellParams,
  type SpotBuyResult,
  type SpotSellResult,
} from './spot';

export {
  estimateStakingReward,
  computeAccruedReward,
  canUnstake,
  DEFAULT_STAKING_TERMS,
  type StakingTerm,
  type StakingTermConfig,
  type RewardEstimateParams,
  type RewardEstimate,
} from './staking';

export const TRADING_MARKETS = ['PHONUSDT-PERP', 'BTCUSDT-SIM', 'ETHUSDT-SIM'] as const;
export type TradingMarketSymbol = (typeof TRADING_MARKETS)[number];

export const SPOT_MARKETS = ['PHON_USDT'] as const;
export type SpotMarketSymbol = (typeof SPOT_MARKETS)[number];
