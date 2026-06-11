import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export interface LimboSelection {
  /** Target multiplier (e.g. "2.00"). Win if result >= target. */
  target: string;
}

export interface LimboResult {
  resultMultiplier: number;
  won: boolean;
}

const MAX_MULTIPLIER = 1000000;

/**
 * Limbo multiplier from float f ∈ [0,1).
 * Same formula as Crash: max(1.00, floor(99 / (1 - f)) / 100)
 * A guard clamps the result to MAX_MULTIPLIER to prevent Infinity from
 * floating-point edge cases (practically unreachable but enforced).
 */
export function limboFromFloat(f: number): number {
  const denom = 1 - f;
  if (denom <= 0) return MAX_MULTIPLIER;
  const raw = Math.floor(99 / denom) / 100;
  return Math.min(MAX_MULTIPLIER, Math.max(1, raw));
}

const limboDefinition: GameDefinition<LimboSelection, LimboResult> = {
  code: 'limbo',
  betSchema: z.object({
    target: z.string(),
  }),
  floatCount: 1,

  resultFromFloats(floats, selection): LimboResult {
    const f = requireFloat(floats, 0);
    const resultMultiplier = limboFromFloat(f);
    const target = parseFloat(selection.target);
    const won = resultMultiplier >= target;
    return { resultMultiplier, won };
  },

  settle(stake, selection, result) {
    if (result.won) {
      const mult = new Decimal(selection.target);
      const payout = stake.mul(mult);
      const houseEdgeLeg = stake.minus(payout);
      return { payout, houseEdgeLeg };
    }
    return { payout: new Decimal('0'), houseEdgeLeg: stake };
  },
};

registerGame(limboDefinition);
export { limboDefinition };
