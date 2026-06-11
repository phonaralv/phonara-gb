/**
 * Admin E2E — S8b/S8c/S8d: authentication + RBAC + audit + operations
 *
 * S8b positive:  admin user logs in → can access /overview, /audit, /operations
 * S8b negative:  regular user logs in to admin app → blocked (admin-forbidden)
 * S8c:           audit log renders for admin; entries appear after operations
 * S8d:           admin can toggle a feature flag → confirmation dialog → action
 *                executes → audit log entry recorded
 *
 * All tests run against the LOCAL Supabase stack via the admin app (port 3001).
 */
import { test, expect, type Page } from '@playwright/test';
import {
  readAuth,
  readAdminAuth,
  adminClient,
  SUPABASE_URL,
  ANON_KEY,
  currencyTotals,
} from './_helpers';
import { createClient } from '@supabase/supabase-js';

const ADMIN_BASE = 'http://localhost:3001';

async function loginAdmin(page: Page, email: string, password: string): Promise<void> {
  await page.goto(`${ADMIN_BASE}/login`);
  await expect(page.getByTestId('admin-login-form')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('admin-email').fill(email);
  await page.getByTestId('admin-password').fill(password);
  await page.getByTestId('admin-login-submit').click();
}

test.describe('Admin RBAC', () => {
  test('positive: admin user can access all admin routes', async ({ page }) => {
    const auth = readAdminAuth();

    await loginAdmin(page, auth.email, 'E2e-Admin-Password-123456');

    // After login, should redirect to /overview.
    await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId('admin-sidebar')).toBeVisible();

    // Navigate to audit log.
    await page.getByTestId('nav-audit').click();
    await expect(page.getByTestId('audit-page')).toBeVisible({ timeout: 10_000 });

    // Navigate to ops alerts.
    await page.getByTestId('nav-alerts').click();
    await expect(page.getByTestId('admin-alerts-page')).toBeVisible({ timeout: 10_000 });

    // Navigate to exception queues.
    await page.getByTestId('nav-queues').click();
    await expect(page.getByTestId('admin-queues-page')).toBeVisible({ timeout: 10_000 });

    // Navigate to operations.
    await page.getByTestId('nav-operations').click();
    await expect(page.getByTestId('operations-page')).toBeVisible({ timeout: 10_000 });

    // No forbidden message should appear.
    await expect(page.getByTestId('admin-forbidden')).not.toBeVisible();
  });

  test('negative: regular user is blocked from admin app', async ({ page }) => {
    const auth = readAuth();

    // Regular user (role='user') attempts to log in to admin app.
    await loginAdmin(page, auth.email, 'E2e-Test-Password-123456');

    // Should see the forbidden screen, NOT the admin dashboard.
    await expect(page.getByTestId('admin-forbidden')).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId('overview-page')).not.toBeVisible();
    await expect(page.getByTestId('audit-page')).not.toBeVisible();
  });
});

