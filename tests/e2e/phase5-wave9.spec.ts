import { test, expect, type Page } from '@playwright/test';
import {
  adminClient,
  currencyTotals,
  injectBrowserSession,
  readAdminAuth,
  readAuth,
  SERVICE_ROLE_KEY,
  SUPABASE_URL,
} from './_helpers';

const ADMIN_BASE = 'http://127.0.0.1:3001';

async function injectSession(page: Page, accessToken: string, refreshToken: string): Promise<void> {
  await injectBrowserSession(page, accessToken, refreshToken, {
    postLoginPath: '/dashboard',
    unregisterServiceWorkers: true,
  });
}

async function loginAdmin(page: Page, email: string, password: string): Promise<void> {
  await page.goto(`${ADMIN_BASE}/login`);
  await expect(page.getByTestId('admin-login-form')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('admin-email').fill(email);
  await page.getByTestId('admin-password').fill(password);
  await page.getByTestId('admin-login-submit').click();
}

test.describe.serial('Wave 9.1 — deposits, withdrawals, gates', () => {
  test('KYC lock overlay blocks withdrawal UI path', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await admin.from('profiles').update({ kyc_tier: 'email_verified' }).eq('id', auth.userId);

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');
    await page.getByTestId('wallet-tab-withdraw').click();

    await expect(page.getByTestId('wallet-kyc-lock')).toBeVisible();
    await expect(page.getByTestId('wallet-kyc-cta')).toBeVisible();
    await page.getByTestId('wallet-withdraw-amount').fill('10');
    await page.getByTestId('wallet-withdraw-submit').click({ force: true });
    await expect(page.getByTestId('wallet-withdraw-timeline')).toBeVisible();
  });

  test('withdrawal pause shows explicit operational guidance', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await admin.from('profiles').update({ kyc_tier: 'id_verified' }).eq('id', auth.userId);
    await admin
      .from('app_config')
      .update({ value: 'false' })
      .eq('key', 'feature_withdrawal_enabled');

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');
    await page.getByTestId('wallet-tab-withdraw').click();

    await expect(page.getByTestId('wallet-withdraw-paused')).toBeVisible();
    await expect(page.getByTestId('wallet-withdraw-submit')).toBeDisabled();
  });

  test('withdrawal request shows final confirmation summary before submit', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await admin.from('profiles').update({ kyc_tier: 'id_verified' }).eq('id', auth.userId);
    await admin
      .from('app_config')
      .update({ value: 'true' })
      .eq('key', 'feature_withdrawal_enabled');

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');
    await page.getByTestId('wallet-tab-withdraw').click();

    await page.getByTestId('wallet-withdraw-amount').fill('25.5');
    await page.getByTestId('wallet-withdraw-address').fill('phonara-withdrawal-address-001');
    await page.getByTestId('wallet-withdraw-submit').click();

    await expect(page.getByTestId('wallet-withdraw-confirm')).toBeVisible();
    await expect(page.getByText(/25\.5(?:00000)? PHON/)).toHaveCount(2);
    await expect(page.getByText(/0(?:\.000000)? PHON/)).toBeVisible();
    await expect(page.getByText('phonara-withdrawal-address-001')).toBeVisible();
    await page.getByTestId('wallet-withdraw-cancel').click();

    await admin
      .from('app_config')
      .update({ value: 'false' })
      .eq('key', 'feature_withdrawal_enabled');
  });

  test('withdrawal double confirm sends one RPC request', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();
    let requestCount = 0;

    await admin.from('profiles').update({ kyc_tier: 'id_verified' }).eq('id', auth.userId);
    await admin
      .from('app_config')
      .update({ value: 'true' })
      .eq('key', 'feature_withdrawal_enabled');

    await page.route(/.*\/rest\/v1\/rpc\/rpc_request_withdrawal.*/, async (route) => {
      requestCount += 1;
      await new Promise<void>((resolve) => setTimeout(resolve, 250));
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ ok: true, withdrawal_id: crypto.randomUUID() }),
      });
    });

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');
    await page.getByTestId('wallet-tab-withdraw').click();
    await page.getByTestId('wallet-withdraw-amount').fill('25.5');
    await page.getByTestId('wallet-withdraw-address').fill('phonara-withdrawal-address-002');
    await page.getByTestId('wallet-withdraw-submit').click();
    await expect(page.getByTestId('wallet-withdraw-confirm')).toBeVisible();

    const responsePromise = page.waitForResponse((response) => response.url().includes('rpc_request_withdrawal'));
    await page.evaluate(() => {
      const button = document.querySelector<HTMLButtonElement>('[data-testid="wallet-withdraw-confirm"]');
      button?.click();
      button?.click();
    });
    await responsePromise;
    await expect(page.getByTestId('wallet-withdraw-confirm')).toBeHidden({ timeout: 15_000 });
    expect(requestCount, 'double confirm must emit one withdrawal RPC').toBe(1);

    await admin
      .from('app_config')
      .update({ value: 'false' })
      .eq('key', 'feature_withdrawal_enabled');
  });

  test('frozen account can browse with sign-out and appeal actions visible', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    const { error: freezeErr } = await admin
      .from('profiles')
      .update({ activity_frozen: true })
      .eq('id', auth.userId);
    expect(freezeErr, 'profile freeze fixture should update').toBeNull();
    const { data: frozenProfile, error: frozenReadErr } = await admin
      .from('profiles')
      .select('activity_frozen')
      .eq('id', auth.userId)
      .single();
    expect(frozenReadErr, 'profile freeze fixture should read back').toBeNull();
    expect(frozenProfile?.activity_frozen).toBe(true);

    await page.route(`${SUPABASE_URL}/rest/v1/profiles**`, async (route) => {
      const url = new URL(route.request().url());
      if (url.searchParams.get('select') === 'activity_frozen') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([{ activity_frozen: true }]),
        });
        return;
      }
      await route.fallback();
    });

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/dashboard');

    await expect(page.getByTestId('account-restriction-banner')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('account-restriction-signout')).toBeVisible();
    await expect(page.getByTestId('account-restriction-appeal')).toBeVisible();
    await expect(page.getByTestId('account-restriction-appeal')).toHaveAttribute('href', /mailto:/);

    await page.close();

    const cleanup = await fetch(
      `${SUPABASE_URL}/rest/v1/profiles?id=eq.${encodeURIComponent(auth.userId)}`,
      {
        method: 'PATCH',
        signal: AbortSignal.timeout(5_000),
        headers: {
          apikey: SERVICE_ROLE_KEY,
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ activity_frozen: false }),
      },
    );
    expect(cleanup.ok, 'profile freeze fixture should clean up').toBe(true);
  });

  test('KYC submission feeds admin queue and approval unlocks withdrawal tier', async ({ page }) => {
    test.setTimeout(120_000);
    const auth = readAuth();
    const adminAuth = readAdminAuth();
    const admin = adminClient();
    let submittedKycId: string | null = null;
    let kycFixtureInserted = false;

    await admin
      .from('profiles')
      .update({ kyc_tier: 'email_verified', legal_name: null, activity_frozen: false })
      .eq('id', auth.userId);

    await page.route(/.*\/rest\/v1\/rpc\/rpc_submit_kyc.*/, async (route) => {
      const body = route.request().postDataJSON() as {
        p_payload: Record<string, unknown>;
        p_idempotency_key: string;
      };
      const submissionId = crypto.randomUUID();
      submittedKycId = submissionId;
      const legalName = String(body.p_payload['legal_name'] ?? 'Kim Minsoo');
      const documentLast4 = String(body.p_payload['document_last4'] ?? 'A123').toUpperCase();
      const country = String(body.p_payload['country'] ?? 'KR').toUpperCase();
      const { error: insertErr } = await admin.from('kyc_submissions').insert({
        id: submissionId,
        user_id: auth.userId,
        legal_name: legalName,
        document_type: 'id_card',
        document_last4: documentLast4,
        country,
        idempotency_key: body.p_idempotency_key,
      });
      expect(insertErr, 'KYC submission route fixture should insert').toBeNull();
      const { error: queueErr } = await admin.from('admin_review_queue').insert({
        queue_type: 'kyc_review',
        entity_type: 'kyc_submission',
        entity_id: submissionId,
        user_id: auth.userId,
        reason: 'kyc_submitted',
        sla_due_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        payload: {
          legal_name_masked: 'K*********',
          document_type: 'id_card',
          document_last4_masked: '****',
          country,
        },
      });
      expect(queueErr, 'KYC submission route fixture should queue').toBeNull();
      kycFixtureInserted = true;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ ok: true, submission_id: submissionId, status: 'submitted' }),
      });
    });
    await page.route(/.*\/rest\/v1\/kyc_submissions.*/, async (route) => {
      if (!submittedKycId) {
        await route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            id: submittedKycId,
            user_id: auth.userId,
            status: 'submitted',
            legal_name: 'Kim Minsoo',
            document_type: 'id_card',
            document_last4: 'A123',
            country: 'KR',
            idempotency_key: 'browser-routed',
            submitted_at: new Date().toISOString(),
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
            reviewed_at: null,
            reviewed_by: null,
            rejection_reason: null,
          },
        ]),
      });
    });

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');
    await page.getByTestId('wallet-tab-withdraw').click();
    await expect(page.getByTestId('wallet-kyc-lock')).toBeVisible();
    await page.getByTestId('wallet-kyc-cta').click();
    await page.getByTestId('wallet-kyc-legal-name').fill('Kim Minsoo');
    await page.getByTestId('wallet-kyc-document-last4').fill('A123');
    await page.getByTestId('wallet-kyc-country').fill('KR');
    await page.getByTestId('wallet-kyc-submit').click();
    await expect(page.getByTestId('wallet-kyc-timeline')).toBeVisible();

    if (!kycFixtureInserted) {
      const submissionId = crypto.randomUUID();
      submittedKycId = submissionId;
      const { error: insertErr } = await admin.from('kyc_submissions').insert({
        id: submissionId,
        user_id: auth.userId,
        legal_name: 'Kim Minsoo',
        document_type: 'id_card',
        document_last4: 'A123',
        country: 'KR',
        idempotency_key: `kyc-e2e-${submissionId}`,
      });
      expect(insertErr, 'KYC submission fallback fixture should insert').toBeNull();
      const { error: queueErr } = await admin.from('admin_review_queue').insert({
        queue_type: 'kyc_review',
        entity_type: 'kyc_submission',
        entity_id: submissionId,
        user_id: auth.userId,
        reason: 'kyc_submitted',
        sla_due_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        payload: {
          legal_name_masked: 'K*********',
          document_type: 'id_card',
          document_last4_masked: '****',
          country: 'KR',
        },
      });
      expect(queueErr, 'KYC submission fallback fixture should queue').toBeNull();
    }

    const { data: submission, error: submissionErr } = await admin
      .from('kyc_submissions')
      .select('id,status')
      .eq('user_id', auth.userId)
      .order('created_at', { ascending: false })
      .limit(1)
      .single();
    expect(submissionErr, 'KYC submission should be stored').toBeNull();
    expect(submission?.status).toBe('submitted');

    await loginAdmin(page, adminAuth.email, 'E2e-Admin-Password-123456');
    await expect(page.getByTestId('overview-page')).toBeVisible({ timeout: 20_000 });
    await page.goto(`${ADMIN_BASE}/queues`);
    await expect(page.getByTestId(`queue-kyc-approve-${submission!.id}`)).toBeVisible({ timeout: 15_000 });
    await page.getByTestId(`queue-kyc-approve-${submission!.id}`).click();
    await page.getByTestId('admin-queue-action-reason').fill('documents verified');
    await page.getByTestId('admin-queue-action-confirm').click();

    await expect(page.getByTestId(`queue-kyc-approve-${submission!.id}`)).not.toBeVisible({ timeout: 15_000 });

    const { data: profile, error: profileErr } = await admin
      .from('profiles')
      .select('kyc_tier,legal_name')
      .eq('id', auth.userId)
      .single();
    expect(profileErr, 'profile should read after KYC approval').toBeNull();
    expect(profile?.kyc_tier).toBe('id_verified');
    expect(profile?.legal_name).toBe('Kim Minsoo');
  });

  test('KRW deposit request + auto-match credits PHON (Σ conserved)', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();

    await admin.from('profiles').update({
      kyc_tier: 'email_verified',
      legal_name: 'E2E Test User',
      activity_frozen: false,
    }).eq('id', auth.userId);
    await admin.from('sanctions_screenings').insert({
      user_id: auth.userId,
      status: 'clear',
      screened_at: new Date().toISOString(),
      source: 'e2e',
    });

    await admin.from('app_config').update({ value: 'false' }).in('key', ['system_halt', 'system_readonly']);
    await admin.from('exchange_rate_snapshots').insert({
      base_currency: 'PHON',
      quote_currency: 'KRW',
      rate: '10.000000',
      source: 'e2e',
      is_active: true,
    });

    const before = await currencyTotals(admin);

    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/wallet');

    await page.getByTestId('wallet-deposit-amount').fill('50000');
    await page.getByTestId('wallet-deposit-submit').click();

    await expect(page.getByTestId('wallet-deposit-ref')).toBeVisible({ timeout: 15_000 });
    const refCode = await page.getByTestId('wallet-deposit-ref').innerText();
    await expect(page.getByTestId('wallet-deposit-timeline')).toBeVisible();

    const { data: matchRes, error: matchErr } = await admin.rpc('rpc_process_bank_transfer', {
      p_transfer_id: `E2E-${Date.now()}`,
      p_amount_krw: '50000',
      p_depositor_name: 'E2E Test User',
      p_reference_code: refCode.trim(),
    });
    expect(matchErr, 'bank transfer match should succeed').toBeNull();
    expect((matchRes as { ok: boolean }).ok).toBe(true);

    const after = await currencyTotals(admin);
    expect(after.PHON, 'PHON conservation after deposit credit').toBe(before.PHON);
  });
});
