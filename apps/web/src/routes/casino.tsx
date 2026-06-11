import { createRoute, Link, useNavigate } from '@tanstack/react-router';
import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useWallet, walletKeys } from '../hooks/use-wallet';
import { callRpc } from '../lib/rpc';
import { translateError } from '../lib/translate-error';
import { isPositiveDecimalInput, normalizeDecimalInput } from '../lib/money-input';
import { supabase } from '../lib/supabase';
import { useT } from '../lib/i18n';
import {
  Button,
  BetPanel,
  Badge,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  FairnessVerifier,
  GameStakeInput,
  MultiplierDisplay,
  ProvablyFairBadge,
  SegmentedControl,
  Skeleton,
  StatusTimeline,
  Toast,
  formatMoney,
} from '@phonara/ui';
import {
  verifyRound,
  type GameCode,
  type VerifyResult,
} from '@phonara/game-engine';
import type { MessageKey } from '@phonara/i18n';
import type { Json } from '@phonara/shared-types';

type Currency = 'PHON' | 'USDT';

interface GameConfig {
  code: GameCode;
  labelKey: MessageKey;
  descriptionKey: MessageKey;
  defaultStake: string;
  defaultSelection: Record<string, unknown>;
  fields: GameField[];
}

type GameField =
  | { kind: 'text'; key: string; labelKey: MessageKey; inputMode?: 'decimal' | 'numeric' }
  | { kind: 'number'; key: string; labelKey: MessageKey; min: number; max: number; step?: number }
  | { kind: 'select'; key: string; labelKey: MessageKey; options: Array<{ value: string; labelKey: MessageKey }> }
  | { kind: 'cells'; key: string; labelKey: MessageKey; max: number };

interface RoundCommitment {
  round_id: string;
  server_seed_hash: string;
}

interface BetResponse {
  bet_id: string;
  round_id: string;
  game: GameCode;
  status: 'won' | 'lost' | 'pending' | 'cancelled' | 'voided' | 'parity_hold';
  server_seed_hash: string;
  result: Record<string, unknown>;
  payout: string;
  already_placed: boolean;
}

interface RevealResponse {
  round_id: string;
  server_seed: string;
  server_seed_hash: string;
  result: Record<string, unknown>;
}

interface VerificationEvidence {
  server_seed_hash: string;
  server_seed: string;
  result: Record<string, unknown>;
  verification: VerifyResult;
}

interface RecentBet {
  id: string;
  game: GameCode;
  status: string;
  stake: string;
  payout: string | null;
  currency: Currency;
  created_at: string;
}

const GAME_CONFIGS: GameConfig[] = [
  {
    code: 'crash',
    labelKey: 'casino.game.crash',
    descriptionKey: 'casino.game.crash.desc',
    defaultStake: '10',
    defaultSelection: { autoCashout: '2.00' },
    fields: [{ kind: 'text', key: 'autoCashout', labelKey: 'casino.field.autoCashout', inputMode: 'decimal' }],
  },
  {
    code: 'limbo',
    labelKey: 'casino.game.limbo',
    descriptionKey: 'casino.game.limbo.desc',
    defaultStake: '10',
    defaultSelection: { target: '2.00' },
    fields: [{ kind: 'text', key: 'target', labelKey: 'casino.field.targetMultiplier', inputMode: 'decimal' }],
  },
  {
    code: 'dice',
    labelKey: 'casino.game.dice',
    descriptionKey: 'casino.game.dice.desc',
    defaultStake: '10',
    defaultSelection: { target: '50.00', direction: 'over' },
    fields: [
      { kind: 'text', key: 'target', labelKey: 'casino.field.target', inputMode: 'decimal' },
      {
        kind: 'select',
        key: 'direction',
        labelKey: 'casino.field.direction',
        options: [
          { value: 'over', labelKey: 'casino.option.over' },
          { value: 'under', labelKey: 'casino.option.under' },
        ],
      },
    ],
  },
  {
    code: 'mines',
    labelKey: 'casino.game.mines',
    descriptionKey: 'casino.game.mines.desc',
    defaultStake: '10',
    defaultSelection: { mineCount: 3, revealedCells: [0, 1, 2] },
    fields: [
      { kind: 'number', key: 'mineCount', labelKey: 'casino.field.mineCount', min: 1, max: 24 },
      { kind: 'cells', key: 'revealedCells', labelKey: 'casino.field.revealedCells', max: 24 },
    ],
  },
  {
    code: 'hilo',
    labelKey: 'casino.game.hilo',
    descriptionKey: 'casino.game.hilo.desc',
    defaultStake: '10',
    defaultSelection: { startCard: null, guesses: ['higher'] },
    fields: [
      {
        kind: 'select',
        key: 'guesses.0',
        labelKey: 'casino.field.firstGuess',
        options: [
          { value: 'higher', labelKey: 'casino.option.higher' },
          { value: 'lower', labelKey: 'casino.option.lower' },
          { value: 'skip', labelKey: 'casino.option.skip' },
        ],
      },
    ],
  },
  {
    code: 'plinko',
    labelKey: 'casino.game.plinko',
    descriptionKey: 'casino.game.plinko.desc',
    defaultStake: '10',
    defaultSelection: { rows: 12, risk: 'medium' },
    fields: [
      {
        kind: 'select',
        key: 'rows',
        labelKey: 'casino.field.rows',
        options: [
          { value: '8', labelKey: 'casino.option.rows8' },
          { value: '12', labelKey: 'casino.option.rows12' },
          { value: '16', labelKey: 'casino.option.rows16' },
        ],
      },
      {
        kind: 'select',
        key: 'risk',
        labelKey: 'casino.field.risk',
        options: [
          { value: 'low', labelKey: 'casino.option.low' },
          { value: 'medium', labelKey: 'casino.option.medium' },
          { value: 'high', labelKey: 'casino.option.high' },
        ],
      },
    ],
  },
];

