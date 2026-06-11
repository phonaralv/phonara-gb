import { describe, it, expect } from 'vitest';
import { computeOpenPosition, computeCloseSettlement } from './index';

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
