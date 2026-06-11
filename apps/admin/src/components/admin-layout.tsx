import { Link, useRouterState } from '@tanstack/react-router';
import type { ReactNode } from 'react';
import { useT } from '../lib/i18n';
import { signOut } from '../lib/auth';
import { Button } from '@phonara/ui';

interface NavItem {
  to: string;
  labelKey:
    | 'admin.nav.overview'
    | 'admin.nav.alerts'
    | 'admin.nav.queues'
    | 'admin.nav.audit'
    | 'admin.nav.operations';
  testId: string;
}

const NAV_ITEMS: NavItem[] = [
  { to: '/overview', labelKey: 'admin.nav.overview', testId: 'nav-overview' },
  { to: '/alerts', labelKey: 'admin.nav.alerts', testId: 'nav-alerts' },
  { to: '/queues', labelKey: 'admin.nav.queues', testId: 'nav-queues' },
  { to: '/audit', labelKey: 'admin.nav.audit', testId: 'nav-audit' },
  { to: '/operations', labelKey: 'admin.nav.operations', testId: 'nav-operations' },
];

export function AdminLayout({ children }: { children: ReactNode }) {
  const t = useT();
  const { location } = useRouterState();

  async function handleSignOut() {
    await signOut();
  }

  return (
    <div className="flex min-h-dvh">
      <aside
        className="w-64 shrink-0 flex flex-col border-r border-border bg-surface"
        data-testid="admin-sidebar"
      >
        <div className="px-6 py-5 border-b border-border">
          <span className="font-bold text-primary tracking-wide text-sm uppercase">
            PHONARA Admin
          </span>
        </div>

        <nav className="flex-1 px-3 py-4 flex flex-col gap-1" aria-label="Admin navigation">
          {NAV_ITEMS.map(({ to, labelKey, testId }) => {
            const active = location.pathname === to || location.pathname.startsWith(`${to}/`);
            return (
              <Link
                key={to}
                to={to}
                data-testid={testId}
                className={[
                  'flex items-center px-3 py-2 rounded-xl text-sm font-medium transition-colors',
                  active
                    ? 'bg-primary/15 text-primary'
                    : 'text-muted hover:bg-surface-2 hover:text-fg',
                ].join(' ')}
              >
                {t(labelKey)}
              </Link>
            );
          })}
        </nav>

        <div className="px-3 py-4 border-t border-border">
          <Button
            variant="outline"
            size="sm"
            className="w-full"
            data-testid="admin-logout"
            onClick={handleSignOut}
          >
            {t('nav.logout')}
          </Button>
        </div>
      </aside>

      <main className="flex-1 overflow-auto p-8">{children}</main>
    </div>
  );
}
