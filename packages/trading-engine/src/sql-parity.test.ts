import { describe, it, expect } from 'vitest';
import { Decimal } from '@phonara/money';
import { computeOpenPosition, computeCloseSettlement, isLiquidatable, TradingError } from './index';

// ─────────────────────────────────────────────────────────────────────────────
// TS ↔ SQL parity lock.
//
// These inputs and expected constants MUST stay byte-for-byte identical to
// `supabase/tests/futures_parity_test.sql`, which drives the real SQL RPCs
// (rpc_open_futures_position / rpc_close_futures_position) with the same numbers
// and asserts the same outputs. This unit test reproduces those constants from
// the TS engine alone, so any change to the engine math fails HERE immediately
// (no DB needed) instead of only at the slower SQL integration gate. If you
// change one side, you MUST change both.
//
// Inputs: long, USDT margin 123.456789, leverage 7, entry 0.012345, exit 0.012900,
// default fees (open/close 0.0006, mmr 0.005), max leverage 100.
// ─────────────────────────────────────────────────────────────────────────────

describe('TS ↔ SQL futures parity (mirrors supabase/tests/futures_parity_test.sql)', () => {
  const open = computeOpenPosition({
    side: 'long',
    marginCurrency: 'USDT',
    marginAmount: '123.456789',
    leverage: '7',
    entryPrice: '0.012345',
    maxLeverage: '100',
  });

  it('open: entry/quantity/notional/openFee/liquidationPrice match the SQL RPC', () => {
    expect(open.entryPrice).toBe('0.012345');
    expect(open.quantity).toBe('70003.849574');
    expect(open.notional).toBe('864.197523');
    expect(open.openFee).toBe('0.518518');
    expect(open.liquidationPrice).toBe('0.010643');
  });

  it('close: exit/realizedPnl/closeFee/equityReturned match the SQL RPC', () => {
    const close = computeCloseSettlement({ position: open, exitPrice: '0.012900' });
    expect(close.exitPrice).toBe('0.0129');
    expect(close.realizedPnl).toBe('38.852136');
    expect(close.closeFee).toBe('0.541829');
    expect(close.equityReturned).toBe('161.767095');
  });
});

describe('TS ↔ SQL futures boundary parity (mirrors SQL boundary formulas)', () => {
  const tick = new Decimal('0.000001');
  const maintenanceMarginRate = new Decimal('0.005');

  function expectedLiquidationPrice(side: 'long' | 'short', entry: string, leverage: string): string {
    const entryPrice = new Decimal(entry);
    const lev = new Decimal(leverage);
    const invLev = new Decimal(1).div(lev);
    const raw =
      side === 'long'
        ? entryPrice.mul(new Decimal(1).minus(invLev).plus(maintenanceMarginRate))
        : entryPrice.mul(new Decimal(1).plus(invLev).minus(maintenanceMarginRate));

    return (raw.isNegative() ? new Decimal(0) : raw)
      .toDecimalPlaces(6, Decimal.ROUND_DOWN)
      .toFixed(6);
  }

  it('matches formula-derived liquidation price exactly at each market max leverage', () => {
    const cases = [
      { symbol: 'PHONUSDT-PERP', maxLeverage: '10', entryPrice: '0.012345' },
      { symbol: 'BTCUSDT-SIM', maxLeverage: '20', entryPrice: '68000.123456' },
      { symbol: 'ETHUSDT-SIM', maxLeverage: '20', entryPrice: '3500.654321' },
    ];

    for (const market of cases) {
      for (const side of ['long', 'short'] as const) {
        const position = computeOpenPosition({
          side,
          marginCurrency: 'USDT',
          marginAmount: '123.456789',
          leverage: market.maxLeverage,
          entryPrice: market.entryPrice,
          maxLeverage: market.maxLeverage,
        });

        expect(position.liquidationPrice, `${market.symbol} ${side}`).toBe(
          expectedLiquidationPrice(side, market.entryPrice, market.maxLeverage),
        );
      }
    }
  });

  it('rejects leverage just above market max', () => {
    for (const maxLeverage of ['10', '20']) {
      expect(() =>
        computeOpenPosition({
          side: 'long',
          marginCurrency: 'USDT',
          marginAmount: '100.000000',
          leverage: new Decimal(maxLeverage).plus(tick).toFixed(6),
          entryPrice: '100.000000',
          maxLeverage,
        }),
      ).toThrow(TradingError);
    }
  });

  it('matches liquidation boundary decisions at exact mark and one 6dp tick around it', () => {
    const cases = [
      { side: 'long' as const, entryPrice: '100.000000', leverage: '10' },
      { side: 'short' as const, entryPrice: '100.000000', leverage: '10' },
    ];

    for (const params of cases) {
      const position = computeOpenPosition({
        ...params,
        marginCurrency: 'USDT',
        marginAmount: '100.000000',
        maxLeverage: params.leverage,
      });
      const liq = new Decimal(position.liquidationPrice);
      const below = liq.minus(tick).toFixed(6);
      const exact = liq.toFixed(6);
      const above = liq.plus(tick).toFixed(6);

      if (params.side === 'long') {
        expect(isLiquidatable(params.side, position.liquidationPrice, above)).toBe(false);
        expect(isLiquidatable(params.side, position.liquidationPrice, exact)).toBe(true);
        expect(isLiquidatable(params.side, position.liquidationPrice, below)).toBe(true);
      } else {
        expect(isLiquidatable(params.side, position.liquidationPrice, below)).toBe(false);
        expect(isLiquidatable(params.side, position.liquidationPrice, exact)).toBe(true);
        expect(isLiquidatable(params.side, position.liquidationPrice, above)).toBe(true);
      }
    }
  });
});
