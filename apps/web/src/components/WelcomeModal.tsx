import { useEffect, useState } from 'react'
import { useWelcomeBonus, useReferral } from '../hooks/use-retention'

interface WelcomeModalProps {
  onDismiss: () => void
}

export function WelcomeModal({ onDismiss }: WelcomeModalProps) {
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
    <div className="modal-overlay" role="dialog" aria-modal="true">
      <div className="modal-card welcome-modal">

        {step === 'referral' && (
          <>
            <div className="welcome-emoji">🎁</div>
            <h2 className="welcome-title">PHONARA에 오신 것을 환영합니다!</h2>
            <p className="welcome-subtitle">
              가입 즉시 <strong>5,000 PHON</strong>을 드립니다
            </p>
            <div className="welcome-value-badge">
              💰 5,000원 상당 무료 지급
            </div>
            <p className="welcome-ref-prompt">추천인 코드가 있으신가요?</p>
            <input
              className="welcome-ref-input"
              placeholder="추천인 코드 입력 (선택)"
              value={refCode}
              onChange={e => setRefCode(e.target.value)}
            />
            {refError && <p className="welcome-ref-error">{refError}</p>}
            {refSuccess && (
              <p className="welcome-ref-success">
                ✅ 추천인 등록! +1,000 PHON 추가 지급
              </p>
            )}
            <div className="welcome-bonus-list">
              <div className="bonus-item">
                <span>🎁 기본 가입 보너스</span>
                <strong>5,000 PHON</strong>
              </div>
              <div className="bonus-item bonus-referral">
                <span>👥 추천인 코드 입력 시</span>
                <strong>+1,000 PHON</strong>
              </div>
            </div>
            <div className="welcome-actions">
              <button
                className="btn-primary btn-full"
                onClick={handleSubmitReferral}
                disabled={refLoading || loading}
              >
                {refCode.trim() ? '추천인 등록 후 보너스 받기 →' : '보너스 받기 →'}
              </button>
              {refCode.trim() && (
                <button className="btn-ghost" onClick={handleSkipReferral}>
                  추천인 없이 진행
                </button>
              )}
            </div>
          </>
        )}

        {step === 'claiming' && (
          <div className="welcome-claiming">
            <div className="spin-animation">⚡</div>
            <p>보너스를 지급하는 중...</p>
          </div>
        )}

        {step === 'done' && result && !claimed && (
          <>
            <div className="welcome-emoji">🎉</div>
            <h2 className="welcome-title">보너스 지급 완료!</h2>
            <div className="welcome-earned">
              <div className="earned-amount">
                +{Number(result.phon_awarded).toLocaleString('ko-KR')} PHON
              </div>
              <div className="earned-krw">
                ≈ {Number(result.phon_awarded).toLocaleString('ko-KR')}원 상당
              </div>
            </div>
            {Number(result.referral_bonus) > 0 && (
              <p className="referral-bonus-note">
                👥 추천인 보너스 +{Number(result.referral_bonus).toLocaleString('ko-KR')} PHON 포함
              </p>
            )}
            <p className="welcome-cta">
              매일 출석하고 룰렛을 돌려 추가 보상을 받으세요!
              <br />
              <small>30일 연속 출석 시 +5,000 PHON 미션 보상 🔥</small>
            </p>
            <button className="btn-primary btn-full" onClick={onDismiss}>
              시작하기 🚀
            </button>
          </>
        )}

        {step === 'done' && claimed && (
          <>
            <div className="welcome-emoji">👋</div>
            <h2 className="welcome-title">다시 오셨군요!</h2>
            <button className="btn-primary btn-full" onClick={onDismiss}>
              대시보드로 이동
            </button>
          </>
        )}

      </div>
    </div>
  )
}
