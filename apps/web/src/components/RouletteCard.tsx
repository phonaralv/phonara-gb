import { useEffect, useRef, useState } from 'react'
import { useRoulette, ROULETTE_LABELS, ROULETTE_PRIZES } from '../hooks/use-retention'

export function RouletteCard() {
  const { spin, canSpinToday, result, spinning, loading, error } = useRoulette()
  const [canSpin, setCanSpin] = useState(false)
  const [animIdx, setAnimIdx] = useState(0)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    canSpinToday().then(setCanSpin)
  }, [canSpinToday])

  useEffect(() => {
    if (spinning) {
      intervalRef.current = setInterval(() => {
        setAnimIdx(prev => (prev + 1) % ROULETTE_LABELS.length)
      }, 120)
    } else {
      if (intervalRef.current) clearInterval(intervalRef.current)
      if (result) setAnimIdx(result.prize_index)
    }
    return () => { if (intervalRef.current) clearInterval(intervalRef.current) }
  }, [spinning, result])

  const handleSpin = async () => {
    const r = await spin()
    if (r) setCanSpin(false)
  }

  const currentLabel = ROULETTE_LABELS[animIdx] ?? ROULETTE_LABELS[0]
  const currentPrize = ROULETTE_PRIZES[animIdx] ?? ROULETTE_PRIZES[0]

  return (
    <div className="retention-card roulette-card">
      <div className="card-header">
        <span className="card-icon">🎰</span>
        <h3>일일 룰렛</h3>
        <span className="badge-once">1일 1회</span>
      </div>

      <div className={`roulette-display ${spinning ? 'spinning' : ''} ${result && !result.already_spun ? 'won' : ''}`}>
        <div className="roulette-prize-label">{currentLabel}</div>
        {!spinning && result && !result.already_spun && (
          <div className="roulette-confetti">🎊</div>
        )}
      </div>

      <div className="prize-tiers">
        {ROULETTE_PRIZES.map((prize, i) => (
          <div
            key={i}
            className={`prize-tier ${result ? (i === result.prize_index ? 'active' : '') : ''} ${prize >= 300 ? 'rare' : ''}`}
          >
            {prize.toLocaleString('ko-KR')}
          </div>
        ))}
      </div>

      <p className="roulette-expected">평균 기대값: ~56 PHON · 최대 1,000 PHON</p>

      <div className="card-action">
        {canSpin ? (
          <button
            className={`btn-spin ${spinning ? 'spinning' : ''}`}
            onClick={handleSpin}
            disabled={loading || spinning}
          >
            {spinning ? '돌리는 중...' : '룰렛 돌리기 🎰'}
          </button>
        ) : (
          <div className="already-claimed">
            {result && !result.already_spun
              ? `✅ 오늘 +${Number(result.phon_awarded).toLocaleString('ko-KR')} PHON 획득!`
              : '✅ 오늘 룰렛 완료 · 내일 다시 도전!'}
          </div>
        )}
      </div>

      {error && <p className="card-error">{error}</p>}

      {result && !result.already_spun && currentPrize >= 300 && (
        <div className="rare-win-banner">
          🏆 레어 당첨! {Number(result.phon_awarded).toLocaleString('ko-KR')} PHON
        </div>
      )}
    </div>
  )
}
