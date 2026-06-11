import { createRoute } from '@tanstack/react-router';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { useT } from '../lib/i18n';
import { supabase } from '../lib/supabase';
import { useAppConfig } from '../hooks/use-app-config';
import { Badge, Button, Card, ErrorState, Skeleton } from '@phonara/ui';
import type { Json } from '@phonara/shared-types';
import type { MessageKey } from '@phonara/i18n';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/overview',
  component: OverviewPage,
});

function OverviewPage() {
  const t = useT();
  const qc = useQueryClient();
  const { data: fallbackConfig } = useAppConfig();
  const { data, error, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['ops-health'],
    queryFn: fetchOpsHealth,
    staleTime: 60_000,
    refetchInterval: 60_000,
  });

  const checks = data?.checks ?? [];
  const systemMode = findCheck(checks, 'system_mode');
  const reconciliation = findCheck(checks, 'reconciliation_latest');
  const cronLiveness = findCheck(checks, 'cron_liquidation_liveness');
  const liquidationError = findCheck(checks, 'liquidation_recent_error');
  const treasuryFreshness = findCheck(checks, 'treasury_freshness');
  const operatorActions = findCheck(checks, 'operator_high_risk_actions');
  const hashChainIntegrity = findCheck(checks, 'hash_chain_integrity');
  const pendingExceptions = findCheck(checks, 'pending_exceptions');
  const treasurySolvency = findCheck(checks, 'treasury_solvency');

  function refreshAll() {
    void refetch();
    void qc.invalidateQueries({ queryKey: ['app-config'] });
  }

  return (
    <AdminLayout>
      <div className="space-y-6" data-testid="overview-page">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 className="text-2xl font-bold text-fg">{t('admin.overview.title')}</h1>
            <p className="text-muted">{t('admin.overview.description')}</p>
            {data?.lastUpdatedAt && (
              <p className="mt-2 text-xs text-muted tabular-nums">
                {t('admin.overview.lastUpdated')}: {formatDateTime(data.lastUpdatedAt)}
              </p>
            )}
          </div>
          <Button
            variant="secondary"
            size="sm"
            onClick={refreshAll}
            disabled={isFetching}
            data-testid="ops-health-refresh"
          >
            {t('admin.overview.refresh')}
          </Button>
        </div>

        {isLoading && (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3" aria-busy="true">
            <Skeleton className="h-40" />
            <Skeleton className="h-40" />
            <Skeleton className="h-40" />
            <Skeleton className="h-40" />
            <Skeleton className="h-40" />
            <Skeleton className="h-40" />
          </div>
        )}

        {!isLoading && error && (
          <div className="space-y-4">
            <ErrorState
              data-testid="ops-health-error"
              title={t('admin.overview.healthUnavailable.title')}
              description={t('admin.overview.healthUnavailable.description')}
            />
            <Card className="p-5" data-testid="ops-health-fallback">
              <CardHeaderLine title={t('admin.overview.card.systemMode')} status="critical" />
              <div className="mt-4 space-y-2 text-sm text-muted">
                <p>
                  {t('admin.overview.fallback.systemHalt', {
                    value: fallbackConfig?.['system_halt'] ?? 'unknown',
                  })}
                </p>
                <p>
                  {t('admin.overview.fallback.systemReadonly', {
                    value: fallbackConfig?.['system_readonly'] ?? 'unknown',
                  })}
                </p>
              </div>
            </Card>
          </div>
        )}

        {!isLoading && !error && (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <HealthCard
              title={t('admin.overview.card.systemMode')}
              check={systemMode}
              testId="ops-card-system-mode"
            />
            <HealthCard
              title={t('admin.overview.card.reconciliation')}
              check={reconciliation}
              testId="ops-card-reconciliation"
            />
            <CombinedHealthCard
              title={t('admin.overview.card.cronLiquidation')}
              checks={[cronLiveness, liquidationError]}
              testId="ops-card-cron-liquidation"
            />
            <HealthCard
              title={t('admin.overview.card.treasuryFreshness')}
              check={treasuryFreshness}
              testId="ops-card-treasury"
            />
            <CombinedHealthCard
              title={t('admin.overview.card.riskSignals')}
              checks={[hashChainIntegrity, pendingExceptions, treasurySolvency]}
              testId="ops-card-risk-signals"
            />
            <HealthCard
              title={t('admin.overview.card.operatorActions')}
              check={operatorActions}
              testId="ops-card-operator-actions"
              className="md:col-span-2 xl:col-span-1"
            />
          </div>
        )}
      </div>
    </AdminLayout>
  );
}

type HealthStatus = 'ok' | 'warning' | 'critical';
type CheckId =
  | 'system_mode'
  | 'reconciliation_latest'
  | 'cron_liquidation_liveness'
  | 'liquidation_recent_error'
  | 'treasury_freshness'
  | 'operator_high_risk_actions'
  | 'hash_chain_integrity'
  | 'pending_exceptions'
  | 'treasury_solvency';

type MetadataField = 'lastSuccessfulAt' | 'lastRunAt' | 'lastErrorAt' | 'observedAt';

