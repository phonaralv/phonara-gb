import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export interface MinesSelection {
  mineCount: number;
  revealedCells: number[];
}

export interface MinesResult {
  minePositions: number[];
  hitMine: boolean;
}

const GRID_SIZE = 25;

export function minePositionsFromFloats(floats: number[], mineCount: number): number[] {
  const arr = Array.from({ length: GRID_SIZE }, (_, i) => i);
  for (let i = GRID_SIZE - 1; i > 0; i--) {
    const j = Math.floor(requireFloat(floats, i - 1) * (i + 1));
    const tmp = arr[i]!;
    arr[i] = arr[j]!;
    arr[j] = tmp;
  }
  return arr.slice(0, mineCount);
}

export function minesMultiplier(mineCount: number, revealCount: number): number {
  if (revealCount <= 0) return 1;
  let mult = 1;
  for (let k = 0; k < revealCount; k++) {
    const safe = GRID_SIZE - mineCount - k;
    const total = GRID_SIZE - k;
    if (safe <= 0 || total <= 0) break;
    mult *= total / safe;
  }
  return Math.floor(mult * 99) / 100;
}

const minesDefinition: GameDefinition<MinesSelection, MinesResult> = {
  code: 'mines',
  betSchema: z
    .object({
      mineCount: z.number().int().min(1).max(24),
      revealedCells: z.array(z.number().int().min(0).max(24)),
    })
    .superRefine((sel, ctx) => {
      const unique = new Set(sel.revealedCells);
      if (unique.size !== sel.revealedCells.length) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'revealedCells must be distinct',
          path: ['revealedCells'],
        });
      }
      const maxSafe = GRID_SIZE - sel.mineCount;
      if (sel.revealedCells.length > maxSafe) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: `revealedCells exceeds safe cells (${maxSafe})`,
          path: ['revealedCells'],
        });
      }
    }),
  floatCount: GRID_SIZE,

  resultFromFloats(floats, selection): MinesResult {
    const minePositions = minePositionsFromFloats(floats, selection.mineCount);
    const mineSet = new Set(minePositions);
    const hitMine = selection.revealedCells.some((c) => mineSet.has(c));
    return { minePositions, hitMine };
  },

  settle(stake, selection, result) {
    if (result.hitMine || selection.revealedCells.length === 0) {
      return { payout: new Decimal('0'), houseEdgeLeg: stake };
    }
    const mult = new Decimal(
      minesMultiplier(selection.mineCount, selection.revealedCells.length).toFixed(2),
    );
    const payout = stake.mul(mult);
    const houseEdgeLeg = stake.minus(payout);
    return { payout, houseEdgeLeg };
  },
};

registerGame(minesDefinition);
export { minesDefinition };
