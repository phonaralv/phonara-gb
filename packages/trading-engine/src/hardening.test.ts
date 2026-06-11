/**
 * P0 Hardening — pure-function unit tests
 *
 * Tests are organized by hardening area:
 *   A1: Conservation invariant (Σ deltas == 0)
 *   A3: Circuit breaker logic
 *   A4: Hash-chain integrity
 */

import { describe, it, expect } from 'vitest';
import Decimal from 'decimal.js';
import { configureDecimal } from '@phonara/money';

configureDecimal();

// ─────────────────────────────────────────────────────────────────────────────
// Helpers that mirror SQL logic in pure TypeScript (for offline CI testing)
// ─────────────────────────────────────────────────────────────────────────────

/** Truncate to 6 decimal places (ROUND_DOWN) — mirrors _fmt6 in SQL */
function fmt6(v: Decimal | number | string): string {
  return new Decimal(v).toDecimalPlaces(6, Decimal.ROUND_DOWN).toFixed(6);
}

/** Token bucket rate limit check — mirrors _enforce_rate_limit in SQL */
interface Bucket { tokens: number; lastRefill: number }
interface RlConfig { capacity: number; refillRate: number; cost: number }

function checkRateLimit(
  bucket: Bucket,
  config: RlConfig,
  nowMs: number,
): { allowed: boolean; newTokens: number } {
  const elapsed = (nowMs - bucket.lastRefill) / 1000;
  const refilled = Math.min(config.capacity, bucket.tokens + elapsed * config.refillRate);
  if (refilled < config.cost) return { allowed: false, newTokens: refilled };
  return { allowed: true, newTokens: refilled - config.cost };
}

/**
 * Circuit breaker tick check — mirrors the price update guard in SQL.
 * Returns { halted: boolean; changePct: number }
 */
function circuitBreakerCheck(
  oldPrice: string,
  newPrice: string,
  maxTickPct: number,
): { halted: boolean; changePct: number } {
  const old = new Decimal(oldPrice);
  const next = new Decimal(newPrice);
  if (old.isZero()) return { halted: false, changePct: 0 };
  const changePct = next.div(old).minus(1).abs().times(100).toNumber();
  return { halted: changePct > maxTickPct, changePct };
}

/**
 * Hash-chain payload builder — mirrors _wl_compute_hash trigger in SQL.
 * Uses a simple SHA-256-like deterministic string for offline testing.
 */
function buildHashPayload(
  prevHash: string | null,
  id: string,
  direction: string,
  currency: string,
  amount: string,
  createdAt: string,
): string {
  return [prevHash ?? 'GENESIS', id, direction, currency, amount, createdAt].join('|');
}

// NOTE: A1 conservation (Σ deltas == 0) is verified by the property-based suite in
// conservation.test.ts (10k random cases per RPC), which mirrors the corrected SQL
// settlement decomposition and cross-checks it against the verified engine. The
// earlier hand-rolled A1 cases here encoded a since-corrected model and were removed.

// ─────────────────────────────────────────────────────────────────────────────
// A3: Circuit breaker tests
// ─────────────────────────────────────────────────────────────────────────────

