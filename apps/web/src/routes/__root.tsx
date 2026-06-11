import { createRootRoute, Outlet } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { AuthProvider } from '../contexts/auth-context';
import { useAuth } from '../contexts/auth-context';
import { signOut } from '../lib/auth';
import { env } from '../lib/env';
import { useT } from '../lib/i18n';
import { Button, Card, buttonVariants } from '@phonara/ui';
import { GlobalNotificationSubscriptions } from '../components/global-notification-subscriptions';
import { useRealtimeConnectionStore } from '../stores/realtime';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <AuthProvider>
      <GlobalNotificationSubscriptions />
      <AccountRestrictionBanner />
      <RealtimeConnectionBanner />
      <Outlet />
    </AuthProvider>
  );
}

function RealtimeConnectionBanner() {
  const t = useT();
  const disconnected = useRealtimeConnectionStore((s) => s.disconnected);

  if (!disconnected) return null;

  return (
    <div className="fixed inset-x-0 top-20 z-40 px-4 pt-3" data-testid="realtime-disconnect-banner">
      <Card className="mx-auto flex max-w-4xl flex-col gap-1 border-warning/40 bg-surface p-4 shadow-lg">
        <p className="text-sm font-semibold text-fg">{t('realtime.banner.title')}</p>
        <p className="text-xs text-muted">{t('realtime.banner.description')}</p>
      </Card>
    </div>
  );
}

function AccountRestrictionBanner() {
  const t = useT();
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const { data: activityFrozen = false } = useQuery({
    queryKey: ['profile-activity-frozen', userId],
    queryFn: async () => {
      const response = await fetch(
        `${env.VITE_SUPABASE_URL}/rest/v1/profiles?select=activity_frozen&id=eq.${encodeURIComponent(userId!)}`,
        {
          headers: {
            apikey: env.VITE_SUPABASE_ANON_KEY,
            Authorization: `Bearer ${session!.access_token}`,
            Accept: 'application/json',
          },
        },
      );
      if (!response.ok) {
        throw new Error(`profile restriction lookup failed: ${response.status}`);
      }
      const rows = (await response.json()) as Array<{ activity_frozen: boolean }>;
      return rows[0]?.activity_frozen ?? false;
    },
    enabled: !!userId,
  });

  if (!activityFrozen) return null;

  return (
    <div className="fixed inset-x-0 top-0 z-50 px-4 pt-3" data-testid="account-restriction-banner">
      <Card className="mx-auto flex max-w-4xl flex-col gap-3 border-down/40 bg-surface p-4 shadow-lg md:flex-row md:items-center md:justify-between">
        <div>
          <p className="text-sm font-semibold text-fg">{t('account.restricted.title')}</p>
          <p className="mt-1 text-xs text-muted">{t('account.restricted.description')}</p>
        </div>
        <div className="flex shrink-0 gap-2">
          <Button
            variant="outline"
            size="sm"
            data-testid="account-restriction-signout"
            onClick={() => { void signOut(); }}
          >
            {t('nav.logout')}
          </Button>
          <a
            className={buttonVariants({ size: 'sm' })}
            href={`mailto:${t('account.restricted.appealEmail')}`}
            data-testid="account-restriction-appeal"
          >
            {t('account.restricted.appeal')}
          </a>
        </div>
      </Card>
    </div>
  );
}
