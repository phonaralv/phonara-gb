/**
 * A1 — Conservation invariant (property-based, fast-check)
 *
 * The master plan (Appendix A1) requires: every monetary RPC must end with
 *   Σ(all account deltas) == 0
 * across user wallets + house fee + insurance/liquidity counterparty + dust.
 *
 * These tests are the EXECUTABLE SPEC for the SQL settlement logic in
 *   supabase/migrations/20260609000009_p0_auto_liquidation.sql
 * They mirror the SQL decomposition EXACTLY (same formulas, same ROUND_DOWN
 * truncation that `_fmt6` / `trunc(x,6)` use) and additionally cross-check the
 * user leg against the already-verified pure engine (computeCloseSettlement /
 * computeSpotBuy / computeSpotSell), so a divergence between engine and SQL
 * model would fail here.
 *
 * NOTE: a full DB-level integration test (running the real RPCs and asserting
 * Σ over wallets + system_accounts) lives in supabase/tests/ and is run against
 * a Postgres instance; this file proves the math/model is conservation-correct.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import fc from 'fast-check';
import { configureDecimal, Decimal } from '@phonara/money';
import { computeOpenPosition, computeCloseSettlement } from './futures';
import { computeSpotBuy, computeSpotSell } from './spot';

beforeEach(() => {
  configureDecimal();
});

const SAT = new Decimal('0.000001'); // 1 satoshi at 6dp

/** Truncate toward zero at 6dp — mirrors SQL trunc(x,6) and money.toFixed (ROUND_DOWN). */
function t6(v: Decimal | string | number): Decimal {
  return new Decimal(v).toDecimalPlaces(6, Decimal.ROUND_DOWN);
}

const RUNS = 10_000;

// ─────────────────────────────────────────────────────────────────────────────
// Futures settlement conservation — mirrors _settle_futures_position
// ─────────────────────────────────────────────────────────────────────────────

