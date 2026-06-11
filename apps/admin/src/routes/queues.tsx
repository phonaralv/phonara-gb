import { createRoute } from '@tanstack/react-router';
import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { AdminActionDialog } from '../components/admin-action-dialog';
import { supabase } from '../lib/supabase';
import { translateError } from '../lib/translate-error';
import { useT } from '../lib/i18n';
import { Badge, Button, Card, DataTable, type ColumnDef } from '@phonara/ui';
import type { Tables } from '@phonara/shared-types';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/queues',
  component: QueuesPage,
});

type ReviewQueueRow = Tables<'admin_review_queue'>;
type WithdrawalRow = Tables<'withdrawal_requests'>;
type StrCaseRow = Tables<'str_cases'>;
type RiskFlagRow = Tables<'risk_flags'>;

type QueueAction =
  | { kind: 'resolveQueue'; id: string }
  | { kind: 'approveWithdrawal'; id: string }
  | { kind: 'rejectWithdrawal'; id: string }
  | { kind: 'markWithdrawalSent'; id: string }
  | { kind: 'reviewStr'; id: string }
  | { kind: 'fileStr'; id: string }
  | { kind: 'dismissStr'; id: string }
  | { kind: 'clearRiskFlag'; id: string }
  | { kind: 'approveKyc'; id: string }
  | { kind: 'rejectKyc'; id: string };

interface QueueData {
  reviewQueue: ReviewQueueRow[];
  withdrawals: WithdrawalRow[];
  strCases: StrCaseRow[];
  riskFlags: RiskFlagRow[];
}

