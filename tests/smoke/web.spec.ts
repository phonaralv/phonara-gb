import { test, expect } from '@playwright/test';

test('web app phase 0 shell loads', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('PHONARA v2')).toBeVisible();
});
