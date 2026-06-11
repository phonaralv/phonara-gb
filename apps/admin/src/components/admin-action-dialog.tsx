import { useEffect, useState } from 'react';
import { Modal, Button, Input } from '@phonara/ui';
import { useT } from '../lib/i18n';

export interface AdminActionDialogProps {
  open: boolean;
  title: string;
  description?: string;
  confirmLabel: string;
  cancelLabel: string;
  /** Visual weight of the confirm button. */
  tone?: 'primary' | 'danger';
  busy?: boolean;
  testId?: string;
  /** Changes when a different admin action is being confirmed. */
  resetKey?: string | null;
  /** Called with the reason text when the admin confirms. */
  onConfirm: (reason: string) => void;
  onCancel: () => void;
}

/**
 * Admin-specific confirmation dialog with a mandatory reason field.
 * Every admin action requires a written reason for the audit log.
 * Uses @phonara/ui Modal + Input; lives in apps/admin (not @phonara/ui)
 * because it carries admin-specific UX (reason requirement).
 */
export function AdminActionDialog({
  open,
  title,
  description,
  confirmLabel,
  cancelLabel,
  tone = 'danger',
  busy = false,
  testId,
  resetKey,
  onConfirm,
  onCancel,
}: AdminActionDialogProps) {
  const t = useT();
  const [reason, setReason] = useState('');

  useEffect(() => {
    setReason('');
  }, [open, resetKey]);

  function handleConfirm() {
    if (!reason.trim()) return;
    onConfirm(reason.trim());
  }

  function handleCancel() {
    setReason('');
    onCancel();
  }

  return (
    <Modal open={open} onClose={handleCancel} dismissible={!busy}>
      <h2 className="text-base font-bold text-fg">{title}</h2>
      {description && <p className="mt-1.5 text-sm text-muted">{description}</p>}

      <div className="mt-4 space-y-1">
        <label className="text-xs font-medium text-muted" htmlFor={`${testId ?? 'aad'}-reason`}>
          {t('admin.action.reasonLabel')}
        </label>
        <Input
          id={`${testId ?? 'aad'}-reason`}
          placeholder={t('admin.action.reasonPlaceholder')}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          disabled={busy}
          data-testid={testId ? `${testId}-reason` : undefined}
        />
      </div>

      <div className="mt-6 flex gap-3">
        <Button
          variant="ghost"
          className="flex-none"
          onClick={handleCancel}
          disabled={busy}
          data-testid={testId ? `${testId}-cancel` : undefined}
        >
          {cancelLabel}
        </Button>
        <Button
          variant={tone === 'danger' ? 'danger' : 'primary'}
          full
          onClick={handleConfirm}
          disabled={busy || !reason.trim()}
          data-testid={testId ? `${testId}-confirm` : undefined}
        >
          {confirmLabel}
        </Button>
      </div>
    </Modal>
  );
}
