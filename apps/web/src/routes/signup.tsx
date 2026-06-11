import { createRoute, Link, useNavigate } from '@tanstack/react-router';
import { useEffect, useState, type FormEvent } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { signUpWithPassword } from '../lib/auth';
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
  path: '/signup',
  component: SignupPage,
});

const MIN_PASSWORD_LENGTH = 8;

type ViewState =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'verifySent' }
  | { kind: 'error'; code: AuthFieldErrorCode };

function SignupPage() {
  const t = useT();
  const { session, loading } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [state, setState] = useState<ViewState>({ kind: 'idle' });

  useEffect(() => {
    if (!loading && session) {
      void navigate({ to: '/dashboard' });
    }
  }, [session, loading, navigate]);

  const isBusy = state.kind === 'submitting';
  const errorKey = state.kind === 'error' ? authErrorMessageKey(state.code) : null;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isBusy) return;
    const trimmed = email.trim();
    if (!trimmed) return setState({ kind: 'error', code: 'emailRequired' });
    if (!isValidEmail(trimmed)) return setState({ kind: 'error', code: 'emailInvalid' });
    if (!password) return setState({ kind: 'error', code: 'passwordRequired' });
    if (password.length < MIN_PASSWORD_LENGTH) {
      return setState({ kind: 'error', code: 'passwordTooShort' });
    }
    if (password !== confirm) {
      return setState({ kind: 'error', code: 'passwordMismatch' });
    }

    setState({ kind: 'submitting' });
    const result = await signUpWithPassword(trimmed, password);
    if (!result.ok) {
      setState({ kind: 'error', code: result.code });
      return;
    }
    if (result.status === 'verify_email') {
      setState({ kind: 'verifySent' });
      return;
    }
    void navigate({ to: '/dashboard' });
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

  if (state.kind === 'verifySent') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <h2 className="text-base font-semibold text-fg">
            {t('auth.entry.signup.verifySentTitle')}
          </h2>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            {t('auth.entry.signup.verifySentBody')}
          </p>
          <Link
            to="/login"
            className="auth-secondary-action mt-6 inline-flex w-full items-center justify-center rounded-xl border border-border bg-surface-2 px-4 text-sm font-semibold text-fg hover:border-border-strong"
          >
            {t('auth.entry.signup.toLogin')}
          </Link>
        </Card>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <Card className="auth-card p-6">
        <form onSubmit={handleSubmit} noValidate className="space-y-4">
          <div className="space-y-1.5">
            <label htmlFor="signup-email" className="text-sm font-medium text-fg">
              {t('auth.entry.shared.emailLabel')}
            </label>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-email" aria-hidden="true" />
              <Input
                id="signup-email"
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
                aria-describedby={errorKey ? 'signup-error' : undefined}
                className="auth-input h-12"
                required
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <label htmlFor="signup-password" className="text-sm font-medium text-fg">
              {t('auth.entry.shared.passwordLabel')}
            </label>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-lock" aria-hidden="true" />
              <Input
                id="signup-password"
                name="new-password"
                type="password"
                autoComplete="new-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={t('auth.entry.shared.passwordPlaceholder')}
                invalid={!!errorKey}
                aria-describedby="signup-password-help signup-error"
                className="auth-input h-12"
                minLength={MIN_PASSWORD_LENGTH}
                required
              />
            </div>
            <p id="signup-password-help" className="text-xs text-muted">
              {t('auth.entry.shared.passwordHelp')}
            </p>
          </div>

          <div className="space-y-1.5">
            <label htmlFor="signup-confirm" className="text-sm font-medium text-fg">
              {t('auth.entry.shared.confirmLabel')}
            </label>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-lock" aria-hidden="true" />
              <Input
                id="signup-confirm"
                name="confirm-password"
                type="password"
                autoComplete="new-password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                placeholder={t('auth.entry.shared.confirmPlaceholder')}
                invalid={!!errorKey}
                aria-describedby={errorKey ? 'signup-error' : undefined}
                className="auth-input h-12"
                required
              />
            </div>
          </div>

          <p
            id="signup-error"
            role="alert"
            aria-live="polite"
            className="min-h-5 text-sm text-down"
          >
            {errorKey ? t(errorKey) : ''}
          </p>

          <Button type="submit" disabled={isBusy} className="auth-cta mt-2 w-full">
            {isBusy
              ? t('auth.entry.signup.submitting')
              : t('auth.entry.signup.submit')}
          </Button>
        </form>
      </Card>
      <footer className="mt-6 text-center text-sm text-muted">
        <p>
          {t('auth.entry.signup.haveAccount')}{' '}
          <Link
            to="/login"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            {t('auth.entry.signup.toLogin')}
          </Link>
        </p>
        <p className="mt-3 text-xs leading-relaxed">
          {t('auth.entry.shared.termsNotice')}{' '}
          <Link to="/terms" className="text-primary underline-offset-4 hover:underline">
            {t('auth.entry.shared.termsLink')}
          </Link>
          {' · '}
          <Link to="/privacy" className="text-primary underline-offset-4 hover:underline">
            {t('auth.entry.shared.privacyLink')}
          </Link>
        </p>
      </footer>
    </AuthShell>
  );
}
