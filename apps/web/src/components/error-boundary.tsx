import { Component, type ErrorInfo, type ReactNode } from 'react';
import { useT } from '../lib/i18n';
import { Button } from '@phonara/ui';

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  hasError: boolean;
}

/**
 * Top-level error boundary. Catches render-time crashes so the whole app never
 * white-screens; shows an i18n-keyed recovery panel instead. In dev the raw
 * error is logged to the console; in production it is swallowed (no stack leak).
 */
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  override state: ErrorBoundaryState = { hasError: false };

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true };
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    if (import.meta.env.DEV) {
      console.error('[ErrorBoundary]', error, info.componentStack);
    }
  }

  override render(): ReactNode {
    if (this.state.hasError) {
      return <ErrorFallback />;
    }
    return this.props.children;
  }
}

function ErrorFallback() {
  const t = useT();
  return (
    <div
      role="alert"
      className="flex min-h-dvh flex-col items-center justify-center gap-4 bg-bg px-6 py-[max(1.5rem,env(safe-area-inset-top))] text-center text-fg"
    >
      <h1 className="text-xl font-semibold">
        {t('error.boundary.title')}
      </h1>
      <p className="max-w-md text-sm text-muted">
        {t('error.boundary.description')}
      </p>
      <Button
        type="button"
        className="mt-2"
        onClick={() => window.location.reload()}
      >
        {t('error.boundary.reload')}
      </Button>
    </div>
  );
}
