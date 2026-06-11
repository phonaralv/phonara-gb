import { createRoute, Link, useNavigate } from '@tanstack/react-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useWallet } from '../hooks/use-wallet';
import { useProfile } from '../hooks/use-profile';
import { env } from '../lib/env';
import { supabase } from '../lib/supabase';
import { useT } from '../lib/i18n';
import { translateError } from '../lib/translate-error';
import {
  Button,
  Card,
  ConfirmDialog,
  Input,
  Skeleton,
  StatusTimeline,
  type StatusTimelineItem,
  formatMoney,
} from '@phonara/ui';
import type { Tables } from '@phonara/shared-types';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/wallet',
  component: WalletPage,
});

type DepositRequest = Tables<'krw_deposit_requests'>;
type WithdrawalRequest = Tables<'withdrawal_requests'>;
type KycSubmission = Tables<'kyc_submissions'>;

function formatDate(value: string) {
  return new Date(value).toLocaleString();
}

function WalletPage() {
  const t = useT();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { session, loading: authLoading } = useAuth();
  const { wallet } = useWallet();
  const { profile, kycVerified } = useProfile();
  const userId = session?.user.id ?? null;

  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit');
  const [depositAmount, setDepositAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');
  const [withdrawAddress, setWithdrawAddress] = useState('');
  const [withdrawConfirmOpen, setWithdrawConfirmOpen] = useState(false);
  const [showKycForm, setShowKycForm] = useState(false);
  const [kycLegalName, setKycLegalName] = useState('');
  const [kycDocumentLast4, setKycDocumentLast4] = useState('');
  const [kycCountry, setKycCountry] = useState('KR');
  const [busy, setBusy] = useState(false);
  const [lastDeposit, setLastDeposit] = useState<{
    reference_code: string;
    expected_phon: string | null;
    deposit_id: string;
    sla_hours: string | null;
  } | null>(null);

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  const { data: deposits = [] } = useQuery({
    queryKey: ['krw-deposits', userId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('krw_deposit_requests')
        .select('*')
        .eq('user_id', userId!)
        .order('created_at', { ascending: false })
        .limit(5);
      if (error) throw error;
      return (data ?? []) as DepositRequest[];
    },
    enabled: !!userId,
  });

  const { data: withdrawals = [] } = useQuery({
    queryKey: ['withdrawals', userId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('withdrawal_requests')
        .select('*')
        .eq('user_id', userId!)
        .order('created_at', { ascending: false })
        .limit(5);
      if (error) throw error;
      return (data ?? []) as WithdrawalRequest[];
    },
    enabled: !!userId,
  });

  const { data: kycSubmissions = [] } = useQuery({
    queryKey: ['kyc-submissions', userId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('kyc_submissions')
        .select('*')
        .eq('user_id', userId!)
        .order('created_at', { ascending: false })
        .limit(3);
      if (error) throw error;
      return (data ?? []) as KycSubmission[];
    },
    enabled: !!userId,
  });

  const activeDeposit = deposits[0] ?? null;
  const { data: withdrawalEnabled } = useQuery({
    queryKey: ['app-config', 'feature_withdrawal_enabled'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('app_config')
        .select('value')
        .eq('key', 'feature_withdrawal_enabled')
        .maybeSingle();
      if (error) throw error;
      return data?.value !== 'false';
    },
  });
  const withdrawalPaused = withdrawalEnabled === false;
  const withdrawCurrency = 'PHON' as const;
  const withdrawFee = '0';
  const withdrawDestination = withdrawAddress.trim();
  const withdrawAmountValid = /^\d+(\.\d+)?$/.test(withdrawAmount);
  const canRequestWithdraw = Boolean(
    withdrawAmountValid && withdrawDestination && !busy && kycVerified && !withdrawalPaused,
  );

  const depositTimeline = useMemo((): StatusTimelineItem[] => {
    const dep = lastDeposit
      ? deposits.find((d) => d.id === lastDeposit.deposit_id) ?? activeDeposit
      : activeDeposit;
    if (!dep) {
      return [
        { id: 'req', label: t('wallet.deposit.timeline.request'), state: 'pending' },
        { id: 'match', label: t('wallet.deposit.timeline.match'), state: 'pending' },
        { id: 'credit', label: t('wallet.deposit.timeline.credit'), state: 'pending' },
      ];
    }
    const status = dep.status;
    const inReview = status === 'pending' && dep.expires_at && new Date(dep.expires_at) < new Date();
    return [
      {
        id: 'req',
        label: t('wallet.deposit.timeline.request'),
        state: 'done',
        description: t('wallet.deposit.timeline.done'),
      },
      {
        id: 'match',
        label: inReview ? t('wallet.deposit.timeline.review') : t('wallet.deposit.timeline.match'),
        state:
          status === 'credited' || status === 'matched'
            ? 'done'
            : status === 'pending'
              ? 'active'
              : 'error',
        description:
          status === 'pending'
            ? t('wallet.deposit.timeline.pending')
            : inReview
              ? t('wallet.deposit.timeline.reviewEta', { hours: '24' })
              : undefined,
      },
      {
        id: 'credit',
        label: t('wallet.deposit.timeline.credit'),
        state: status === 'credited' ? 'done' : 'pending',
      },
    ];
  }, [activeDeposit, deposits, lastDeposit, t]);

  const withdrawTimeline = useMemo((): StatusTimelineItem[] => {
    const wr = withdrawals[0];
    if (!wr) {
      return [
        { id: 'req', label: t('wallet.withdraw.timeline.request'), state: 'pending' },
        { id: 'review', label: t('wallet.withdraw.timeline.review'), state: 'pending' },
        { id: 'send', label: t('wallet.withdraw.timeline.send'), state: 'pending' },
        { id: 'done', label: t('wallet.withdraw.timeline.done'), state: 'pending' },
      ];
    }
    const map: Record<string, number> = {
      pending: 1,
      approved: 2,
      processing: 3,
      completed: 4,
      sent: 4,
      rejected: 0,
      cancelled: 0,
    };
    const step = map[wr.status] ?? 1;
    return [
      { id: 'req', label: t('wallet.withdraw.timeline.request'), state: 'done' },
      {
        id: 'review',
        label: t('wallet.withdraw.timeline.review'),
        state: step >= 2 ? (wr.status === 'rejected' ? 'error' : 'done') : step === 1 ? 'active' : 'pending',
      },
      {
        id: 'send',
        label: t('wallet.withdraw.timeline.send'),
        state: step >= 3 ? 'done' : step === 2 ? 'active' : 'pending',
      },
      {
        id: 'done',
        label: t('wallet.withdraw.timeline.done'),
        state: wr.status === 'completed' ? 'done' : 'pending',
      },
    ];
  }, [withdrawals, t]);

  const kycTimeline = useMemo((): StatusTimelineItem[] => {
    const latest = kycSubmissions[0];
    if (!latest) {
      return [
        { id: 'submit', label: t('wallet.kyc.timeline.submit'), state: 'active' },
        { id: 'review', label: t('wallet.kyc.timeline.review'), state: 'pending' },
        { id: 'complete', label: t('wallet.kyc.timeline.complete'), state: 'pending' },
      ];
    }
    const terminal = latest.status === 'approved' || latest.status === 'rejected';
    return [
      {
        id: 'submit',
        label: t('wallet.kyc.timeline.submit'),
        state: 'done',
        description: formatDate(latest.submitted_at),
      },
      {
        id: 'review',
        label: t('wallet.kyc.timeline.review'),
        state: terminal ? 'done' : 'active',
      },
      {
        id: 'complete',
        label: latest.status === 'rejected' ? t('wallet.kyc.timeline.rejected') : t('wallet.kyc.timeline.complete'),
        state: latest.status === 'approved' ? 'done' : latest.status === 'rejected' ? 'error' : 'pending',
      },
    ];
  }, [kycSubmissions, t]);

  const handleDeposit = useCallback(async () => {
    if (!depositAmount || busy) return;
    setBusy(true);
    try {
      const clientRequestId = crypto.randomUUID();
      const { data, error } = await supabase.rpc('rpc_create_krw_deposit_request', {
        p_amount_krw: depositAmount,
        p_client_request_id: clientRequestId,
      });
      if (error) throw error;
      const row = data as {
        ok: boolean;
        deposit_id: string;
        reference_code: string;
        expected_phon: string;
        sla_hours: string;
      };
      setLastDeposit({
        deposit_id: row.deposit_id,
        reference_code: row.reference_code,
        expected_phon: row.expected_phon,
        sla_hours: row.sla_hours,
      });
      toast.success(t('wallet.deposit.success'));
      void qc.invalidateQueries({ queryKey: ['krw-deposits', userId] });
    } catch (err) {
      toast.error(t(translateError(err)));
    } finally {
      setBusy(false);
    }
  }, [busy, depositAmount, qc, t, userId]);

  const openWithdrawConfirm = useCallback(() => {
    if (!withdrawAmountValid || busy || !kycVerified || !withdrawDestination) return;
    if (withdrawalPaused) {
      toast.error(t('wallet.withdraw.unavailableToast'));
      return;
    }
    setWithdrawConfirmOpen(true);
  }, [busy, kycVerified, t, withdrawalPaused, withdrawAmountValid, withdrawDestination]);

  const handleWithdraw = useCallback(async () => {
    if (!canRequestWithdraw) return;
    setBusy(true);
    try {
      const idem = crypto.randomUUID().replace(/-/g, '').slice(0, 24);
      const { error } = await supabase.rpc('rpc_request_withdrawal', {
        p_currency: withdrawCurrency,
        p_amount: withdrawAmount,
        p_destination: { address: withdrawDestination, currency: withdrawCurrency },
        p_idempotency_key: idem,
        p_client_request_id: crypto.randomUUID(),
      });
      if (error) throw error;
      toast.success(t('wallet.withdraw.success'));
      setWithdrawConfirmOpen(false);
      setWithdrawAmount('');
      setWithdrawAddress('');
      void qc.invalidateQueries({ queryKey: ['withdrawals', userId] });
      void qc.invalidateQueries({ queryKey: ['wallet', userId] });
    } catch (err) {
      toast.error(t(translateError(err)));
    } finally {
      setBusy(false);
    }
  }, [canRequestWithdraw, qc, t, userId, withdrawAmount, withdrawDestination]);

  const handleSubmitKyc = useCallback(async () => {
    if (!userId || !session || busy || !kycLegalName || !kycDocumentLast4 || !kycCountry) return;
    setBusy(true);
    try {
      const response = await fetch(`${env.VITE_SUPABASE_URL}/rest/v1/rpc/rpc_submit_kyc`, {
        method: 'POST',
        headers: {
          apikey: env.VITE_SUPABASE_ANON_KEY,
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          p_payload: {
            legal_name: kycLegalName,
            document_type: 'id_card',
            document_last4: kycDocumentLast4,
            country: kycCountry.toUpperCase(),
          },
          p_idempotency_key: `kyc-${userId}-${crypto.randomUUID()}`,
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      toast.success(t('wallet.kyc.submitOk'));
      setShowKycForm(false);
      await qc.invalidateQueries({ queryKey: ['kyc-submissions', userId] });
    } catch (err) {
      toast.error(t(translateError(err)));
    } finally {
      setBusy(false);
    }
  }, [busy, kycCountry, kycDocumentLast4, kycLegalName, qc, session, t, userId]);

  const copyRef = useCallback(async (code: string) => {
    await navigator.clipboard.writeText(code);
    toast.success(t('wallet.deposit.copyOk'));
  }, [t]);

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

  const refCode = lastDeposit?.reference_code ?? activeDeposit?.reference_code;
  const expectedPhon = lastDeposit?.expected_phon ?? activeDeposit?.expected_phon;

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <Link to="/dashboard" className="logo-name" style={{ textDecoration: 'none' }}>
              ← PHONARA
            </Link>
          </div>
          <nav className="dash-nav">
            <Link to="/ledger" className="nav-link">{t('nav.ledgerHistory')}</Link>
          </nav>
        </header>

        <div className="flex gap-2 mb-6">
          <Button
            variant={tab === 'deposit' ? 'primary' : 'outline'}
            onClick={() => setTab('deposit')}
            data-testid="wallet-tab-deposit"
          >
            {t('wallet.tab.deposit')}
          </Button>
          <Button
            variant={tab === 'withdraw' ? 'primary' : 'outline'}
            onClick={() => setTab('withdraw')}
            data-testid="wallet-tab-withdraw"
          >
            {t('wallet.tab.withdraw')}
          </Button>
        </div>

        {tab === 'deposit' && (
          <section className="wallet-deposit-section">
            <h2 className="section-title">{t('wallet.deposit.title')}</h2>
            <p className="text-sm text-muted mb-4">{t('wallet.deposit.subtitle')}</p>

            <Card className="p-4 mb-4 border-amber-500/40 bg-surface">
              <p className="text-sm font-medium text-fg">{t('wallet.deposit.bankWarning')}</p>
              <p className="text-xs text-muted mt-2">{t('wallet.deposit.bankAccount')}: {t('wallet.deposit.bankAccountDisplay')}</p>
            </Card>

            <div className="flex flex-col gap-3 max-w-md mb-6">
              <label className="text-sm text-muted" htmlFor="deposit-amount">
                {t('wallet.deposit.amountLabel')}
              </label>
              <Input
                id="deposit-amount"
                data-testid="wallet-deposit-amount"
                inputMode="numeric"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value.replace(/[^\d]/g, ''))}
              />
              <Button
                data-testid="wallet-deposit-submit"
                disabled={busy || !depositAmount}
                onClick={() => void handleDeposit()}
              >
                {busy ? t('common.processing') : t('wallet.deposit.submit')}
              </Button>
            </div>

            {refCode && (
              <Card className="p-4 mb-4">
                <p className="text-sm text-muted">{t('wallet.deposit.referenceCode')}</p>
                <p className="text-lg font-mono font-semibold text-fg" data-testid="wallet-deposit-ref">
                  {refCode}
                </p>
                {expectedPhon && (
                  <p className="text-sm text-muted mt-2">
                    {t('wallet.deposit.expectedPhon')}: {formatMoney(expectedPhon, 'PHON')}
                  </p>
                )}
                <Button
                  variant="outline"
                  size="sm"
                  className="mt-3"
                  data-testid="wallet-deposit-copy"
                  onClick={() => void copyRef(refCode)}
                >
                  {t('wallet.deposit.copyCode')}
                </Button>
              </Card>
            )}

            <StatusTimeline items={depositTimeline} data-testid="wallet-deposit-timeline" />
          </section>
        )}

        {tab === 'withdraw' && (
          <section className="wallet-withdraw-section relative">
            <h2 className="section-title">{t('wallet.withdraw.title')}</h2>

            <div className="relative max-w-md">
              {withdrawalPaused && (
                <Card className="p-4 mb-4 border-border bg-surface" data-testid="wallet-withdraw-paused">
                  <p className="text-sm font-medium text-fg">{t('wallet.withdraw.unavailableTitle')}</p>
                  <p className="text-xs text-muted mt-2">{t('wallet.withdraw.unavailableDesc')}</p>
                </Card>
              )}

              <div className="flex flex-col gap-3 mb-6">
                <p className="text-sm text-muted">
                  {t('wallet.available')}: {formatMoney(wallet?.phon_available ?? '0', 'PHON')}
                </p>
                <label className="text-sm text-muted" htmlFor="withdraw-amount">
                  {t('wallet.withdraw.amountLabel')} ({withdrawCurrency})
                </label>
                <Input
                  id="withdraw-amount"
                  data-testid="wallet-withdraw-amount"
                  inputMode="decimal"
                  value={withdrawAmount}
                  onChange={(e) => setWithdrawAmount(e.target.value)}
                />
                <label className="text-sm text-muted" htmlFor="withdraw-address">
                  {t('wallet.withdraw.addressLabel')}
                </label>
                <Input
                  id="withdraw-address"
                  data-testid="wallet-withdraw-address"
                  autoComplete="off"
                  value={withdrawAddress}
                  placeholder={t('wallet.withdraw.addressPlaceholder')}
                  onChange={(e) => setWithdrawAddress(e.target.value)}
                />
                <Button
                  data-testid="wallet-withdraw-submit"
                  disabled={busy || !withdrawAmount || !withdrawDestination || withdrawalPaused}
                  onClick={openWithdrawConfirm}
                >
                  {busy ? t('common.processing') : t('wallet.withdraw.submit')}
                </Button>
              </div>

              {!kycVerified && (
                <div
                  className="absolute inset-0 flex flex-col items-center justify-center rounded-2xl bg-bg/90 backdrop-blur-sm p-6 text-center"
                  data-testid="wallet-kyc-lock"
                >
                  <p className="text-lg font-semibold text-fg">{t('wallet.withdraw.kycLockTitle')}</p>
                  <p className="text-sm text-muted mt-2 max-w-xs">{t('wallet.withdraw.kycLockDesc')}</p>
                  <div className="mt-4 w-full max-w-sm">
                    <StatusTimeline items={kycTimeline} data-testid="wallet-kyc-timeline" />
                  </div>
                  {!showKycForm ? (
                    <Button
                      variant="primary"
                      className="mt-4"
                      data-testid="wallet-kyc-cta"
                      onClick={() => setShowKycForm(true)}
                    >
                      {t('wallet.withdraw.kycCta')}
                    </Button>
                  ) : (
                    <div className="mt-4 grid w-full max-w-sm gap-3 text-left" data-testid="wallet-kyc-form">
                      <label className="text-xs text-muted" htmlFor="kyc-legal-name">
                        {t('wallet.kyc.legalName')}
                      </label>
                      <Input
                        id="kyc-legal-name"
                        data-testid="wallet-kyc-legal-name"
                        value={kycLegalName}
                        onChange={(e) => setKycLegalName(e.target.value)}
                      />
                      <label className="text-xs text-muted" htmlFor="kyc-document-last4">
                        {t('wallet.kyc.documentLast4')}
                      </label>
                      <Input
                        id="kyc-document-last4"
                        data-testid="wallet-kyc-document-last4"
                        value={kycDocumentLast4}
                        maxLength={4}
                        onChange={(e) => setKycDocumentLast4(e.target.value)}
                      />
                      <label className="text-xs text-muted" htmlFor="kyc-country">
                        {t('wallet.kyc.country')}
                      </label>
                      <Input
                        id="kyc-country"
                        data-testid="wallet-kyc-country"
                        value={kycCountry}
                        maxLength={2}
                        onChange={(e) => setKycCountry(e.target.value.toUpperCase())}
                      />
                      <Button
                        data-testid="wallet-kyc-submit"
                        disabled={busy || !kycLegalName || !kycDocumentLast4 || !kycCountry}
                        onClick={() => void handleSubmitKyc()}
                      >
                        {busy ? t('common.processing') : t('wallet.kyc.submit')}
                      </Button>
                    </div>
                  )}
                </div>
              )}
            </div>

            <div className="mt-8">
              <StatusTimeline items={withdrawTimeline} data-testid="wallet-withdraw-timeline" />
            </div>
            {profile && (
              <p className="sr-only" data-testid="wallet-kyc-tier">{profile.kyc_tier}</p>
            )}
            <ConfirmDialog
              open={withdrawConfirmOpen}
              title={t('wallet.withdraw.confirmTitle')}
              description={t('wallet.withdraw.confirmDesc')}
              rows={[
                { label: t('wallet.withdraw.confirmCurrency'), value: withdrawCurrency },
                {
                  label: t('wallet.withdraw.confirmAmount'),
                  value: withdrawAmountValid
                    ? `${formatMoney(withdrawAmount, withdrawCurrency)} ${withdrawCurrency}`
                    : withdrawAmount,
                },
                {
                  label: t('wallet.withdraw.confirmFee'),
                  value: `${formatMoney(withdrawFee, withdrawCurrency)} ${withdrawCurrency}`,
                },
                {
                  label: t('wallet.withdraw.confirmNet'),
                  value: withdrawAmountValid
                    ? `${formatMoney(withdrawAmount, withdrawCurrency)} ${withdrawCurrency}`
                    : withdrawAmount,
                },
                { label: t('wallet.withdraw.confirmAddress'), value: withdrawDestination || '-' },
              ]}
              confirmLabel={t('wallet.withdraw.confirmProceed')}
              cancelLabel={t('common.cancel')}
              processingLabel={t('common.processing')}
              tone="danger"
              busy={busy}
              testId="wallet-withdraw"
              onConfirm={() => void handleWithdraw()}
              onCancel={() => setWithdrawConfirmOpen(false)}
            />
          </section>
        )}
      </div>
    </div>
  );
}
