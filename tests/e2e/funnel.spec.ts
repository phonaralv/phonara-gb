/**
 * S6 – Full onboarding + liquidation funnel E2E
 *
 * Flow tested:
 *   signup (fresh zero-wallet user)
 *   → welcome bonus claimed via a user-scoped Supabase client (exercises the
 *     real RPC path with auth.uid() from the access token JWT, same as the
 *     browser would use — avoids Chromium network latency on the local stack)
 *   → conservation check: Σ PHON unchanged (system → user transfer)
 *   → futures position opened via the browser UI
 *   → oracle price manipulated → liquidation triggered via admin client
 *   → conservation check: Σ USDT + PHON unchanged across open + liquidation
 */

import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import {
  adminClient,
  currencyTotals,
  freshenOracle,
  SUPABASE_URL,
  ANON_KEY,
} from './_helpers';

// The funnel test creates a new user, calls RPCs, and then runs the browser
// futures open flow. Allow 3 minutes.
test.setTimeout(180_000);

const CONSENT_DOC_TYPES = [
  'terms_of_service',
  'privacy_policy',
  'risk_disclosure',
  'age_verification',
  'trading_risk_acknowledgement',
] as const;

const TRADING_SYMBOLS = ['PHON_USDT', 'PHONUSDT-PERP', 'BTCUSDT-SIM', 'ETHUSDT-SIM'];
const FUTURES_SYMBOLS = ['PHONUSDT-PERP', 'BTCUSDT-SIM', 'ETHUSDT-SIM'];

