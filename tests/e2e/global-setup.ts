import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  SUPABASE_URL,
  ANON_KEY,
  AUTH_FILE,
  ADMIN_AUTH_FILE,
  adminClient,
  fundE2EWallet,
  resetE2EOracleState,
} from './_helpers';

const CONSENT_DOC_TYPES = [
  'terms_of_service',
  'privacy_policy',
  'risk_disclosure',
  'age_verification',
  'trading_risk_acknowledgement',
] as const;

const FUTURES_SYMBOLS = ['PHONUSDT-PERP', 'BTCUSDT-SIM', 'ETHUSDT-SIM'];

const FIXTURE_WAIT_MS = 15_000;
const FIXTURE_POLL_MS = 200;

async function waitForProfileAndWallet(
  admin: SupabaseClient,
  userId: string,
  label: string,
): Promise<void> {
  // Production signup creates these rows via SECURITY DEFINER triggers
  // (auth.users -> profiles -> wallets). E2E must not INSERT directly into
  // client-closed tables; poll with the service-role reader instead.
  const attempts = Math.ceil(FIXTURE_WAIT_MS / FIXTURE_POLL_MS);
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const { data: profile, error: profileErr } = await admin
      .from('profiles')
      .select('id')
      .eq('id', userId)
      .maybeSingle();
    if (profileErr) throw new Error(`${label} profile lookup failed: ${profileErr.message}`);

    const { data: wallet, error: walletErr } = await admin
      .from('wallets')
      .select('user_id')
      .eq('user_id', userId)
      .maybeSingle();
    if (walletErr) throw new Error(`${label} wallet lookup failed: ${walletErr.message}`);

    if (profile && wallet) return;
    if (attempt < attempts) {
      await new Promise<void>((resolve) => setTimeout(resolve, FIXTURE_POLL_MS));
    }
  }

  throw new Error(
    `${label} profile/wallet not created by handle_new_user trigger within ${FIXTURE_WAIT_MS / 1000} s`,
  );
}

/**
 * Provisions a funded, consented test user on the LOCAL stack and persists a
 * real session for the spec to inject (no magic-link flow). Uses the service
 * role (bypasses RLS) — mirrors the fixture pattern in supabase/tests/*.sql.
 */
async function globalSetup(): Promise<void> {
  const admin = adminClient();
  const email = `e2e_${Date.now()}@phonara.local`;
  const password = 'E2e-Test-Password-123456';

  const { data: created, error: cErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (cErr || !created.user) throw new Error(`createUser failed: ${cErr?.message ?? 'no user'}`);
  const userId = created.user.id;

  await waitForProfileAndWallet(admin, userId, 'user');

  // Fund the auto-created wallet generously through the local ledger-write guard.
  fundE2EWallet(userId, { phon: '1000000.000000', usdt: '1000000.000000' });

  // Record onboarding consents (the gate is a no-op unless enabled, but be explicit).
  const { error: ceErr } = await admin.from('user_consents').insert(
    CONSENT_DOC_TYPES.map((doc_type) => ({
      user_id: userId,
      doc_type,
      doc_version: 'e2e',
      accepted: true,
    })),
  );
  if (ceErr) throw new Error(`consent insert failed: ${ceErr.message}`);

  // Ensure the platform is live and the relevant features are on (idempotent).
  await admin.from('app_config').update({ value: 'false' }).eq('key', 'system_halt');
  await admin.from('app_config').update({ value: 'false' }).eq('key', 'system_readonly');
  for (const feature of [
    'feature_spot_enabled',
    'feature_futures_enabled',
    'feature_staking_enabled',
    'feature_game_enabled',
    'feature_game_crash_enabled',
    'feature_game_limbo_enabled',
    'feature_game_dice_enabled',
    'feature_game_mines_enabled',
    'feature_game_hilo_enabled',
    'feature_game_plinko_enabled',
  ]) {
    await admin.from('app_config').update({ value: 'true' }).eq('key', feature);
  }

  // Remove oracle-staleness time pressure for the duration of the test and lift caps.
  await resetE2EOracleState(admin);
  await admin
    .from('futures_markets')
    .update({ is_active: true, max_user_positions: 100, max_open_interest: '1000000.000000', max_leverage: '10' })
    .in('symbol', FUTURES_SYMBOLS);
  await admin.from('spot_markets').update({ is_active: true }).eq('symbol', 'PHON_USDT');

  // Obtain a real session (access + refresh) via password sign-in.
  const pub = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signIn, error: sErr } = await pub.auth.signInWithPassword({ email, password });
  if (sErr || !signIn.session) throw new Error(`sign-in failed: ${sErr?.message ?? 'no session'}`);

  mkdirSync(dirname(AUTH_FILE), { recursive: true });
  writeFileSync(
    AUTH_FILE,
    JSON.stringify(
      {
        userId,
        email,
        accessToken: signIn.session.access_token,
        refreshToken: signIn.session.refresh_token,
      },
      null,
      2,
    ),
  );

  // ── Admin test user ──────────────────────────────────────────────────────
  // A separate user with role='admin' for admin E2E tests (positive path).
  const adminEmail = `e2e_admin_${Date.now()}@phonara.local`;
  const adminPassword = 'E2e-Admin-Password-123456';

  const { data: adminCreated, error: acErr } = await admin.auth.admin.createUser({
    email: adminEmail,
    password: adminPassword,
    email_confirm: true,
  });
  if (acErr || !adminCreated.user) {
    throw new Error(`createUser (admin) failed: ${acErr?.message ?? 'no user'}`);
  }
  const adminUserId = adminCreated.user.id;

  await waitForProfileAndWallet(admin, adminUserId, 'admin');

  // Promote to admin role.
  const { error: roleErr } = await admin
    .from('profiles')
    .update({ role: 'admin' })
    .eq('id', adminUserId);
  if (roleErr) throw new Error(`promote admin failed: ${roleErr.message}`);

  const { data: adminSignIn, error: asErr } = await pub.auth.signInWithPassword({
    email: adminEmail,
    password: adminPassword,
  });
  if (asErr || !adminSignIn.session) {
    throw new Error(`admin sign-in failed: ${asErr?.message ?? 'no session'}`);
  }

  writeFileSync(
    ADMIN_AUTH_FILE,
    JSON.stringify(
      {
        userId: adminUserId,
        email: adminEmail,
        accessToken: adminSignIn.session.access_token,
        refreshToken: adminSignIn.session.refresh_token,
      },
      null,
      2,
    ),
  );
}

export default globalSetup;
