import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { useEffect } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useLedger } from '../hooks/use-wallet';
import type { MessageKey } from '@phonara/i18n';
import { useI18n, useT } from '../lib/i18n';
import { Badge, Card, DataTable, EmptyState, ErrorState, Skeleton, type ColumnDef, formatMoney } from '@phonara/ui';
import type { Tables } from '@phonara/shared-types';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/ledger',
  component: LedgerPage,
});

const DIRECTION_KEY: Record<string, MessageKey> = {
  credit: 'ledger.direction.credit',
  debit: 'ledger.direction.debit',
  lock: 'ledger.direction.lock',
  unlock: 'ledger.direction.unlock',
  reverse: 'ledger.direction.reverse',
};

type LedgerEntry = Tables<'wallet_ledger'>;

function LedgerPage() {
  const t = useT();
  const { locale } = useI18n();
  const dateFmt = new Intl.DateTimeFormat(locale === 'ko' ? 'ko-KR' : 'en-US', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
  const { session, loading: authLoading } = useAuth();
  const { entries, loading, error, refetch } = useLedger(50);
  const navigate = useNavigate();
  const columns: ColumnDef<LedgerEntry>[] = [
    {
      key: 'datetime',
      header: t('ledger.col.datetime'),
      cell: (entry) => <span className="text-muted tabular-nums">{dateFmt.format(new Date(entry.created_at))}</span>,
    },
    {
      key: 'type',
      header: t('ledger.col.type'),
      cell: (entry) => <DirectionBadge direction={entry.direction} />,
    },
    {
      key: 'currency',
      header: t('ledger.col.currency'),
      cell: (entry) => <span className="font-bold tracking-wide">{entry.currency}</span>,
    },
    {
      key: 'amount',
      header: t('ledger.col.amount'),
      cell: (entry) => <span className="font-semibold tabular-nums">{formatMoney(entry.amount, entry.currency)}</span>,
    },
    {
      key: 'reason',
      header: t('ledger.col.reason'),
      cell: (entry) => <span className="text-muted">{entry.reason_code}</span>,
    },
    {
      key: 'balance',
      header: t('ledger.col.balanceAfter'),
      cell: (entry) => <span className="text-muted tabular-nums">{formatMoney(entry.available_after, entry.currency)}</span>,
    },
  ];

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <span className="logo-mark">P</span>
            <span className="logo-name">PHONARA</span>
          </div>
          <nav className="dash-nav">
            <Link to="/dashboard" className="nav-link">{t('nav.dashboard')}</Link>
          </nav>
        </header>

        <section className="wallet-section">
          <h2 className="section-title">{t('ledger.title')}</h2>

          {loading && <Skeleton className="h-[240px]" data-testid="ledger-loading" />}

          {!loading && error && (
            <ErrorState
              data-testid="ledger-error"
              title={t('wallet.loadError')}
              description={t(error)}
              actionLabel={t('common.retry')}
              onAction={() => void refetch()}
            />
          )}

          {!loading && !error && entries.length === 0 && (
            <EmptyState data-testid="ledger-empty" title={t('ledger.empty')} />
          )}

          {!loading && !error && entries.length > 0 && (
            <div className="space-y-3">
              <div className="hidden md:block">
                <DataTable
                  columns={columns}
                  data={entries}
                  keyExtractor={(entry) => entry.id}
                  emptyState={t('ledger.empty')}
                  size="sm"
                  data-testid="ledger-table"
                />
              </div>
              <div className="grid gap-3 md:hidden" data-testid="ledger-mobile-list">
                {entries.map((entry) => (
                  <Card key={entry.id} className="grid gap-3 p-4">
                    <div className="flex items-center justify-between gap-3">
                      <DirectionBadge direction={entry.direction} />
                      <span className="text-xs text-muted">{dateFmt.format(new Date(entry.created_at))}</span>
                    </div>
                    <div className="flex items-end justify-between gap-3">
                      <div>
                        <p className="text-xs text-muted">{entry.reason_code}</p>
                        <p className="mt-1 text-sm font-bold tracking-wide text-fg">{entry.currency}</p>
                      </div>
                      <div className="text-right">
                        <p className="text-sm font-semibold tabular-nums text-fg">{formatMoney(entry.amount, entry.currency)}</p>
                        <p className="mt-1 text-xs tabular-nums text-muted">
                          {t('ledger.col.balanceAfter')}: {formatMoney(entry.available_after, entry.currency)}
                        </p>
                      </div>
                    </div>
                  </Card>
                ))}
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

function DirectionBadge({ direction }: { direction: string }) {
  const t = useT();
  const tone =
    direction === 'credit' || direction === 'unlock'
      ? 'up'
      : direction === 'debit'
        ? 'down'
        : direction === 'lock'
          ? 'warning'
          : 'neutral';
  return <Badge tone={tone}>{DIRECTION_KEY[direction] ? t(DIRECTION_KEY[direction]!) : direction}</Badge>;
}
