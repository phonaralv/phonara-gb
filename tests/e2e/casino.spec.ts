import { test, expect, type Page } from '@playwright/test';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { verifyRound, type GameCode } from '../../packages/game-engine/src';
import {
  adminClient,
  readAuth,
  ANON_KEY,
  SUPABASE_URL,
  currencyTotals,
  type E2EAuth,
} from './_helpers';

interface RoundCommitment {
  round_id: string;
  server_seed_hash: string;
}

interface BetResponse {
  bet_id: string;
  status: string;
  server_seed_hash: string;
  result: Record<string, unknown>;
  already_placed: boolean;
}

interface RevealResponse {
  server_seed: string;
  server_seed_hash: string;
  result: Record<string, unknown>;
}

const GAME_CASES: Array<{ game: GameCode; selection: Record<string, unknown>; stake: string }> = [
  { game: 'crash', selection: { autoCashout: '1.10' }, stake: '10.000000' },
  { game: 'limbo', selection: { target: '1.10' }, stake: '10.000000' },
  { game: 'dice', selection: { target: '50.00', direction: 'over' }, stake: '10.000000' },
  { game: 'mines', selection: { mineCount: 3, revealedCells: [0, 1, 2] }, stake: '10.000000' },
  { game: 'hilo', selection: { startCard: null, guesses: ['higher'] }, stake: '10.000000' },
  { game: 'plinko', selection: { rows: 12, risk: 'medium' }, stake: '10.000000' },
];

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

