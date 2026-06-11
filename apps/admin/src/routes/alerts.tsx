import { createRoute } from '@tanstack/react-router';
import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { AdminActionDialog } from '../components/admin-action-dialog';
import { supabase } from '../lib/supabase';
import { useT } from '../lib/i18n';
import { Badge, Button, Card, DataTable, type ColumnDef } from '@phonara/ui';
import type { Json } from '@phonara/shared-types';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/alerts',
  component: AlertsPage,
});

type AlertStatus = 'open' | 'acknowledged' | 'resolved';
type AlertSeverity = 'warning' | 'critical';

type AlertAction = { kind: 'ack'; id: string } | { kind: 'resolve'; id: string };

interface OpsAlertRow {
  id: string;
  dedupe_key: string;
  source_check_id: string;
  severity: AlertSeverity;
  status: AlertStatus;
  summary: string;
  runbook_key: string;
  first_seen_at: string;
  last_seen_at: string;
  occurrence_count: number;
  acknowledged_at: string | null;
  resolved_at: string | null;
}

export function AlertsPage() {
  const t = useT();
  const qc = useQueryClient();
  const [action, setAction] = useState<AlertAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const { data, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['ops-alerts'],
    queryFn: fetchOpsAlerts,
    staleTime: 60_000,
    refetchInterval: 60_000,
  });

  const alerts = data?.alerts ?? [];
  const openCritical = alerts.filter((a) => a.status !== 'resolved' && a.severity === 'critical').length;
  const openWarning = alerts.filter((a) => a.status !== 'resolved' && a.severity === 'warning').length;
  const acknowledged = alerts.filter((a) => a.status === 'acknowledged').length;

  const columns = useMemo<ColumnDef<OpsAlertRow>[]>(
    () => [
      {
        key: 'severity',
        header: t('admin.alerts.col.severity'),
        cell: (row) => <SeverityBadge severity={row.severity} />,
      },
      {
        key: 'status',
        header: t('admin.alerts.col.status'),
        cell: (row) => <StatusBadge status={row.status} />,
      },
      {
        key: 'check',
        header: t('admin.alerts.col.check'),
        cell: (row) => <span className="font-mono text-xs">{row.source_check_id}</span>,
      },
      {
        key: 'summary',
        header: t('admin.alerts.col.summary'),
        cell: (row) => <span className="text-sm">{row.summary}</span>,
      },
      {
        key: 'occurrences',
        header: t('admin.alerts.col.occurrences'),
        cell: (row) => <span className="tabular-nums">{row.occurrence_count}</span>,
      },
      {
        key: 'lastSeen',
        header: t('admin.alerts.col.lastSeen'),
        cell: (row) => <span className="tabular-nums text-muted">{formatDate(row.last_seen_at)}</span>,
      },
      {
        key: 'runbook',
        header: t('admin.alerts.col.runbook'),
        cell: (row) => <span className="font-mono text-xs text-muted">{row.runbook_key}</span>,
      },
      {
        key: 'action',
        header: t('admin.alerts.col.action'),
        align: 'right',
        cell: (row) => (
          <div className="flex justify-end gap-2">
            {row.status === 'open' && (
              <Button
                size="sm"
                variant="outline"
                data-testid={`alert-ack-${row.id}`}
                onClick={() => setAction({ kind: 'ack', id: row.id })}
              >
                {t('admin.alerts.action.ack')}
              </Button>
            )}
            {row.status !== 'resolved' && (
              <Button
                size="sm"
                variant="primary"
                data-testid={`alert-resolve-${row.id}`}
                onClick={() => setAction({ kind: 'resolve', id: row.id })}
              >
                {t('admin.alerts.action.resolve')}
              </Button>
            )}
          </div>
        ),
      },
    ],
    [t],
  );

  async function handleSync() {
    setBusy(true);
    setErrorMsg(null);
    try {
      const { error } = await supabase.rpc('rpc_sync_ops_alerts_from_health');
      if (error) throw new Error(error.message);
      await invalidateAlertQueries(qc);
      await refetch();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : t('error.UNKNOWN'));
    } finally {
      setBusy(false);
    }
  }

  async function handleConfirm(reason: string) {
    if (!action) return;
    setBusy(true);
    setErrorMsg(null);
    try {
      if (action.kind === 'ack') {
        const { error } = await supabase.rpc('rpc_ack_ops_alert', {
          p_alert_id: action.id,
          p_reason: reason,
        });
        if (error) throw new Error(error.message);
      } else {
        const { error } = await supabase.rpc('rpc_resolve_ops_alert', {
          p_alert_id: action.id,
          p_reason: reason,
        });
        if (error) throw new Error(error.message);
      }
      await invalidateAlertQueries(qc);
      setAction(null);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : t('error.UNKNOWN'));
    } finally {
      setBusy(false);
    }
  }

  return (
    <AdminLayout>
      <div className="space-y-6" data-testid="admin-alerts-page">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 className="text-2xl font-bold text-fg">{t('admin.alerts.title')}</h1>
            <p className="text-muted mt-1">{t('admin.alerts.description')}</p>
            {data?.fetchedAt && (
              <p className="mt-2 text-xs text-muted tabular-nums">
                {t('admin.alerts.lastSynced')}: {formatDate(data.fetchedAt)}
              </p>
            )}
          </div>
          <Button
            variant="secondary"
            size="sm"
            onClick={handleSync}
            disabled={busy || isFetching}
            data-testid="ops-alerts-sync"
          >
            {t('admin.alerts.sync')}
          </Button>
        </div>

        {errorMsg && (
          <p className="text-down text-sm" role="alert" data-testid="admin-alerts-error">
            {errorMsg}
          </p>
        )}

        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          <MetricCard label={t('admin.alerts.metric.critical')} value={openCritical} />
          <MetricCard label={t('admin.alerts.metric.warning')} value={openWarning} />
          <MetricCard label={t('admin.alerts.metric.acknowledged')} value={acknowledged} />
        </div>

        <DataTable
          columns={columns}
          data={alerts}
          keyExtractor={(row) => row.id}
          emptyState={t('admin.alerts.empty')}
          loading={isLoading}
          size="sm"
          data-testid="admin-alerts-table"
        />
      </div>

      <AdminActionDialog
        open={action !== null}
        title={actionTitle(action, t)}
        description={t('admin.action.auditNote')}
        confirmLabel={t('admin.action.confirmApply')}
        cancelLabel={t('common.cancel')}
        tone={action?.kind === 'resolve' ? 'primary' : 'primary'}
        busy={busy}
        testId="admin-alert-action"
        resetKey={actionKey(action)}
        onConfirm={handleConfirm}
        onCancel={() => setAction(null)}
      />
    </AdminLayout>
  );
}

