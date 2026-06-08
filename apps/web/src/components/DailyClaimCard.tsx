import { useEffect } from 'react'
import { useDailyClaim } from '../hooks/use-retention'

export function DailyClaimCard() {
  const { claimDaily, fetchStreak, canClaimToday, result, streak, loading, error } = useDailyClaim()

  useEffect(() => {
    fetchStreak()
  }, [fetchStreak])

  const canClaim = canClaimToday()
  const nextReward = streak
    ? 50 + Math.min(streak.current_streak, 29) * 10
    : 50

  return (
    <div className="retention-card daily-card">
      <div className="card-header">
        <span className="card-icon">📅</span>
        <h3>출석 체크</h3>
        {streak && (
          <span className="streak-badge">
            🔥 {streak.current_streak}일 연속
          </span>
        )}
      </div>

      <div className="streak-bar">
        {Array.from({ length: 7 }, (_, i) => {
          const day = i + 1
          const done = streak ? streak.current_streak >= day : false
          const isToday = streak ? streak.current_streak + 1 === day && canClaim : i === 0 && canClaim
          return (
            <div
              key={i}
              className={`streak-day ${done ? 'done' : ''} ${isToday ? 'today' : ''}`}
            >
              <span className="day-label">Day {day}</span>
              <span className="day-reward">{50 + i * 10}</span>
            </div>
          )
        })}
      </div>

      {streak && streak.current_streak >= 7 && (
        <div className="streak-milestone">
          ✨ 7일 연속 달성! 다음 목표: 30일 (+5,000 PHON 미션)
        </div>
      )}

      <div className="card-action">
        {canClaim ? (
          <button
            className="btn-claim"
            onClick={claimDaily}
            disabled={loading}
          >
            {loading ? '지급 중...' : `오늘의 보상 받기 (+${nextReward} PHON)`}
          </button>
        ) : (
          <div className="already-claimed">
            ✅ 오늘 출석 완료 · 내일 +{nextReward} PHON 예정
          </div>
        )}
      </div>

      {result && !result.already_claimed && (
        <div className="claim-toast">
          🎉 +{Number(result.phon_awarded).toLocaleString('ko-KR')} PHON 지급!
          {result.streak_day >= 7 && ' (스트릭 7일 달성 🏆)'}
        </div>
      )}

      {error && <p className="card-error">{error}</p>}

      {streak && (
        <div className="streak-stats">
          <span>총 획득: {Number(streak.total_phon_earned).toLocaleString('ko-KR')} PHON</span>
          <span>최장 스트릭: {streak.longest_streak}일</span>
        </div>
      )}
    </div>
  )
}