const GAME_BY_CODE = Object.fromEntries(GAME_CONFIGS.map((game) => [game.code, game])) as Record<GameCode, GameConfig>;

export const casinoIndexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino',
  component: () => <CasinoPage initialGame="dice" />,
});

export const casinoCrashRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/crash',
  component: () => <CasinoPage initialGame="crash" />,
});

export const casinoLimboRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/limbo',
  component: () => <CasinoPage initialGame="limbo" />,
});

export const casinoDiceRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/dice',
  component: () => <CasinoPage initialGame="dice" />,
});

export const casinoMinesRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/mines',
  component: () => <CasinoPage initialGame="mines" />,
});

export const casinoHiloRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/hilo',
  component: () => <CasinoPage initialGame="hilo" />,
});

export const casinoPlinkoRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/plinko',
  component: () => <CasinoPage initialGame="plinko" />,
});

export const casinoFairnessRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/casino/fairness',
  component: FairnessDocsPage,
});

function CasinoPage({ initialGame }: { initialGame: GameCode }) {
  const t = useT();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { session, loading: authLoading } = useAuth();
  const { wallet, loading: walletLoading } = useWallet();
  const [gameCode, setGameCode] = useState<GameCode>(initialGame);
  const [currency, setCurrency] = useState<Currency>('PHON');
  const [stake, setStake] = useState(GAME_BY_CODE[initialGame].defaultStake);
  const [selection, setSelection] = useState<Record<string, unknown>>(GAME_BY_CODE[initialGame].defaultSelection);
  const [clientSeed, setClientSeed] = useState(() => randomHex());
  const [clientSeedIsAuto, setClientSeedIsAuto] = useState(true);
  const [commitment, setCommitment] = useState<RoundCommitment | null>(null);
  const [bet, setBet] = useState<BetResponse | null>(null);
  const [verificationEvidence, setVerificationEvidence] = useState<VerificationEvidence | null>(null);
  const [recentBets, setRecentBets] = useState<RecentBet[]>([]);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [errorKey, setErrorKey] = useState<MessageKey | null>(null);
  const [toastKey, setToastKey] = useState<MessageKey | null>(null);
  const betIdempotencyKeyRef = useRef<string | null>(null);
  const betInFlightRef = useRef(false);

  const config = GAME_BY_CODE[gameCode];
  const available = currency === 'PHON' ? wallet?.phon_available : wallet?.usdt_available;
  const canSubmit = Boolean(commitment && isPositiveDecimalInput(stake) && !busy);

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  useEffect(() => {
    setGameCode(initialGame);
    setStake(GAME_BY_CODE[initialGame].defaultStake);
    setSelection(GAME_BY_CODE[initialGame].defaultSelection);
    setCommitment(null);
    setBet(null);
    setVerificationEvidence(null);
  }, [initialGame]);

  useEffect(() => {
    void loadRecentBets().then(setRecentBets);
  }, []);

  const timeline = useMemo(
    () => [
      {
        id: 'commit',
        label: t('casino.timeline.commit'),
        description: commitment?.server_seed_hash ?? t('casino.timeline.waiting'),
        state: commitment ? 'done' as const : busy ? 'active' as const : 'pending' as const,
      },
      {
        id: 'settle',
        label: t('casino.timeline.settle'),
        description: bet ? t(bet.status === 'won' ? 'casino.result.won' : 'casino.result.lost') : t('casino.timeline.waiting'),
        state: bet ? 'done' as const : busy && commitment ? 'active' as const : 'pending' as const,
      },
      {
        id: 'reveal',
        label: t('casino.timeline.reveal'),
        description: verificationEvidence
          ? t(verificationEvidence.verification.resultMatch ? 'casino.verify.match' : 'casino.verify.mismatch')
          : t('casino.timeline.waiting'),
        state: verificationEvidence
          ? (verificationEvidence.verification.resultMatch ? 'done' as const : 'error' as const)
          : 'pending' as const,
      },
    ],
    [bet, busy, commitment, t, verificationEvidence],
  );

  async function prepareRound(nextGame = gameCode, options: { preserveEvidence?: boolean } = {}) {
    setBusy(true);
    setErrorKey(null);
    setBet(null);
    if (!options.preserveEvidence) {
      setVerificationEvidence(null);
    }
    try {
      const round = await callRpc('rpc_open_game_round', { p_game: nextGame }) as unknown as RoundCommitment;
      setCommitment(round);
      if (clientSeedIsAuto) {
        setClientSeed(randomHex());
      }
      setToastKey('casino.toast.hashReady');
    } catch (error) {
      setErrorKey(errorToKey(error));
    } finally {
      setBusy(false);
    }
  }

  async function submitBet() {
    if (!commitment || betInFlightRef.current) return;
    const idempotencyKey = betIdempotencyKeyRef.current ?? (betIdempotencyKeyRef.current = `casino:${randomHex()}`);
    betInFlightRef.current = true;
    setBusy(true);
    setErrorKey(null);
    setVerificationEvidence(null);
    try {
      const placed = await callRpc('rpc_place_game_bet', {
        p_round_id: commitment.round_id,
        p_currency: currency,
        p_stake: stake,
        p_selection: selection as Json,
        p_client_seed: clientSeed,
        p_idempotency_key: idempotencyKey,
      }) as unknown as BetResponse;
      const revealed = await callRpc('rpc_reveal_game_round', { p_round_id: commitment.round_id }) as unknown as RevealResponse;
      const verified = await verifyRound({
        game: gameCode,
        serverSeed: revealed.server_seed,
        serverSeedHash: commitment.server_seed_hash,
        clientSeed,
        nonce: 1,
        selection,
        expectedResult: placed.result,
      });
      setBet(placed);
      setVerificationEvidence({
        server_seed_hash: commitment.server_seed_hash,
        server_seed: revealed.server_seed,
        result: placed.result,
        verification: verified,
      });
      setConfirmOpen(false);
      setToastKey(placed.status === 'won' ? 'casino.toast.won' : 'casino.toast.settled');
      await queryClient.invalidateQueries({ queryKey: walletKeys.all(session?.user.id ?? null) });
      setRecentBets(await loadRecentBets());
      await prepareRound(gameCode, { preserveEvidence: true });
    } catch (error) {
      setErrorKey(errorToKey(error));
    } finally {
      setBusy(false);
      betInFlightRef.current = false;
      betIdempotencyKeyRef.current = null;
    }
  }

  function openBetConfirm() {
    if (!canSubmit) return;
    betIdempotencyKeyRef.current ??= `casino:${randomHex()}`;
    setConfirmOpen(true);
  }

  function selectGame(next: GameCode) {
    void navigate({ to: next === 'dice' ? '/casino/dice' : `/casino/${next}` });
  }

  function updateSelection(key: string, value: string) {
    setSelection((current) => {
      if (key === 'guesses.0') return { ...current, guesses: [value] };
      if (key === 'revealedCells') return { ...current, revealedCells: cellsFromText(value, 24) };
      if (key === 'rows' || key === 'mineCount') return { ...current, [key]: Number(value) };
      return { ...current, [key]: value };
    });
    setCommitment(null);
    setBet(null);
    setVerificationEvidence(null);
  }

  function updateClientSeed(value: string) {
    setClientSeed(value);
    setClientSeedIsAuto(false);
    setCommitment(null);
    setBet(null);
    setVerificationEvidence(null);
  }

  if (authLoading) {
    return <div className="shell"><Skeleton className="h-40" /></div>;
  }

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <Link to="/dashboard" className="logo-name" style={{ textDecoration: 'none' }}>PHONARA</Link>
          </div>
          <nav className="dash-nav">
            <Link to="/casino/fairness" className="nav-link">{t('casino.fairness.link')}</Link>
            <Link to="/dashboard" className="nav-link">{t('nav.dashboard')}</Link>
          </nav>
        </header>

        <section className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-black text-fg">{t('casino.title')}</h1>
              <ProvablyFairBadge>{t('casino.provablyFair')}</ProvablyFairBadge>
            </div>
            <p className="max-w-3xl text-sm text-muted">{t('casino.subtitle')}</p>
          </div>

          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
            <BetPanel
              title={t(config.labelKey)}
              description={t(config.descriptionKey)}
              actions={<Badge tone="primary">{t('casino.instantSettle')}</Badge>}
            >
              <div className="mb-5 grid grid-cols-2 gap-2 md:grid-cols-6">
                {GAME_CONFIGS.map((game) => (
                  <Link
                    key={game.code}
                    to={game.code === 'dice' ? '/casino/dice' : `/casino/${game.code}`}
                    className={`rounded-2xl border px-3 py-3 text-center text-sm font-semibold transition-colors ${
                      game.code === gameCode
                        ? 'border-primary bg-primary/15 text-primary'
                        : 'border-border bg-surface-2/70 text-muted hover:text-fg'
                    }`}
                    onClick={() => selectGame(game.code)}
                  >
                    {t(game.labelKey)}
                  </Link>
                ))}
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <GameStakeInput
                  data-testid="casino-stake-input"
                  label={t('casino.stake')}
                  value={stake}
                  onChange={(event) => setStake(normalizeDecimalInput(event.target.value))}
                  currency={currency}
                  hint={
                    walletLoading
                      ? t('common.loading')
                      : t('casino.available', { amount: formatMoney(available ?? '0', currency), currency })
                  }
                />

                <label className="flex flex-col gap-2">
                  <span className="text-sm font-medium text-fg">{t('casino.currency')}</span>
                  <SegmentedControl<Currency>
                    value={currency}
                    onChange={setCurrency}
                    options={[
                      { value: 'PHON', label: 'PHON' },
                      { value: 'USDT', label: 'USDT' },
                    ]}
                  />
                </label>
              </div>

              <div className="mt-4 grid gap-3 md:grid-cols-2">
                {config.fields.map((field) => (
                  <GameFieldControl
                    key={field.key}
                    field={field}
                    selection={selection}
                    onChange={updateSelection}
                  />
                ))}
              </div>

              <label className="mt-4 flex flex-col gap-2">
                <span className="text-sm font-medium text-fg">{t('casino.field.clientSeed')}</span>
                <input
                  className="rounded-xl border border-border bg-surface-2 px-3 py-2 text-fg tabular-nums"
                  data-testid="casino-client-seed-input"
                  value={clientSeed}
                  onChange={(event) => updateClientSeed(event.target.value)}
                />
                <span className="text-xs text-muted">
                  {t(clientSeedIsAuto ? 'casino.field.clientSeedAutoHint' : 'casino.field.clientSeedManualHint')}
                </span>
              </label>

              <div className="mt-5 grid gap-3 md:grid-cols-3">
                <MultiplierDisplay label={t('casino.hashStatus')} value={commitment ? t('casino.hashReady') : t('casino.hashMissing')} tone={commitment ? 'primary' : 'neutral'} />
                <MultiplierDisplay label={t('casino.lastPayout')} value={bet ? `${formatMoney(bet.payout, currency)} ${currency}` : '-'} tone={bet?.status === 'won' ? 'up' : bet ? 'down' : 'neutral'} />
                <MultiplierDisplay label={t('casino.lossLimit')} value={t('casino.lossLimitValue')} tone="primary" />
              </div>

              <div className="mt-5 flex flex-col gap-2 sm:flex-row">
                <Button
                  variant="outline"
                  disabled={busy}
                  data-testid="casino-prepare-hash"
                  onClick={() => void prepareRound()}
                >
                  {commitment ? t('casino.refreshHash') : t('casino.prepareHash')}
                </Button>
                <Button full data-testid="casino-place-bet" disabled={!canSubmit} onClick={openBetConfirm}>
                  {busy ? t('common.processing') : t('casino.placeBet')}
                </Button>
              </div>

              {errorKey && (
                <ErrorState
                  className="mt-4"
                  data-testid="casino-error"
                  title={t('casino.error.title')}
                  description={t(errorKey)}
                />
              )}
            </BetPanel>

            <aside className="flex flex-col gap-4">
              <FairnessVerifier
                data-testid="casino-fairness-verifier"
                title={t('casino.verify.title')}
                seedHashLabel={t('casino.verify.seedHash')}
                seedHash={verificationEvidence?.server_seed_hash ?? commitment?.server_seed_hash ?? t('casino.timeline.waiting')}
                serverSeedLabel={verificationEvidence ? t('casino.verify.serverSeed') : undefined}
                serverSeed={verificationEvidence?.server_seed}
                resultLabel={verificationEvidence ? t('casino.verify.result') : undefined}
                result={verificationEvidence ? JSON.stringify(verificationEvidence.result) : undefined}
                statusLabel={
                  verificationEvidence
                    ? t(
                      verificationEvidence.verification.seedHashMatch && verificationEvidence.verification.resultMatch
                        ? 'casino.verify.match'
                        : 'casino.verify.mismatch',
                    )
                    : t('casino.verify.pending')
                }
                verified={verificationEvidence ? verificationEvidence.verification.seedHashMatch && verificationEvidence.verification.resultMatch === true : null}
              />
              <StatusTimeline items={timeline} />
              {toastKey && <Toast tone="success" title={t(toastKey)} />}
            </aside>
          </div>

          <BetPanel title={t('casino.recent.title')} description={t('casino.recent.description')}>
            {recentBets.length === 0 ? (
              <EmptyState title={t('casino.recent.empty')} description={t('casino.recent.emptyDesc')} />
            ) : (
              <div className="grid gap-2">
                {recentBets.map((row) => (
                  <div key={row.id} className="grid grid-cols-4 items-center gap-2 rounded-xl border border-border bg-surface-2/60 px-3 py-2 text-sm">
                    <span className="font-semibold text-fg">{t(GAME_BY_CODE[row.game].labelKey)}</span>
                    <Badge tone={row.status === 'won' ? 'up' : 'down'} size="sm">{row.status}</Badge>
                    <span className="text-right text-muted">{formatMoney(row.stake, row.currency)} {row.currency}</span>
                    <span className="text-right font-semibold text-fg">{formatMoney(row.payout ?? '0', row.currency)}</span>
                  </div>
                ))}
              </div>
            )}
          </BetPanel>
        </section>
      </div>

      <ConfirmDialog
        open={confirmOpen}
        testId="casino-bet-confirm"
        title={t('casino.confirm.title')}
        description={t('casino.confirm.description')}
        tone="primary"
        rows={[
          { label: t('casino.confirm.game'), value: t(config.labelKey) },
          { label: t('casino.stake'), value: `${formatMoney(stake, currency)} ${currency}` },
          { label: t('casino.field.clientSeed'), value: clientSeed.slice(0, 16) },
          { label: t('casino.verify.seedHash'), value: commitment?.server_seed_hash.slice(0, 16) ?? '-' },
        ]}
        confirmLabel={t('casino.placeBet')}
        cancelLabel={t('common.cancel')}
        busy={busy}
        onConfirm={() => void submitBet()}
        onCancel={() => {
          if (betInFlightRef.current) return;
          betIdempotencyKeyRef.current = null;
          setConfirmOpen(false);
        }}
      />
    </div>
  );
}

