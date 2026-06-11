/**
 * Wave 1 — per-game exploit regression tests.
 * These MUST fail on pre-Wave-1 code (duplicate cells, >10 HiLo guesses, +EV Plinko 12-low).
 */

import { describe, it, expect } from 'vitest';
import Decimal from 'decimal.js';
import { floatStream } from '../fairness/float';
import { plinkoDefinition, plinkoRtp, PAYOUT_TABLES } from './plinko';
import { minesDefinition } from './mines';
import { hiloDefinition, HILO_MAX_GUESSES } from './hilo';
import { crashDefinition } from './crash';

// Register side effects
import './crash';
import './limbo';
import './dice';
import './mines';
import './hilo';
import './plinko';

const SERVER_SEED = 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';
const CLIENT_SEED = 'test_client';
const NONCE = 7;

/** Legacy 12-low table — ~104% RTP (+EV); regression anchor. */
const LEGACY_12_LOW = [
  8.1, 4.0, 3.0, 1.4, 1.1, 1.0, 0.5, 1.0, 1.1, 1.4, 3.0, 4.0, 8.1,
];

function legacy12LowRtp(): number {
  let ev = 0;
  const n = 12;
  for (let k = 0; k <= n; k++) {
    let c = 1;
    for (let i = 0; i < k; i++) c = (c * (n - i)) / (i + 1);
    ev += (c / 2 ** n) * (LEGACY_12_LOW[k] ?? 0);
  }
  return ev;
}

describe('Plinko RTP (exact binomial)', () => {
  it('12-low is strictly below 100% (fixes +EV exploit)', () => {
    const rtp = plinkoRtp(12, 'low');
    expect(rtp).toBeLessThan(1);
    expect(rtp).toBeGreaterThanOrEqual(0.985);
    expect(legacy12LowRtp()).toBeGreaterThan(1.03);
  });

  it('12-medium and 12-high sit in 98.5–99.5% band', () => {
    expect(plinkoRtp(12, 'medium')).toBeGreaterThanOrEqual(0.985);
    expect(plinkoRtp(12, 'medium')).toBeLessThanOrEqual(0.995);
    expect(plinkoRtp(12, 'high')).toBeGreaterThanOrEqual(0.985);
    expect(plinkoRtp(12, 'high')).toBeLessThanOrEqual(0.995);
  });

  /**
   * 16-high: extreme buckets (3836×) dominate variance — exact RTP ~99% but
   * Monte Carlo 100k needs wide tolerance; exact binomial is the gate.
   */
  it('16-high exact RTP ~99% (high-variance — MC band documented in monte-carlo test)', () => {
    const rtp = plinkoRtp(16, 'high');
    expect(rtp).toBeGreaterThanOrEqual(0.985);
    expect(rtp).toBeLessThanOrEqual(0.995);
    expect(PAYOUT_TABLES[16]!.high[0]).toBe(3836);
  });
});

describe('Plinko cursor boundary (row 16 uses float index 15)', () => {
  it('16th direction uses floats[15] from cursor=1 stream', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 16);
    const forced = [...floats];
    forced[15] = 0.1;
    const result = plinkoDefinition.resultFromFloats(forced, { rows: 16, risk: 'low' });
    expect(result.path).toHaveLength(16);
    expect(result.path[15]).toBe(0);
    forced[15] = 0.9;
    const result2 = plinkoDefinition.resultFromFloats(forced, { rows: 16, risk: 'low' });
    expect(result2.path[15]).toBe(1);
  });

  it('throws when row count exceeds float stream (no silent ?? 0)', () => {
    expect(() =>
      plinkoDefinition.resultFromFloats([0.5], { rows: 16, risk: 'low' }),
    ).toThrow(/exhausted at index/);
  });
});

describe('Plinko Monte Carlo (deterministic PRNG)', () => {
  function mulberry32(seed: number) {
    return () => {
      let t = (seed += 0x6d2b79f5);
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  it('12-low simulated RTP within band of exact (100k, seed=42)', () => {
    const rng = mulberry32(42);
    const rows = 12;
    const table = PAYOUT_TABLES[12]!.low;
    let sum = 0;
    const n = 100_000;
    for (let i = 0; i < n; i++) {
      let bucket = 0;
      for (let r = 0; r < rows; r++) bucket += rng() < 0.5 ? 0 : 1;
      sum += table[bucket] ?? 0;
    }
    const mcRtp = sum / n;
    const exact = plinkoRtp(12, 'low');
    expect(mcRtp).toBeGreaterThan(exact - 0.02);
    expect(mcRtp).toBeLessThan(exact + 0.02);
    expect(mcRtp).toBeLessThan(1);
  });
});

describe('Mines exploit regression', () => {
  it('rejects duplicate revealedCells (would be +EV if allowed)', () => {
    const parsed = minesDefinition.betSchema.safeParse({
      mineCount: 3,
      revealedCells: [0, 0, 1],
    });
    expect(parsed.success).toBe(false);
  });

  it('distinct cells pass schema', () => {
    const parsed = minesDefinition.betSchema.safeParse({
      mineCount: 3,
      revealedCells: [0, 1, 2],
    });
    expect(parsed.success).toBe(true);
  });
});

describe('HiLo exploit regression', () => {
  it('rejects more than 10 guesses', () => {
    const guesses = Array.from({ length: 11 }, () => 'higher' as const);
    const parsed = hiloDefinition.betSchema.safeParse({ startCard: 7, guesses });
    expect(parsed.success).toBe(false);
  });

  it('throws when float stream too short for guesses (no ?? 0 fallback)', () => {
    expect(() =>
      hiloDefinition.resultFromFloats([0.5, 0.5], {
        startCard: null,
        guesses: ['skip', 'skip', 'skip'],
      }),
    ).toThrow(/exhausted at index/);
  });

  it('allows exactly 10 guesses in schema', () => {
    const guesses = Array.from({ length: HILO_MAX_GUESSES }, () => 'skip' as const);
    expect(hiloDefinition.betSchema.safeParse({ startCard: null, guesses }).success).toBe(
      true,
    );
  });
});

describe('Crash one-shot (Phase 4)', () => {
  it('requires autoCashout string — nullable manual path removed', () => {
    expect(crashDefinition.betSchema.safeParse({ autoCashout: null }).success).toBe(false);
  });

  it('wins when autoCashout <= crash multiplier', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    const result = crashDefinition.resultFromFloats(floats, { autoCashout: '2.00' });
    expect(result.crashMultiplier).toBeGreaterThanOrEqual(2);
    expect(result.cashedOut).toBe(true);
    const stake = new Decimal('10');
    const { payout } = crashDefinition.settle(stake, { autoCashout: '2.00' }, result);
    expect(payout.toFixed(2)).toBe('20.00');
  });
});