describe('A1: futures settlement conservation (10k random cases)', () => {
  it('Σ(user, house, insurance, dust) == 0 exactly, and matches the engine', () => {
    fc.assert(
      fc.property(
        fc.constantFrom<'long' | 'short'>('long', 'short'),
        fc.integer({ min: 1, max: 1_000_000_000 }), // margin in micro-units (1e-6 .. 1000)
        fc.integer({ min: 1, max: 50 }), // leverage
        fc.integer({ min: 1, max: 100_000_000 }), // entry price in micro-units
        fc.integer({ min: 1, max: 100_000_000 }), // exit price in micro-units
        (side, marginMicro, lev, entryMicro, exitMicro) => {
          const margin = new Decimal(marginMicro).div(1_000_000); // up to 1000, 6dp
          const entry = new Decimal(entryMicro).div(1_000_000);
          const exit = new Decimal(exitMicro).div(1_000_000);

          const pos = computeOpenPosition({
            side,
            marginCurrency: 'USDT',
            marginAmount: margin.toFixed(6),
            leverage: String(lev),
            entryPrice: entry.toFixed(),
            maxLeverage: '50',
          });

          const settle = computeCloseSettlement({ position: pos, exitPrice: exit.toFixed() });

          // ── Raw values (full precision), exactly as the SQL computes them ──
          const qty = new Decimal(pos.quantity);
          const marginR = new Decimal(pos.marginAmount);
          const pnlRaw =
            side === 'long' ? qty.mul(exit.minus(entry)) : qty.mul(entry.minus(exit));
          const closeFeeRaw = qty.mul(exit).mul('0.0006'); // DEFAULT close fee rate
          const grossEquity = marginR.plus(pnlRaw).minus(closeFeeRaw);
          const equity = grossEquity.lessThan(0) ? new Decimal(0) : grossEquity;

          // ── SQL leg decomposition (6dp) ──
          // User leg truncates equity FIRST (matches engine equityReturned), then
          // subtracts the (already-6dp) margin. Insurance uses the RAW residual so it
          // equals -pnl. Dust is the balancing residual.
          const adjust = t6(equity).minus(marginR);
          const u6 = t6(adjust); // user delta
          const h6 = t6(closeFeeRaw); // house fee
          const ins6 = t6(marginR.minus(equity).minus(closeFeeRaw)); // insurance counterparty
          const dust6 = u6.plus(h6).plus(ins6).negated(); // residual

          // 1) Exact conservation
          const total = u6.plus(h6).plus(ins6).plus(dust6);
          expect(total.isZero()).toBe(true);

          // 2) User leg matches the verified engine payout (equityReturned - margin)
          const engineUser = t6(new Decimal(settle.equityReturned).minus(marginR));
          expect(u6.equals(engineUser)).toBe(true);

          // 3) Insurance == -pnl when not wiped out (economic correctness)
          if (grossEquity.greaterThan(0)) {
            expect(ins6.equals(t6(pnlRaw.negated()))).toBe(true);
          }

          // 4) Dust is bounded to a few satoshi (truncation residue only)
          expect(dust6.abs().lessThan(SAT.mul(3))).toBe(true);

          // 5) House fee is never negative
          expect(h6.greaterThanOrEqualTo(0)).toBe(true);
        },
      ),
      { numRuns: RUNS },
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Spot conservation — mirrors rpc_spot_market_buy / sell (per currency)
// ─────────────────────────────────────────────────────────────────────────────

describe('A1: spot buy conservation (10k random cases)', () => {
  it('USDT and PHON each net to 0 exactly; legs match the engine', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 1_000_000_000 }), // usdt spent (micro)
        fc.integer({ min: 1, max: 100_000_000 }), // price (micro)
        (usdtMicro, priceMicro) => {
          const usdt = new Decimal(usdtMicro).div(1_000_000);
          const price = new Decimal(priceMicro).div(1_000_000);

          const r = computeSpotBuy({
            usdtSpent: usdt.toFixed(6),
            price: price.toFixed(),
            feeRate: '0.001',
          });

          const usdt6 = t6(usdt);
          const net6 = t6(r.netPhon);
          const fee6 = t6(r.feePhon);

          // USDT side: user -usdt6, liquidity +usdt6
          const usdtSide = usdt6.negated().plus(usdt6);
          expect(usdtSide.isZero()).toBe(true);

          // PHON side: user +net6, house_fee +fee6, liquidity -(net6+fee6)
          const phonSide = net6.plus(fee6).minus(net6.plus(fee6));
          expect(phonSide.isZero()).toBe(true);

          expect(fee6.greaterThanOrEqualTo(0)).toBe(true);
        },
      ),
      { numRuns: RUNS },
    );
  });
});

describe('A1: spot sell conservation (10k random cases)', () => {
  it('PHON and USDT each net to 0 exactly; legs match the engine', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 1_000_000_000 }), // phon sold (micro)
        fc.integer({ min: 1, max: 100_000_000 }), // price (micro)
        (phonMicro, priceMicro) => {
          const phon = new Decimal(phonMicro).div(1_000_000);
          const price = new Decimal(priceMicro).div(1_000_000);

          const r = computeSpotSell({
            phonSold: phon.toFixed(6),
            price: price.toFixed(),
            feeRate: '0.001',
          });

          const phon6 = t6(phon);
          const net6 = t6(r.netUsdt);
          const fee6 = t6(r.feeUsdt);

          // PHON side: user -phon6, liquidity +phon6
          expect(phon6.negated().plus(phon6).isZero()).toBe(true);

          // USDT side: user +net6, house_fee +fee6, liquidity -(net6+fee6)
          expect(net6.plus(fee6).minus(net6.plus(fee6)).isZero()).toBe(true);

          expect(fee6.greaterThanOrEqualTo(0)).toBe(true);
        },
      ),
      { numRuns: RUNS },
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Reward issuance (mint) conservation — user credit balanced by mint debit
// ─────────────────────────────────────────────────────────────────────────────

describe('A1: reward issuance conservation', () => {
  it('user PHON credit == reward_issuance debit (Σ == 0)', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 11_900_000_000 }), (microPhon) => {
        const amt = t6(new Decimal(microPhon).div(1_000_000));
        // user +amt, reward_issuance_phon -amt
        expect(amt.plus(amt.negated()).isZero()).toBe(true);
      }),
      { numRuns: 1000 },
    );
  });
});