function GameFieldControl({
  field,
  selection,
  onChange,
}: {
  field: GameField;
  selection: Record<string, unknown>;
  onChange: (key: string, value: string) => void;
}) {
  const t = useT();
  const value = getSelectionValue(selection, field.key);

  if (field.kind === 'select') {
    return (
      <label className="flex flex-col gap-2">
        <span className="text-sm font-medium text-fg">{t(field.labelKey)}</span>
        <SegmentedControl<string>
          value={String(value)}
          onChange={(next) => onChange(field.key, next)}
          options={field.options.map((option) => ({ value: option.value, label: t(option.labelKey) }))}
        />
      </label>
    );
  }

  if (field.kind === 'cells') {
    return (
      <label className="flex flex-col gap-2">
        <span className="text-sm font-medium text-fg">{t(field.labelKey)}</span>
        <input
          className="rounded-xl border border-border bg-surface-2 px-3 py-2 text-fg"
          value={Array.isArray(value) ? value.join(',') : ''}
          onChange={(event) => onChange(field.key, cellsFromText(event.target.value, field.max).join(','))}
        />
        <span className="text-xs text-muted">{t('casino.field.cellsHint')}</span>
      </label>
    );
  }

  return (
    <label className="flex flex-col gap-2">
      <span className="text-sm font-medium text-fg">{t(field.labelKey)}</span>
      <input
        className="rounded-xl border border-border bg-surface-2 px-3 py-2 text-right text-fg tabular-nums"
        inputMode={field.kind === 'number' ? 'numeric' : field.inputMode}
        min={field.kind === 'number' ? field.min : undefined}
        max={field.kind === 'number' ? field.max : undefined}
        step={field.kind === 'number' ? field.step : undefined}
        value={String(value)}
        onChange={(event) => {
          const next = field.kind === 'text' && field.inputMode === 'decimal'
            ? normalizeDecimalInput(event.target.value)
            : event.target.value;
          onChange(field.key, next);
        }}
      />
    </label>
  );
}