interface OpsHealthCheck {
  id: CheckId;
  status: HealthStatus;
  summary: string;
  observedAt: string | null;
  lastRunAt: string | null;
  lastSuccessfulAt: string | null;
  lastErrorAt: string | null;
  runbookKey: string;
}

interface MetadataConfig {
  fields: MetadataField[];
  observedLabelKey?: MessageKey;
  lastRunLabelKey?: MessageKey;
  lastErrorLabelKey?: MessageKey;
}

interface MetadataEntry {
  labelKey: MessageKey;
  value: string | null;
  showWhenMissing: boolean;
}

interface OpsHealthResponse {
  status: HealthStatus;
  lastUpdatedAt: string;
  checks: OpsHealthCheck[];
}

const CHECK_METADATA_CONFIG: Partial<Record<CheckId, MetadataConfig>> = {
  reconciliation_latest: { fields: ['lastSuccessfulAt', 'lastRunAt'] },
  cron_liquidation_liveness: { fields: ['lastRunAt', 'lastSuccessfulAt'] },
  liquidation_recent_error: { fields: ['lastErrorAt'] },
  treasury_freshness: {
    fields: ['observedAt'],
    observedLabelKey: 'admin.overview.meta.oldestAttestation',
  },
  operator_high_risk_actions: {
    fields: ['observedAt'],
    observedLabelKey: 'admin.overview.meta.lastAction',
  },
  hash_chain_integrity: { fields: ['lastRunAt', 'lastSuccessfulAt', 'lastErrorAt'] },
  pending_exceptions: {
    fields: ['lastRunAt', 'lastErrorAt'],
    lastRunLabelKey: 'admin.overview.meta.oldestOpen',
    lastErrorLabelKey: 'admin.overview.meta.oldestOverdue',
  },
  treasury_solvency: {
    fields: ['observedAt', 'lastSuccessfulAt'],
    observedLabelKey: 'admin.overview.meta.oldestAttestation',
  },
};

async function fetchOpsHealth(): Promise<OpsHealthResponse> {
  const { data, error } = await supabase.rpc('rpc_get_ops_health');
  if (error) throw error;
  return parseOpsHealth(data);
}

function parseOpsHealth(value: Json): OpsHealthResponse {
  if (!isRecord(value)) throw new Error('invalid_ops_health');
  const status = parseStatus(value['status']);
  const lastUpdatedAt =
    typeof value['lastUpdatedAt'] === 'string' ? value['lastUpdatedAt'] : new Date().toISOString();
  const rawChecks = Array.isArray(value['checks']) ? value['checks'] : [];
  return {
    status,
    lastUpdatedAt,
    checks: rawChecks.map(parseCheck).filter((check): check is OpsHealthCheck => check !== null),
  };
}

function parseCheck(value: Json): OpsHealthCheck | null {
  if (!isRecord(value)) return null;
  const id = parseCheckId(value['id']);
  if (!id) return null;
  return {
    id,
    status: parseStatus(value['status']),
    summary: typeof value['summary'] === 'string' ? value['summary'] : '',
    observedAt: parseOptionalTimestamp(value['observedAt']),
    lastRunAt: parseOptionalTimestamp(value['lastRunAt']),
    lastSuccessfulAt: parseOptionalTimestamp(value['lastSuccessfulAt']),
    lastErrorAt: parseOptionalTimestamp(value['lastErrorAt']),
    runbookKey: typeof value['runbookKey'] === 'string' ? value['runbookKey'] : '',
  };
}

function parseOptionalTimestamp(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return value;
}

function isRecord(value: Json | unknown): value is Record<string, Json | undefined> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseStatus(value: unknown): HealthStatus {
  return value === 'critical' || value === 'warning' || value === 'ok' ? value : 'warning';
}

function parseCheckId(value: unknown): CheckId | null {
  if (
    value === 'system_mode' ||
    value === 'reconciliation_latest' ||
    value === 'cron_liquidation_liveness' ||
    value === 'liquidation_recent_error' ||
    value === 'treasury_freshness' ||
    value === 'operator_high_risk_actions' ||
    value === 'hash_chain_integrity' ||
    value === 'pending_exceptions' ||
    value === 'treasury_solvency'
  ) {
    return value;
  }
  return null;
}

function findCheck(checks: OpsHealthCheck[], id: CheckId): OpsHealthCheck | undefined {
  return checks.find((check) => check.id === id);
}

function metadataLabelKey(field: MetadataField, config?: MetadataConfig): MessageKey {
  if (field === 'observedAt') {
    return config?.observedLabelKey ?? 'admin.overview.observedAt';
  }
  if (field === 'lastSuccessfulAt') return 'admin.overview.meta.lastSuccessfulAt';
  if (field === 'lastRunAt') {
    return config?.lastRunLabelKey ?? 'admin.overview.meta.lastRunAt';
  }
  return config?.lastErrorLabelKey ?? 'admin.overview.meta.lastErrorAt';
}

function getMetadataFieldValue(check: OpsHealthCheck, field: MetadataField): string | null {
  return check[field];
}

