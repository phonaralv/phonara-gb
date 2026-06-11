import { createRoute, Link, useNavigate } from '@tanstack/react-router';
import { useEffect, useState, type FormEvent } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { signInWithPassword, sendMagicLink } from '../lib/auth';
import {
  authErrorMessageKey,
  isValidEmail,
  type AuthFieldErrorCode,
} from '../lib/auth-error-key';
import { Button, Card, Input } from '@phonara/ui';
import { useT } from '../lib/i18n';
import { AuthShell } from '../components/auth-shell';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: LoginPage,
});

type ViewState =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'magicSending' }
  | { kind: 'magicSent' }
  | { kind: 'error'; code: AuthFieldErrorCode };

function LoginPage() {
  const t = useT();
  const { session, loading } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [state, setState] = useState<ViewState>({ kind: 'idle' });

  useEffect(() => {
    if (!loading && session) {
      void navigate({ to: '/dashboard' });
    }
  }, [session, loading, navigate]);

  const isBusy = state.kind === 'submitting' || state.kind === 'magicSending';
  const errorKey = state.kind === 'error' ? authErrorMessageKey(state.code) : null;

  async function handlePasswordLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isBusy) return;
    const trimmed = email.trim();
    if (!trimmed) return setState({ kind: 'error', code: 'emailRequired' });
    if (!isValidEmail(trimmed)) return setState({ kind: 'error', code: 'emailInvalid' });
    if (!password) return setState({ kind: 'error', code: 'passwordRequired' });

    setState({ kind: 'submitting' });
    const result = await signInWithPassword(trimmed, password);
    if (result.ok) {
      void navigate({ to: '/dashboard' });
      return;
    }
    setState({ kind: 'error', code: result.code });
  }

  async function handleMagicLink() {
    if (isBusy) return;
    const trimmed = email.trim();
    if (!trimmed) return setState({ kind: 'error', code: 'emailRequired' });
    if (!isValidEmail(trimmed)) return setState({ kind: 'error', code: 'emailInvalid' });

    setState({ kind: 'magicSending' });
    const { error } = await sendMagicLink(trimmed);
    if (error) {
      setState({ kind: 'error', code: 'generic' });
      return;
    }
    setState({ kind: 'magicSent' });
  }

  if (loading) {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <p className="text-sm text-muted" role="status" aria-live="polite">
            {t('auth.entry.shared.statusLoading')}
          </p>
        </Card>
      </AuthShell>
    );
  }

  if (state.kind === 'magicSent') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <h2 className="text-base font-semibold text-fg">
            {t('auth.entry.shared.magicLinkSentTitle')}
          </h2>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            {t('auth.entry.shared.magicLinkSentBody')}
          </p>
          <Button
            type="button"
            variant="secondary"
            className="auth-secondary-action mt-6 w-full"
            onClick={() => setState({ kind: 'idle' })}
          >
            {t('auth.entry.shared.back')}
          </Button>
        </Card>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <Card className="auth-card p-6">
        <form onSubmit={handlePasswordLogin} noValidate className="space-y-4">
          <div className="space-y-1.5">
            <label htmlFor="login-email" className="text-sm font-medium text-fg">
              {t('auth.entry.shared.emailLabel')}
            </label>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-email" aria-hidden="true" />
              <Input
                id="login-email"
                name="email"
                type="email"
                autoComplete="email"
                inputMode="email"
                spellCheck={false}
                autoCapitalize="off"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder={t('auth.entry.shared.emailPlaceholder')}
                invalid={!!errorKey}
                aria-describedby={errorKey ? 'login-error' : undefined}
                className="auth-input h-12"
                required
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <div className="flex items-center justify-between">
              <label htmlFor="login-password" className="text-sm font-medium text-fg">
                {t('auth.entry.shared.passwordLabel')}
              </label>
              <Link
                to="/reset-password"
                className="text-xs font-medium text-primary underline-offset-4 hover:underline"
              >
                {t('auth.entry.login.forgot')}
              </Link>
            </div>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-lock" aria-hidden="true" />
              <Input
                id="login-password"
                name="password"
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={t('auth.entry.shared.passwordPlaceholder')}
                invalid={!!errorKey}
                aria-describedby={errorKey ? 'login-error' : undefined}
                className="auth-input h-12"
                required
              />
            </div>
          </div>

          <p
            id="login-error"
            role="alert"
            aria-live="polite"
            className="min-h-5 text-sm text-down"
          >
            {errorKey ? t(errorKey) : ''}
          </p>

          <Button type="submit" disabled={isBusy} className="auth-cta mt-2 w-full">
            {state.kind === 'submitting'
              ? t('auth.entry.login.submitting')
              : t('auth.entry.login.submit')}
          </Button>
        </form>

        <div className="my-6 flex items-center gap-3" aria-hidden="true">
          <span className="h-px flex-1 bg-border" />
          <span className="text-xs text-muted">
            {t('auth.entry.shared.or')}
          </span>
          <span className="h-px flex-1 bg-border" />
        </div>

        <Button
          type="button"
          variant="secondary"
          disabled={isBusy}
          onClick={handleMagicLink}
          className="auth-secondary-action w-full"
        >
          {state.kind === 'magicSending'
            ? t('auth.entry.shared.magicLinkSending')
            : t('auth.entry.shared.magicLinkSecondary')}
        </Button>

      </Card>
      <footer className="mt-6 text-center text-sm text-muted">
        <p>
          {t('auth.entry.login.noAccount')}{' '}
          <Link
            to="/signup"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            {t('auth.entry.login.toSignup')}
          </Link>
        </p>
        <p className="mt-3 text-xs">
          <Link to="/terms" className="hover:text-fg hover:underline">
            {t('auth.entry.shared.termsLink')}
          </Link>
          {' · '}
          <Link to="/privacy" className="hover:text-fg hover:underline">
            {t('auth.entry.shared.privacyLink')}
          </Link>
        </p>
      </footer>
    </AuthShell>
  );
}
