import { createRoute, useNavigate } from '@tanstack/react-router';
import { useState } from 'react';
import { Route as rootRoute } from './__root';
import { useT } from '../lib/i18n';
import { signIn } from '../lib/auth';
import { Button, Input } from '@phonara/ui';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: AdminLoginPage,
});

function AdminLoginPage() {
  const t = useT();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    const { error: authError } = await signIn(email, password);
    setSubmitting(false);
    if (authError) {
      setError(authError.message);
      return;
    }
    void navigate({ to: '/overview' });
  }

  return (
    <div
      className="flex items-center justify-center min-h-dvh bg-bg"
      data-testid="admin-login-page"
    >
      <div className="w-full max-w-sm space-y-6 px-6">
        <div className="space-y-1 text-center">
          <p className="text-xs font-bold tracking-widest uppercase text-primary">PHONARA</p>
          <h1 className="text-xl font-bold text-fg">{t('admin.login.title')}</h1>
          <p className="text-sm text-muted">{t('admin.login.adminOnly')}</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4" data-testid="admin-login-form">
          <div className="space-y-1">
            <label className="text-xs text-muted font-medium" htmlFor="admin-email">
              {t('auth.email')}
            </label>
            <Input
              id="admin-email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              data-testid="admin-email"
            />
          </div>

          <div className="space-y-1">
            <label className="text-xs text-muted font-medium" htmlFor="admin-password">
              {t('auth.password')}
            </label>
            <Input
              id="admin-password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              data-testid="admin-password"
            />
          </div>

          {error && (
            <p className="text-sm text-down" data-testid="admin-login-error" role="alert">
              {error}
            </p>
          )}

          <Button
            type="submit"
            variant="primary"
            full
            disabled={submitting}
            data-testid="admin-login-submit"
          >
            {submitting ? t('admin.login.signing') : t('admin.login.signIn')}
          </Button>
        </form>
      </div>
    </div>
  );
}
