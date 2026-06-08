import { createRoute, useNavigate } from '@tanstack/react-router';
import { useEffect } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';

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
      <span className="spinner" aria-label="Loading" />
    </div>
  );
}
