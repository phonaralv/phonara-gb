import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useWallet } from '../hooks/use-wallet';
import {
  useStakingPools,
  useStakingPositions,
  useStakingActions,
  type StakingPool,
  type StakingPosition,
} from '../hooks/use-trading';
import { estimateStakingReward } from '@phonara/trading-engine';
import { formatMoney, ConfirmDialog, Button, Card, Stat, Badge, Input, EmptyState, Skeleton } from '@phonara/ui';
import type { MessageKey } from '@phonara/i18n';
import { isPositiveAmount, ratePercent } from '../lib/money-display';
import { useI18n, useT } from '../lib/i18n';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/staking',
  component: StakingPage,
});

const TERM_KEYS: Record<string, MessageKey> = {
  flexible: 'staking.term.flexible',
  days_7: 'staking.term.days_7',
  days_30: 'staking.term.days_30',
  days_90: 'staking.term.days_90',
};

function StakingPage() {
  const t = useT();
  const { session, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const { wallet } = useWallet();
  const pools = useStakingPools();
  const { positions, refresh } = useStakingPositions();

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  if (authLoading) {
    return (
      <div className="shell">
        <Card className="grid w-full max-w-md gap-4 p-5" aria-busy="true">
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-28" />
          <Skeleton className="h-10" />
        </Card>
      </div>
    );
  }

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <Link to="/dashboard" className="logo-name" style={{ textDecoration: 'none' }}>← PHONARA</Link>
          </div>
          <nav className="dash-nav">
            <Link to="/trade" className="nav-link">{t('nav.trade')}</Link>
            <Link to="/dashboard" className="nav-link">{t('nav.dashboard')}</Link>
          </nav>
        </header>

        <section className="staking-section">
          <h2 className="section-title">
            {t('staking.title')}
            <span className="section-sub">{t('staking.subtitle')}</span>
          </h2>
          <p className="staking-disclaimer">
            {t('staking.disclaimer')}
          </p>

          <div className="pools-grid">
            {pools.map(pool => (
              <StakeCard key={pool.id} pool={pool} phonAvail={wallet?.phon_available ?? '0'} onStaked={refresh} />
            ))}
          </div>
        </section>

        <ActivePositions positions={positions} onChange={refresh} />
      </div>
    </div>
  );
}

function StakeCard({ pool, phonAvail, onStaked }: { pool: StakingPool; phonAvail: string; onStaked: () => void }) {
  const t = useT();
  const [amount, setAmount] = useState('1000');
  const [confirmOpen, setConfirmOpen] = useState(false);
  const { stake, busy, error } = useStakingActions(onStaked);

  const aprPct = ratePercent(pool.estimated_apr);
  const days = pool.lock_days > 0 ? String(pool.lock_days) : '365';
  const est = (() => {
    try {
      if (!isPositiveAmount(amount)) return null;
      return estimateStakingReward({ principal: amount, apr: pool.estimated_apr, days });
    } catch { return null; }
  })();

  const termLabel = TERM_KEYS[pool.term] ? t(TERM_KEYS[pool.term]!) : pool.term;

  async function submitStake() {
    await stake(pool.term, amount);
    setConfirmOpen(false);
  }

  return (
    <Card className="flex flex-col gap-2.5 p-4">
      <div className="flex items-center justify-between">
        <span className="text-[0.9rem] font-semibold text-fg">{TERM_KEYS[pool.term] ? t(TERM_KEYS[pool.term]!) : pool.term}</span>
        <span className="text-base font-extrabold text-up">{aprPct}% APR</span>
      </div>
      <div className="field-row">
        <Input inputMode="decimal" value={amount} onChange={e => setAmount(e.target.value)} className="flex-1 min-w-0 text-right" />
        <span className="input-suffix">PHON</span>
      </div>
      <div className="field-hint">{t('staking.holding')}: {formatMoney(phonAvail, 'PHON')}</div>
      {est && (
        <div className="flex flex-col gap-1.5 rounded-xl bg-surface-2/60 px-3 py-2.5">
          <Stat
            label={pool.lock_days > 0 ? t('staking.estRewardAfter', { days: pool.lock_days }) : t('staking.estRewardAnnual')}
            value={`${formatMoney(est.estimatedReward, 'PHON', { signed: true })} PHON`}
            tone="up"
          />
        </div>
      )}
      {error && <p className="card-error">{t(error)}</p>}
      <Button
        variant="success"
        full
        data-testid="stake-submit"
        disabled={busy || !est}
        onClick={() => setConfirmOpen(true)}
      >
        {busy ? t('common.processing') : t('staking.stakeBtn')}
      </Button>

      <ConfirmDialog
        open={confirmOpen}
        title={t('confirm.stake.title')}
        rows={[
          { label: t('confirm.row.term'), value: termLabel },
          { label: t('confirm.row.amount'), value: `${formatMoney(amount, 'PHON')} PHON` },
          {
            label: pool.lock_days > 0
              ? t('staking.estRewardAfter', { days: pool.lock_days })
              : t('staking.estRewardAnnual'),
            value: `${formatMoney(est?.estimatedReward ?? '0', 'PHON')} PHON`,
          },
        ]}
        confirmLabel={t('staking.stakeBtn')}
        cancelLabel={t('common.cancel')}
        processingLabel={t('common.processing')}
        busy={busy}
        testId="stake"
        onConfirm={() => void submitStake()}
        onCancel={() => setConfirmOpen(false)}
      />
    </Card>
  );
}

