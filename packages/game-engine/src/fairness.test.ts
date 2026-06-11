/**
 * Fairness module — deterministic fixed-vector tests.
 *
 * These vectors are pre-computed with Node crypto (identical HMAC-SHA256 impl)
 * and locked here. Any change to the algorithm must fail these tests first.
 *
 * Coverage: seed hashing, HMAC, float derivation, cursor extension (>8 floats),
 * and bias-free distribution (all floats in [0,1)).
 */

import { describe, it, expect } from 'vitest';
import { hmacSha256 } from './fairness/hmac';
import { floatStream } from './fairness/float';
import { hashServerSeed } from './fairness/seed';
import { recomputeResult, verifyRound } from './fairness/verifier';

const SERVER_SEED = 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';
const SERVER_SEED_HASH = '806571d9ce36a258bb70b4fd735b3e396e2631048b97295ea85ea9045788cd46';
const CLIENT_SEED = 'test_client';
const NONCE = 7;

describe('fairness/seed', () => {
  it('hashes server seed deterministically', async () => {
    const hash = await hashServerSeed(SERVER_SEED);
    expect(hash).toBe(SERVER_SEED_HASH);
  });
});

describe('fairness/hmac', () => {
  it('produces deterministic HMAC output — vector 0', async () => {
    const h = await hmacSha256(SERVER_SEED, 'clientseed123:1:0');
    expect(h).toBe('3da85043843dcc86097243b6eb72a3feac050603cf1d8dfd2253b9732838e92e');
  });

  it('produces deterministic HMAC output — vector 1 (different message)', async () => {
    const h = await hmacSha256(SERVER_SEED, 'clientseed123:1:1');
    expect(h).toBe('9173c81aa302f15642d7db587f782a235f93a6dc5f517ec5db701a9851df1545');
  });

  it('produces deterministic HMAC output — vector 2 (different nonce)', async () => {
    const h = await hmacSha256(SERVER_SEED, 'clientseed123:2:0');
    expect(h).toBe('8be751858a47e8a3103e775f7ec43b4a8f2b663159b290d7e82215847a42d1af');
  });
});

describe('fairness/float', () => {
  it('derives first float correctly from fixed vector', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    expect(floats[0]).toBeCloseTo(0.76942979, 7);
  });

  it('all floats are in [0, 1)', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 8);
    for (const f of floats) {
      expect(f).toBeGreaterThanOrEqual(0);
      expect(f).toBeLessThan(1);
    }
  });

  it('extends beyond 8 floats via cursor increment (bug fix)', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 9);
    expect(floats).toHaveLength(9);
    // 9th float comes from cursor=1 HMAC — must differ from the 1st float
    expect(floats[8]).toBeCloseTo(0.72129345, 7);
    // All in [0, 1)
    for (const f of floats) {
      expect(f).toBeGreaterThanOrEqual(0);
      expect(f).toBeLessThan(1);
    }
  });

  it('16 floats all in [0, 1) — Plinko row count', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 16);
    expect(floats).toHaveLength(16);
    for (const f of floats) {
      expect(f).toBeGreaterThanOrEqual(0);
      expect(f).toBeLessThan(1);
    }
  });

  it('25 floats all in [0, 1) — Mines full grid', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 25);
    expect(floats).toHaveLength(25);
    for (const f of floats) {
      expect(f).toBeGreaterThanOrEqual(0);
      expect(f).toBeLessThan(1);
    }
  });
});

