import { createRoute } from '@tanstack/react-router';
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { AdminActionDialog } from '../components/admin-action-dialog';
import { useT } from '../lib/i18n';
import { supabase } from '../lib/supabase';
import { useAppConfig } from '../hooks/use-app-config';
import { Button, Badge, Card, ErrorState, Skeleton } from '@phonara/ui';
import type { MessageKey } from '@phonara/i18n';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/operations',
  component: OperationsPage,
});

type FeatureKey = 'spot' | 'futures' | 'staking' | 'game' | 'referral' | 'deposit' | 'withdrawal';
const FEATURES: FeatureKey[] = ['spot', 'futures', 'staking', 'game', 'referral', 'deposit', 'withdrawal'];

const FEATURE_LABEL_KEYS: Record<FeatureKey, MessageKey> = {
  spot: 'admin.operations.feature.spot',
  futures: 'admin.operations.feature.futures',
  staking: 'admin.operations.feature.staking',
  game: 'admin.operations.feature.game',
  referral: 'admin.operations.feature.referral',
  deposit: 'admin.operations.feature.deposit',
  withdrawal: 'admin.operations.feature.withdrawal',
};

function isEnabled(config: Record<string, string> | undefined, key: string): boolean {
  return config?.[key] === 'true';
}

function OperationsPage() {
  const t = useT();
  const { data: config, isLoading } = useAppConfig();
  const qc = useQueryClient();

  const [dialog, setDialog] = useState<{
    type: 'system_halt' | 'system_readonly' | 'feature';
    feature?: FeatureKey;
    targetValue: boolean;
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  function refreshAll() {
    void qc.invalidateQueries({ queryKey: ['app-config'] });
    void qc.invalidateQueries({ queryKey: ['audit-logs'] });
  }

  async function handleConfirm(reason: string) {
    if (!dialog) return;
    setBusy(true);
    setErrorMsg(null);
    try {
      if (dialog.type === 'system_halt' || dialog.type === 'system_readonly') {
        const halt = dialog.type === 'system_halt' ? dialog.targetValue : isEnabled(config, 'system_halt');
        const readonly = dialog.type === 'system_readonly' ? dialog.targetValue : isEnabled(config, 'system_readonly');
        const { error } = await supabase.rpc('rpc_set_system_mode', {
          p_halt: halt,
          p_readonly: readonly,
          p_reason: reason,
        });
        if (error) throw new Error(error.message);
      } else if (dialog.type === 'feature' && dialog.feature) {
        const { error } = await supabase.rpc('rpc_set_feature_enabled', {
          p_feature: dialog.feature,
          p_enabled: dialog.targetValue,
          p_reason: reason,
        });
        if (error) throw new Error(error.message);
      }
      refreshAll();
      setDialog(null);
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : t('error.UNKNOWN'));
    } finally {
      setBusy(false);
    }
  }

  const actionLabel = dialog?.targetValue
    ? t('admin.operations.action.enable')
    : t('admin.operations.action.disable');

  const dialogTitle = dialog
    ? dialog.type === 'system_halt'
      ? t('admin.operations.dialog.systemHalt', { action: actionLabel })
      : dialog.type === 'system_readonly'
        ? t('admin.operations.dialog.systemReadonly', { action: actionLabel })
        : t('admin.operations.dialog.feature', {
            feature: dialog.feature ? t(FEATURE_LABEL_KEYS[dialog.feature]) : '',
            action: actionLabel,
          })
    : '';

  if (isLoading) {
    return (
      <AdminLayout>
        <Card className="grid max-w-2xl gap-4 p-5" aria-busy="true">
          <Skeleton className="h-6 w-48" />
          <Skeleton className="h-24" />
          <Skeleton className="h-40" />
        </Card>
      </AdminLayout>
    );
  }

  const systemHalted = isEnabled(config, 'system_halt');
  const systemReadonly = isEnabled(config, 'system_readonly');

  return (
    <AdminLayout>
      <div className="space-y-8 max-w-2xl" data-testid="operations-page">
        <div>
          <h1 className="text-2xl font-bold text-fg">{t('admin.operations.title')}</h1>
          <p className="text-muted mt-1">{t('admin.operations.description')}</p>
        </div>

        {errorMsg && (
          <ErrorState
            data-testid="ops-error"
            title={t('error.UNKNOWN')}
            description={errorMsg}
          />
        )}

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-muted uppercase tracking-wide">
            {t('admin.operations.section.systemMode')}
          </h2>
          <div className="rounded-2xl border border-border bg-surface p-4 space-y-4">
            <ToggleRow
              label={t('admin.operations.systemHalt.label')}
              description={t('admin.operations.systemHalt.description')}
              enabled={systemHalted}
              tone="danger"
              testId="ops-system-halt"
              onToggle={(v) => setDialog({ type: 'system_halt', targetValue: v })}
            />
            <ToggleRow
              label={t('admin.operations.systemReadonly.label')}
              description={t('admin.operations.systemReadonly.description')}
              enabled={systemReadonly}
              tone="warning"
              testId="ops-system-readonly"
              onToggle={(v) => setDialog({ type: 'system_readonly', targetValue: v })}
            />
          </div>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-muted uppercase tracking-wide">
            {t('admin.operations.section.featureFlags')}
          </h2>
          <div className="rounded-2xl border border-border bg-surface divide-y divide-border">
            {FEATURES.map((feature) => (
              <ToggleRow
                key={feature}
                label={t(FEATURE_LABEL_KEYS[feature])}
                enabled={isEnabled(config, `feature_${feature}_enabled`)}
                tone="primary"
                testId={`ops-feature-${feature}`}
                className="px-4 py-3"
                onToggle={(v) => setDialog({ type: 'feature', feature, targetValue: v })}
              />
            ))}
          </div>
        </section>
      </div>

      <AdminActionDialog
        open={dialog !== null}
        title={dialogTitle}
        description={t('admin.action.auditNote')}
        confirmLabel={t('admin.action.confirmApply')}
        cancelLabel={t('common.cancel')}
        tone={
          dialog?.type === 'system_halt' && dialog?.targetValue ? 'danger' : 'primary'
        }
        busy={busy}
        testId="ops-confirm"
        resetKey={dialogKey(dialog)}
        onConfirm={handleConfirm}
        onCancel={() => setDialog(null)}
      />
    </AdminLayout>
  );
}