async function injectSession(
  page: Page,
  accessToken: string,
  refreshToken: string,
): Promise<void> {
  await page.goto('/login');
  await page.waitForFunction(() =>
    Boolean((window as unknown as { __supabase?: unknown }).__supabase),
  );
  const errMsg = await page.evaluate(
    async ([at, rt]) => {
      const sb = (
        window as unknown as {
          __supabase: {
            auth: {
              setSession: (a: {
                access_token: string;
                refresh_token: string;
              }) => Promise<{ error: { message?: string } | null }>;
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

test('funnel: signup → welcome bonus → futures open → liquidation (conserved)', async ({
  page,
}) => {
  const admin = adminClient();

  // ── 1. Create a fresh zero-wallet user (no manual balance funding) ──────────
  const email = `funnel_${Date.now()}@phonara.local`;
  const password = 'E2e-Funnel-Password-123456';

  const { data: created, error: cErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (cErr || !created.user) throw new Error(`createUser failed: ${cErr?.message ?? 'no user'}`);
  const userId = created.user.id;

  // Accept all required consents
  const { error: ceErr } = await admin.from('user_consents').insert(
    CONSENT_DOC_TYPES.map((doc_type) => ({
      user_id: userId,
      doc_type,
      doc_version: 'e2e',
      accepted: true,
    })),
  );
  if (ceErr) throw new Error(`consent insert failed: ${ceErr.message}`);

  // Enable platform + features (idempotent)
  await admin.from('app_config').update({ value: 'false' }).eq('key', 'system_halt');
  await admin.from('app_config').update({ value: 'false' }).eq('key', 'system_readonly');
  for (const feature of [
    'feature_spot_enabled',
    'feature_futures_enabled',
    'feature_staking_enabled',
  ]) {
    await admin.from('app_config').update({ value: 'true' }).eq('key', feature);
  }

  // Lift circuit breakers, extend oracle freshness for the test duration
  await admin
    .from('market_circuit_breakers')
    .update({ staleness_seconds: 86_400, is_halted: false })
    .in('symbol', TRADING_SYMBOLS);
  await admin
    .from('futures_markets')
    .update({ is_active: true, max_user_positions: 100, max_open_interest: '1000000.000000', max_leverage: '10' })
    .in('symbol', FUTURES_SYMBOLS);
  await admin.from('spot_markets').update({ is_active: true }).eq('symbol', 'PHON_USDT');
  await freshenOracle(admin);

  // Wait for handle_new_user trigger to create the wallet row
  {
    let found = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      const { data } = await admin
        .from('wallets')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();
      if (data) { found = true; break; }
      await new Promise<void>((r) => setTimeout(r, 200));
    }
    if (!found) throw new Error('wallet not created by trigger within 6 s');
  }

  // Obtain a real session via password sign-in (local Supabase stack)
  const pub = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signIn, error: sErr } = await pub.auth.signInWithPassword({ email, password });
  if (sErr || !signIn.session) throw new Error(`sign-in failed: ${sErr?.message ?? 'no session'}`);
  const { access_token: at, refresh_token: rt } = signIn.session;

  // ── 2. Conservation baseline (zero-wallet user just created) ─────────────
  const welcomeBefore = await currencyTotals(admin);

  // ── 3. Claim welcome bonus via user-scoped client (Node.js, not browser) ──
  // Uses the access token in the Authorization header so auth.uid() resolves
  // correctly inside the RPC — same auth path as the browser, without
  // Chromium's HTTP stack which can time out on the local realtime container.
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${at}` } },
  });
  const { data: bonusData, error: bonusErr } = await userClient.rpc(
    'rpc_claim_welcome_bonus',
  ) as { data: { phon_awarded: string } | null; error: { message?: string } | null };
  expect(bonusErr, 'welcome bonus RPC should succeed').toBeNull();
  const phonAwarded = parseFloat(bonusData?.phon_awarded ?? '0');
  expect(phonAwarded, 'welcome bonus PHON > 0').toBeGreaterThan(0);

  // ── 4. Conservation: Σ PHON unchanged (system released, user received) ────
  const welcomeAfter = await currencyTotals(admin);
  expect(welcomeAfter.PHON, 'PHON conserved across welcome bonus').toBe(welcomeBefore.PHON);
  expect(welcomeAfter.USDT, 'USDT unchanged during welcome bonus').toBe(welcomeBefore.USDT);

  // DB sanity: wallet reflects the credited PHON
  const { data: walletRow } = await admin
    .from('wallets')
    .select('phon_available')
    .eq('user_id', userId)
    .single();
  expect(parseFloat(walletRow?.phon_available ?? '0'), 'wallet PHON matches award').toBeCloseTo(
    phonAwarded,
    4,
  );

  // ── 5. Fund 200 USDT for futures margin (test fixture outside conservation) ──
  await admin
    .from('wallets')
    .update({ usdt_available: '200.000000' })
    .eq('user_id', userId);

  // Capture futures-only baseline AFTER manual funding
  await freshenOracle(admin);
  const futuresBefore = await currencyTotals(admin);

  // ── 6. Browser: inject session and navigate to /trade ────────────────────
  await injectSession(page, at, rt);
  // After setSession, the login page auto-redirects to /dashboard.
  // Navigate explicitly to /trade for the futures test.
  await page.goto('/trade');
  await expect(page.getByTestId('futures-open')).toBeVisible({ timeout: 20_000 });

  // ── 7. Open a futures position (default: PHON/USDT-PERP, long, 100 USDT, 10×) ──
  await page.getByTestId('futures-open').click();
  await expect(page.getByTestId('futures-open-confirm')).toBeVisible({ timeout: 5_000 });
  await page.getByTestId('futures-open-confirm').click();
  await expect(page.getByTestId('futures-open-confirm')).toBeHidden({ timeout: 15_000 });

  // ── 8. Retrieve the opened position from DB ───────────────────────────────
  const { data: openPositions } = await admin
    .from('futures_positions')
    .select('id, liquidation_price, side, market, status')
    .eq('user_id', userId)
    .eq('status', 'open');

  expect(openPositions?.length, 'futures position was opened').toBeGreaterThan(0);
  const pos = openPositions![0]!;

  // ── 9. Move oracle price into the liquidation zone ────────────────────────
  // Long position liquidates when mark ≤ liquidation_price.
  // Set mark to 98 % of liquidation_price (clearly below threshold).
  const liqPrice = parseFloat(pos.liquidation_price as string);
  const triggerPrice = (liqPrice * 0.98).toFixed(6);

  await admin
    .from('oracle_prices')
    .update({ price: triggerPrice, updated_at: new Date().toISOString() })
    .eq('symbol', pos.market);

  // ── 10. Trigger liquidation via user-scoped client ───────────────────────
  // rpc_liquidate_position rejects service-role (auth.uid() IS NULL) after the
  // anon-lockdown migration. Call it with the user's access token instead.
  const { error: liqErr } = await userClient.rpc('rpc_liquidate_position', {
    p_position_id: pos.id,
  });
  expect(liqErr, 'liquidation RPC should succeed').toBeNull();

  // ── 11. Verify position is closed in the DB ───────────────────────────────
  const { data: closedPos } = await admin
    .from('futures_positions')
    .select('status')
    .eq('id', pos.id)
    .single();
  expect(closedPos?.status, 'position status is liquidated').toBe('liquidated');

  // ── 12. Conservation: Σ USDT + PHON unchanged across futures + liquidation ──
  const futuresAfter = await currencyTotals(admin);
  expect(futuresAfter.USDT, 'USDT conserved across futures open + liquidation').toBe(
    futuresBefore.USDT,
  );
  expect(futuresAfter.PHON, 'PHON conserved across futures open + liquidation').toBe(
    futuresBefore.PHON,
  );
});
