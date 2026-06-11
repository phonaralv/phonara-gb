import { describe, it, expect } from 'vitest';
import {
  computeOpenPosition,
  computePnl,
  computeCloseSettlement,
  isLiquidatable,
  TradingError,
  type ComputedPosition,
} from './index';

const baseMarket = { maxLeverage: '100' };

describe('computeOpenPosition', () => {
  it('computes notional, quantity, fee for a long', () => {
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '10',
      entryPrice: '100',
      ...baseMarket,
    });
    expect(pos.notional).toBe('1000.000000');
    expect(pos.quantity).toBe('10.000000');
    // openFee = 1000 × 0.0006 = 0.6
    expect(pos.openFee).toBe('0.600000');
  });

  it('computes long liquidation price (entry × (1 − 1/lev + mmr))', () => {
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '10',
      entryPrice: '100',
      ...baseMarket,
    });
    // 100 × (1 − 0.1 + 0.005) = 90.5
    expect(pos.liquidationPrice).toBe('90.500000');
  });

  it('computes short liquidation price (entry × (1 + 1/lev − mmr))', () => {
    const pos = computeOpenPosition({
      side: 'short',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '10',
      entryPrice: '100',
      ...baseMarket,
    });
    // 100 × (1 + 0.1 − 0.005) = 109.5
    expect(pos.liquidationPrice).toBe('109.500000');
  });

  it('rejects leverage above market max', () => {
    expect(() =>
      computeOpenPosition({
        side: 'long',
        marginCurrency: 'USDT',
        marginAmount: '100',
        leverage: '150',
        entryPrice: '100',
        maxLeverage: '100',
      }),
    ).toThrow(TradingError);
  });

  it('rejects non-positive margin and price', () => {
    expect(() =>
      computeOpenPosition({
        side: 'long',
        marginCurrency: 'USDT',
        marginAmount: '0',
        leverage: '10',
        entryPrice: '100',
        ...baseMarket,
      }),
    ).toThrow(TradingError);
    expect(() =>
      computeOpenPosition({
        side: 'long',
        marginCurrency: 'USDT',
        marginAmount: '100',
        leverage: '10',
        entryPrice: '0',
        ...baseMarket,
      }),
    ).toThrow(TradingError);
  });

  it('supports PHON margin', () => {
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'PHON',
      marginAmount: '5000',
      leverage: '5',
      entryPrice: '2',
      ...baseMarket,
    });
    expect(pos.marginCurrency).toBe('PHON');
    expect(pos.notional).toBe('25000.000000');
    expect(pos.quantity).toBe('12500.000000');
  });
});

describe('TS<->SQL 6dp parity (fmt6 mirrors SQL _fmt6)', () => {
  const SIX_DP = /^\d+\.\d{6}$/;

  it('emits quantity/entryPrice/liquidationPrice at exactly 6dp like the DB', () => {
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '10',
      entryPrice: '100',
      ...baseMarket,
    });
    expect(pos.quantity).toMatch(SIX_DP);
    expect(pos.entryPrice).toMatch(SIX_DP);
    expect(pos.liquidationPrice).toMatch(SIX_DP);
  });

  it('TRUNCATES (not rounds) quantity to 6dp exactly as SQL trunc(v,6)', () => {
    // notional/entry = 300/7 = 42.857142857142...  → SQL _fmt6 = '42.857142'
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '3',
      entryPrice: '7',
      ...baseMarket,
    });
    expect(pos.quantity).toBe('42.857142');
  });

  it('settlement consumes the 6dp-stored quantity (open→settle determinism)', () => {
    // A position whose raw quantity has >6dp; settlement must use the truncated qty
    // so TS PnL equals SQL PnL (which reads the stored 6dp quantity).
    const pos = computeOpenPosition({
      side: 'long',
      marginCurrency: 'USDT',
      marginAmount: '100',
      leverage: '3',
      entryPrice: '7',
      ...baseMarket,
    });
    // qty=42.857142 (truncated). pnl at exit 8 = 42.857142×(8−7)=42.857142
    const pnl = computePnl(pos.side, pos.quantity, pos.entryPrice, '8', 'USDT');
    expect(pnl).toBe('42.857142');
    const settle = computeCloseSettlement({ position: pos, exitPrice: '8' });
    expect(settle.realizedPnl).toBe('42.857142');
  });
});

describe('computePnl', () => {
  it('long profit', () => {
    expect(computePnl('long', '10', '100', '110', 'USDT')).toBe('100.000000');
  });
  it('long loss', () => {
    expect(computePnl('long', '10', '100', '90', 'USDT')).toBe('-100.000000');
  });
  it('short profit', () => {
    expect(computePnl('short', '10', '100', '90', 'USDT')).toBe('100.000000');
  });
  it('short loss', () => {
    expect(computePnl('short', '10', '100', '110', 'USDT')).toBe('-100.000000');
  });
});

describe('computeCloseSettlement', () => {
  const longPos: ComputedPosition = {
    side: 'long',
    marginCurrency: 'USDT',
    marginAmount: '100.000000',
    leverage: '10',
    entryPrice: '100',
    notional: '1000.000000',
    quantity: '10',
    openFee: '0.600000',
    liquidationPrice: '90.5',
  };

  it('settles a winning long (margin + pnl − closeFee)', () => {
    const s = computeCloseSettlement({ position: longPos, exitPrice: '110' });
    // pnl = 100, exitNotional = 1100, closeFee = 0.66
    expect(s.realizedPnl).toBe('100.000000');
    expect(s.closeFee).toBe('0.660000');
    expect(s.equityReturned).toBe('199.340000');
    expect(s.isWipeout).toBe(false);
    expect(s.roi).toBe('0.9934');
  });

  it('floors equity at 0 on wipeout (loss exceeds margin)', () => {
    const s = computeCloseSettlement({ position: longPos, exitPrice: '80' });
    // pnl = 10×(80−100) = −200 → equity floored to 0
    expect(s.realizedPnl).toBe('-200.000000');
    expect(s.isWipeout).toBe(true);
    expect(s.equityReturned).toBe('0.000000');
    expect(s.roi).toBe('-1');
  });

  it('settles a losing-but-not-wiped long', () => {
    const s = computeCloseSettlement({ position: longPos, exitPrice: '95' });
    // pnl = 10×(95−100) = −50; exitNotional=950; closeFee=0.57
    expect(s.realizedPnl).toBe('-50.000000');
    expect(s.closeFee).toBe('0.570000');
    expect(s.equityReturned).toBe('49.430000');
    expect(s.isWipeout).toBe(false);
  });
});

describe('isLiquidatable', () => {
  it('long liquidates when mark <= liqPrice', () => {
    expect(isLiquidatable('long', '90.5', '91')).toBe(false);
    expect(isLiquidatable('long', '90.5', '90.5')).toBe(true);
    expect(isLiquidatable('long', '90.5', '90')).toBe(true);
  });
  it('short liquidates when mark >= liqPrice', () => {
    expect(isLiquidatable('short', '109.5', '109')).toBe(false);
    expect(isLiquidatable('short', '109.5', '109.5')).toBe(true);
    expect(isLiquidatable('short', '109.5', '110')).toBe(true);
  });
});
