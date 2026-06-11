import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  SUPABASE_URL,
  ANON_KEY,
  AUTH_FILE,
  ADMIN_AUTH_FILE,
  adminClient,
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

interface DbError {
  code?: string;
  message: string;
}

function isDuplicateKey(error: DbError): boolean {
  return error.code === '23505' || error.message.toLowerCase().includes('duplicate key');
}

async function insertIfMissing(
  admin: SupabaseClient,
  table: 'profiles' | 'wallets',
  row: Record<string, string>,
  label: string,
): Promise<void> {
  const { error } = await admin.from(table).insert(row);
  if (error && !isDuplicateKey(error)) {
    throw new Error(`${label} fixture insert failed: ${error.message}`);
  }
}

async function ensureProfileAndWallet(admin: SupabaseClient, userId: string, label: string): Promise<void> {
  // The production trigger chain should create these rows. CI can occasionally
  // observe missing fixture rows, so the service-role setup makes the invariant
  // explicit and idempotent without changing product auth behavior.
  await insertIfMissing(admin, 'profiles', { id: userId }, `${label} profile`);
  await insertIfMissing(admin, 'wallets', { user_id: userId }, `${label} wallet`);
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

  await ensureProfileAndWallet(admin, userId, 'user');

  // Fund the auto-created wallet generously.
  const { data: funded, error: wErr } = await admin
    .from('wallets')
    .update({ usdt_available: '1000000.000000', phon_available: '1000000.000000' })
    .eq('user_id', userId)
    .select('user_id');
  if (wErr) throw new Error(`fund wallet failed: ${wErr.message}`);
  if (!funded?.length) throw new Error('fund wallet failed: 0 rows updated (trigger race)');

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

  await ensureProfileAndWallet(admin, adminUserId, 'admin');

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
