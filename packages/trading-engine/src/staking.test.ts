import { describe, it, expect } from 'vitest';
import {
  estimateStakingReward,
  computeAccruedReward,
  canUnstake,
  TradingError,
} from './index';

const DAY = 24 * 60 * 60 * 1000;

describe('estimateStakingReward', () => {
  it('computes linear APR reward', () => {
    const r = estimateStakingReward({ principal: '10000', apr: '0.12', days: '30' });
    // 10000 × 0.12 × (30/365) = 98.630136986...
    expect(r.estimatedReward).toBe('98.630136');
    expect(r.estimatedTotal).toBe('10098.630136');
  });

  it('zero apr yields zero reward', () => {
    const r = estimateStakingReward({ principal: '10000', apr: '0', days: '30' });
    expect(r.estimatedReward).toBe('0.000000');
  });

  it('rejects negative apr and non-positive principal', () => {
    expect(() =>
      estimateStakingReward({ principal: '100', apr: '-0.1', days: '30' }),
    ).toThrow(TradingError);
    expect(() =>
      estimateStakingReward({ principal: '0', apr: '0.1', days: '30' }),
    ).toThrow(TradingError);
  });
});

describe('computeAccruedReward', () => {
  it('accrues over elapsed time', () => {
    const t0 = 1_000_000_000_000;
    const reward = computeAccruedReward('10000', '0.12', t0, t0 + 30 * DAY);
    expect(reward).toBe('98.630136');
  });

  it('zero elapsed yields zero', () => {
    const t0 = 1_000_000_000_000;
    expect(computeAccruedReward('10000', '0.12', t0, t0)).toBe('0.000000');
  });

  it('rejects now before staked', () => {
    expect(() => computeAccruedReward('10000', '0.12', 1000, 500)).toThrow(TradingError);
  });
});

describe('canUnstake', () => {
  const t0 = 1_000_000_000_000;
  it('flexible always allowed', () => {
    expect(canUnstake('flexible', 0, t0, t0)).toBe(true);
  });
  it('locked blocked before unlock', () => {
    expect(canUnstake('days_30', 30, t0, t0 + 29 * DAY)).toBe(false);
  });
  it('locked allowed at/after unlock', () => {
    expect(canUnstake('days_30', 30, t0, t0 + 30 * DAY)).toBe(true);
    expect(canUnstake('days_30', 30, t0, t0 + 31 * DAY)).toBe(true);
  });
});