export function QueuesPage() {
  const t = useT();
  const qc = useQueryClient();
  const [action, setAction] = useState<QueueAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: ['admin-queues'],
    queryFn: fetchQueueData,
    staleTime: 10_000,
    refetchInterval: 30_000,
  });

  const queueData: QueueData = data ?? {
    reviewQueue: [],
    withdrawals: [],
    strCases: [],
    riskFlags: [],
  };

  const reviewColumns = useMemo<ColumnDef<ReviewQueueRow>[]>(
    () => [
      { key: 'type', header: t('admin.queues.col.type'), cell: (row) => row.queue_type },
      { key: 'reason', header: t('admin.queues.col.reason'), cell: (row) => row.reason ?? '—' },
      {
        key: 'sla',
        header: t('admin.queues.col.sla'),
        cell: (row) => <SlaBadge dueAt={row.sla_due_at} />,
      },
      {
        key: 'payload',
        header: t('admin.queues.col.payload'),
        cell: (row) => <span className="text-muted">{summarizeJson(row.payload)}</span>,
      },
      {
        key: 'action',
        header: t('admin.queues.col.action'),
        align: 'right',
        cell: (row) => row.entity_type === 'kyc_submission' ? (
          <div className="flex justify-end gap-2">
            <Button
              size="sm"
              variant="primary"
              data-testid={`queue-kyc-approve-${row.entity_id}`}
              onClick={() => setAction({ kind: 'approveKyc', id: row.entity_id })}
            >
              {t('admin.queues.action.approve')}
            </Button>
            <Button
              size="sm"
              variant="danger"
              data-testid={`queue-kyc-reject-${row.entity_id}`}
              onClick={() => setAction({ kind: 'rejectKyc', id: row.entity_id })}
            >
              {t('admin.queues.action.reject')}
            </Button>
          </div>
        ) : (
          <Button
            size="sm"
            variant="outline"
            data-testid={`queue-resolve-${row.id}`}
            onClick={() => setAction({ kind: 'resolveQueue', id: row.id })}
          >
            {t('admin.queues.action.resolve')}
          </Button>
        ),
      },
    ],
    [t],
  );

  const withdrawalColumns = useMemo<ColumnDef<WithdrawalRow>[]>(
    () => [
      { key: 'amount', header: t('admin.queues.col.amount'), cell: (row) => `${row.amount} ${row.currency}` },
      {
        key: 'status',
        header: t('admin.queues.col.status'),
        cell: (row) => <StatusBadge status={row.status} />,
      },
      {
        key: 'created',
        header: t('admin.queues.col.created'),
        cell: (row) => formatDate(row.created_at),
      },
      {
        key: 'destination',
        header: t('admin.queues.col.destination'),
        cell: (row) => <span className="text-muted">{summarizeJson(row.destination)}</span>,
      },
      {
        key: 'action',
        header: t('admin.queues.col.action'),
        align: 'right',
        cell: (row) => (
          <div className="flex justify-end gap-2">
            {row.status === 'pending' && (
              <>
                <Button
                  size="sm"
                  variant="primary"
                  data-testid={`queue-withdraw-approve-${row.id}`}
                  onClick={() => setAction({ kind: 'approveWithdrawal', id: row.id })}
                >
                  {t('admin.queues.action.approve')}
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  data-testid={`queue-withdraw-reject-${row.id}`}
                  onClick={() => setAction({ kind: 'rejectWithdrawal', id: row.id })}
                >
                  {t('admin.queues.action.reject')}
                </Button>
              </>
            )}
            {row.status === 'approved' && (
              <Button
                size="sm"
                variant="outline"
                data-testid={`queue-withdraw-sent-${row.id}`}
                onClick={() => setAction({ kind: 'markWithdrawalSent', id: row.id })}
              >
                {t('admin.queues.action.markSent')}
              </Button>
            )}
          </div>
        ),
      },
    ],
    [t],
  );

  const strColumns = useMemo<ColumnDef<StrCaseRow>[]>(
    () => [
      { key: 'type', header: t('admin.queues.col.type'), cell: (row) => row.case_type },
      { key: 'status', header: t('admin.queues.col.status'), cell: (row) => <StatusBadge status={row.status} /> },
      { key: 'trigger', header: t('admin.queues.col.trigger'), cell: (row) => row.trigger_ref ?? '—' },
      {
        key: 'details',
        header: t('admin.queues.col.details'),
        cell: (row) => <span className="text-muted">{summarizeJson(row.details)}</span>,
      },
      {
        key: 'action',
        header: t('admin.queues.col.action'),
        align: 'right',
        cell: (row) => (
          <div className="flex justify-end gap-2">
            {row.status === 'open' && (
              <Button
                size="sm"
                variant="outline"
                data-testid={`queue-str-review-${row.id}`}
                onClick={() => setAction({ kind: 'reviewStr', id: row.id })}
              >
                {t('admin.queues.action.review')}
              </Button>
            )}
            <Button
              size="sm"
              variant="primary"
              data-testid={`queue-str-file-${row.id}`}
              onClick={() => setAction({ kind: 'fileStr', id: row.id })}
            >
              {t('admin.queues.action.file')}
            </Button>
            <Button
              size="sm"
              variant="danger"
              data-testid={`queue-str-dismiss-${row.id}`}
              onClick={() => setAction({ kind: 'dismissStr', id: row.id })}
            >
              {t('admin.queues.action.dismiss')}
            </Button>
          </div>
        ),
      },
    ],
    [t],
  );

  const riskColumns = useMemo<ColumnDef<RiskFlagRow>[]>(
    () => [
      { key: 'type', header: t('admin.queues.col.type'), cell: (row) => row.flag_type },
      { key: 'status', header: t('admin.queues.col.status'), cell: (row) => <StatusBadge status={row.status} /> },
      {
        key: 'created',
        header: t('admin.queues.col.created'),
        cell: (row) => formatDate(row.created_at),
      },
      {
        key: 'details',
        header: t('admin.queues.col.details'),
        cell: (row) => <span className="text-muted">{summarizeJson(row.details)}</span>,
      },
      {
        key: 'action',
        header: t('admin.queues.col.action'),
        align: 'right',
        cell: (row) => (
          <Button
            size="sm"
            variant="outline"
            data-testid={`queue-risk-clear-${row.id}`}
            onClick={() => setAction({ kind: 'clearRiskFlag', id: row.id })}
          >
            {t('admin.queues.action.clear')}
          </Button>
        ),
      },
    ],
    [t],
  );

  async function handleConfirm(reason: string) {
    if (!action) return;
    setBusy(true);
    setErrorMsg(null);
    try {
      await runAction(action, reason);
      await Promise.all([
        qc.invalidateQueries({ queryKey: ['admin-queues'] }),
        qc.invalidateQueries({ queryKey: ['audit-logs'] }),
      ]);
      setAction(null);
    } catch (err) {
      setErrorMsg(t(translateError(err)));
    } finally {
      setBusy(false);
    }
  }

  return (
    <AdminLayout>
      <div className="space-y-6" data-testid="admin-queues-page">
        <div>
          <h1 className="text-2xl font-bold text-fg">{t('admin.queues.title')}</h1>
          <p className="text-muted mt-1">{t('admin.queues.description')}</p>
        </div>

        {errorMsg && (
          <p className="text-down text-sm" role="alert" data-testid="admin-queues-error">
            {errorMsg}
          </p>
        )}

        <div className="grid grid-cols-1 gap-3 md:grid-cols-4">
          <MetricCard label={t('admin.queues.metric.review')} value={queueData.reviewQueue.length} />
          <MetricCard label={t('admin.queues.metric.withdrawals')} value={queueData.withdrawals.length} />
          <MetricCard label={t('admin.queues.metric.str')} value={queueData.strCases.length} />
          <MetricCard label={t('admin.queues.metric.risk')} value={queueData.riskFlags.length} />
        </div>

        <QueueSection
          title={t('admin.queues.review.title')}
          data={queueData.reviewQueue}
          columns={reviewColumns}
          loading={isLoading}
          empty={t('admin.queues.empty')}
          testId="admin-review-queue-table"
        />
        <QueueSection
          title={t('admin.queues.withdrawals.title')}
          data={queueData.withdrawals}
          columns={withdrawalColumns}
          loading={isLoading}
          empty={t('admin.queues.empty')}
          testId="admin-withdrawals-table"
        />
        <QueueSection
          title={t('admin.queues.str.title')}
          data={queueData.strCases}
          columns={strColumns}
          loading={isLoading}
          empty={t('admin.queues.empty')}
          testId="admin-str-table"
        />
        <QueueSection
          title={t('admin.queues.risk.title')}
          data={queueData.riskFlags}
          columns={riskColumns}
          loading={isLoading}
          empty={t('admin.queues.empty')}
          testId="admin-risk-table"
        />
      </div>

      <AdminActionDialog
        open={action !== null}
        title={actionTitle(action, t)}
        description={t('admin.action.auditNote')}
        confirmLabel={t('admin.action.confirmApply')}
        cancelLabel={t('common.cancel')}
        tone={action?.kind === 'rejectWithdrawal' || action?.kind === 'dismissStr' || action?.kind === 'rejectKyc' ? 'danger' : 'primary'}
        busy={busy}
        testId="admin-queue-action"
        resetKey={actionKey(action)}
        onConfirm={handleConfirm}
        onCancel={() => setAction(null)}
      />
    </AdminLayout>
  );
}

