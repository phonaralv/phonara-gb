import { toFixed } from '@phonara/money';
import {
  Decimal,
  dec,
  assertPositive,
  TradingError,
} from './shared';

// ─── PHON Staking ────────────────────────────────────────────────────────────
// Pool-based variable rewards. APR is an ESTIMATE, never guaranteed.
// Reward accrues linearly: reward = principal × apr × (elapsedDays / 365).

export type StakingTerm = 'flexible' | 'days_7' | 'days_30' | 'days_90';

export interface StakingTermConfig {
  readonly term: StakingTerm;
  /** lock duration in days; 0 for flexible */
  readonly lockDays: number;
  /** estimated APR as decimal string, e.g. "0.12" = 12% */
  readonly estimatedApr: string;
}

export const DEFAULT_STAKING_TERMS: readonly StakingTermConfig[] = [
  { term: 'flexible', lockDays: 0, estimatedApr: '0.03' },
  { term: 'days_7', lockDays: 7, estimatedApr: '0.06' },
  { term: 'days_30', lockDays: 30, estimatedApr: '0.12' },
  { term: 'days_90', lockDays: 90, estimatedApr: '0.20' },
];

export interface RewardEstimateParams {
  /** staked PHON principal */
  readonly principal: string;
  /** estimated APR, decimal string */
  readonly apr: string;
  /** number of days the principal is staked */
  readonly days: string;
}

export interface RewardEstimate {
  readonly principal: string;
  readonly apr: string;
  readonly days: string;
  /** estimated reward in PHON (truncated) */
  readonly estimatedReward: string;
  /** principal + estimatedReward */
  readonly estimatedTotal: string;
}

/**
 * Estimates a PHON staking reward. This is purely indicative — actual
 * rewards depend on the pool and may differ.
 */
export function estimateStakingReward(params: RewardEstimateParams): RewardEstimate {
  const principal = dec(params.principal, 'principal');
  const apr = dec(params.apr, 'apr');
  const days = dec(params.days, 'days');

  assertPositive(principal, 'principal', 'INVALID_AMOUNT');
  if (apr.isNegative()) {
    throw new TradingError('apr must not be negative', 'INVALID_AMOUNT');
  }
  if (days.isNegative()) {
    throw new TradingError('days must not be negative', 'INVALID_AMOUNT');
  }

  const reward = principal.mul(apr).mul(days.div(365));
  const total = principal.plus(reward);

  return {
    principal: toFixed(principal, 'PHON'),
    apr: apr.toFixed(),
    days: days.toFixed(),
    estimatedReward: toFixed(reward, 'PHON'),
    estimatedTotal: toFixed(total, 'PHON'),
  };
}

/**
 * Computes the accrued reward between two timestamps (ms epoch) for an
 * active position, used at claim/unstake time.
 */
export function computeAccruedReward(
  principal: string,
  apr: string,
  stakedAtMs: number,
  nowMs: number,
): string {
  if (!Number.isFinite(stakedAtMs) || !Number.isFinite(nowMs) || nowMs < stakedAtMs) {
    throw new TradingError('invalid timestamps for reward accrual', 'INVALID_AMOUNT');
  }
  const elapsedMs = new Decimal(nowMs - stakedAtMs);
  const elapsedDays = elapsedMs.div(1000 * 60 * 60 * 24);
  const reward = dec(principal, 'principal').mul(dec(apr, 'apr')).mul(elapsedDays.div(365));
  return toFixed(reward, 'PHON');
}

/** Whether a locked staking position can be unstaked at `nowMs`. */
export function canUnstake(
  term: StakingTerm,
  lockDays: number,
  stakedAtMs: number,
  nowMs: number,
): boolean {
  if (term === 'flexible' || lockDays <= 0) return true;
  const unlockMs = stakedAtMs + lockDays * 24 * 60 * 60 * 1000;
  return nowMs >= unlockMs;
}