async function fetchOpsAlerts(): Promise<{ alerts: OpsAlertRow[]; fetchedAt: string }> {
  const { data, error } = await supabase.rpc('rpc_get_ops_alerts');
  if (error) throw error;
  return parseOpsAlertsResponse(data);
}

function parseOpsAlertsResponse(value: Json): { alerts: OpsAlertRow[]; fetchedAt: string } {
  if (!isRecord(value)) throw new Error('invalid_ops_alerts');
  const fetchedAt = typeof value['fetchedAt'] === 'string' ? value['fetchedAt'] : new Date().toISOString();
  const rawAlerts = Array.isArray(value['alerts']) ? value['alerts'] : [];
  return {
    fetchedAt,
    alerts: rawAlerts.map(parseAlertRow).filter((row): row is OpsAlertRow => row !== null),
  };
}

function parseAlertRow(value: Json): OpsAlertRow | null {
  if (!isRecord(value)) return null;
  const id = typeof value['id'] === 'string' ? value['id'] : null;
  const sourceCheckId = typeof value['source_check_id'] === 'string' ? value['source_check_id'] : null;
  const severity = value['severity'];
  const status = value['status'];
  if (!id || !sourceCheckId) return null;
  if (severity !== 'warning' && severity !== 'critical') return null;
  if (status !== 'open' && status !== 'acknowledged' && status !== 'resolved') return null;

  return {
    id,
    dedupe_key: typeof value['dedupe_key'] === 'string' ? value['dedupe_key'] : sourceCheckId,
    source_check_id: sourceCheckId,
    severity,
    status,
    summary: typeof value['summary'] === 'string' ? value['summary'] : '',
    runbook_key: typeof value['runbook_key'] === 'string' ? value['runbook_key'] : '',
    first_seen_at: typeof value['first_seen_at'] === 'string' ? value['first_seen_at'] : '',
    last_seen_at: typeof value['last_seen_at'] === 'string' ? value['last_seen_at'] : '',
    occurrence_count: typeof value['occurrence_count'] === 'number' ? value['occurrence_count'] : 1,
    acknowledged_at: typeof value['acknowledged_at'] === 'string' ? value['acknowledged_at'] : null,
    resolved_at: typeof value['resolved_at'] === 'string' ? value['resolved_at'] : null,
  };
}

function isRecord(value: Json | unknown): value is Record<string, Json | undefined> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function invalidateAlertQueries(qc: ReturnType<typeof useQueryClient>) {
  await Promise.all([
    qc.invalidateQueries({ queryKey: ['ops-alerts'] }),
    qc.invalidateQueries({ queryKey: ['ops-health'] }),
    qc.invalidateQueries({ queryKey: ['audit-logs'] }),
  ]);
}

function MetricCard({ label, value }: { label: string; value: number }) {
  return (
    <Card className="p-4">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-1 text-2xl font-bold text-fg tabular-nums">{value}</p>
    </Card>
  );
}

function SeverityBadge({ severity }: { severity: AlertSeverity }) {
  return <Badge tone={severity === 'critical' ? 'down' : 'warning'}>{severity}</Badge>;
}

function StatusBadge({ status }: { status: AlertStatus }) {
  const tone =
    status === 'open' ? 'warning' : status === 'acknowledged' ? 'primary' : 'neutral';
  return <Badge tone={tone}>{status}</Badge>;
}

function formatDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function actionTitle(action: AlertAction | null, t: ReturnType<typeof useT>) {
  if (!action) return '';
  return action.kind === 'ack'
    ? t('admin.alerts.dialog.ack')
    : t('admin.alerts.dialog.resolve');
}

function actionKey(action: AlertAction | null): string | null {
  return action ? `${action.kind}:${action.id}` : null;
}
