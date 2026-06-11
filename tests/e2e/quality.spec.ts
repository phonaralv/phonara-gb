import { expect, test, type Page } from '@playwright/test';
import { readAuth } from './_helpers';

async function injectSession(page: Page, accessToken: string, refreshToken: string): Promise<void> {
  await page.goto('/login');
  await page.waitForFunction(() => Boolean((window as unknown as { __supabase?: unknown }).__supabase));
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

async function expectNamedButtons(page: Page): Promise<void> {
  const unnamedButtons = await page.locator('button').evaluateAll((buttons) =>
    buttons
      .map((button) => button.textContent?.trim() || button.getAttribute('aria-label') || button.getAttribute('title') || '')
      .filter((name) => name.length === 0).length,
  );
  expect(unnamedButtons, 'every button must have visible text or an accessible name').toBe(0);
}

test('PWA and accessibility smoke: install metadata, offline fallback, named controls', async ({ page }) => {
  test.setTimeout(90_000);

  await page.goto('/login');
  await expect(page.locator('meta[name="viewport"]')).toHaveAttribute('content', /viewport-fit=cover/);
  await expect(page.locator('link[rel="apple-touch-icon"]')).toHaveAttribute('href', /apple-touch-icon/);
  await expectNamedButtons(page);

  await expect(page.locator('link[rel="manifest"]')).toHaveAttribute('href', '/manifest.webmanifest');

  const offline = await page.request.get('/offline.html');
  expect(offline.ok(), 'offline fallback should be served').toBe(true);
  expect(await offline.text()).toContain('phonara.locale');

  const auth = readAuth();
  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/dashboard');
  await expect(page.getByTestId('dashboard-page')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('referral-dashboard')).toBeVisible({ timeout: 15_000 });
  await expectNamedButtons(page);
});
