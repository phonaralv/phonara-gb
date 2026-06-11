import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClientProvider } from '@tanstack/react-query';
import { RouterProvider } from '@tanstack/react-router';
import { Toaster } from 'sonner';
import { router } from './router';
import { queryClient } from './lib/query';
import { I18nProvider } from './lib/i18n';
import { ErrorBoundary } from './components/error-boundary';
import { supabase } from './lib/supabase';
import './theme.css';
import './styles.css';

// DEV-only: expose the Supabase client so E2E (Playwright) can inject a real
// session via `auth.setSession(...)` instead of completing a magic-link flow.
// Excluded from production builds by the `import.meta.env.DEV` guard.
if (import.meta.env.DEV) {
  (window as unknown as { __supabase?: typeof supabase }).__supabase = supabase;
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <I18nProvider>
        <ErrorBoundary>
          <RouterProvider router={router} />
        </ErrorBoundary>
        <Toaster position="top-center" theme="dark" richColors closeButton />
      </I18nProvider>
    </QueryClientProvider>
  </StrictMode>,
);