function dialogKey(dialog: {
  type: 'system_halt' | 'system_readonly' | 'feature';
  feature?: FeatureKey;
  targetValue: boolean;
} | null): string | null {
  return dialog ? `${dialog.type}:${dialog.feature ?? ''}:${String(dialog.targetValue)}` : null;
}

interface ToggleRowProps {
  label: string;
  description?: string;
  enabled: boolean;
  tone: 'danger' | 'warning' | 'primary';
  testId: string;
  className?: string;
  onToggle: (next: boolean) => void;
}

function ToggleRow({ label, description, enabled, tone, testId, className = '', onToggle }: ToggleRowProps) {
  const t = useT();

  return (
    <div className={`flex items-center justify-between gap-4 ${className}`} data-testid={testId}>
      <div>
        <p className="text-sm font-medium text-fg">{label}</p>
        {description && <p className="text-xs text-muted mt-0.5">{description}</p>}
      </div>
      <div className="flex items-center gap-3 flex-shrink-0">
        <Badge
          tone={enabled ? (tone === 'danger' ? 'down' : tone === 'warning' ? 'warning' : 'up') : 'neutral'}
          data-testid={`${testId}-badge`}
        >
          {enabled ? t('admin.operations.toggle.on') : t('admin.operations.toggle.off')}
        </Badge>
        <Button
          variant={enabled ? 'danger' : 'primary'}
          size="sm"
          onClick={() => onToggle(!enabled)}
          data-testid={`${testId}-toggle`}
        >
          {enabled ? t('admin.operations.toggle.disable') : t('admin.operations.toggle.enable')}
        </Button>
      </div>
    </div>
  );
}
