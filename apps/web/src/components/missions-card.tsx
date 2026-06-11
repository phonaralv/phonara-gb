import { formatMoney, Badge, Card, Stat } from '@phonara/ui'
import type { MessageKey } from '@phonara/i18n'
import { useMissions } from '../hooks/use-retention'
import { sumAmounts } from '../lib/money-display'
import { useT } from '../lib/i18n'

const MISSION_META: Record<string, { labelKey: MessageKey; reward: string }> = {
  complete_profile:  { labelKey: 'mission.complete_profile', reward: '200'  },
  first_trade:       { labelKey: 'mission.first_trade',      reward: '1000' },
  first_game:        { labelKey: 'mission.first_game',       reward: '500'  },
  first_deposit:     { labelKey: 'mission.first_deposit',    reward: '500'  },
  kyc_verified:      { labelKey: 'mission.kyc_verified',     reward: '3000' },
  invite_3_friends:  { labelKey: 'mission.invite_3_friends', reward: '1500' },
  streak_7_days:     { labelKey: 'mission.streak_7_days',    reward: '1000' },
  streak_30_days:    { labelKey: 'mission.streak_30_days',   reward: '5000' },
}

const ALL_MISSIONS = Object.keys(MISSION_META)

export function MissionsCard() {
  const t = useT()
  // TanStack Query auto-fetches on mount; fetchMissions triggers cache invalidation
  const { missions, loading } = useMissions()

  const completedSet = new Set(
    missions.filter(m => m.completed_at).map(m => m.mission)
  )
  const totalAvailable = sumAmounts(ALL_MISSIONS.map(m => MISSION_META[m]?.reward ?? '0'))
  const totalEarned = sumAmounts(
    missions.filter(m => m.completed_at).map(m => m.phon_awarded)
  )
  const claimableTotal = sumAmounts(
    ALL_MISSIONS
      .filter(code => !completedSet.has(code))
      .map(code => MISSION_META[code]?.reward ?? '0')
  )

  return (
    <Card className="flex flex-col gap-3.5 p-[18px]">
      <div className="flex items-center gap-2">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary">M</span>
        <h3 className="flex-1 text-base font-semibold text-fg">{t('missions.title')}</h3>
        <Badge tone="up">{t('missions.progress', { done: completedSet.size, total: ALL_MISSIONS.length })}</Badge>
      </div>

      <div className="grid grid-cols-1 gap-2 rounded-2xl border border-border bg-surface-2 p-3 sm:grid-cols-3">
        <Stat layout="stack" label={t('missions.claimableTotal')} value={formatMoney(claimableTotal, 'PHON')} tone="up" />
        <Stat layout="stack" label={t('missions.earnedTotal')} value={formatMoney(totalEarned, 'PHON')} />
        <Stat layout="stack" label={t('missions.maxTotal')} value={formatMoney(totalAvailable, 'PHON')} tone="muted" />
      </div>

      {loading ? (
        <div className="flex flex-col gap-2">
          {[1, 2, 3].map(i => <div key={i} className="h-10 animate-pulse rounded-xl bg-surface-2" />)}
        </div>
      ) : (
        <ul className="flex flex-col gap-2">
          {ALL_MISSIONS.map(code => {
            const meta = MISSION_META[code]
            if (!meta) return null
            const done = completedSet.has(code)
            return (
              <li
                key={code}
                className={`flex items-center gap-3 rounded-xl border px-3 py-2 transition-colors ${
                  done
                    ? 'border-up/20 bg-up/5'
                    : 'border-border bg-surface-2'
                }`}
              >
                <span className={`h-2.5 w-2.5 rounded-full ${done ? 'bg-up' : 'bg-primary'}`} />
                <span className={`flex-1 text-sm ${done ? 'text-muted line-through' : 'text-fg'}`}>{t(meta.labelKey)}</span>
                <Badge tone={done ? 'up' : 'primary'}>
                  {done ? t('missions.done') : `+${formatMoney(meta.reward, 'PHON')}`}
                </Badge>
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}
