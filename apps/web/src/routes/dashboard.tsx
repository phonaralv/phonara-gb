import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { signOut } from '../lib/auth';
import { useWallet } from '../hooks/use-wallet';
import { format } from '@phonara/money';
import { WelcomeModal } from '../components/WelcomeModal';
import { DailyClaimCard } from '../components/DailyClaimCard';
import { RouletteCard } from '../components/RouletteCard';
import { MissionsCard } from '../components/MissionsCard';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/dashboard',
  component: DashboardPage,
});

function DashboardPage() {
  const { session, loading: authLoading } = useAuth();
  const { wallet, loading: walletLoading, error } = useWallet();
  const navigate = useNavigate();
  const [showWelcome, setShowWelcome] = useState(false);

  useEffect(() => {
    if (!authLoading && !session) {
      void navigate({ to: '/login' });
    }
  }, [session, authLoading, navigate]);

  // Show welcome modal for new users (no wallet balance yet)
  useEffect(() => {
    if (!walletLoading && wallet) {
      const isNew =
        wallet.phon_available === '0.000000' &&
        wallet.usdt_available === '0.000000' &&
        wallet.krw_available === '0';
      if (isNew) setShowWelcome(true);
    }
  }, [wallet, walletLoading]);

  async function handleSignOut() {
    await signOut();
    void navigate({ to: '/login' });
  }

  if (authLoading) {
    return (
      <div className="shell">
        <span className="spinner" aria-label="Loading" />
      </div>
    );
  }

  return (
    <div className="shell">
      {showWelcome && (
        <WelcomeModal onDismiss={() => setShowWelcome(false)} />
      )}

      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <span className="logo-mark">P</span>
            <span className="logo-name">PHONARA</span>
          </div>
          <nav className="dash-nav">
            <Link to="/ledger" className="nav-link">원장 내역</Link>
            <button onClick={handleSignOut} className="btn-ghost-sm">로그아웃</button>
          </nav>
        </header>

        <section className="wallet-section">
          <h2 className="section-title">내 지갑</h2>

          {walletLoading && (
            <div className="wallet-grid">
              {['PHON', 'USDT', 'KRW'].map(c => (
                <div key={c} className="wallet-card skeleton" />
              ))}
            </div>
          )}

          {error && <p className="error-msg">지갑 로딩 실패: {error}</p>}

          {wallet && !walletLoading && (
            <div className="wallet-grid">
              <WalletCard currency="PHON" available={wallet.phon_available} locked={wallet.phon_locked} color="#38bdf8" />
              <WalletCard currency="USDT" available={wallet.usdt_available} locked={wallet.usdt_locked} color="#34d399" />
              <WalletCard currency="KRW"  available={wallet.krw_available}  locked={wallet.krw_locked}  color="#a78bfa" />
            </div>
          )}
        </section>

        {/* Phase 2: Retention Section */}
        <section className="retention-section">
          <h2 className="section-title">
            🏆 보상 센터
            <span className="section-sub">매일 출석하고 룰렛을 돌려 PHON을 모으세요</span>
          </h2>
          <div className="retention-grid">
            <DailyClaimCard />
            <RouletteCard />
          </div>
          <div className="retention-missions">
            <MissionsCard />
          </div>
        </section>

        <section className="quick-section">
          <h2 className="section-title">빠른 메뉴</h2>
          <div className="quick-grid">
            <Link to="/ledger" className="quick-card">
              <span className="quick-icon">📋</span>
              <span>원장 내역</span>
            </Link>
            <div className="quick-card coming-soon">
              <span className="quick-icon">💳</span>
              <span>원화 입금</span>
              <span className="badge-soon">준비중</span>
            </div>
            <div className="quick-card coming-soon">
              <span className="quick-icon">📈</span>
              <span>트레이딩</span>
              <span className="badge-soon">준비중</span>
            </div>
            <div className="quick-card coming-soon">
              <span className="quick-icon">🎮</span>
              <span>카지노</span>
              <span className="badge-soon">준비중</span>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

function WalletCard({
  currency,
  available,
  locked,
  color,
}: {
  currency: 'PHON' | 'USDT' | 'KRW';
  available: string;
  locked: string;
  color: string;
}) {
  const fmtAvail = format({ currency, amount: available });
  const fmtLocked = format({ currency, amount: locked });

  return (
    <div className="wallet-card" style={{ '--accent': color } as React.CSSProperties}>
      <div className="wc-header">
        <span className="wc-currency">{currency}</span>
        <span className="wc-dot" />
      </div>
      <div className="wc-available">
        <span className="wc-label">사용 가능</span>
        <span className="wc-amount">{fmtAvail}</span>
      </div>
      {locked !== '0' && locked !== '0.000000' && (
        <div className="wc-locked">
          <span className="wc-label">잠금</span>
          <span className="wc-amount-sm">{fmtLocked}</span>
        </div>
      )}
    </div>
  );
}
