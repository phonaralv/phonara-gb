import { createRootRoute, Outlet, Navigate } from '@tanstack/react-router';
import { useEffect, useState } from 'react';
import { useAuth } from '../contexts/auth-context';
import { useIsAdmin } from '../hooks/use-is-admin';
import { useT } from '../lib/i18n';
import { signOut } from '../lib/auth';
import { supabase } from '../lib/supabase';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  const { session, loading: authLoading } = useAuth();
  const { isAdmin, loading: adminLoading } = useIsAdmin();
  const [mfaLevel, setMfaLevel] = useState<string | null>(null);
  const [mfaLoading, setMfaLoading] = useState(false);
  const t = useT();

  useEffect(() => {
    if (!session || !import.meta.env.PROD) {
      setMfaLevel(null);
      return;
    }
    setMfaLoading(true);
    void supabase.auth.mfa.getAuthenticatorAssuranceLevel().then(({ data }) => {
      setMfaLevel(data?.currentLevel ?? null);
      setMfaLoading(false);
    });
  }, [session]);

  if (authLoading) {
    return (
      <div className="flex items-center justify-center min-h-dvh text-muted text-sm">
        {t('common.loading')}
      </div>
    );
  }

  const isLogin = window.location.pathname === '/login';

  if (!session) {
    if (isLogin) return <Outlet />;
    return <Navigate to="/login" />;
  }

  // Session exists — wait for admin check before rendering protected routes.
  if (!isLogin) {
    if (adminLoading) {
      return (
        <div className="flex items-center justify-center min-h-dvh text-muted text-sm">
          {t('admin.loading')}
        </div>
      );
    }

    if (!isAdmin) {
      return (
        <div
          className="flex flex-col items-center justify-center min-h-dvh gap-4"
          data-testid="admin-forbidden"
        >
          <p className="text-down font-semibold">{t('admin.forbidden')}</p>
          <button
            className="text-sm text-muted underline"
            onClick={() => { void signOut(); }}
          >
            {t('nav.logout')}
          </button>
        </div>
      );
    }

    if (import.meta.env.PROD && (mfaLoading || mfaLevel !== 'aal2')) {
      return (
        <div
          className="flex flex-col items-center justify-center min-h-dvh gap-4 px-6 text-center"
          data-testid="admin-mfa-required"
        >
          <p className="text-down font-semibold">{t('admin.mfa.required')}</p>
          <p className="max-w-sm text-sm text-muted">{t('admin.mfa.description')}</p>
          <button
            className="text-sm text-muted underline"
            onClick={() => { void signOut(); }}
          >
            {t('nav.logout')}
          </button>
        </div>
      );
    }
  }

  return <Outlet />;
}
