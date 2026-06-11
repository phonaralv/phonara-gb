import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export interface CrashSelection {
  /** Target auto-cashout multiplier (e.g. "2.00"). Phase 4 one-shot: required. */
  autoCashout: string;
}

export interface CrashResult {
  crashMultiplier: number;
  cashedOut: boolean;
  cashoutMultiplier: number;
}

export function crashFromFloat(f: number): number {
  if (f >= 1) return 1;
  const raw = Math.floor(99 / (1 - f)) / 100;
  return Math.max(1, raw);
}

const crashDefinition: GameDefinition<CrashSelection, CrashResult> = {
  code: 'crash',
  betSchema: z.object({
    autoCashout: z
      .string()
      .regex(/^\d+(\.\d{1,2})?$/)
      .refine((s) => {
        const v = parseFloat(s);
        return v >= 1.01 && v <= 1000000;
      }),
  }),
  floatCount: 1,

  resultFromFloats(floats, selection): CrashResult {
    const f = requireFloat(floats, 0);
    const crashMultiplier = crashFromFloat(f);
    const target = parseFloat(selection.autoCashout);
    const cashedOut = target <= crashMultiplier && target >= 1.01;
    const cashoutMultiplier = cashedOut ? target : 0;
    return { crashMultiplier, cashedOut, cashoutMultiplier };
  },

  settle(stake, _selection, result) {
    if (result.cashedOut && result.cashoutMultiplier >= 1.01) {
      const payout = stake.mul(new Decimal(result.cashoutMultiplier.toFixed(2)));
      const houseEdgeLeg = stake.minus(payout);
      return { payout, houseEdgeLeg };
    }
    return { payout: new Decimal('0'), houseEdgeLeg: stake };
  },
};

registerGame(crashDefinition);
export { crashDefinition };
