import { useEffect } from 'react'
import { useMissions } from '../hooks/use-retention'

const MISSION_META: Record<string, { label: string; icon: string; reward: number }> = {
  complete_profile:  { label: '프로필 완성',       icon: '👤', reward: 200   },
  first_trade:       { label: '첫 거래 실행',       icon: '📈', reward: 1000  },
  first_game:        { label: '첫 게임 참여',       icon: '🎮', reward: 500   },
  first_deposit:     { label: '첫 입금',            icon: '💳', reward: 500   },
  kyc_verified:      { label: 'KYC 인증 완료',      icon: '✅', reward: 3000  },
  invite_3_friends:  { label: '친구 3명 초대',      icon: '👥', reward: 1500  },
  streak_7_days:     { label: '7일 연속 출석',      icon: '🔥', reward: 1000  },
  streak_30_days:    { label: '30일 연속 출석',     icon: '🏆', reward: 5000  },
}

const ALL_MISSIONS = Object.keys(MISSION_META)

export function MissionsCard() {
  const { fetchMissions, missions, loading } = useMissions()

  useEffect(() => {
    fetchMissions()
  }, [fetchMissions])

  const completedSet = new Set(
    missions.filter(m => m.completed_at).map(m => m.mission)
  )
  const totalAvailable = ALL_MISSIONS.reduce(
    (sum, m) => sum + (MISSION_META[m]?.reward ?? 0),
    0
  )
  const totalEarned = missions.reduce(
    (sum, m) => sum + (m.completed_at ? Number(m.phon_awarded) : 0),
    0
  )

  return (
    <div className="retention-card missions-card">
      <div className="card-header">
        <span className="card-icon">🎯</span>
        <h3>미션</h3>
        <span className="missions-progress">
          {completedSet.size}/{ALL_MISSIONS.length} 완료
        </span>
      </div>

      <div className="missions-total-reward">
        최대 {totalAvailable.toLocaleString('ko-KR')} PHON 획득 가능 · 현재 {totalEarned.toLocaleString('ko-KR')} PHON 획득
      </div>

      {loading ? (
        <div className="missions-skeleton">
          {[1, 2, 3].map(i => <div key={i} className="skeleton-row" />)}
        </div>
      ) : (
        <ul className="mission-list">
          {ALL_MISSIONS.map(code => {
            const meta = MISSION_META[code]
            if (!meta) return null
            const done = completedSet.has(code)
            return (
              <li key={code} className={`mission-item ${done ? 'done' : 'pending'}`}>
                <span className="mission-icon">{meta.icon}</span>
                <span className="mission-label">{meta.label}</span>
                <span className="mission-reward">
                  {done ? '✅' : `+${meta.reward.toLocaleString('ko-KR')} PHON`}
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
