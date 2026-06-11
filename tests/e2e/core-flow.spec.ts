import { test, expect, type Page } from '@playwright/test';
import { adminClient, readAuth, currencyTotals, freshenOracle, injectBrowserSession } from './_helpers';

test.setTimeout(180_000);

async function injectSession(page: Page, accessToken: string, refreshToken: string): Promise<void> {
  await injectBrowserSession(page, accessToken, refreshToken, { unregisterServiceWorkers: true });
}

async function resetTradingRiskLimits(admin: ReturnType<typeof adminClient>): Promise<void> {
  await admin
    .from('futures_markets')
    .update({ is_active: true, max_user_positions: 100, max_open_interest: '1000000.000000', max_leverage: '10' })
    .in('symbol', ['PHONUSDT-PERP', 'BTCUSDT-SIM', 'ETHUSDT-SIM']);
}

test('core money flow: spot buy → futures open/close → stake → claim (ledger conserved)', async ({
  page,
}) => {
  const auth = readAuth();
  const admin = adminClient();

  await freshenOracle(admin);
  await resetTradingRiskLimits(admin);
  const before = await currencyTotals(admin);

  await injectSession(page, auth.accessToken, auth.refreshToken);

  // Navigate directly to trade (dashboard wallet rendering is covered by visual.spec.ts).
  // ── Spot buy (10 USDT → PHON) ──
  await page.goto('/trade');
  await expect(page.getByTestId('spot-submit')).toBeEnabled({ timeout: 15_000 });
  await page.getByTestId('spot-submit').click();
  await page.getByTestId('spot-confirm').click();
  await expect(page.getByTestId('spot-confirm')).toBeHidden({ timeout: 45_000 });

  // ── Futures open (default market, long, USDT margin) ──
  await freshenOracle(admin);
  await expect(page.getByTestId('futures-open')).toBeEnabled({ timeout: 15_000 });
  await page.getByTestId('futures-open').click();
  await page.getByTestId('futures-open-confirm').click();
  await expect(page.getByTestId('futures-close').first()).toBeVisible({ timeout: 15_000 });

  // ── Futures close ──
  await freshenOracle(admin);
  await page.getByTestId('futures-close').first().click();
  await page.getByTestId('futures-close-confirm').click();
  await expect(page.getByTestId('futures-close')).toHaveCount(0, { timeout: 15_000 });

  // ── Stake (first pool = flexible) ──
  await page.goto('/staking');
  await page.getByTestId('stake-submit').first().click();
  await page.getByTestId('stake-confirm').click();
  await expect(page.getByTestId('stake-claim').first()).toBeVisible({ timeout: 15_000 });

  // ── Claim staking reward ──
  await page.getByTestId('stake-claim').first().click();
  await page.getByTestId('staking-action-confirm').click();
  await expect(page.getByTestId('staking-action-confirm')).toBeHidden({ timeout: 15_000 });

  // ── Ledger conservation: Σ(users) + Σ(system) unchanged per currency ──
  const after = await currencyTotals(admin);
  expect(after.USDT, 'USDT must be conserved across the full flow').toBe(before.USDT);
  expect(after.PHON, 'PHON must be conserved across the full flow').toBe(before.PHON);

  // DB sanity: the user actually produced the expected entities.
  const { count: spotCount } = await admin
    .from('spot_trades')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  expect(spotCount ?? 0, 'a spot trade was recorded').toBeGreaterThan(0);

  const { count: stakeCount } = await admin
    .from('staking_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  expect(stakeCount ?? 0, 'a staking position was recorded').toBeGreaterThan(0);

  const { count: closedCount } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId)
    .eq('status', 'closed');
  expect(closedCount ?? 0, 'a futures position was opened and closed').toBeGreaterThan(0);
});

/**
 * S5 – ConfirmDialog negative path: clicking Cancel closes the dialog and
 * produces no server-side side effect. Asserts that DB record counts and
 * currency totals are UNCHANGED relative to the baseline captured at test
 * start (robust even when prior tests leave existing records for the same
 * user).
 */