function ActivePositions({ positions, onChange }: { positions: ReturnType<typeof useStakingPositions>['positions']; onChange: () => void }) {
  const t = useT();
  const { locale } = useI18n();
  const dateLocale = locale === 'ko' ? 'ko-KR' : 'en-US';
  const { unstake, claim, busy } = useStakingActions(onChange);
  const [pending, setPending] = useState<{ type: 'unstake' | 'claim'; pos: StakingPosition } | null>(null);
  const active = positions.filter(p => p.status === 'active');

  async function submitPending() {
    if (!pending) return;
    if (pending.type === 'unstake') await unstake(pending.pos.id);
    else await claim(pending.pos.id);
    setPending(null);
  }

  return (
    <section className="positions-section">
      <h2 className="section-title">{t('staking.myStaking')}</h2>
      {active.length === 0 && <EmptyState data-testid="staking-empty" title={t('staking.noneActive')} />}
      {active.map(pos => {
        const locked = pos.unlock_at ? new Date(pos.unlock_at) > new Date() : false;
        return (
          <Card key={pos.id} className="mb-3 flex flex-col gap-2.5 p-4">
            <div className="flex items-center gap-2">
              <Badge tone="up">{TERM_KEYS[pos.term] ? t(TERM_KEYS[pos.term]!) : pos.term}</Badge>
              <span className="text-sm text-muted">{ratePercent(pos.apr_snapshot)}% APR</span>
            </div>
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              <Stat layout="stack" label={t('staking.principal')} value={`${formatMoney(pos.principal, 'PHON')} PHON`} />
              <Stat layout="stack" label={t('staking.rewardReceived')} value={`${formatMoney(pos.reward_claimed, 'PHON')} PHON`} tone="up" />
              {pos.unlock_at && <Stat layout="stack" label={t('staking.unlockAt')} value={new Date(pos.unlock_at).toLocaleDateString(dateLocale)} />}
            </div>
            <div className="flex gap-2">
              <Button variant="primary" size="sm" className="flex-1" data-testid="stake-claim" disabled={busy} onClick={() => setPending({ type: 'claim', pos })}>{t('staking.claimReward')}</Button>
              <Button variant="secondary" size="sm" data-testid="stake-unstake" disabled={busy || locked} onClick={() => setPending({ type: 'unstake', pos })}>
                {locked ? t('staking.locked') : t('staking.unstake')}
              </Button>
            </div>
          </Card>
        );
      })}

      <ConfirmDialog
        open={pending !== null}
        title={t(pending?.type === 'unstake' ? 'confirm.unstake.title' : 'confirm.claim.title')}
        description={t(pending?.type === 'unstake' ? 'confirm.unstakeNote' : 'confirm.claimNote')}
        tone={pending?.type === 'unstake' ? 'danger' : 'primary'}
        rows={pending ? [
          { label: t('staking.principal'), value: `${formatMoney(pending.pos.principal, 'PHON')} PHON` },
          { label: t('staking.rewardReceived'), value: `${formatMoney(pending.pos.reward_claimed, 'PHON')} PHON` },
        ] : []}
        confirmLabel={t(pending?.type === 'unstake' ? 'staking.unstake' : 'staking.claimReward')}
        cancelLabel={t('common.cancel')}
        processingLabel={t('common.processing')}
        busy={busy}
        testId="staking-action"
        onConfirm={() => void submitPending()}
        onCancel={() => setPending(null)}
      />
    </section>
  );
}
