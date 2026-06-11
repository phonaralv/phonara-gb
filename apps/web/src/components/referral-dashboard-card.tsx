import { useMemo, useState } from 'react'
import { Badge, Button, Card, Stat, formatMoney } from '@phonara/ui'
import { useReferralDashboard } from '../hooks/use-retention'
import { sumAmounts } from '../lib/money-display'
import { useT } from '../lib/i18n'

export function ReferralDashboardCard() {
  const t = useT()
  const { data, isLoading } = useReferralDashboard()
  const [shared, setShared] = useState(false)
  const paidTotal = useMemo(() => sumAmounts(data?.paidPhon ?? []), [data?.paidPhon])
  const shareUrl = typeof window === 'undefined' ? '' : window.location.origin
  const shareText = data?.code
    ? t('referral.shareText', { code: data.code, url: shareUrl })
    : t('referral.noCode')

  async function handleShare() {
    if (!data?.code) return
    if (navigator.share) {
      await navigator.share({
        title: t('referral.title'),
        text: shareText,
        url: shareUrl,
      })
    } else {
      await navigator.clipboard.writeText(shareText)
    }
    setShared(true)
  }

  return (
    <Card className="flex flex-col gap-3.5 p-[18px]" data-testid="referral-dashboard">
      <div className="flex items-center gap-2">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary">R</span>
        <h3 className="flex-1 text-base font-semibold text-fg">{t('referral.title')}</h3>
        <Badge tone="primary">{t('referral.honestBadge')}</Badge>
      </div>

      <p className="text-sm leading-6 text-muted">{t('referral.description')}</p>

      <div className="grid grid-cols-3 gap-2 rounded-2xl border border-border bg-surface-2 p-3">
        <Stat layout="stack" label={t('referral.pending')} value={isLoading ? '-' : data?.pending ?? 0} />
        <Stat layout="stack" label={t('referral.approved')} value={isLoading ? '-' : data?.approved ?? 0} tone="up" />
        <Stat layout="stack" label={t('referral.paid')} value={isLoading ? '-' : formatMoney(paidTotal, 'PHON')} />
      </div>

      <div className="rounded-2xl border border-border bg-surface p-3">
        <span className="text-xs text-muted">{t('referral.code')}</span>
        <p className="mt-1 break-all text-lg font-bold tracking-wide text-fg">{data?.code || t('referral.codeUnavailable')}</p>
      </div>

      <Button variant="outline" full onClick={handleShare} disabled={!data?.code}>
        {shared ? t('referral.shared') : t('referral.share')}
      </Button>
    </Card>
  )
}