test('confirm dialog: cancel closes without executing any action', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();

  await freshenOracle(admin);
  await resetTradingRiskLimits(admin);
  const before = await currencyTotals(admin);
  await injectSession(page, auth.accessToken, auth.refreshToken);

  // Snapshot pre-existing record counts so assertions compare deltas, not
  // absolute values (the money-flow test may have already created records).
  const { count: spotBefore } = await admin
    .from('spot_trades')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  const { count: stakeBefore } = await admin
    .from('staking_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  const { count: futuresBefore } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);

  // ── Spot cancel ──
  await page.goto('/trade');
  await expect(page.getByTestId('spot-submit')).toBeEnabled({ timeout: 15_000 });
  await page.getByTestId('spot-submit').click();
  await expect(page.getByTestId('spot-confirm')).toBeVisible({ timeout: 5_000 });
  await page.getByTestId('spot-cancel').click();
  await expect(page.getByTestId('spot-confirm')).toBeHidden({ timeout: 5_000 });

  // ── Futures open cancel ──
  await freshenOracle(admin);
  await expect(page.getByTestId('futures-open')).toBeEnabled({ timeout: 15_000 });
  // Capture the existing open-position count so the assertion is stable when
  // prior tests left behind open futures positions.
  const futuresCloseBefore = await page.getByTestId('futures-close').count();
  await page.getByTestId('futures-open').click();
  await expect(page.getByTestId('futures-open-confirm')).toBeVisible({ timeout: 5_000 });
  await page.getByTestId('futures-open-cancel').click();
  await expect(page.getByTestId('futures-open-confirm')).toBeHidden({ timeout: 5_000 });
  // Count must not have increased.
  await expect(page.getByTestId('futures-close')).toHaveCount(futuresCloseBefore);

  // ── Stake cancel ──
  const { count: activeStakeBefore } = await admin
    .from('staking_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId)
    .eq('status', 'active');
  await page.goto('/staking');
  await expect(page.getByTestId('stake-submit').first()).toBeVisible({ timeout: 15_000 });
  // Capture existing claim-buttons after positions have settled in the UI.
  const stakeClaimBefore = activeStakeBefore ?? 0;
  await expect(page.getByTestId('stake-claim')).toHaveCount(stakeClaimBefore, { timeout: 15_000 });
  await page.getByTestId('stake-submit').first().click();
  await expect(page.getByTestId('stake-confirm')).toBeVisible({ timeout: 5_000 });
  await page.getByTestId('stake-cancel').click();
  await expect(page.getByTestId('stake-confirm')).toBeHidden({ timeout: 5_000 });
  // Count must not have increased.
  await expect(page.getByTestId('stake-claim')).toHaveCount(stakeClaimBefore);

  // ── DB conservation: no money moved ──
  const after = await currencyTotals(admin);
  expect(after.USDT, 'cancel: USDT unchanged').toBe(before.USDT);
  expect(after.PHON, 'cancel: PHON unchanged').toBe(before.PHON);

  // DB sanity: record counts must be identical to pre-test baseline (delta = 0).
  const { count: spotAfter } = await admin
    .from('spot_trades')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  const { count: stakeAfter } = await admin
    .from('staking_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  const { count: futuresAfter } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);

  expect(spotAfter ?? 0, 'cancel: no new spot trade').toBe(spotBefore ?? 0);
  expect(stakeAfter ?? 0, 'cancel: no new staking position').toBe(stakeBefore ?? 0);
  expect(futuresAfter ?? 0, 'cancel: no new futures position').toBe(futuresBefore ?? 0);
});

test('futures risk caps reject in browser without moving money', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();

  await freshenOracle(admin);
  await resetTradingRiskLimits(admin);
  await admin
    .from('futures_markets')
    .update({ max_user_positions: 100, max_open_interest: '1.000000', max_leverage: '10' })
    .eq('symbol', 'PHONUSDT-PERP');

  const before = await currencyTotals(admin);
  const { count: positionsBefore } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);

  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/trade');
  await expect(page.getByTestId('futures-open')).toBeEnabled({ timeout: 15_000 });

  await page.getByTestId('futures-open').click();
  await page.getByTestId('futures-open-confirm').click();
  await expect(page.getByText(/open-interest|미결제약정|market has reached|한도/i)).toBeVisible({ timeout: 45_000 });

  const afterOi = await currencyTotals(admin);
  expect(afterOi.USDT, 'OI reject: USDT unchanged').toBe(before.USDT);
  expect(afterOi.PHON, 'OI reject: PHON unchanged').toBe(before.PHON);

  const { count: positionsAfterOi } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  expect(positionsAfterOi ?? 0, 'OI reject: no new position').toBe(positionsBefore ?? 0);

  await page.getByRole('slider').press('End');

  // Keep the stale client-side market metadata at 10x, then tighten the server
  // cap underneath it. The RPC must be the trusted guard.
  await admin
    .from('futures_markets')
    .update({ max_open_interest: '1000000.000000', max_leverage: '1' })
    .eq('symbol', 'PHONUSDT-PERP');

  const leverageError = await page.evaluate(async () => {
    const sb = (
      window as unknown as {
        __supabase: {
          rpc: (
            name: string,
            args: Record<string, string>,
          ) => Promise<{ error: { message?: string } | null }>;
        };
      }
    ).__supabase;
    const { error } = await sb.rpc('rpc_open_futures_position', {
      p_market: 'PHONUSDT-PERP',
      p_side: 'long',
      p_margin_currency: 'USDT',
      p_margin_amount: '100.000000',
      p_leverage: '10',
      p_client_request_id: `e2e-lev-${Date.now()}`,
    });
    return error?.message ?? null;
  });
  expect(leverageError, 'trusted RPC must reject stale client leverage').toMatch(/leverage_too_high|maximum allowed leverage|최대 레버리지/i);

  const afterLev = await currencyTotals(admin);
  expect(afterLev.USDT, 'leverage reject: USDT unchanged').toBe(before.USDT);
  expect(afterLev.PHON, 'leverage reject: PHON unchanged').toBe(before.PHON);

  const { count: positionsAfterLev } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId);
  expect(positionsAfterLev ?? 0, 'leverage reject: no new position').toBe(positionsBefore ?? 0);

  await admin
    .from('futures_markets')
    .update({ max_open_interest: '1000000.000000', max_leverage: '10' })
    .eq('symbol', 'PHONUSDT-PERP');
});