describe('fairness/game-result formulas', () => {
  it('dice: floor(f × 10000) / 100 yields [0.00, 99.99]', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    const roll = Math.floor(floats[0]! * 10000) / 100;
    // Vector-locked: f ≈ 0.76942979 → roll = 76.94
    expect(roll).toBe(76.94);
    // Boundary: f = 0 → 0.00
    expect(Math.floor(0 * 10000) / 100).toBe(0);
    // Boundary: f < 1 → max is 99.99 (f = 0.9999... → floor(9999.x) / 100 = 99.99)
    expect(Math.floor(0.9999999 * 10000) / 100).toBe(99.99);
    // Dice NEVER reaches 100.00 with this formula (unlike floor(f × 10001) / 100)
    expect(Math.floor(0.9999999 * 10000) / 100).toBeLessThan(100);
  });

  it('crash: max(1, floor(99 / (1 - f)) / 100)', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    const crash = Math.max(1, Math.floor(99 / (1 - floats[0]!)) / 100);
    // Vector-locked: f ≈ 0.76943 → 99/(1-0.76943) = 99/0.23057 ≈ 429.3 → 4.29
    expect(crash).toBe(4.29);
    // Instant bust guard: f very close to 0 → multiplier ~= 1.00
    expect(Math.max(1, Math.floor(99 / (1 - 0.001)) / 100)).toBe(1);
    // Always >= 1
    expect(Math.max(1, Math.floor(99 / (1 - 0.99)) / 100)).toBeGreaterThanOrEqual(1);
  });

  it('limbo: max(1, floor(99/(1-f))/100) — output is always finite and >= 1', async () => {
    // Limbo uses the same float-to-multiplier formula as Crash.
    // The MAX_MULTIPLIER cap guards against f→1 floating-point edge cases.
    const MAX_MULTIPLIER = 1000000;
    const limboResult = (f: number): number => {
      const denom = 1 - f;
      if (denom <= 0) return MAX_MULTIPLIER;
      const raw = Math.floor(99 / denom) / 100;
      return Math.min(MAX_MULTIPLIER, Math.max(1, raw));
    };
    // f = 0: 99/1 = 99 → floor/100 = 0.99 → max(1) = 1.00 (low float = low multiplier)
    expect(limboResult(0)).toBe(1);
    // f = 0.5: 99/0.5 = 198 → 1.98
    expect(limboResult(0.5)).toBe(1.98);
    // f = 0.99: 99/(1-0.99) ≈ 9900 → floor/100 ≈ 98.99 (FP: 1-0.99 = 0.010000...009)
    expect(limboResult(0.99)).toBeCloseTo(98.99, 1);
    // Infinity guard: denom ≤ 0 → MAX_MULTIPLIER (can't happen with [0,1) float, but guarded)
    expect(Number.isFinite(limboResult(1.0))).toBe(true);
    expect(limboResult(1.0)).toBe(MAX_MULTIPLIER);
    // Vector-locked: f ≈ 0.76943 → 99/(1-0.76943) = 99/0.23057 ≈ 429.3 → floor = 429 → 4.29
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    expect(limboResult(floats[0]!)).toBe(4.29);
  });
});

describe('fairness/verifier', () => {
  it('confirms seed hash match with fixed vector', async () => {
    const result = await verifyRound({
      game: 'dice',
      serverSeed: SERVER_SEED,
      serverSeedHash: SERVER_SEED_HASH,
      clientSeed: CLIENT_SEED,
      nonce: NONCE,
    });
    expect(result.seedHashMatch).toBe(true);
    expect(result.floats[0]).toBeCloseTo(0.76942979, 7);
  });

  it('recomputes the game result and matches the stored outcome', async () => {
    const result = await verifyRound({
      game: 'dice',
      serverSeed: SERVER_SEED,
      serverSeedHash: SERVER_SEED_HASH,
      clientSeed: CLIENT_SEED,
      nonce: NONCE,
      selection: { target: '50.00', direction: 'over' },
      expectedResult: { roll: 76.94, won: true },
    });

    expect(result.recomputedResult).toEqual({ roll: 76.94, won: true });
    expect(result.resultMatch).toBe(true);
  });

  it('flags a stored outcome mismatch after recomputing the game result', async () => {
    const result = await verifyRound({
      game: 'dice',
      serverSeed: SERVER_SEED,
      serverSeedHash: SERVER_SEED_HASH,
      clientSeed: CLIENT_SEED,
      nonce: NONCE,
      selection: { target: '50.00', direction: 'over' },
      expectedResult: { roll: 76.94, won: false },
    });

    expect(result.resultMatch).toBe(false);
  });

  it('exposes recomputeResult as the single game-result path', async () => {
    const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, 1);
    expect(recomputeResult('dice', floats, { target: '50.00', direction: 'over' })).toEqual({
      roll: 76.94,
      won: true,
    });
  });

  it('flags hash mismatch when server seed is wrong', async () => {
    const result = await verifyRound({
      game: 'dice',
      serverSeed: 'wrongseedwrongseedwrongseedwrongseedwrongseedwrongseedwrongseed1',
      serverSeedHash: SERVER_SEED_HASH,
      clientSeed: CLIENT_SEED,
      nonce: NONCE,
    });
    expect(result.seedHashMatch).toBe(false);
  });
});
