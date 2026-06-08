import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { useEffect } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useLedger } from '../hooks/use-wallet';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/ledger',
  component: LedgerPage,
});

const DIRECTION_LABEL: Record<string, string> = {
  credit: '입금', debit: '출금', lock: '잠금', unlock: '잠금해제', reverse: '취소',
};
const DIRECTION_COLOR: Record<string, string> = {
  credit: '#34d399', debit: '#f87171', lock: '#facc15', unlock: '#38bdf8', reverse: '#a78bfa',
};

function formatDate(iso: string) {
  return new Intl.DateTimeFormat('ko-KR', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

function LedgerPage() {
  const { session, loading: authLoading } = useAuth();
  const { entries, loading } = useLedger(50);
  const navigate = useNavigate();

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <span className="logo-mark">P</span>
            <span className="logo-name">PHONARA</span>
          </div>
          <nav className="dash-nav">
            <Link to="/dashboard" className="nav-link">대시보드</Link>
          </nav>
        </header>

        <section className="wallet-section">
          <h2 className="section-title">원장 내역</h2>

          {loading && <div className="ledger-skeleton" />}

          {!loading && entries.length === 0 && (
            <div className="empty-state">
              <span>📭</span>
              <p>아직 거래 내역이 없습니다.</p>
            </div>
          )}

          {!loading && entries.length > 0 && (
            <div className="ledger-table-wrap">
              <table className="ledger-table">
                <thead>
                  <tr>
                    <th>일시</th>
                    <th>유형</th>
                    <th>통화</th>
                    <th>금액</th>
                    <th>사유</th>
                    <th>변동 후 잔고</th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map(e => (
                    <tr key={e.id}>
                      <td className="ledger-date">{formatDate(e.created_at)}</td>
                      <td>
                        <span className="ledger-badge" style={{ color: DIRECTION_COLOR[e.direction] ?? '#fff' }}>
                          {DIRECTION_LABEL[e.direction] ?? e.direction}
                        </span>
                      </td>
                      <td className="ledger-currency">{e.currency}</td>
                      <td className="ledger-amount">{e.amount}</td>
                      <td className="ledger-reason">{e.reason_code}</td>
                      <td className="ledger-balance">{e.available_after}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
