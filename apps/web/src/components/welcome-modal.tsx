import { useEffect, useState } from 'react'
import { formatMoney, Button, Modal, Input } from '@phonara/ui'
import { useWelcomeBonus, useReferral } from '../hooks/use-retention'
import { isPositiveAmount } from '../lib/money-display'
import { useT } from '../lib/i18n'

interface WelcomeModalProps {
  onDismiss: () => void
}

export function WelcomeModal({ onDismiss }: WelcomeModalProps) {
  const t = useT()
  const { claimWelcomeBonus, checkClaimed, result, loading } = useWelcomeBonus()
  const { registerReferral, loading: refLoading, error: refError, success: refSuccess } = useReferral()
  const [step, setStep] = useState<'referral' | 'claiming' | 'done'>('referral')
  const [refCode, setRefCode] = useState('')
  const [claimed, setClaimed] = useState(false)

  useEffect(() => {
    checkClaimed().then(alreadyClaimed => {
      if (alreadyClaimed) {
        setClaimed(true)
        setStep('done')
      }
    })
  }, [checkClaimed])

  const handleSkipReferral = async () => {
    setStep('claiming')
    const r = await claimWelcomeBonus()
    if (r) setStep('done')
  }

  const handleSubmitReferral = async () => {
    if (refCode.trim()) {
      await registerReferral(refCode)
    }
    setStep('claiming')
    const r = await claimWelcomeBonus()
    if (r) setStep('done')
  }

  return (
    <Modal
      open
      onClose={onDismiss}
      dismissible={step !== 'claiming'}
      labelledBy="welcome-modal-title"
      className="max-w-[420px] text-center"
    >
      {step === 'referral' && (
        <>
          <div className="welcome-emoji">🎁</div>
          <h2 id="welcome-modal-title" className="welcome-title">{t('welcome.title')}</h2>
          <p className="welcome-subtitle">
            {t('welcome.subtitle')}
          </p>
          <div className="welcome-value-badge">
            💰 {t('welcome.valueBadge')}
          </div>
          <p className="welcome-ref-prompt">{t('welcome.refPrompt')}</p>
          <Input
            placeholder={t('welcome.refPlaceholder')}
            value={refCode}
            onChange={e => setRefCode(e.target.value)}
            className="text-center tracking-widest"
          />
          {refError && <p className="welcome-ref-error">{t(refError)}</p>}
          {refSuccess && (
            <p className="welcome-ref-success">
              ✅ {t('welcome.refSuccess')}
            </p>
          )}
          <div className="welcome-bonus-list">
            <div className="bonus-item">
              <span>🎁 {t('welcome.bonusBase')}</span>
              <strong>5,000 PHON</strong>
            </div>
            <div className="bonus-item bonus-referral">
              <span>👥 {t('welcome.bonusReferral')}</span>
              <strong>+1,000 PHON</strong>
            </div>
          </div>
          <div className="welcome-actions">
            <Button
              variant="primary"
              full
              data-testid="welcome-claim"
              onClick={handleSubmitReferral}
              disabled={refLoading || loading}
            >
              {refCode.trim() ? t('welcome.claimWithRef') : t('welcome.claim')}
            </Button>
            {refCode.trim() && (
              <Button variant="ghost" data-testid="welcome-skip-ref" onClick={handleSkipReferral}>
                {t('welcome.skipRef')}
              </Button>
            )}
          </div>
        </>
      )}

      {step === 'claiming' && (
        <div className="welcome-claiming">
          <div className="spin-animation">⚡</div>
          <p>{t('welcome.claiming')}</p>
        </div>
      )}

      {step === 'done' && result && !claimed && (
        <div data-testid="welcome-done">
          <div className="welcome-emoji">🎉</div>
          <h2 id="welcome-modal-title" className="welcome-title">{t('welcome.doneTitle')}</h2>
          <div className="welcome-earned">
            <div className="earned-amount">
              +{formatMoney(result.phon_awarded, 'PHON')} PHON
            </div>
            <div className="earned-krw">
              {t('welcome.earnedKrw', { amount: formatMoney(result.phon_awarded, 'KRW') })}
            </div>
          </div>
          {isPositiveAmount(String(result.referral_bonus)) && (
            <p className="referral-bonus-note">
              👥 {t('welcome.referralIncluded', { amount: formatMoney(result.referral_bonus, 'PHON') })}
            </p>
          )}
          <p className="welcome-cta">
            {t('welcome.cta')}
            <br />
            <small>{t('welcome.ctaSmall')} 🔥</small>
          </p>
          <Button variant="primary" full data-testid="welcome-start" onClick={onDismiss}>
            {t('welcome.start')} 🚀
          </Button>
        </div>
      )}

      {step === 'done' && claimed && (
        <div data-testid="welcome-done">
          <div className="welcome-emoji">👋</div>
          <h2 id="welcome-modal-title" className="welcome-title">{t('welcome.returningTitle')}</h2>
          <Button variant="primary" full data-testid="welcome-start" onClick={onDismiss}>
            {t('welcome.goDashboard')}
          </Button>
        </div>
      )}
    </Modal>
  )
}
