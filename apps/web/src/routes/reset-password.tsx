import { createRoute, Link } from '@tanstack/react-router';
import { useEffect, useState, type FormEvent } from 'react';
import { Route as rootRoute } from './__root';
import { supabase } from '../lib/supabase';
import { sendPasswordReset, updatePassword } from '../lib/auth';
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
  path: '/reset-password',
  component: ResetPasswordPage,
});

const MIN_PASSWORD_LENGTH = 8;

type Mode = 'loading' | 'request' | 'update' | 'recoveryInvalid';

type ViewState =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'requestSent' }
  | { kind: 'updateDone' }
  | { kind: 'error'; code: AuthFieldErrorCode };

function isRecoveryUrl(): boolean {
  if (typeof window === 'undefined') return false;
  const hash = window.location.hash || '';
  const search = window.location.search || '';
  return (
    hash.includes('type=recovery') ||
    search.includes('type=recovery') ||
    hash.includes('access_token') ||
    search.includes('code=')
  );
}

function ResetPasswordPage() {
  const t = useT();
  const [mode, setMode] = useState<Mode>('loading');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [state, setState] = useState<ViewState>({ kind: 'idle' });

  useEffect(() => {
    let cancelled = false;

    const { data: sub } = supabase.auth.onAuthStateChange((event) => {
      if (cancelled) return;
      if (event === 'PASSWORD_RECOVERY') setMode('update');
    });

    void (async () => {
      const { data } = await supabase.auth.getSession();
      if (cancelled) return;
      if (data.session) {
        setMode('update');
        return;
      }
      if (isRecoveryUrl()) {
        setMode('recoveryInvalid');
        return;
      }
      setMode('request');
    })();

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  const isBusy = state.kind === 'submitting';
  const errorKey = state.kind === 'error' ? authErrorMessageKey(state.code) : null;

  async function handleRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isBusy) return;
    const trimmed = email.trim();
    if (!trimmed) return setState({ kind: 'error', code: 'emailRequired' });
    if (!isValidEmail(trimmed)) return setState({ kind: 'error', code: 'emailInvalid' });

    setState({ kind: 'submitting' });
    const result = await sendPasswordReset(trimmed);
    if (!result.ok) {
      setState({ kind: 'error', code: result.code });
      return;
    }
    setState({ kind: 'requestSent' });
  }

  async function handleUpdate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (isBusy) return;
    if (!password) return setState({ kind: 'error', code: 'passwordRequired' });
    if (password.length < MIN_PASSWORD_LENGTH) {
      return setState({ kind: 'error', code: 'passwordTooShort' });
    }
    if (password !== confirm) {
      return setState({ kind: 'error', code: 'passwordMismatch' });
    }

    setState({ kind: 'submitting' });
    const result = await updatePassword(password);
    if (!result.ok) {
      setState({ kind: 'error', code: result.code });
      return;
    }
    await supabase.auth.signOut();
    setState({ kind: 'updateDone' });
  }

  if (mode === 'loading') {
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

  if (state.kind === 'requestSent') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <h2 className="text-base font-semibold text-fg">
            {t('auth.entry.reset.requestSentTitle')}
          </h2>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            {t('auth.entry.reset.requestSentBody')}
          </p>
          <Link
            to="/login"
            className="auth-secondary-action mt-6 inline-flex w-full items-center justify-center rounded-xl border border-border bg-surface-2 px-4 text-sm font-semibold text-fg hover:border-border-strong"
          >
            {t('auth.entry.reset.backToLogin')}
          </Link>
        </Card>
      </AuthShell>
    );
  }

  if (state.kind === 'updateDone') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <h2 className="text-base font-semibold text-fg">
            {t('auth.entry.reset.updateDoneTitle')}
          </h2>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            {t('auth.entry.reset.updateDoneBody')}
          </p>
          <Link
            to="/login"
            className="auth-cta mt-6 inline-flex w-full items-center justify-center rounded-xl px-4 text-sm"
          >
            {t('auth.entry.reset.backToLogin')}
          </Link>
        </Card>
      </AuthShell>
    );
  }

  if (mode === 'recoveryInvalid') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <h2 className="text-base font-semibold text-fg">
            {t('auth.entry.reset.title')}
          </h2>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            {t('auth.entry.reset.recoveryInvalid')}
          </p>
          <Link
            to="/login"
            className="auth-secondary-action mt-6 inline-flex w-full items-center justify-center rounded-xl border border-border bg-surface-2 px-4 text-sm font-semibold text-fg hover:border-border-strong"
          >
            {t('auth.entry.reset.backToLogin')}
          </Link>
        </Card>
      </AuthShell>
    );
  }

  if (mode === 'update') {
    return (
      <AuthShell>
        <Card className="auth-card p-6">
          <p className="mb-4 text-sm leading-relaxed text-muted">
            {t('auth.entry.shared.passwordHelp')}
          </p>
          <form onSubmit={handleUpdate} noValidate className="space-y-4">
            <div className="space-y-1.5">
              <label htmlFor="reset-new" className="text-sm font-medium text-fg">
                {t('auth.entry.reset.newPasswordLabel')}
              </label>
              <div className="auth-field">
                <span className="auth-field-icon auth-field-icon-lock" aria-hidden="true" />
                <Input
                  id="reset-new"
                  name="new-password"
                  type="password"
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder={t('auth.entry.reset.newPasswordPlaceholder')}
                  invalid={!!errorKey}
                  aria-describedby={errorKey ? 'reset-error' : undefined}
                  className="auth-input h-12"
                  minLength={MIN_PASSWORD_LENGTH}
                  required
                />
              </div>
            </div>

            <div className="space-y-1.5">
              <label htmlFor="reset-confirm" className="text-sm font-medium text-fg">
                {t('auth.entry.reset.confirmNewLabel')}
              </label>
              <div className="auth-field">
                <span className="auth-field-icon auth-field-icon-lock" aria-hidden="true" />
                <Input
                  id="reset-confirm"
                  name="confirm-password"
                  type="password"
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  placeholder={t('auth.entry.reset.confirmNewPlaceholder')}
                  invalid={!!errorKey}
                  aria-describedby={errorKey ? 'reset-error' : undefined}
                  className="auth-input h-12"
                  required
                />
              </div>
            </div>

            <p
              id="reset-error"
              role="alert"
              aria-live="polite"
              className="min-h-5 text-sm text-down"
            >
              {errorKey ? t(errorKey) : ''}
            </p>

            <Button type="submit" disabled={isBusy} className="auth-cta mt-2 w-full">
              {isBusy
                ? t('auth.entry.reset.updateSubmitting')
                : t('auth.entry.reset.updateSubmit')}
            </Button>
          </form>
        </Card>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <Card className="auth-card p-6">
        <p className="mb-4 text-sm leading-relaxed text-muted">
          {t('auth.entry.reset.subtitle')}
        </p>
        <form onSubmit={handleRequest} noValidate className="space-y-4">
          <div className="space-y-1.5">
            <label htmlFor="reset-email" className="text-sm font-medium text-fg">
              {t('auth.entry.shared.emailLabel')}
            </label>
            <div className="auth-field">
              <span className="auth-field-icon auth-field-icon-email" aria-hidden="true" />
              <Input
                id="reset-email"
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
                aria-describedby={errorKey ? 'reset-error' : undefined}
                className="auth-input h-12"
                required
              />
            </div>
          </div>

          <p
            id="reset-error"
            role="alert"
            aria-live="polite"
            className="min-h-5 text-sm text-down"
          >
            {errorKey ? t(errorKey) : ''}
          </p>

          <Button type="submit" disabled={isBusy} className="auth-cta mt-2 w-full">
            {isBusy
              ? t('auth.entry.reset.requestSubmitting')
              : t('auth.entry.reset.requestSubmit')}
          </Button>
        </form>
      </Card>
      <footer className="mt-6 text-center text-sm text-muted">
        <p>
          <Link
            to="/login"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            {t('auth.entry.reset.backToLogin')}
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