async function fetchQueueData(): Promise<QueueData> {
  const [reviewQueue, withdrawals, strCases, riskFlags] = await Promise.all([
    supabase
      .from('admin_review_queue')
      .select('*')
      .in('status', ['pending', 'in_review'])
      .order('sla_due_at', { ascending: true })
      .limit(50),
    supabase
      .from('withdrawal_requests')
      .select('*')
      .in('status', ['pending', 'approved'])
      .order('created_at', { ascending: true })
      .limit(50),
    supabase
      .from('str_cases')
      .select('*')
      .in('status', ['open', 'reviewing'])
      .order('created_at', { ascending: true })
      .limit(50),
    supabase
      .from('risk_flags')
      .select('*')
      .eq('status', 'active')
      .order('created_at', { ascending: true })
      .limit(50),
  ]);

  for (const result of [reviewQueue, withdrawals, strCases, riskFlags]) {
    if (result.error) throw new Error(result.error.message);
  }

  return {
    reviewQueue: (reviewQueue.data ?? []) as ReviewQueueRow[],
    withdrawals: (withdrawals.data ?? []) as WithdrawalRow[],
    strCases: (strCases.data ?? []) as StrCaseRow[],
    riskFlags: (riskFlags.data ?? []) as RiskFlagRow[],
  };
}