describe('A3: Circuit breaker — price change guard', () => {
  it('no halt when change is within ±10%', () => {
    expect(circuitBreakerCheck('0.01000', '0.01090', 10).halted).toBe(false);
    expect(circuitBreakerCheck('0.01000', '0.00910', 10).halted).toBe(false);
    expect(circuitBreakerCheck('0.01000', '0.01099', 10).halted).toBe(false);
  });

  it('halts when price moves exactly at the limit', () => {
    // 10% up
    const { halted, changePct } = circuitBreakerCheck('0.01000', '0.01101', 10);
    expect(halted).toBe(true);
    expect(changePct).toBeGreaterThan(10);
  });

  it('halts on a large crash (−50%)', () => {
    const { halted } = circuitBreakerCheck('1.000000', '0.500000', 10);
    expect(halted).toBe(true);
  });

  it('no halt when old price is zero (first tick)', () => {
    const { halted } = circuitBreakerCheck('0', '0.01', 10);
    expect(halted).toBe(false);
  });

  it('accurately computes change percentage', () => {
    const { changePct } = circuitBreakerCheck('1.000000', '1.050000', 10);
    expect(Math.abs(changePct - 5)).toBeLessThan(0.001);
  });

  it('up-move and matching down-move are both caught by the same threshold', () => {
    // +20% up → halted (exceeds 10%)
    const up = circuitBreakerCheck('0.010000', '0.012000', 10);
    expect(up.halted).toBe(true);
    // −16.67% down from new price → also halted
    const down = circuitBreakerCheck('0.012000', '0.010000', 10);
    expect(down.halted).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// A4: Hash-chain integrity tests
// ─────────────────────────────────────────────────────────────────────────────

describe('A4: Hash-chain ledger — payload construction', () => {
  const TS = '2026-06-09T00:00:00.000000Z';

  it('first entry uses GENESIS as prev_hash', () => {
    const payload = buildHashPayload(null, 'id-1', 'credit', 'PHON', '5000.000000', TS);
    expect(payload).toMatch(/^GENESIS\|/);
  });

  it('chained entry includes previous hash', () => {
    const prev = 'abc123def456';
    const payload = buildHashPayload(prev, 'id-2', 'debit', 'USDT', '10.000000', TS);
    expect(payload.startsWith(prev + '|')).toBe(true);
  });

  it('different amounts produce different payloads', () => {
    const p1 = buildHashPayload('abc', 'id-1', 'credit', 'PHON', '100.000000', TS);
    const p2 = buildHashPayload('abc', 'id-1', 'credit', 'PHON', '200.000000', TS);
    expect(p1).not.toBe(p2);
  });

  it('tampered direction produces different payload (detectable)', () => {
    const honest  = buildHashPayload('abc', 'id-1', 'credit', 'PHON', '100.000000', TS);
    const tampered = buildHashPayload('abc', 'id-1', 'debit',  'PHON', '100.000000', TS);
    expect(honest).not.toBe(tampered);
  });

  it('verification walk detects a broken chain', () => {
    // Simulate 3-row chain
    const entries = [
      { id: 'e1', direction: 'credit', currency: 'PHON', amount: '5000.000000', createdAt: TS },
      { id: 'e2', direction: 'debit',  currency: 'PHON', amount: '100.000000',  createdAt: TS },
      { id: 'e3', direction: 'credit', currency: 'PHON', amount: '50.000000',   createdAt: TS },
    ];

    // Build hashes
    let prevHash: string | null = null;
    const hashes: string[] = [];
    for (const e of entries) {
      const payload = buildHashPayload(prevHash, e.id, e.direction, e.currency, e.amount, e.createdAt);
      // Simulate SHA-256 with a deterministic surrogate (btoa for offline test)
      const hash = btoa(payload);
      hashes.push(hash);
      prevHash = hash;
    }

    // Verify chain (should be clean)
    prevHash = null;
    let broken = false;
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i]!;
      const payload = buildHashPayload(prevHash, e.id, e.direction, e.currency, e.amount, e.createdAt);
      const expected = btoa(payload);
      if (expected !== hashes[i]) { broken = true; break; }
      prevHash = hashes[i] ?? null;
    }
    expect(broken).toBe(false);

    // Tamper with row 1 (change amount) and re-verify
    entries[1]!.amount = '999.000000'; // tampered

    prevHash = null;
    broken = false;
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i]!;
      const payload = buildHashPayload(prevHash, e.id, e.direction, e.currency, e.amount, e.createdAt);
      const expected = btoa(payload);
      if (expected !== hashes[i]) { broken = true; break; }
      prevHash = hashes[i] ?? null;
    }
    expect(broken).toBe(true); // tampering detected
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// A5: Rate limit token bucket tests
// ─────────────────────────────────────────────────────────────────────────────

describe('A5: Rate limit — token bucket', () => {
  const config: RlConfig = { capacity: 5, refillRate: 5 / 60, cost: 1 }; // 5/min

  it('full bucket allows calls', () => {
    const bucket: Bucket = { tokens: 5, lastRefill: 0 };
    const { allowed } = checkRateLimit(bucket, config, 0);
    expect(allowed).toBe(true);
  });

  it('empty bucket blocks calls', () => {
    const bucket: Bucket = { tokens: 0, lastRefill: Date.now() };
    const { allowed } = checkRateLimit(bucket, config, Date.now());
    expect(allowed).toBe(false);
  });

  it('refills over time', () => {
    const now = 1000000;
    const bucket: Bucket = { tokens: 0, lastRefill: now - 60000 }; // 60s ago → full refill
    const { allowed, newTokens } = checkRateLimit(bucket, config, now);
    expect(allowed).toBe(true);
    expect(newTokens).toBeCloseTo(4, 0); // 5 refilled - 1 cost
  });

  it('does not exceed capacity on long idle', () => {
    const now = 1000000;
    const bucket: Bucket = { tokens: 0, lastRefill: now - 3600000 }; // 1hr ago
    const { newTokens } = checkRateLimit(bucket, config, now);
    expect(newTokens).toBeLessThanOrEqual(config.capacity);
  });

  it('successive rapid calls deplete bucket', () => {
    let bucket: Bucket = { tokens: 3, lastRefill: Date.now() };
    const now = Date.now();
    for (let i = 0; i < 3; i++) {
      const res = checkRateLimit(bucket, config, now);
      expect(res.allowed).toBe(true);
      bucket = { tokens: res.newTokens, lastRefill: now };
    }
    // 4th call: bucket empty, same instant
    const res = checkRateLimit(bucket, config, now);
    expect(res.allowed).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// A1: fmt6 truncation (no rounding that could create dust mismatch)
// ─────────────────────────────────────────────────────────────────────────────

describe('A1: fmt6 — ROUND_DOWN for dust safety', () => {
  it('truncates at 6 dp without rounding up', () => {
    expect(fmt6('1.0000009')).toBe('1.000000');
    expect(fmt6('1.9999999')).toBe('1.999999');
    expect(fmt6('0.0000001')).toBe('0.000000');
  });

  it('returns 6 dp even for whole numbers', () => {
    expect(fmt6('100')).toBe('100.000000');
  });

  it('dust from truncation is always non-negative', () => {
    const original = new Decimal('1.9999999');
    const truncated = new Decimal(fmt6('1.9999999'));
    const dust = original.minus(truncated);
    expect(dust.greaterThanOrEqualTo(0)).toBe(true);
    expect(dust.lessThan('0.000001')).toBe(true);
  });
});