test.describe('Admin Operations + Audit (S8c/S8d)', () => {
  test.setTimeout(120_000);

  test('admin can toggle a feature flag and audit log records the action', async ({ page }) => {
    const adminAuth = readAdminAuth();
    const dbAdmin = adminClient();

    // Ensure game feature is enabled before the test.
    await dbAdmin.from('app_config').update({ value: 'true' }).eq('key', 'feature_game_enabled');

    // Log in as admin.
    await loginAdmin(page, adminAuth.email, 'E2e-Admin-Password-123456');
    await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });

    // Navigate to operations.
    await page.getByTestId('nav-operations').click();
    await expect(page.getByTestId('operations-page')).toBeVisible({ timeout: 10_000 });

    // Count audit log entries before the action.
    const { count: auditBefore } = await dbAdmin
      .from('audit_logs')
      .select('*', { count: 'exact', head: true })
      .eq('action', 'feature_toggle');

    // Disable the game feature (currently enabled → click Disable).
    await expect(page.getByTestId('ops-feature-game-toggle')).toBeVisible({ timeout: 10_000 });
    await page.getByTestId('ops-feature-game-toggle').click();

    // Confirmation dialog with reason input should appear.
    await expect(page.getByTestId('ops-confirm-reason')).toBeVisible({ timeout: 5_000 });
    await page.getByTestId('ops-confirm-reason').fill('E2E test: disable game for maintenance');

    // Confirm the action.
    await page.getByTestId('ops-confirm-confirm').click();
    await expect(page.getByTestId('ops-confirm-confirm')).not.toBeVisible({ timeout: 10_000 });

    // Verify DB: feature_game_enabled should now be false.
    const { data: configRow } = await dbAdmin
      .from('app_config')
      .select('value')
      .eq('key', 'feature_game_enabled')
      .single();
    expect(configRow?.value, 'feature_game_enabled should be false after disable').toBe('false');

    // Verify audit log: one new entry with action='feature_toggle'.
    const { count: auditAfter } = await dbAdmin
      .from('audit_logs')
      .select('*', { count: 'exact', head: true })
      .eq('action', 'feature_toggle');
    expect(auditAfter ?? 0, 'audit log should have 1 new entry').toBe((auditBefore ?? 0) + 1);

    await page.getByTestId('ops-feature-game-toggle').click();
    await expect(page.getByTestId('ops-confirm-reason')).toBeVisible({ timeout: 5_000 });
    await expect(page.getByTestId('ops-confirm-reason')).toHaveValue('');
    await expect(page.getByTestId('ops-confirm-confirm')).toBeDisabled();
    await page.getByTestId('ops-confirm-reason').fill('E2E restore game after reason reset check');
    await page.getByTestId('ops-confirm-confirm').click();
    await expect(page.getByTestId('ops-confirm-confirm')).not.toBeVisible({ timeout: 10_000 });

    // Navigate to audit page and verify the entry renders.
    await page.getByTestId('nav-audit').click();
    await expect(page.getByTestId('audit-page')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('audit-table')).toBeVisible({ timeout: 10_000 });
  });

  test('negative: server-side guard blocks non-admin calling operations RPC directly', async () => {
    // Regular user tries to call rpc_set_system_mode via their JWT.
    const auth = readAuth();
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
    });
    const { error } = await userClient.rpc('rpc_set_system_mode', {
      p_halt: false,
      p_readonly: false,
      p_reason: 'E2E negative test',
    });
    expect(error, 'non-admin must be rejected by server-side guard').not.toBeNull();
    expect(error?.message ?? '', 'error should mention forbidden').toMatch(/forbidden|Forbidden|403/i);
  });
});