function authedClient(auth: E2EAuth): SupabaseClient {
  return createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${auth.accessToken}` } },
  });
}

async function rpcClient<T>(
  client: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}

async function createSecondUser(admin: SupabaseClient): Promise<E2EAuth> {
  const email = `casino_e2e_${Date.now()}@phonara.local`;
  const password = 'Casino-E2e-Password-123456';
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (createError || !created.user) throw new Error(createError?.message ?? 'create second user failed');
  const userId = created.user.id;

  for (let attempt = 0; attempt < 30; attempt++) {
    const { data } = await admin.from('wallets').select('user_id').eq('user_id', userId).maybeSingle();
    if (data) break;
    await new Promise<void>((resolve) => setTimeout(resolve, 200));
  }

  await admin.from('wallets').update({ phon_available: '1000000.000000' }).eq('user_id', userId);
  await admin.from('user_consents').insert(
    ['terms_of_service', 'privacy_policy', 'risk_disclosure', 'age_verification'].map((doc_type) => ({
      user_id: userId,
      doc_type,
      doc_version: 'e2e',
      accepted: true,
    })),
  );

  const pub = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signIn, error: signInError } = await pub.auth.signInWithPassword({ email, password });
  if (signInError || !signIn.session) throw new Error(signInError?.message ?? 'second user sign-in failed');
  return {
    userId,
    email,
    accessToken: signIn.session.access_token,
    refreshToken: signIn.session.refresh_token,
  };
}

test.describe('casino provably fair E2E', () => {
  for (const gameCase of GAME_CASES) {
    test(`${gameCase.game}: commit, settle, reveal, verify, idempotency, auth`, async ({ page }) => {
      const auth = readAuth();
      const admin = adminClient();
      const client = authedClient(auth);
      await injectSession(page, auth.accessToken, auth.refreshToken);
      await page.goto(`/casino/${gameCase.game}`);
      await expect(page.getByTestId('casino-fairness-verifier')).toBeVisible({ timeout: 15_000 });

      const before = await currencyTotals(admin);
      const round = await rpcClient<RoundCommitment>(client, 'rpc_open_game_round', {
        p_game: gameCase.game,
      });
      expect(round.server_seed_hash, `${gameCase.game}: hash length`).toHaveLength(64);
      expect(Object.hasOwn(round, 'server_seed'), `${gameCase.game}: seed hidden`).toBe(false);

      const clientSeed = `casino-e2e-${gameCase.game}`;
      const idempotencyKey = `casino-e2e-${gameCase.game}-${crypto.randomUUID()}`;
      const bet = await rpcClient<BetResponse>(client, 'rpc_place_game_bet', {
        p_round_id: round.round_id,
        p_currency: 'PHON',
        p_stake: gameCase.stake,
        p_selection: gameCase.selection,
        p_client_seed: clientSeed,
        p_idempotency_key: idempotencyKey,
      });
      expect(['won', 'lost'].includes(bet.status), `${gameCase.game}: terminal status`).toBe(true);
      expect(bet.server_seed_hash, `${gameCase.game}: bet hash matches`).toBe(round.server_seed_hash);

      const duplicate = await rpcClient<BetResponse>(client, 'rpc_place_game_bet', {
        p_round_id: round.round_id,
        p_currency: 'PHON',
        p_stake: gameCase.stake,
        p_selection: gameCase.selection,
        p_client_seed: clientSeed,
        p_idempotency_key: idempotencyKey,
      });
      expect(duplicate.already_placed, `${gameCase.game}: duplicate is idempotent`).toBe(true);
      expect(duplicate.bet_id, `${gameCase.game}: duplicate bet id`).toBe(bet.bet_id);

      const reveal = await rpcClient<RevealResponse>(client, 'rpc_reveal_game_round', {
        p_round_id: round.round_id,
      });
      expect(reveal.server_seed_hash, `${gameCase.game}: reveal hash`).toBe(round.server_seed_hash);
      expect(reveal.result, `${gameCase.game}: reveal result`).toEqual(bet.result);

      const verified = await verifyRound({
        game: gameCase.game,
        serverSeed: reveal.server_seed,
        serverSeedHash: round.server_seed_hash,
        clientSeed,
        nonce: 1,
        selection: gameCase.selection,
        expectedResult: bet.result,
      });
      expect(verified.seedHashMatch, `${gameCase.game}: seed hash verified`).toBe(true);
      expect(verified.resultMatch, `${gameCase.game}: result recomputed`).toBe(true);

      const tampered = await verifyRound({
        game: gameCase.game,
        serverSeed: `${reveal.server_seed}:tampered`,
        serverSeedHash: round.server_seed_hash,
        clientSeed,
        nonce: 1,
        selection: gameCase.selection,
        expectedResult: bet.result,
      });
      expect(tampered.seedHashMatch, `${gameCase.game}: tampered seed rejected`).toBe(false);

      const after = await currencyTotals(admin);
      expect(after.PHON, `${gameCase.game}: PHON conserved`).toBe(before.PHON);
      expect(after.USDT, `${gameCase.game}: USDT conserved`).toBe(before.USDT);

      const { count: betCount } = await admin
        .from('game_bets')
        .select('*', { count: 'exact', head: true })
        .eq('id', bet.bet_id)
        .eq('user_id', auth.userId);
      expect(betCount, `${gameCase.game}: one user bet row`).toBe(1);

      const { error: settleError } = await client.rpc('rpc_settle_game_bet', {
        p_bet_id: bet.bet_id,
        p_server_seed: reveal.server_seed,
      });
      expect(settleError?.message ?? null, `${gameCase.game}: unauthorized settle rejected`).not.toBeNull();

      const second = await createSecondUser(admin);
      const secondClient = authedClient(second);
      const secondRound = await rpcClient<RoundCommitment>(secondClient, 'rpc_open_game_round', {
        p_game: gameCase.game,
      });
      const secondBet = await rpcClient<BetResponse>(secondClient, 'rpc_place_game_bet', {
        p_round_id: secondRound.round_id,
        p_currency: 'PHON',
        p_stake: gameCase.stake,
        p_selection: gameCase.selection,
        p_client_seed: `${clientSeed}-second-user`,
        p_idempotency_key: idempotencyKey,
      });
      expect(secondBet.already_placed, `${gameCase.game}: cross-user idem is scoped`).toBe(false);

      const { count: residueCount } = await admin
        .from('game_bets')
        .select('*', { count: 'exact', head: true })
        .eq('status', 'pending')
        .eq('parity_hold', false);
      expect(residueCount, `${gameCase.game}: no pending residue`).toBe(0);
    });
  }

  test('expected-result belt settles matching bets and auto-kills mismatches', async ({ page }) => {
    const auth = readAuth();
    const admin = adminClient();
    const client = authedClient(auth);
    await injectSession(page, auth.accessToken, auth.refreshToken);
    await page.goto('/casino/dice');
    await expect(page.getByTestId('casino-fairness-verifier')).toBeVisible({ timeout: 15_000 });

    await admin.from('wallets').update({ phon_available: '1000000.000000' }).eq('user_id', auth.userId);
    await admin
      .from('app_config')
      .update({ value: 'true' })
      .in('key', ['feature_game_enabled', 'feature_game_dice_enabled', 'consent_gate_enabled']);

    const selection = { target: '50.00', direction: 'over' };
    const clientSeed = 'casino-e2e-parity-belt';
    const goodSeed = 'parity_belt_good_seed_value_for_validation';
    const goodRound = await rpcClient<RoundCommitment>(admin, 'rpc_create_game_round', {
      p_game: 'dice',
      p_server_seed: goodSeed,
    });
    const goodExpected = await verifyRound({
      game: 'dice',
      serverSeed: goodSeed,
      serverSeedHash: goodRound.server_seed_hash,
      clientSeed,
      nonce: 1,
      selection,
    });
    expect(goodExpected.seedHashMatch).toBe(true);
    expect(goodExpected.recomputedResult).not.toBeNull();

    const before = await currencyTotals(admin);
    const goodBet = await rpcClient<BetResponse>(client, 'rpc_place_game_bet', {
      p_round_id: goodRound.round_id,
      p_currency: 'PHON',
      p_stake: '10.000000',
      p_selection: selection,
      p_client_seed: clientSeed,
      p_idempotency_key: `casino-e2e-parity-good-${crypto.randomUUID()}`,
      p_expected_result: goodExpected.recomputedResult,
    });
    expect(['won', 'lost'].includes(goodBet.status), 'matching expected result settles').toBe(true);
    const after = await currencyTotals(admin);
    expect(after.PHON, 'matching expected result preserves PHON').toBe(before.PHON);
    expect(after.USDT, 'matching expected result preserves USDT').toBe(before.USDT);

    const badSeed = 'parity_belt_bad_seed_value_for_validation';
    const badRound = await rpcClient<RoundCommitment>(admin, 'rpc_create_game_round', {
      p_game: 'dice',
      p_server_seed: badSeed,
    });
    const badBet = await rpcClient<BetResponse>(client, 'rpc_place_game_bet', {
      p_round_id: badRound.round_id,
      p_currency: 'PHON',
      p_stake: '10.000000',
      p_selection: selection,
      p_client_seed: clientSeed,
      p_idempotency_key: `casino-e2e-parity-bad-${crypto.randomUUID()}`,
      p_expected_result: { roll: 0, won: false },
    });
    expect(badBet.status, 'mismatched expected result enters hold').toBe('parity_hold');

    const { data: heldBet, error: heldBetError } = await admin
      .from('game_bets')
      .select('status, parity_hold')
      .eq('id', badBet.bet_id)
      .single();
    expect(heldBetError).toBeNull();
    expect(heldBet).toMatchObject({ status: 'pending', parity_hold: true });

    const { data: flag, error: flagError } = await admin
      .from('app_config')
      .select('value')
      .eq('key', 'feature_game_dice_enabled')
      .single();
    expect(flagError).toBeNull();
    expect(flag?.value, 'mismatch disables affected game').toBe('false');

    const { count: auditCount, error: auditError } = await admin
      .from('audit_logs')
      .select('*', { count: 'exact', head: true })
      .eq('action', 'parity_mismatch')
      .eq('entity_type', 'game_bets')
      .eq('entity_id', badBet.bet_id);
    expect(auditError).toBeNull();
    expect(auditCount, 'mismatch writes audit row').toBe(1);

    await admin.from('app_config').update({ value: 'true' }).eq('key', 'feature_game_dice_enabled');
  });
});