function buildMetadataEntries(
  check: OpsHealthCheck | undefined,
  config: MetadataConfig | undefined,
): MetadataEntry[] {
  if (!check || !config) {
    return [
      {
        labelKey: 'admin.overview.observedAt',
        value: check?.observedAt ?? null,
        showWhenMissing: true,
      },
    ];
  }

  const entries: MetadataEntry[] = [];

  for (const field of config.fields) {
    const value = getMetadataFieldValue(check, field);
    const isObserved = field === 'observedAt';
    if (value || isObserved) {
      entries.push({
        labelKey: metadataLabelKey(field, config),
        value,
        showWhenMissing: isObserved,
      });
    }
  }

  if (entries.length === 0 && !config.fields.includes('observedAt')) {
    entries.push({
      labelKey: 'admin.overview.observedAt',
      value: check.observedAt,
      showWhenMissing: true,
    });
  }

  return entries;
}

function HealthCard({
  title,
  check,
  testId,
  className = '',
}: {
  title: string;
  check: OpsHealthCheck | undefined;
  testId: string;
  className?: string;
}) {
  const t = useT();
  const status = check?.status ?? 'warning';
  return (
    <Card className={`p-5 ${className}`} data-testid={testId}>
      <CardHeaderLine title={title} status={status} />
      <p className="mt-4 text-sm text-fg">{check?.summary ?? t('admin.overview.noObservedAt')}</p>
      <CheckMeta check={check} />
    </Card>
  );
}

function CombinedHealthCard({
  title,
  checks,
  testId,
}: {
  title: string;
  checks: Array<OpsHealthCheck | undefined>;
  testId: string;
}) {
  const t = useT();
  const status = worstStatus(checks.map((check) => check?.status ?? 'warning'));
  return (
    <Card className="p-5" data-testid={testId}>
      <CardHeaderLine title={title} status={status} />
      <div className="mt-4 space-y-4">
        {checks.map((check) => (
          <div
            key={check?.id ?? 'missing'}
            className="rounded-xl border border-border bg-surface-2/40 p-3"
          >
            <CardHeaderLine
              title={check ? t(checkLabelKey(check.id)) : t('admin.overview.noObservedAt')}
              status={check?.status ?? 'warning'}
              compact
            />
            <p className="mt-2 text-sm text-fg">{check?.summary}</p>
            <CheckMeta check={check} />
          </div>
        ))}
      </div>
    </Card>
  );
}

function CardHeaderLine({
  title,
  status,
  compact = false,
}: {
  title: string;
  status: HealthStatus;
  compact?: boolean;
}) {
  const t = useT();
  return (
    <div className="flex items-center justify-between gap-3">
      <h2
        className={compact ? 'text-xs font-semibold text-muted' : 'text-sm font-semibold text-fg'}
      >
        {title}
      </h2>
      <Badge tone={statusTone(status)} size="sm">
        {t(statusLabelKey(status))}
      </Badge>
    </div>
  );
}

function CheckMeta({ check }: { check: OpsHealthCheck | undefined }) {
  const t = useT();
  const config = check ? CHECK_METADATA_CONFIG[check.id] : undefined;
  const entries = buildMetadataEntries(check, config);

  return (
    <div className="mt-4 space-y-1 text-xs text-muted">
      {entries.map((entry) => (
        <p key={entry.labelKey}>
          {t(entry.labelKey)}:{' '}
          <span className="tabular-nums">
            {entry.value
              ? formatDateTime(entry.value)
              : entry.showWhenMissing
                ? t('admin.overview.noObservedAt')
                : null}
          </span>
        </p>
      ))}
      {check?.runbookKey && (
        <p>
          {t('admin.overview.runbook')}: <span className="font-mono">{check.runbookKey}</span>
        </p>
      )}
    </div>
  );
}

function worstStatus(statuses: HealthStatus[]): HealthStatus {
  if (statuses.includes('critical')) return 'critical';
  if (statuses.includes('warning')) return 'warning';
  return 'ok';
}

function statusTone(status: HealthStatus): 'up' | 'warning' | 'down' {
  if (status === 'critical') return 'down';
  if (status === 'warning') return 'warning';
  return 'up';
}

function statusLabelKey(status: HealthStatus): MessageKey {
  if (status === 'critical') return 'admin.overview.status.critical';
  if (status === 'warning') return 'admin.overview.status.warning';
  return 'admin.overview.status.ok';
}

function checkLabelKey(id: CheckId): MessageKey {
  if (id === 'system_mode') return 'admin.overview.card.systemMode';
  if (id === 'reconciliation_latest') return 'admin.overview.card.reconciliation';
  if (id === 'cron_liquidation_liveness') return 'admin.overview.check.cronLiveness';
  if (id === 'liquidation_recent_error') return 'admin.overview.check.liquidationError';
  if (id === 'treasury_freshness') return 'admin.overview.card.treasuryFreshness';
  if (id === 'hash_chain_integrity') return 'admin.overview.check.hashChainIntegrity';
  if (id === 'pending_exceptions') return 'admin.overview.check.pendingExceptions';
  if (id === 'treasury_solvency') return 'admin.overview.check.treasurySolvency';
  return 'admin.overview.card.operatorActions';
}

function formatDateTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}
