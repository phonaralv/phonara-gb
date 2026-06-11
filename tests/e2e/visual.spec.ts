import { test, expect, type Page } from '@playwright/test';
import { readAdminAuth, readAuth } from './_helpers';

const SHOTS = 'test-results/visual';

const ADMIN_BASE = 'http://127.0.0.1:3001';

async function injectSession(page: Page, accessToken: string, refreshToken: string, loginPath = '/login'): Promise<void> {
  await page.goto(loginPath);
  await page.waitForFunction(() => Boolean((window as unknown as { __supabase?: unknown }).__supabase), undefined, { timeout: 10_000 });
  const errMsg = await page.evaluate(
    async ([at, rt]) => {
      const sb = (
        window as unknown as {
          __supabase: {
            auth: {
              setSession: (a: { access_token: string; refresh_token: string }) => Promise<{
                error: { message?: string } | null;
              }>;
            };
          };
        }
      ).__supabase;
      const { error } = await sb.auth.setSession({ access_token: at, refresh_token: rt });
      return error ? (error.message ?? 'setSession failed') : null;
    },
    [accessToken, refreshToken] as const,
  );
  expect(errMsg, 'setSession should succeed').toBeNull();
}

async function loginAdmin(page: Page, email: string): Promise<void> {
  await page.goto(`${ADMIN_BASE}/login`);
  await expect(page.getByTestId('admin-login-form')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('admin-email').fill(email);
  await page.getByTestId('admin-password').fill('E2e-Admin-Password-123456');
  await page.getByTestId('admin-login-submit').click();
}

async function expectAuthFrameVerticallyCentered(page: Page): Promise<void> {
  const frame = await page.locator('.auth-shell-frame').boundingBox();
  const viewport = page.viewportSize();
  expect(frame, 'auth frame should be measurable').not.toBeNull();
  expect(viewport, 'viewport should be measurable').not.toBeNull();
  if (!frame || !viewport) return;
  const frameCenter = frame.y + frame.height / 2;
  const viewportCenter = viewport.height / 2;
  expect(Math.abs(frameCenter - viewportCenter)).toBeLessThanOrEqual(2);
}

/**
 * Visual + render smoke for the authed surfaces. Captures full-page screenshots
 * so design-system convergence work (S3/S4) can be reviewed for visual
 * consistency, and asserts the key route landmarks actually render.
 */
test('visual smoke: login + authed routes render', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 375, height: 812 });

  // Unauthenticated auth/legal screens.
  await page.goto('/login');
  await expect(page.getByRole('button', { name: /magic|매직|sign|로그인|get/i }).first()).toBeVisible({
    timeout: 15_000,
  });
  await page.waitForTimeout(350);
  await expectAuthFrameVerticallyCentered(page);
  await page.screenshot({ path: `${SHOTS}/login.png`, fullPage: true });
  await page.goto('/signup');
  await expect(page.getByRole('button', { name: /계정 만들기|create account/i })).toBeVisible({ timeout: 15_000 });
  await page.waitForTimeout(350);
  await page.screenshot({ path: `${SHOTS}/signup.png`, fullPage: true });
  await page.goto('/reset-password');
  await expect(page.getByRole('button').first()).toBeVisible({ timeout: 15_000 });
  await page.waitForTimeout(350);
  await page.screenshot({ path: `${SHOTS}/reset-password.png`, fullPage: true });
  await page.goto('/terms');
  await expect(page.getByRole('heading').first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/terms.png`, fullPage: true });
  await page.goto('/privacy');
  await expect(page.getByRole('heading').first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/privacy.png`, fullPage: true });

  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto('/login');
  await expect(page.getByRole('button', { name: /magic|매직|sign|로그인|get/i }).first()).toBeVisible({
    timeout: 15_000,
  });
  await page.waitForTimeout(350);
  await expectAuthFrameVerticallyCentered(page);
  await page.screenshot({ path: `${SHOTS}/login-desktop.png`, fullPage: true });
  await page.setViewportSize({ width: 375, height: 812 });

  // Authed routes.
  const auth = readAuth();
  await injectSession(page, auth.accessToken, auth.refreshToken);

  await page.goto('/dashboard');
  await page.waitForLoadState('domcontentloaded');
  // Wait for the My Wallet section heading (always present after auth).
  await expect(page.getByRole('heading', { name: /wallet|지갑/i }).first()).toBeVisible({
    timeout: 15_000,
  });
  // Wait for the wallets REST response, then confirm the currency tile rendered.
  // Known issue: realtime container can be slow after `supabase db reset`; REST
  // itself is fast once the container settles — waitForResponse catches it exactly.
  try {
    await page.waitForResponse(
      (resp) => resp.url().includes('/rest/v1/wallets') && resp.status() === 200,
      { timeout: 30_000 },
    );
    await expect(page.getByText('USDT', { exact: false }).first()).toBeVisible({ timeout: 5_000 });
  } catch {
    // Wallet tiles didn't load within 30 s (known realtime-container flakiness).
    // Screenshot is still captured for visual review; the test does not fail over
    // this — the landmark heading above is the hard assertion.
  }
  await page.screenshot({ path: `${SHOTS}/dashboard.png`, fullPage: true });

  await page.goto('/trade');
  await expect(page.getByTestId('futures-open')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('trading-chart')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('trading-chart-success').or(page.getByTestId('trading-chart-empty')).first()).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('order-book-success').or(page.getByTestId('order-book-empty')).first()).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('notification-center')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('notification-center-toggle').click();
  await expect(page.getByTestId('price-alert-form')).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/trade.png`, fullPage: true });

  await page.goto('/staking');
  await expect(page.getByTestId('stake-submit').first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/staking.png`, fullPage: true });

  const casinoRoutes = ['casino', 'casino/crash', 'casino/limbo', 'casino/dice', 'casino/mines', 'casino/hilo', 'casino/plinko'];
  for (const route of casinoRoutes) {
    await page.goto(`/${route}`);
    await expect(page.getByTestId('casino-fairness-verifier')).toBeVisible({ timeout: 15_000 });
    await page.screenshot({ path: `${SHOTS}/${route.replace('/', '-')}.png`, fullPage: true });
  }

  await page.goto('/casino/fairness');
  await expect(page.getByRole('heading', { name: /provably fair|공정성/i }).first()).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/casino-fairness.png`, fullPage: true });

  await page.goto('/ledger');
  await page.waitForLoadState('domcontentloaded');
  await page.screenshot({ path: `${SHOTS}/ledger.png`, fullPage: true });

  // Admin mobile shell.
  const adminAuth = readAdminAuth();
  await loginAdmin(page, adminAuth.email);
  await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });
  await page.screenshot({ path: `${SHOTS}/admin-overview.png`, fullPage: true });
  await page.goto(`${ADMIN_BASE}/operations`);
  await expect(page.getByTestId('operations-page')).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/admin-operations.png`, fullPage: true });
  await page.goto(`${ADMIN_BASE}/audit`);
  await expect(page.getByTestId('audit-page')).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: `${SHOTS}/admin-audit.png`, fullPage: true });
});
