import { useEffect, useRef } from 'react'
import { formatMoney, Card } from '@phonara/ui'
import { useRoulette, ROULETTE_LABELS, ROULETTE_PRIZES } from '../hooks/use-retention'
import { useT } from '../lib/i18n'
import { useState } from 'react'

export function RouletteCard() {
  const t = useT()
  // canSpinToday is now sync (driven by TanStack Query cache)
  const { spin, canSpinToday, result, spinning, loading, error } = useRoulette()
  const canSpin = canSpinToday()
  const [animIdx, setAnimIdx] = useState(0)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

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
    await spin()
    // canSpin auto-updates via query cache invalidation after spin
  }

  const currentLabel = ROULETTE_LABELS[animIdx] ?? ROULETTE_LABELS[0]
  const currentPrize = ROULETTE_PRIZES[animIdx] ?? ROULETTE_PRIZES[0]

  return (
    <Card className="flex flex-col gap-3.5 p-[18px]">
      <div className="flex items-center gap-2">
        <span className="text-xl">🎰</span>
        <h3 className="flex-1 text-base font-semibold text-fg">{t('roulette.title')}</h3>
        <span className="badge-once">{t('roulette.oncePerDay')}</span>
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
            {formatMoney(String(prize), 'PHON')}
          </div>
        ))}
      </div>

      <p className="roulette-expected">{t('roulette.expected')}</p>

      <div className="card-action">
        {canSpin ? (
          <button
            className={`btn-spin ${spinning ? 'spinning' : ''}`}
            data-testid="roulette-spin-submit"
            onClick={handleSpin}
            disabled={loading || spinning}
          >
            {spinning ? t('roulette.spinning') : `${t('roulette.spin')} 🎰`}
          </button>
        ) : (
          <div className="already-claimed">
            {result && !result.already_spun
              ? `✅ ${t('roulette.wonToday', { amount: formatMoney(result.phon_awarded, 'PHON') })}`
              : `✅ ${t('roulette.doneToday')}`}
          </div>
        )}
      </div>

      {error && <p className="card-error">{t(error)}</p>}

      {result && !result.already_spun && currentPrize >= 300 && (
        <div className="rare-win-banner">
          🏆 {t('roulette.rareWin', { amount: formatMoney(result.phon_awarded, 'PHON') })}
        </div>
      )}
    </Card>
  )
}
