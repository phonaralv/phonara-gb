import { createRoute } from '@tanstack/react-router';
import { Route as rootRoute } from './__root';
import { AdminLayout } from '../components/admin-layout';
import { useT } from '../lib/i18n';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/overview',
  component: OverviewPage,
});

function OverviewPage() {
  const t = useT();

  return (
    <AdminLayout>
      <div className="space-y-4" data-testid="overview-page">
        <h1 className="text-2xl font-bold text-fg">{t('admin.overview.title')}</h1>
        <p className="text-muted">{t('admin.overview.description')}</p>
      </div>
    </AdminLayout>
  );
}