function FairnessDocsPage() {
  const t = useT();
  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <Link to="/casino" className="logo-name" style={{ textDecoration: 'none' }}>PHONARA</Link>
          </div>
          <nav className="dash-nav">
            <Link to="/casino" className="nav-link">{t('casino.title')}</Link>
            <Link to="/dashboard" className="nav-link">{t('nav.dashboard')}</Link>
          </nav>
        </header>
        <BetPanel title={t('casino.fairness.title')} description={t('casino.fairness.description')}>
          <div className="grid gap-4 md:grid-cols-3">
            <StatusTimeline
              items={[
                { id: 'commit', label: t('casino.fairness.step1'), description: t('casino.fairness.step1.desc'), state: 'done' },
                { id: 'settle', label: t('casino.fairness.step2'), description: t('casino.fairness.step2.desc'), state: 'active' },
                { id: 'verify', label: t('casino.fairness.step3'), description: t('casino.fairness.step3.desc'), state: 'pending' },
              ]}
            />
            <div className="rounded-2xl border border-border bg-surface-2 p-4 md:col-span-2">
              <pre className="overflow-x-auto whitespace-pre-wrap text-xs text-muted">
{`server_seed -> SHA-256 commitment
HMAC-SHA256(server_seed, client_seed:nonce:cursor) -> floats
GAME_REGISTRY.resultFromFloats(floats, selection) -> stored result`}
              </pre>
            </div>
          </div>
        </BetPanel>
      </div>
    </div>
  );
}

function getSelectionValue(selection: Record<string, unknown>, key: string): unknown {
  if (key === 'guesses.0') {
    const guesses = selection['guesses'];
    return Array.isArray(guesses) ? guesses[0] : 'higher';
  }
  return selection[key];
}

function cellsFromText(text: string, max: number): number[] {
  const values = text
    .split(',')
    .map((part) => Number(part.trim()))
    .filter((value) => Number.isInteger(value) && value >= 0 && value <= max);
  return [...new Set(values)].slice(0, 24);
}

async function loadRecentBets(): Promise<RecentBet[]> {
  const { data } = await supabase
    .from('game_bets')
    .select('id,game,status,stake,payout,currency,created_at')
    .order('created_at', { ascending: false })
    .limit(5);
  return (data ?? []) as RecentBet[];
}

function randomHex(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function errorToKey(error: unknown): MessageKey {
  const translated = translateError(error);
  if (translated !== 'error.UNKNOWN') return translated;
  return 'error.UNKNOWN';
}