async function runAction(action: QueueAction, reason: string) {
  switch (action.kind) {
    case 'resolveQueue': {
      const { error } = await supabase.rpc('rpc_resolve_admin_review_queue', {
        p_queue_id: action.id,
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'approveWithdrawal': {
      const { error } = await supabase.rpc('rpc_approve_withdrawal', {
        p_withdrawal_id: action.id,
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'rejectWithdrawal': {
      const { error } = await supabase.rpc('rpc_reject_withdrawal', {
        p_withdrawal_id: action.id,
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'markWithdrawalSent': {
      const { error } = await supabase.rpc('rpc_mark_withdrawal_sent', {
        p_withdrawal_id: action.id,
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'reviewStr': {
      const { error } = await supabase.rpc('rpc_update_str_case_status', {
        p_case_id: action.id,
        p_status: 'reviewing',
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'fileStr': {
      const { error } = await supabase.rpc('rpc_update_str_case_status', {
        p_case_id: action.id,
        p_status: 'filed',
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'dismissStr': {
      const { error } = await supabase.rpc('rpc_update_str_case_status', {
        p_case_id: action.id,
        p_status: 'dismissed',
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'clearRiskFlag': {
      const { error } = await supabase.rpc('rpc_clear_risk_flag', {
        p_flag_id: action.id,
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'approveKyc': {
      const { error } = await supabase.rpc('rpc_review_kyc_submission', {
        p_submission_id: action.id,
        p_status: 'approved',
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
    case 'rejectKyc': {
      const { error } = await supabase.rpc('rpc_review_kyc_submission', {
        p_submission_id: action.id,
        p_status: 'rejected',
        p_reason: reason,
      });
      if (error) throw new Error(error.message);
      return;
    }
  }
}

function QueueSection<T>({
  title,
  data,
  columns,
  loading,
  empty,
  testId,
}: {
  title: string;
  data: T[];
  columns: ColumnDef<T>[];
  loading: boolean;
  empty: string;
  testId: string;
}) {
  return (
    <section className="space-y-3">
      <h2 className="text-sm font-semibold text-muted uppercase tracking-wide">{title}</h2>
      <DataTable
        columns={columns}
        data={data}
        keyExtractor={(row, i) => ('id' in (row as Record<string, unknown>) ? String((row as { id: string }).id) : i)}
        emptyState={empty}
        loading={loading}
        size="sm"
        data-testid={testId}
      />
    </section>
  );
}

function MetricCard({ label, value }: { label: string; value: number }) {
  return (
    <Card className="p-4">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-1 text-2xl font-bold text-fg tabular-nums">{value}</p>
    </Card>
  );
}

function StatusBadge({ status }: { status: string }) {
  const tone = status === 'pending' || status === 'open'
    ? 'warning'
    : status === 'active'
      ? 'down'
      : status === 'approved' || status === 'reviewing'
        ? 'primary'
        : 'neutral';
  return <Badge tone={tone}>{status}</Badge>;
}

function SlaBadge({ dueAt }: { dueAt: string }) {
  const overdue = new Date(dueAt).getTime() < Date.now();
  return (
    <Badge tone={overdue ? 'down' : 'warning'}>
      {formatDate(dueAt)}
    </Badge>
  );
}

function formatDate(value: string) {
  return new Date(value).toLocaleString();
}

function summarizeJson(value: unknown) {
  if (!value || typeof value !== 'object') return '—';
  const text = JSON.stringify(maskSensitiveJson(value));
  return text.length > 80 ? `${text.slice(0, 77)}...` : text;
}

function maskSensitiveJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(maskSensitiveJson);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
      const normalized = key.toLowerCase();
      if (
        normalized.includes('legal_name') ||
        normalized.includes('document_last4') ||
        normalized.includes('birth') ||
        normalized.includes('address')
      ) {
        return [key, '***'];
      }
      return [key, maskSensitiveJson(entry)];
    }),
  );
}

function actionTitle(action: QueueAction | null, t: ReturnType<typeof useT>) {
  if (!action) return '';
  switch (action.kind) {
    case 'resolveQueue':
      return t('admin.queues.dialog.resolve');
    case 'approveWithdrawal':
      return t('admin.queues.dialog.approveWithdrawal');
    case 'rejectWithdrawal':
      return t('admin.queues.dialog.rejectWithdrawal');
    case 'markWithdrawalSent':
      return t('admin.queues.dialog.markSent');
    case 'reviewStr':
      return t('admin.queues.dialog.reviewStr');
    case 'fileStr':
      return t('admin.queues.dialog.fileStr');
    case 'dismissStr':
      return t('admin.queues.dialog.dismissStr');
    case 'clearRiskFlag':
      return t('admin.queues.dialog.clearRisk');
    case 'approveKyc':
      return t('admin.queues.dialog.approveKyc');
    case 'rejectKyc':
      return t('admin.queues.dialog.rejectKyc');
  }
}

function actionKey(action: QueueAction | null): string | null {
  return action ? `${action.kind}:${action.id}` : null;
}
