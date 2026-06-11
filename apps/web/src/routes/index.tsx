import { createRoute, useNavigate } from '@tanstack/react-router';
import { useEffect } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { Card, Skeleton } from '@phonara/ui';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  component: IndexRedirect,
});

function IndexRedirect() {
  const { session, loading } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (loading) return;
    if (session) {
      void navigate({ to: '/dashboard' });
    } else {
      void navigate({ to: '/login' });
    }
  }, [session, loading, navigate]);

  return (
    <div className="shell">
      <Card className="grid w-full max-w-sm gap-4 p-5" aria-busy="true">
        <Skeleton className="h-5 w-28" />
        <Skeleton className="h-20" />
      </Card>
    </div>
  );
}
