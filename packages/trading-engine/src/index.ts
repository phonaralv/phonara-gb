import type { Currency } from '@phonara/shared-types';

export type TradingMarket = 'PHON_USDT';

export type PositionSide = 'long' | 'short';

export interface TradingPositionDraft {
  readonly market: TradingMarket;
  readonly side: PositionSide;
  readonly marginCurrency: Currency;
  readonly marginAmount: string;
  readonly leverage: string;
}

export const tradingEngineStatus = 'scaffold-only' as const;
