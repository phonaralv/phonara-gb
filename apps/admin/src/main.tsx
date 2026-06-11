import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { createRouter, RouterProvider } from '@tanstack/react-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { Route as rootRoute } from './routes/__root';
import { Route as loginRoute } from './routes/login';
import { Route as overviewRoute } from './routes/overview';
import { Route as queuesRoute } from './routes/queues';
import { Route as auditRoute } from './routes/audit';
import { Route as operationsRoute } from './routes/operations';
import { AuthProvider } from './contexts/auth-context';
import { I18nProvider } from './lib/i18n';
import { queryClient } from './lib/query';
import './theme.css';

const routeTree = rootRoute.addChildren([
  loginRoute,
  overviewRoute,
  queuesRoute,
  auditRoute,
  operationsRoute,
]);

const router = createRouter({ routeTree, defaultPreload: 'intent' });

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <RouterProvider router={router} />
        </AuthProvider>
      </QueryClientProvider>
    </I18nProvider>
  </StrictMode>,
);
