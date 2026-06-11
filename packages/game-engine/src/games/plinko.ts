import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export type PlinkoRisk = 'low' | 'medium' | 'high';

export interface PlinkoSelection {
  rows: number;
  risk: PlinkoRisk;
}

export interface PlinkoResult {
  path: number[];
  bucket: number;
  bucketMultiplier: string;
}

/**
 * Payout tables — binomial fair mult × risk shaping, calibrated to ~99% RTP per (rows, risk).
 * Formula base: edge × 2^n / (C(n,k) × (n+1)); low/medium compress variance vs high.
 * 12-low legacy table was ~104% RTP (+EV); replaced here (Wave 1).
 */
export const PAYOUT_TABLES: Record<number, Record<PlinkoRisk, number[]>> = {
  8: {
    low: [6.5, 1.6, 1, 0.9, 0.9, 0.9, 1, 1.6, 6.5],
    medium: [15.9, 2.4, 1, 0.7, 0.7, 0.7, 1, 2.4, 15.9],
    high: [28.4, 3.5, 1, 0.5, 0.4, 0.5, 1, 3.5, 28.4],
  },
  12: {
    low: [63.9, 6.3, 1.8, 1.1, 0.9, 0.9, 0.8, 0.9, 0.9, 1.1, 1.8, 6.3, 63.9],
    medium: [168.9, 14.5, 3, 1.2, 0.8, 0.7, 0.6, 0.7, 0.8, 1.2, 3, 14.5, 168.9],
    high: [319, 26.6, 4.8, 1.5, 0.6, 0.4, 0.3, 0.4, 0.6, 1.5, 4.8, 26.6, 319],
  },
  16: {
    low: [788, 51.8, 7.9, 2.4, 1.3, 1, 0.9, 0.8, 0.8, 0.8, 0.9, 1, 1.3, 2.4, 7.9, 51.8, 788],
    medium: [2153.8, 135, 18.4, 4.3, 1.6, 0.9, 0.7, 0.6, 0.6, 0.6, 0.7, 0.9, 1.6, 4.3, 18.4, 135, 2153.8],
    high: [3836, 239.7, 32, 6.8, 2.1, 0.9, 0.5, 0.3, 0.3, 0.3, 0.5, 0.9, 2.1, 6.8, 32, 239.7, 3836],
  },
};

/** Exact binomial RTP for a payout table (unit tests). */
export function plinkoRtp(rows: number, risk: PlinkoRisk): number {
  const table = PAYOUT_TABLES[rows]?.[risk];
  if (!table) return 0;
  let ev = 0;
  for (let k = 0; k <= rows; k++) {
    let c = 1;
    for (let i = 0; i < k; i++) c = (c * (rows - i)) / (i + 1);
    ev += (c / 2 ** rows) * (table[k] ?? 0);
  }
  return ev;
}

const DEFAULT_ROWS = 16;

const plinkoDefinition: GameDefinition<PlinkoSelection, PlinkoResult> = {
  code: 'plinko',
  betSchema: z.object({
    rows: z.number().int().refine((r) => [8, 12, 16].includes(r)),
    risk: z.enum(['low', 'medium', 'high']),
  }),
  floatCount: DEFAULT_ROWS,

  resultFromFloats(floats, selection): PlinkoResult {
    const { rows, risk } = selection;
    const path: number[] = [];
    let bucket = 0;

    for (let r = 0; r < rows; r++) {
      const dir = requireFloat(floats, r) < 0.5 ? 0 : 1;
      path.push(dir);
      bucket += dir;
    }

    const table = PAYOUT_TABLES[rows]?.[risk] ?? PAYOUT_TABLES[16]!.medium;
    const bucketMultiplier = (table[bucket] ?? 0).toFixed(1);

    return { path, bucket, bucketMultiplier };
  },

  settle(stake, _selection, result) {
    const mult = new Decimal(result.bucketMultiplier);
    const payout = stake.mul(mult);
    const houseEdgeLeg = stake.minus(payout);
    return { payout, houseEdgeLeg };
  },
};

registerGame(plinkoDefinition);
export { plinkoDefinition };
