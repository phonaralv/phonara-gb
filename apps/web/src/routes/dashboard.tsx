import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { signOut } from '../lib/auth';
import { useWallet } from '../hooks/use-wallet';
import { formatMoney, Badge, Button, Card, Skeleton } from '@phonara/ui';
import { useT } from '../lib/i18n';
import { WelcomeModal } from '../components/welcome-modal';
import { DailyClaimCard } from '../components/daily-claim-card';
import { RouletteCard } from '../components/roulette-card';
import { MissionsCard } from '../components/missions-card';
import { ReferralDashboardCard } from '../components/referral-dashboard-card';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/dashboard',
  component: DashboardPage,
});

function DashboardPage() {
  const t = useT();
  const { session, loading: authLoading } = useAuth();
  const { wallet, loading: walletLoading, error } = useWallet();
  const navigate = useNavigate();
  const [showWelcome, setShowWelcome] = useState(false);

  useEffect(() => {
    if (!authLoading && !session) {
      void navigate({ to: '/login' });
    }
  }, [session, authLoading, navigate]);

  // Show welcome modal for new users (no wallet balance yet)
  useEffect(() => {
    if (!walletLoading && wallet) {
      const isNew =
        wallet.phon_available === '0.000000' &&
        wallet.usdt_available === '0.000000' &&
        wallet.krw_available === '0';
      if (isNew) setShowWelcome(true);
    }
  }, [wallet, walletLoading]);

  async function handleSignOut() {
    await signOut();
    void navigate({ to: '/login' });
  }

  if (authLoading) {
    return (
      <div className="shell">
        <Card className="grid w-full max-w-md gap-4 p-5" aria-busy="true">
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-24" />
          <Skeleton className="h-10" />
        </Card>
      </div>
    );
  }

  return (
    <div className="shell">
      {showWelcome && (
        <WelcomeModal onDismiss={() => setShowWelcome(false)} />
      )}

      <div className="dashboard" data-testid="dashboard-page">
        <header className="dash-header">
          <div className="dash-logo">
            <span className="logo-mark">P</span>
            <span className="logo-name">PHONARA</span>
          </div>
          <nav className="dash-nav">
            <Link to="/ledger" className="nav-link">{t('nav.ledgerHistory')}</Link>
            <Button variant="outline" size="sm" onClick={handleSignOut}>{t('nav.logout')}</Button>
          </nav>
        </header>

        <section className="wallet-section">
          <h2 className="section-title">{t('wallet.title')}</h2>

          {walletLoading && (
            <div className="wallet-grid">
              {['PHON', 'USDT', 'KRW'].map(c => (
                <Card key={c} className="h-[120px] animate-pulse bg-surface-2/40" />
              ))}
            </div>
          )}

          {error && <p className="error-msg">{t('wallet.loadError')}</p>}

          {wallet && !walletLoading && (
            <>
              <Card className="mb-4 flex flex-col gap-3 p-4 md:flex-row md:items-center md:justify-between">
                <div>
                  <p className="text-sm font-semibold text-fg">{t('dashboard.balanceSummary')}</p>
                  <p className="mt-1 text-xs text-muted">{t('dashboard.balanceSummaryDesc')}</p>
                </div>
                <Badge tone={wallet.phon_locked !== '0.000000' ? 'warning' : 'primary'}>
                  {wallet.phon_locked !== '0.000000' ? t('dashboard.badge.locked') : t('dashboard.badge.live')}
                </Badge>
              </Card>
              <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                <WalletCard currency="PHON" available={wallet.phon_available} locked={wallet.phon_locked} />
                <WalletCard currency="USDT" available={wallet.usdt_available} locked={wallet.usdt_locked} />
                <WalletCard currency="KRW" available={wallet.krw_available} locked={wallet.krw_locked} />
              </div>
            </>
          )}
        </section>

        <section className="px-5 pb-4">
          <h2 className="section-title flex flex-col gap-1 sm:flex-row sm:items-baseline">
            {t('dashboard.rewardCenter')}
            <span className="text-xs font-normal text-muted">{t('dashboard.rewardCenterSub')}</span>
          </h2>
          <div className="mb-3 grid grid-cols-1 gap-3 lg:grid-cols-3">
            <DailyClaimCard />
            <RouletteCard />
            <ReferralDashboardCard />
          </div>
          <MissionsCard />
        </section>

        <section className="quick-section">
          <h2 className="section-title">{t('dashboard.quickMenu')}</h2>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <QuickLink to="/ledger" label={t('nav.ledgerHistory')} />
            <QuickLink to="/wallet" label={t('dashboard.krwDeposit')} />
            <QuickLink to="/trade" label={t('nav.trade')} />
            <QuickLink to="/staking" label={t('nav.staking')} />
            <QuickLink to="/casino" label={t('dashboard.casino')} />
          </div>
        </section>
      </div>
    </div>
  );
}

function WalletCard({
  currency,
  available,
  locked,
}: {
  currency: 'PHON' | 'USDT' | 'KRW';
  available: string;
  locked: string;
}) {
  const t = useT();
  const fmtAvail = formatMoney(available, currency);
  const fmtLocked = formatMoney(locked, currency);
  const hasLocked = locked !== '0' && locked !== '0.000000';

  return (
    <Card className="relative flex flex-col gap-3 overflow-hidden p-5 transition-colors before:absolute before:inset-x-0 before:top-0 before:h-0.5 before:bg-primary hover:border-border-strong">
      <div className="flex items-center justify-between">
        <span className="text-xs font-bold tracking-wide text-primary">{currency}</span>
        <Badge tone={hasLocked ? 'warning' : 'neutral'}>{hasLocked ? t('wallet.lockedShort') : t('common.available')}</Badge>
      </div>
      <div>
        <span className="mb-1 block text-xs text-muted">{t('wallet.available')}</span>
        <span className="text-2xl font-bold tabular-nums text-fg">{fmtAvail}</span>
      </div>
      {hasLocked && (
        <div>
          <span className="mb-1 block text-xs text-muted">{t('wallet.lockedShort')}</span>
          <span className="text-sm font-medium tabular-nums text-muted">{fmtLocked}</span>
        </div>
      )}
    </Card>
  );
}

function QuickLink({ to, label }: { to: '/ledger' | '/wallet' | '/trade' | '/staking' | '/casino'; label: string }) {
  return (
    <Link to={to} className="rounded-2xl border border-border bg-surface p-4 text-sm font-semibold text-fg transition-colors hover:border-border-strong hover:bg-surface-2">
      {label}
    </Link>
  );
}
