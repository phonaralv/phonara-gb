import { createRouter } from '@tanstack/react-router';
import { Route as rootRoute } from './routes/__root';
import { Route as indexRoute } from './routes/index';
import { Route as loginRoute } from './routes/login';
import { Route as signupRoute } from './routes/signup';
import { Route as resetPasswordRoute } from './routes/reset-password';
import { Route as termsRoute } from './routes/terms';
import { Route as privacyRoute } from './routes/privacy';
import { Route as dashboardRoute } from './routes/dashboard';
import { Route as ledgerRoute } from './routes/ledger';
import { Route as tradeRoute } from './routes/trade';
import { Route as stakingRoute } from './routes/staking';
import {
  casinoIndexRoute,
  casinoCrashRoute,
  casinoLimboRoute,
  casinoDiceRoute,
  casinoMinesRoute,
  casinoHiloRoute,
  casinoPlinkoRoute,
  casinoFairnessRoute,
} from './routes/casino';
import { Route as walletRoute } from './routes/wallet';

const routeTree = rootRoute.addChildren([
  indexRoute,
  loginRoute,
  signupRoute,
  resetPasswordRoute,
  termsRoute,
  privacyRoute,
  dashboardRoute,
  ledgerRoute,
  tradeRoute,
  stakingRoute,
  walletRoute,
  casinoIndexRoute,
  casinoCrashRoute,
  casinoLimboRoute,
  casinoDiceRoute,
  casinoMinesRoute,
  casinoHiloRoute,
  casinoPlinkoRoute,
  casinoFairnessRoute,
]);

export const router = createRouter({
  routeTree,
  defaultPreload: 'intent',
});

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
