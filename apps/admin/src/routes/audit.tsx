import { createRoute } from '@tanstack/react-router';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { useT } from '../lib/i18n';
import { useAuditLogs } from '../hooks/use-audit-logs';
import { EmptyState, Skeleton } from '@phonara/ui';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/audit',
  component: AuditPage,
});

function AuditPage() {
  const t = useT();
  const { data: logs = [], isLoading } = useAuditLogs();

  return (
    <AdminLayout>
      <div className="space-y-4" data-testid="audit-page">
        <h1 className="text-2xl font-bold text-fg">{t('admin.audit.title')}</h1>

        {isLoading && (
          <div className="grid gap-3" aria-busy="true">
            <Skeleton className="h-10" />
            <Skeleton className="h-10" />
            <Skeleton className="h-10" />
          </div>
        )}

        {!isLoading && logs.length === 0 && (
          <EmptyState data-testid="audit-empty" title={t('admin.audit.empty')} />
        )}

        {!isLoading && logs.length > 0 && (
          <div className="overflow-x-auto rounded-2xl border border-border">
            <table className="w-full text-sm" data-testid="audit-table">
              <thead>
                <tr className="border-b border-border bg-surface-2/60">
                  <th className="px-4 py-3 text-left font-medium text-muted">{t('admin.audit.col.time')}</th>
                  <th className="px-4 py-3 text-left font-medium text-muted">{t('admin.audit.col.action')}</th>
                  <th className="px-4 py-3 text-left font-medium text-muted">{t('admin.audit.col.reason')}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {logs.map((log) => (
                  <tr key={log.id} className="bg-surface hover:bg-surface-2/40 transition-colors">
                    <td className="px-4 py-3 text-muted tabular-nums whitespace-nowrap">
                      {new Date(log.created_at).toLocaleString()}
                    </td>
                    <td className="px-4 py-3 text-fg font-medium">{log.action}</td>
                    <td className="px-4 py-3 text-muted max-w-xs truncate">
                      {typeof log.payload === 'object' && log.payload !== null
                        ? (log.payload as Record<string, unknown>)['reason'] as string ?? '—'
                        : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </AdminLayout>
  );
}
