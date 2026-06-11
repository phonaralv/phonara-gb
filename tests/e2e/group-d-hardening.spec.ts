import { test, expect, type Page } from '@playwright/test';
import Decimal from 'decimal.js';
import {
  adminClient,
  readAuth,
  currencyTotals,
  freshenOracle,
  injectBrowserSession,
  resetE2EOracleState,
} from './_helpers';

test.setTimeout(180_000);

async function injectSession(page: Page, accessToken: string, refreshToken: string): Promise<void> {
  await injectBrowserSession(page, accessToken, refreshToken, { unregisterServiceWorkers: true });
}

async function readMarketOpenInterest(admin: ReturnType<typeof adminClient>, symbol: string): Promise<Decimal> {
  const { data } = await admin
    .from('futures_positions')
    .select('notional')
    .eq('market', symbol)
    .eq('status', 'open');
  let total = new Decimal(0);
  for (const row of data ?? []) total = total.plus(row.notional ?? '0');
  return total;
}

test('candles expose global spot volume (not user-local)', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();
  await resetE2EOracleState(admin);

  const peerEmail = `vol_peer_${Date.now()}@phonara.local`;
  const { data: peerCreated, error: peerErr } = await admin.auth.admin.createUser({
    email: peerEmail,
    password: 'E2e-Vol-Peer-123456',
    email_confirm: true,
  });
  if (peerErr || !peerCreated.user) throw new Error(peerErr?.message ?? 'peer user missing');
  const peerId = peerCreated.user.id;

  for (let attempt = 0; attempt < 30; attempt++) {
    const { data } = await admin.from('wallets').select('user_id').eq('user_id', peerId).maybeSingle();
    if (data) break;
    await page.waitForTimeout(200);
  }

  await admin.from('wallets').update({ usdt_available: '1000000.000000', phon_available: '1000000.000000' }).eq('user_id', peerId);
  await admin.from('wallets').update({ usdt_available: '1000000.000000', phon_available: '1000000.000000' }).eq('user_id', auth.userId);

  const bucketAt = new Date();
  bucketAt.setUTCSeconds(0, 0);
  const bucket = bucketAt.toISOString();
  const bucketEpoch = Math.floor(bucketAt.getTime() / 1000);
  await admin.from('price_ticks').insert({ symbol: 'PHON_USDT', price: '0.010000', created_at: bucket });
  const { data: beforeCandles, error: beforeCandleErr } = await admin.rpc('rpc_get_candles', {
    p_symbol: 'PHON_USDT',
    p_interval: '1m',
    p_limit: 5,
  });
  expect(beforeCandleErr, 'pre-insert rpc_get_candles should succeed').toBeNull();
  const beforeRows = beforeCandles as Array<{ time?: number; volume?: string }> | null;
  const beforeVolume = new Decimal(beforeRows?.find((row) => row.time === bucketEpoch)?.volume ?? '0.000000');
  await admin.from('spot_trades').insert([
    {
      user_id: auth.userId,
      market: 'PHON_USDT',
      side: 'buy',
      price: '0.010000',
      usdt_amount: '5.000000',
      phon_amount: '5.000000',
      fee_currency: 'USDT',
      fee_amount: '0.005000',
      created_at: bucket,
    },
    {
      user_id: peerId,
      market: 'PHON_USDT',
      side: 'buy',
      price: '0.010000',
      usdt_amount: '7.000000',
      phon_amount: '7.000000',
      fee_currency: 'USDT',
      fee_amount: '0.007000',
      created_at: bucket,
    },
  ]);

  const { data: candles, error: candleErr } = await admin.rpc('rpc_get_candles', {
    p_symbol: 'PHON_USDT',
    p_interval: '1m',
    p_limit: 5,
  });
  expect(candleErr, 'rpc_get_candles should succeed').toBeNull();
  const rows = candles as Array<{ time?: number; volume?: string }> | null;
  const globalVolume = new Decimal(rows?.find((row) => row.time === bucketEpoch)?.volume ?? '0.000000');
  expect(globalVolume.minus(beforeVolume).toFixed(6), 'global volume delta sums all users in bucket').toBe('12.000000');

  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/trade');
  await expect(page.getByTestId('trading-chart-success').or(page.getByTestId('trading-chart-empty')).first()).toBeVisible({ timeout: 20_000 });

  const uiVolume = await page.evaluate(async (expectedBucket) => {
    const sb = (window as unknown as { __supabase: { rpc: (n: string, a: object) => Promise<{ data: unknown }> } }).__supabase;
    const { data } = await sb.rpc('rpc_get_candles', { p_symbol: 'PHON_USDT', p_interval: '1m', p_limit: 5 });
    const rows = data as Array<{ time?: number; volume?: string }> | null;
    return rows?.find((row) => row.time === expectedBucket)?.volume ?? null;
  }, bucketEpoch);
  expect(new Decimal(uiVolume ?? '0').minus(beforeVolume).toFixed(6), 'browser candle RPC sees global volume delta').toBe('12.000000');
});

