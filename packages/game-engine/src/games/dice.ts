import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export type DiceDirection = 'over' | 'under';

export interface DiceSelection {
  /** Target value (0.00–99.99). Roll must be over/under this value to win. */
  target: string;
  direction: DiceDirection;
}

export interface DiceResult {
  /** Roll result in [0.00, 99.99] */
  roll: number;
  won: boolean;
}

/**
 * Dice roll from float f ∈ [0,1).
 * Formula: floor(f × 10000) / 100 → [0.00, 99.99]
 * This is the canonical formula — NOT floor(f × 10001) which could reach 100.00.
 */
export function diceFromFloat(f: number): number {
  return Math.floor(f * 10000) / 100;
}

/**
 * Win probability given target and direction.
 * over N: wins if roll > N → probability = (9999 - floor(N*100)) / 10000
 * under N: wins if roll < N → probability = floor(N*100) / 10000
 */
export function diceWinProbability(target: number, direction: DiceDirection): number {
  const targetCents = Math.floor(target * 100);
  if (direction === 'over') {
    return (9999 - targetCents) / 10000;
  } else {
    return targetCents / 10000;
  }
}

/**
 * Dice payout multiplier: 99 / win_probability (1% house edge).
 */
export function diceMultiplier(target: number, direction: DiceDirection): number {
  const prob = diceWinProbability(target, direction);
  if (prob <= 0) return 0;
  return Math.floor(99 / prob) / 100;
}

const diceDefinition: GameDefinition<DiceSelection, DiceResult> = {
  code: 'dice',
  betSchema: z.object({
    target: z.string(),
    direction: z.enum(['over', 'under']),
  }),
  floatCount: 1,

  resultFromFloats(floats, selection): DiceResult {
    const f = requireFloat(floats, 0);
    const roll = diceFromFloat(f);
    const target = parseFloat(selection.target);
    const won =
      selection.direction === 'over' ? roll > target : roll < target;
    return { roll, won };
  },

  settle(stake, selection, result) {
    if (result.won) {
      const target = parseFloat(selection.target);
      const mult = new Decimal(diceMultiplier(target, selection.direction).toFixed(2));
      const payout = stake.mul(mult);
      const houseEdgeLeg = stake.minus(payout);
      return { payout, houseEdgeLeg };
    }
    return { payout: new Decimal('0'), houseEdgeLeg: stake };
  },
};

registerGame(diceDefinition);
export { diceDefinition };
