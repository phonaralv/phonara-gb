import { formatMoney, Badge, Button, Card, Stat } from '@phonara/ui'
import { useDailyClaim } from '../hooks/use-retention'
import { useT } from '../lib/i18n'

export function DailyClaimCard() {
  const t = useT()
  // fetchStreak now triggers query invalidation; no manual useEffect needed
  const { claimDaily, canClaimToday, result, streak, loading, error } = useDailyClaim()

  const canClaim = canClaimToday()
  const nextReward = streak
    ? (50n + BigInt(Math.min(streak.current_streak, 29)) * 10n).toString()
    : '50'

  return (
    <Card className="flex flex-col gap-3.5 p-[18px]">
      <div className="flex items-center gap-2">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary">D</span>
        <h3 className="flex-1 text-base font-semibold text-fg">{t('daily.title')}</h3>
        {streak && (
          <Badge tone="warning">{t('daily.streak', { days: streak.current_streak })}</Badge>
        )}
      </div>

      <div className="grid grid-cols-7 gap-1">
        {Array.from({ length: 7 }, (_, i) => {
          const day = i + 1
          const done = streak ? streak.current_streak >= day : false
          const isToday = streak ? streak.current_streak + 1 === day && canClaim : i === 0 && canClaim
          return (
            <div
              key={i}
              className={`flex flex-col items-center gap-0.5 rounded-lg border px-0.5 py-1.5 text-[0.68rem] transition-colors ${
                done
                  ? 'border-primary/30 bg-primary/10 text-primary'
                  : isToday
                    ? 'border-warning/40 bg-warning/10 font-bold text-warning'
                    : 'border-transparent bg-surface-2 text-muted'
              }`}
            >
              <span className="opacity-75">{t('daily.dayLabel', { day })}</span>
              <span className="font-semibold">{(50n + BigInt(i) * 10n).toString()}</span>
            </div>
          )
        })}
      </div>

      {streak && streak.current_streak >= 7 && (
        <div className="rounded-xl border border-warning/30 bg-warning/10 px-3 py-2 text-center text-xs text-warning">
          {t('daily.milestone')}
        </div>
      )}

      {canClaim ? (
        <Button
          variant="primary"
          full
          data-testid="daily-claim-submit"
          onClick={claimDaily}
          disabled={loading}
        >
          {loading ? t('daily.granting') : t('daily.claimReward', { amount: nextReward })}
        </Button>
      ) : (
        <div className="rounded-xl border border-up/20 bg-up/10 px-3 py-2 text-center text-sm text-up">
          {t('daily.doneToday', { amount: nextReward })}
        </div>
      )}

      {result && !result.already_claimed && (
        <div className="rounded-xl border border-warning/30 bg-warning/10 px-3 py-2 text-center text-sm text-warning">
          {t('daily.claimedToast', { amount: formatMoney(result.phon_awarded, 'PHON') })}
          {result.streak_day >= 7 && ` (${t('daily.streak7Reached')})`}
        </div>
      )}

      {error && <p className="text-center text-sm text-down">{t(error)}</p>}

      {streak && (
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <Stat layout="stack" label={t('daily.totalEarnedLabel')} value={formatMoney(streak.total_phon_earned, 'PHON')} />
          <Stat layout="stack" label={t('daily.longestStreakLabel')} value={t('daily.daysValue', { days: streak.longest_streak })} />
        </div>
      )}
    </Card>
  )
}