test('price alert notification fires off /trade route', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();
  await resetE2EOracleState(admin);
  await admin.from('oracle_prices').update({ price: '0.010000', updated_at: new Date().toISOString() }).eq('symbol', 'PHONUSDT-PERP');

  await page.addInitScript(() => {
    window.localStorage.setItem('phonara.trade.priceAlert.v1', JSON.stringify({
      symbol: 'PHONUSDT-PERP',
      target: '0.010500',
      direction: 'above',
      enabled: true,
      triggered: false,
    }));
  });
  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/dashboard');
  await expect(page.getByTestId('dashboard-page')).toBeVisible({ timeout: 15_000 });
  await expect.poll(
    () => page.evaluate(() => window.localStorage.getItem('phonara.trade.priceAlert.v1')),
    { timeout: 5_000 },
  ).toContain('PHONUSDT-PERP');
  await page.waitForTimeout(3_000);

  const alertPromise = page.locator('[data-sonner-toast]').filter({ hasText: /price alert|가격 알림/i }).first()
    .waitFor({ timeout: 30_000 });
  await admin.from('oracle_prices').update({ price: '0.011000', updated_at: new Date().toISOString() }).eq('symbol', 'PHONUSDT-PERP');
  await alertPromise;

  await resetE2EOracleState(admin);
});

test('stale oracle shows market-data-status warning on /trade', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();
  await resetE2EOracleState(admin);
  const staleAt = new Date(Date.now() - 600_000).toISOString();
  await admin
    .from('oracle_prices')
    .update({ updated_at: staleAt })
    .in('symbol', ['PHONUSDT-PERP', 'PHON_USDT']);

  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/trade');
  await expect(page.getByTestId('futures-open')).toBeDisabled({ timeout: 20_000 });
  await expect(page.getByTestId('market-data-status')).toBeVisible({ timeout: 10_000 });
  await expect.poll(
    async () => await page.getByTestId('market-data-status').textContent(),
    { timeout: 20_000 },
  ).toMatch(/delayed|지연|syncing|동기화/i);
});

test('parallel futures opens respect OI cap (race boundary)', async ({ page }) => {
  const auth = readAuth();
  const admin = adminClient();
  await freshenOracle(admin);

  const slotNotional = new Decimal('20.000000');
  const currentOi = await readMarketOpenInterest(admin, 'PHONUSDT-PERP');
  const oiCap = currentOi.plus(slotNotional).plus('0.000001').toFixed(6);

  await admin
    .from('futures_markets')
    .update({
      is_active: true,
      max_user_positions: 100,
      max_open_interest: oiCap,
      max_leverage: '10',
    })
    .eq('symbol', 'PHONUSDT-PERP');

  const before = await currencyTotals(admin);
  const { count: positionsBefore } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId)
    .eq('status', 'open');

  await injectSession(page, auth.accessToken, auth.refreshToken);
  await page.goto('/trade');
  await expect(page.getByTestId('futures-open')).toBeEnabled({ timeout: 20_000 });

  const results = await page.evaluate(async () => {
    const sb = (
      window as unknown as {
        __supabase: {
          rpc: (
            name: string,
            args: Record<string, string>,
          ) => Promise<{ data: unknown; error: { message?: string; code?: string } | null }>;
        };
      }
    ).__supabase;

    const base = {
      p_market: 'PHONUSDT-PERP',
      p_side: 'long',
      p_margin_currency: 'USDT',
      p_margin_amount: '10.000000',
      p_leverage: '2',
    };
    const stamp = Date.now();

    return Promise.all([
      sb.rpc('rpc_open_futures_position', { ...base, p_client_request_id: `race-a-${stamp}` }),
      sb.rpc('rpc_open_futures_position', { ...base, p_client_request_id: `race-b-${stamp + 1}` }),
    ]);
  });

  const successes = results.filter((r) => !r.error);
  const failures = results.filter((r) => r.error);
  const failureMsg = failures.map((r) => r.error?.message ?? 'unknown').join(' | ');
  expect(successes.length, `exactly one parallel open succeeds at OI cap (failures: ${failureMsg})`).toBe(1);
  expect(failures.length, 'second parallel open rejected').toBe(1);
  expect(failures[0]?.error?.message ?? '').toMatch(/market_oi_cap|open.interest|open_interest|미결제약정|market has reached|한도/i);

  const { count: positionsAfter } = await admin
    .from('futures_positions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', auth.userId)
    .eq('status', 'open');
  expect((positionsAfter ?? 0) - (positionsBefore ?? 0), 'at most one new open position').toBeLessThanOrEqual(1);

  const after = await currencyTotals(admin);
  expect(after.USDT, 'OI race conserves USDT Σ').toBe(before.USDT);
  expect(after.PHON, 'OI race conserves PHON Σ').toBe(before.PHON);

  await admin
    .from('futures_markets')
    .update({ max_open_interest: '1000000.000000' })
    .eq('symbol', 'PHONUSDT-PERP');
});
