import { test, expect, type Page } from '@playwright/test';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { messages } from '../../packages/i18n/src/index.ts';
import {
  adminClient,
  injectBrowserSession,
  readAuth,
  ANON_KEY,
  SUPABASE_URL,
  currencyTotals,
  type E2EAuth,
} from './_helpers';

const ROULETTE_PRIZES = [10, 20, 30, 50, 100, 300, 500, 1000] as const;
const DEFAULT_MAX_PAYOUT_PHON = '1000000.000000';
const LOW_MAX_PAYOUT_PHON = '10.000000';

async function injectSession(page: Page, accessToken: string, refreshToken: string): Promise<void> {
  await injectBrowserSession(page, accessToken, refreshToken, {
    unregisterServiceWorkers: true,
  });
}

function authedClient(auth: E2EAuth): SupabaseClient {
  return createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
  });
}

test.describe.configure({ mode: 'serial', timeout: 120_000 });

test.describe('Wave 7 Phase 4 closeout', () => {
  test('cap rejection: confirm dialog then i18n error, not raw SQL code', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await admin
      .from('app_config')
      .update({ value: LOW_MAX_PAYOUT_PHON })
      .eq('key', 'casino_max_payout_phon');

    try {
      await page.addInitScript(() => {
        window.localStorage.setItem('phonara.locale', 'ko');
      });
      await injectSession(page, auth.accessToken, auth.refreshToken);

      const { count: betsBefore } = await admin
        .from('game_bets')
        .select('*', { count: 'exact', head: true })
        .eq('user_id', auth.userId);
      const before = await currencyTotals(admin);

      await page.goto('/casino/dice');
      await expect(page.getByTestId('casino-fairness-verifier')).toBeVisible({ timeout: 15_000 });

      await page.getByTestId('casino-prepare-hash').click();
      await expect(page.getByTestId('casino-place-bet')).toBeEnabled({ timeout: 15_000 });

      await page.getByTestId('casino-stake-input').fill('100');
      await page.getByTestId('casino-place-bet').click();
      await expect(page.getByTestId('casino-bet-confirm-confirm')).toBeVisible({ timeout: 5_000 });

      await page.getByTestId('casino-bet-confirm-confirm').click();
      await expect(page.getByTestId('casino-error')).toBeVisible({ timeout: 15_000 });

      const errorText = await page.getByTestId('casino-error').innerText();
      expect(errorText, 'raw SQL code must not leak').not.toMatch(/house_exposure_cap/i);
      expect(errorText).toContain(messages.ko['error.HOUSE_EXPOSURE_CAP']);

      const after = await currencyTotals(admin);
      expect(after.PHON, 'cap reject: PHON conserved').toBe(before.PHON);
      expect(after.USDT, 'cap reject: USDT conserved').toBe(before.USDT);

      const { count: betsAfter } = await admin
        .from('game_bets')
        .select('*', { count: 'exact', head: true })
        .eq('user_id', auth.userId);
      expect(betsAfter ?? 0, 'cap reject: no new bet row').toBe(betsBefore ?? 0);
    } finally {
      await admin
        .from('app_config')
        .update({ value: DEFAULT_MAX_PAYOUT_PHON })
        .eq('key', 'casino_max_payout_phon');
    }
  });

  test('casino confirm cancel: dialog dismiss leaves wallet and bets unchanged', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await injectSession(page, auth.accessToken, auth.refreshToken);

    const before = await currencyTotals(admin);
    const { count: betsBefore } = await admin
      .from('game_bets')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', auth.userId);

    await page.goto('/casino/dice');
    await expect(page.getByTestId('casino-fairness-verifier')).toBeVisible({ timeout: 15_000 });
    await page.getByTestId('casino-prepare-hash').click();
    await expect(page.getByTestId('casino-place-bet')).toBeEnabled({ timeout: 15_000 });

    await page.getByTestId('casino-place-bet').click();
    await expect(page.getByTestId('casino-bet-confirm-cancel')).toBeVisible({ timeout: 5_000 });
    await page.getByTestId('casino-bet-confirm-cancel').click();
    await expect(page.getByTestId('casino-bet-confirm-confirm')).toBeHidden({ timeout: 5_000 });

    const after = await currencyTotals(admin);
    expect(after.PHON, 'cancel: PHON delta 0').toBe(before.PHON);
    expect(after.USDT, 'cancel: USDT delta 0').toBe(before.USDT);

    const { count: betsAfter } = await admin
      .from('game_bets')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', auth.userId);
    expect(betsAfter ?? 0, 'cancel: bet count delta 0').toBe(betsBefore ?? 0);
  });

  test('daily claim and roulette: server authority and Σ conservation', async ({ page }) => {
    test.setTimeout(180_000);
    const auth = readAuth();
    const admin = adminClient();
    const client = authedClient(auth);

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/dashboard');
    await expect(page.getByTestId('daily-claim-submit')).toBeVisible({ timeout: 15_000 });

    const beforeDaily = await currencyTotals(admin);
    await Promise.all([
      page.waitForResponse((resp) => resp.url().includes('rpc_claim_daily_reward') && resp.status() < 500, {
        timeout: 30_000,
      }),
      page.getByTestId('daily-claim-submit').click(),
    ]);
    const afterDaily = await currencyTotals(admin);
    expect(afterDaily.PHON, 'daily claim: PHON conserved').toBe(beforeDaily.PHON);
    expect(afterDaily.USDT, 'daily claim: USDT conserved').toBe(beforeDaily.USDT);

    const beforeRoulette = await currencyTotals(admin);

    const rouletteBodies: string[] = [];
    page.on('request', (req) => {
      if (req.method() === 'POST' && req.url().includes('rpc_spin_roulette')) {
        rouletteBodies.push(req.postData() ?? '');
      }
    });

    await Promise.all([
      page.waitForResponse((resp) => resp.url().includes('rpc_spin_roulette') && resp.status() < 500, {
        timeout: 30_000,
      }),
      page.getByTestId('roulette-spin-submit').click(),
    ]);

    expect(rouletteBodies.length, 'roulette RPC must be called from browser').toBeGreaterThan(0);
    const spinBody = JSON.parse(rouletteBodies[0] ?? '{}') as Record<string, unknown>;
    expect(Object.keys(spinBody), 'client cannot pass outcome parameters').toHaveLength(0);

    const afterRoulette = await currencyTotals(admin);
    expect(afterRoulette.PHON, 'roulette spin: PHON conserved').toBe(beforeRoulette.PHON);
    expect(afterRoulette.USDT, 'roulette spin: USDT conserved').toBe(beforeRoulette.USDT);

    const { data: spinRow, error: spinReadErr } = await admin
      .from('roulette_spins')
      .select('prize_index, phon_awarded, server_seed_hash')
      .eq('user_id', auth.userId)
      .eq('spun_date', new Date().toISOString().slice(0, 10))
      .single();
    expect(spinReadErr, 'roulette spin row must exist').toBeNull();
    expect(spinRow?.prize_index).not.toBeNull();

    const expectedAward = ROULETTE_PRIZES[spinRow!.prize_index];
    expect(Number(spinRow!.phon_awarded), 'stored award matches server prize table').toBe(expectedAward);

    const { data: reveal, error: revealErr } = await client.rpc('rpc_reveal_roulette_spin', {
      p_spin_date: new Date().toISOString().slice(0, 10),
    });
    expect(revealErr, 'reveal must succeed after spin').toBeNull();
    expect(reveal?.server_seed_hash).toBe(spinRow!.server_seed_hash);
    expect(reveal?.prize_index).toBe(spinRow!.prize_index);
  });
});
