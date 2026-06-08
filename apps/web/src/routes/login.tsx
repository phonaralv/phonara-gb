import { createRoute, useNavigate } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { sendMagicLink } from '../lib/auth';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: LoginPage,
});

function LoginPage() {
  const { session, loading } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<'idle' | 'loading' | 'sent' | 'error'>('idle');
  const [errorMsg, setErrorMsg] = useState('');

  useEffect(() => {
    if (!loading && session) {
      void navigate({ to: '/dashboard' });
    }
  }, [session, loading, navigate]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus('loading');
    setErrorMsg('');
    const { error } = await sendMagicLink(email);
    if (error) {
      setErrorMsg(error);
      setStatus('error');
    } else {
      setStatus('sent');
    }
  }

  if (loading) {
    return (
      <div className="shell">
        <span className="spinner" aria-label="Loading" />
      </div>
    );
  }

  if (status === 'sent') {
    return (
      <div className="shell">
        <div className="auth-card">
          <div className="auth-icon">✉️</div>
          <h1>이메일을 확인하세요</h1>
          <p className="auth-desc">
            <strong>{email}</strong>으로 로그인 링크를 보냈습니다.<br />
            링크를 클릭하면 자동으로 로그인됩니다.
          </p>
          <button className="btn-ghost" onClick={() => setStatus('idle')}>
            다시 시도
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="shell">
      <div className="auth-card">
        <div className="auth-logo">
          <span className="logo-mark">P</span>
        </div>
        <h1>PHONARA에 오신 것을 환영합니다</h1>
        <p className="auth-desc">이메일로 비밀번호 없이 로그인합니다.</p>

        <form onSubmit={handleSubmit} className="auth-form">
          <label htmlFor="email" className="sr-only">이메일</label>
          <input
            id="email"
            type="email"
            placeholder="이메일 주소 입력"
            value={email}
            onChange={e => setEmail(e.target.value)}
            required
            autoFocus
            className="input"
          />
          {status === 'error' && <p className="error-msg">{errorMsg}</p>}
          <button
            type="submit"
            className="btn-primary"
            disabled={status === 'loading'}
          >
            {status === 'loading' ? '전송 중…' : '로그인 링크 받기'}
          </button>
        </form>

        <p className="auth-hint">
          링크를 클릭하면 자동으로 가입 및 로그인됩니다.
        </p>
      </div>
    </div>
  );
}
