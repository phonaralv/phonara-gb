import { createRootRoute, Outlet } from '@tanstack/react-router';
import { AuthProvider } from '../contexts/auth-context';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <AuthProvider>
      <Outlet />
    </AuthProvider>
  );
}