test.describe('Admin Exception Queues (W9-R1)', () => {
  test.setTimeout(120_000);

  test('admin can reject withdrawal queue item, audit reason, and refund Σ=0', async ({ page }) => {
    const auth = readAuth();
    const adminAuth = readAdminAuth();
    const dbAdmin = adminClient();
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
    });

    await ensureLedgerBackedFunding(auth.userId);
    await dbAdmin.from('profiles').update({ kyc_tier: 'id_verified' }).eq('id', auth.userId);
    await dbAdmin.from('sanctions_screenings').insert({
      user_id: auth.userId,
      status: 'clear',
      screened_at: new Date().toISOString(),
    });
    await dbAdmin.from('app_config').update({ value: 'false' }).in('key', ['system_halt', 'system_readonly']);
    await dbAdmin.from('app_config').update({ value: 'true' }).eq('key', 'feature_withdrawal_enabled');
    await dbAdmin.from('treasury_reserves').update({ real_balance: '999999999.000000' }).eq('currency', 'PHON');
    const { error: reconErr } = await dbAdmin.rpc('rpc_run_reconciliation');
    expect(reconErr, 'reconciliation before withdrawal should pass').toBeNull();

    const before = await currencyTotals(dbAdmin);
    const { data: requestData, error: requestErr } = await userClient.rpc('rpc_request_withdrawal', {
      p_currency: 'PHON',
      p_amount: '25.000000',
      p_destination: { kind: 'e2e' },
      p_idempotency_key: `e2e-wd-${Date.now()}`,
      p_client_request_id: crypto.randomUUID(),
    });
    expect(requestErr, 'withdrawal request should create a pending locked item').toBeNull();
    const withdrawalId = (requestData as { withdrawal_id: string }).withdrawal_id;

    await loginAdmin(page, adminAuth.email, 'E2e-Admin-Password-123456');
    await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });
    await page.getByTestId('nav-queues').click();
    await expect(page.getByTestId('admin-withdrawals-table')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId(`queue-withdraw-reject-${withdrawalId}`).click();
    await expect(page.getByTestId('admin-queue-action-reason')).toBeVisible({ timeout: 5_000 });
    await page.getByTestId('admin-queue-action-reason').fill('E2E reject withdrawal and verify refund');
    await page.getByTestId('admin-queue-action-confirm').click();
    await expect(page.getByTestId('admin-queue-action-confirm')).not.toBeVisible({ timeout: 10_000 });

    const { data: wr } = await dbAdmin
      .from('withdrawal_requests')
      .select('status')
      .eq('id', withdrawalId)
      .single();
    expect(wr?.status).toBe('rejected');

    const after = await currencyTotals(dbAdmin);
    expect(after.PHON, 'reject path must conserve PHON across wallets + system').toBe(before.PHON);

    const { count: auditCount } = await dbAdmin
      .from('audit_logs')
      .select('*', { count: 'exact', head: true })
      .eq('action', 'withdrawal_rejected')
      .eq('entity_id', withdrawalId);
    expect(auditCount ?? 0, 'reject action should be audited').toBeGreaterThan(0);

    await dbAdmin.from('app_config').update({ value: 'false' }).eq('key', 'feature_withdrawal_enabled');
  });

  test('admin can sync, acknowledge ops alert, and audit row is recorded', async ({ page }) => {
    const adminAuth = readAdminAuth();
    const dbAdmin = adminClient();

    await dbAdmin.from('reconciliation_log').delete().neq('id', '00000000-0000-0000-0000-000000000000');

    await loginAdmin(page, adminAuth.email, 'E2e-Admin-Password-123456');
    await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });

    await page.getByTestId('nav-alerts').click();
    await expect(page.getByTestId('admin-alerts-page')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('ops-alerts-sync').click();

    const alertRow = page.locator('[data-testid^="alert-ack-"]').first();
    await expect(alertRow).toBeVisible({ timeout: 15_000 });
    const testId = await alertRow.getAttribute('data-testid');
    const alertId = testId?.replace('alert-ack-', '');
    expect(alertId, 'alert id must be present in test id').toBeTruthy();

    await alertRow.click();
    await expect(page.getByTestId('admin-alert-action-reason')).toBeVisible({ timeout: 5_000 });
    await page.getByTestId('admin-alert-action-reason').fill('E2E acknowledge operational alert');
    await page.getByTestId('admin-alert-action-confirm').click();
    await expect(page.getByTestId('admin-alert-action-confirm')).not.toBeVisible({ timeout: 10_000 });

    const { data: alertRowDb } = await dbAdmin
      .from('ops_alerts')
      .select('status')
      .eq('id', alertId!)
      .single();
    expect(alertRowDb?.status).toBe('acknowledged');

    const { count: auditCount } = await dbAdmin
      .from('audit_logs')
      .select('*', { count: 'exact', head: true })
      .eq('action', 'ops_alert_acknowledged')
      .eq('entity_id', alertId!);
    expect(auditCount ?? 0, 'ack action should be audited').toBeGreaterThan(0);
  });

  test('negative: non-admin cannot call ops alert RPC directly', async () => {
    const auth = readAuth();
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
    });
    const { error } = await userClient.rpc('rpc_ack_ops_alert', {
      p_alert_id: crypto.randomUUID(),
      p_reason: 'E2E negative test',
    });
    expect(error, 'non-admin must be rejected by server-side guard').not.toBeNull();
    expect(error?.message ?? '', 'error should mention forbidden').toMatch(/forbidden|Forbidden|403/i);
  });

  test('negative: non-admin cannot call queue resolution RPC directly', async () => {
    const auth = readAuth();
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
    });
    const { error } = await userClient.rpc('rpc_clear_risk_flag', {
      p_flag_id: crypto.randomUUID(),
      p_reason: 'E2E negative test',
    });
    expect(error, 'non-admin must be rejected by server-side guard').not.toBeNull();
    expect(error?.message ?? '', 'error should mention forbidden').toMatch(/forbidden|Forbidden|403/i);
  });
});

async function ensureLedgerBackedFunding(userId: string): Promise<void> {
  const dbAdmin = adminClient();
  const { data: wallet, error: walletErr } = await dbAdmin
    .from('wallets')
    .select('id, phon_available, phon_locked, usdt_available, usdt_locked')
    .eq('user_id', userId)
    .single();
  if (walletErr || !wallet) throw new Error(`wallet lookup failed: ${walletErr?.message ?? 'missing'}`);

  const rows = [
    {
      currency: 'PHON',
      amount: wallet.phon_available,
      locked: wallet.phon_locked,
      key: `e2e-initial-funding-phon-${userId}`,
    },
    {
      currency: 'USDT',
      amount: wallet.usdt_available,
      locked: wallet.usdt_locked,
      key: `e2e-initial-funding-usdt-${userId}`,
    },
  ] as const;

  for (const row of rows) {
    const { data: existing } = await dbAdmin
      .from('wallet_ledger')
      .select('id')
      .eq('idempotency_key', row.key)
      .maybeSingle();
    if (existing) continue;

    const { error } = await dbAdmin.from('wallet_ledger').insert({
      wallet_id: wallet.id,
      user_id: userId,
      idempotency_key: row.key,
      direction: 'credit',
      currency: row.currency,
      amount: row.amount,
      available_before: '0.000000',
      locked_before: '0.000000',
      available_after: row.amount,
      locked_after: row.locked,
      reason_code: 'e2e_initial_funding',
    });
    if (error) throw new Error(`funding ledger insert failed: ${error.message}`);
  }
}
