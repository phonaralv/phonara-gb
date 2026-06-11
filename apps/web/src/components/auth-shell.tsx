import type { ReactNode } from 'react';
import { Link } from '@tanstack/react-router';
import { useT } from '../lib/i18n';

type AuthShellProps = {
  children: ReactNode;
};

export function AuthShell({ children }: AuthShellProps) {
  const t = useT();
  return (
    <main className="auth-shell-root flex min-h-screen items-center justify-center text-fg">
      <div className="auth-shell-frame w-full max-w-[420px] px-4">
        <header className="mb-8 text-center">
          <div className="auth-live-badge auth-stagger auth-stagger-0 mb-4">
            <span className="auth-live-dot" aria-hidden="true" />
            <span>{t('auth.entry.brand.eyebrow')}</span>
          </div>
          <Link
            to="/"
            className="auth-brand-link auth-stagger auth-stagger-1 inline-flex text-sm font-semibold text-primary transition-colors hover:text-fg"
          >
            {t('common.appName')}
          </Link>
          <h1 className="auth-headline auth-stagger auth-stagger-2 mt-3 text-3xl font-extrabold leading-tight text-fg sm:text-4xl">
            {t('auth.entry.brand.headlineBefore')}{' '}
            <span className="auth-headline-phon bg-clip-text text-transparent">
              {t('auth.entry.brand.headlinePhon')}
            </span>{' '}
            {t('auth.entry.brand.headlineAfter')}
          </h1>
          <p className="auth-stagger auth-stagger-3 mx-auto mt-3 max-w-[340px] text-sm leading-relaxed tracking-normal text-muted">
            {t('auth.entry.brand.subtitle')}
          </p>
        </header>

        <div className="auth-content">
          {children}
        </div>
      </div>
    </main>
  );
}
