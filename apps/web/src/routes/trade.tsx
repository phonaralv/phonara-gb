import { createRoute, useNavigate, Link } from '@tanstack/react-router';
import { lazy, Suspense, useEffect, useMemo, useState } from 'react';
import type { MessageKey } from '@phonara/i18n';
import { Route as rootRoute } from './__root';
import { useAuth } from '../contexts/auth-context';
import { useWallet } from '../hooks/use-wallet';
import { useTradeNotifications, type PriceAlertConfig, type TradeNotification } from '../hooks/use-trade-notifications';
import {
  usePrices,
  useFuturesMarkets,
  useSpotMarkets,
  useCandles,
  useSyntheticBook,
  useFuturesPositions,
  useFuturesActions,
  useTradingRiskAcknowledgement,
  useSpotActions,
  type FuturesPosition,
  type FuturesMarket,
  type SpotMarket,
} from '../hooks/use-trading';
import {
  computeOpenPosition,
  computePnl,
  computeSpotBuy,
  computeSpotSell,
  TradingError,
  type PositionSide,
} from '@phonara/trading-engine';
import { formatMoney, ConfirmDialog, Button, Card, Stat, Badge, Input, SegmentedControl, Slider, OrderBook, Skeleton } from '@phonara/ui';
import { toDecimal } from '@phonara/money';
import { isPositiveAmount, isNegativeAmount } from '../lib/money-display';
import { normalizeDecimalInput } from '../lib/money-input';
import { useT } from '../lib/i18n';
import { useRealtimeConnectionStore } from '../stores/realtime';

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/trade',
  component: TradePage,
});

const LazyTradingChart = lazy(() => import('../components/trading-chart-loader'));

function TradePage() {
  const t = useT();
  const { session, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const { wallet, loading: walletLoading } = useWallet();
  const realtimeDisconnected = useRealtimeConnectionStore((s) => s.disconnected);
  const {
    prices,
    isError: pricesError,
    isFetching: pricesFetching,
    dataUpdatedAt: pricesUpdatedAt,
    refetch: refetchPrices,
    oracleStale,
    isPriceStale,
  } = usePrices();
  const { markets: futuresMarkets, loading: futuresMarketsLoading, isError: futuresMarketsError } = useFuturesMarkets();
  const { markets: spotMarkets, isError: spotMarketsError } = useSpotMarkets();
  const {
    positions,
    refresh,
    isError: positionsError,
    isFetching: positionsFetching,
    dataUpdatedAt: positionsUpdatedAt,
    refetch: refetchPositions,
  } = useFuturesPositions();
  const tradeNotifications = useTradeNotifications();
  const selectedSpotMarket = useMemo(
    () => spotMarkets.find((market) => market.symbol === 'PHON_USDT') ?? spotMarkets[0] ?? null,
    [spotMarkets],
  );

  useEffect(() => {
    if (!authLoading && !session) void navigate({ to: '/login' });
  }, [session, authLoading, navigate]);

  if (authLoading) {
    return (
      <div className="shell">
        <Card className="grid w-full max-w-3xl gap-4 p-5" aria-busy="true">
          <Skeleton className="h-5 w-40" />
          <Skeleton className="h-[260px]" />
          <Skeleton className="h-24" />
        </Card>
      </div>
    );
  }

  return (
    <div className="shell">
      <div className="dashboard">
        <header className="dash-header">
          <div className="dash-logo">
            <Link to="/dashboard" className="logo-name" style={{ textDecoration: 'none' }}>← PHONARA</Link>
          </div>
          <nav className="dash-nav">
            <Link to="/staking" className="nav-link">{t('nav.staking')}</Link>
            <Link to="/dashboard" className="nav-link">{t('nav.dashboard')}</Link>
          </nav>
          <TradeNotificationCenter
            markets={futuresMarkets}
            prices={prices}
            notifications={tradeNotifications.notifications}
            permission={tradeNotifications.permission}
            permissionBusy={tradeNotifications.permissionBusy}
            permissionError={tradeNotifications.permissionError}
            pushConsent={tradeNotifications.pushConsent}
            priceAlert={tradeNotifications.priceAlert}
            onRequestPermission={tradeNotifications.requestBrowserNotifications}
            onSetPriceAlert={tradeNotifications.setPriceAlert}
            onClearPriceAlert={tradeNotifications.clearPriceAlert}
            onClearNotifications={tradeNotifications.clearNotifications}
          />
        </header>

        <MarketDataStatus
          pricesError={pricesError}
          positionsError={positionsError}
          marketsError={futuresMarketsError || spotMarketsError}
          pricesFetching={pricesFetching}
          positionsFetching={positionsFetching}
          pricesUpdatedAt={pricesUpdatedAt}
          positionsUpdatedAt={positionsUpdatedAt}
          oracleStale={oracleStale}
          onRetry={() => {
            void refetchPrices();
            void refetchPositions();
          }}
        />

        <section className="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(0,7fr)_minmax(320px,3fr)]">
          <FuturesPanel
            markets={futuresMarkets}
            marketsLoading={futuresMarketsLoading}
            prices={prices}
            phonAvail={wallet?.phon_available ?? '0'}
            usdtAvail={wallet?.usdt_available ?? '0'}
            walletLoading={walletLoading}
            isPriceStale={isPriceStale}
            realtimeDisconnected={realtimeDisconnected}
            onTraded={refresh}
          />
          <SpotPanel
            market={selectedSpotMarket}
            price={selectedSpotMarket ? (prices[selectedSpotMarket.symbol] ?? '0') : '0'}
            usdtAvail={wallet?.usdt_available ?? '0'}
            phonAvail={wallet?.phon_available ?? '0'}
            priceStale={selectedSpotMarket ? isPriceStale(selectedSpotMarket.symbol) : false}
            realtimeDisconnected={realtimeDisconnected}
          />
        </section>

        <OpenPositions
          positions={positions}
          prices={prices}
          isPriceStale={isPriceStale}
          realtimeDisconnected={realtimeDisconnected}
          onClosed={refresh}
        />
      </div>
    </div>
  );
}

function MarketDataStatus({
  pricesError,
  positionsError,
  marketsError,
  pricesFetching,
  positionsFetching,
  pricesUpdatedAt,
  positionsUpdatedAt,
  oracleStale,
  onRetry,
}: {
  pricesError: boolean;
  positionsError: boolean;
  marketsError: boolean;
  pricesFetching: boolean;
  positionsFetching: boolean;
  pricesUpdatedAt: number;
  positionsUpdatedAt: number;
  oracleStale: boolean;
  onRetry: () => void;
}) {
  const t = useT();
  const hasError = pricesError || positionsError || marketsError;
  const oldestUpdate = Math.min(
    pricesUpdatedAt || Number.POSITIVE_INFINITY,
    positionsUpdatedAt || Number.POSITIVE_INFINITY,
  );
  const stale = oracleStale || (oldestUpdate !== Number.POSITIVE_INFINITY && Date.now() - oldestUpdate > 30_000);
  if (!hasError && !stale && !pricesFetching && !positionsFetching) return null;

  return (
    <Card
      className="flex flex-wrap items-center justify-between gap-3 border-warning/40 bg-warning/10 px-4 py-3 text-sm"
      data-testid="market-data-status"
    >
      <div className="flex flex-wrap items-center gap-2">
        {hasError && <Badge tone="down">{t('trade.dataStatus.error')}</Badge>}
        {!hasError && stale && <Badge tone="warning">{t('trade.dataStatus.stale')}</Badge>}
        {!hasError && !stale && (pricesFetching || positionsFetching) && (
          <Badge tone="primary">{t('trade.dataStatus.syncing')}</Badge>
        )}
        <span className="text-muted">
          {hasError
            ? t('trade.dataStatus.errorDescription')
            : stale
              ? t('trade.dataStatus.staleDescription')
              : t('trade.dataStatus.syncingDescription')}
        </span>
      </div>
      {hasError && (
        <Button size="sm" variant="secondary" onClick={onRetry}>
          {t('common.retry')}
        </Button>
      )}
    </Card>
  );
}

function TradeNotificationCenter({
  markets,
  prices,
  notifications,
  permission,
  permissionBusy,
  permissionError,
  pushConsent,
  priceAlert,
  onRequestPermission,
  onSetPriceAlert,
  onClearPriceAlert,
  onClearNotifications,
}: {
  markets: FuturesMarket[];
  prices: Record<string, string>;
  notifications: TradeNotification[];
  permission: NotificationPermission | 'unsupported';
  permissionBusy: boolean;
  permissionError: MessageKey | null;
  pushConsent: boolean;
  priceAlert: PriceAlertConfig | null;
  onRequestPermission: () => Promise<boolean>;
  onSetPriceAlert: (next: Omit<PriceAlertConfig, 'enabled' | 'triggered'>) => boolean;
  onClearPriceAlert: () => void;
  onClearNotifications: () => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [symbol, setSymbol] = useState(markets[0]?.symbol ?? '');
  const [target, setTarget] = useState('');
  const [direction, setDirection] = useState<'above' | 'below'>('above');

  useEffect(() => {
    if (!symbol && markets[0]) {
      setSymbol(markets[0].symbol);
    }
  }, [markets, symbol]);

  const selectedPrice = symbol ? (prices[symbol] ?? '0') : '0';
  const permissionLabel = permission === 'granted'
    ? t('notif.permission.statusGranted')
    : permission === 'denied'
      ? t('notif.permission.statusDenied')
      : permission === 'unsupported'
        ? t('notif.permission.statusUnsupported')
        : t('notif.permission.statusDefault');

  return (
    <div className="relative z-50" data-testid="notification-center">
      <Button
        variant="secondary"
        size="sm"
        data-testid="notification-center-toggle"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        {t('notif.center.toggle')}
        {notifications.length > 0 && <Badge tone="primary">{notifications.length}</Badge>}
      </Button>

      {open && (
        <Card className="fixed right-4 top-20 z-100 flex w-[min(92vw,390px)] flex-col gap-3 p-4 text-left shadow-2xl">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h3 className="text-sm font-bold text-fg">{t('notif.center.title')}</h3>
              <p className="text-xs text-muted">{t('notif.center.description')}</p>
            </div>
            <Button variant="ghost" size="sm" onClick={() => setOpen(false)}>{t('common.close')}</Button>
          </div>

          <div className="rounded-xl border border-border bg-surface-2/60 p-3" data-testid="notification-permission">
            <div className="flex items-center justify-between gap-3">
              <div>
                <p className="text-sm font-semibold text-fg">{t('notif.permission.title')}</p>
                <p className="text-xs text-muted">{permissionLabel}</p>
              </div>
              <Button
                variant="outline"
                size="sm"
                disabled={permissionBusy || permission === 'unsupported'}
                data-testid="notification-permission-button"
                onClick={() => void onRequestPermission()}
              >
                {permissionBusy ? t('common.processing') : t('notif.permission.cta')}
              </Button>
            </div>
            {pushConsent && <p className="mt-2 text-xs text-up">{t('notif.permission.consentLinked')}</p>}
            {permissionError && <p className="mt-2 text-xs text-down">{t(permissionError)}</p>}
          </div>

          <div className="rounded-xl border border-border bg-surface-2/60 p-3" data-testid="price-alert-form">
            <p className="text-sm font-semibold text-fg">{t('notif.priceAlert.formTitle')}</p>
            <p className="text-xs text-muted">{t('notif.priceAlert.formDescription')}</p>
            <div className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-[1fr_0.8fr]">
              <select
                className="h-10 rounded-xl border border-border bg-surface px-3 text-sm text-fg"
                value={symbol}
                data-testid="price-alert-symbol"
                onChange={(event) => setSymbol(event.target.value)}
              >
                {markets.map((market) => (
                  <option key={market.symbol} value={market.symbol}>{market.display_name ?? market.symbol}</option>
                ))}
              </select>
              <SegmentedControl<'above' | 'below'>
                size="sm"
                value={direction}
                onChange={setDirection}
                options={[
                  { value: 'above', label: t('notif.priceAlert.above') },
                  { value: 'below', label: t('notif.priceAlert.below') },
                ]}
              />
            </div>
            <div className="mt-2 flex gap-2">
              <Input
                value={target}
                inputMode="decimal"
                data-testid="price-alert-target"
                placeholder={t('notif.priceAlert.targetPlaceholder')}
                onChange={(event) => setTarget(normalizeDecimalInput(event.target.value))}
              />
              <Button
                size="sm"
                data-testid="price-alert-save"
                disabled={!symbol}
                onClick={() => {
                  if (onSetPriceAlert({ symbol, target, direction })) setTarget('');
                }}
              >
                {t('common.save')}
              </Button>
            </div>
            <p className="mt-2 text-xs text-muted">
              {t('notif.priceAlert.current', { symbol: symbol || '-', price: formatMoney(selectedPrice, 'USDT') })}
            </p>
            {priceAlert && (
              <div className="mt-3 flex items-center justify-between gap-2 rounded-lg bg-surface px-3 py-2 text-xs">
                <span className="text-muted">
                  {t('notif.priceAlert.active', {
                    symbol: priceAlert.symbol,
                    direction: t(priceAlert.direction === 'above' ? 'notif.priceAlert.above' : 'notif.priceAlert.below'),
                    target: priceAlert.target,
                  })}
                </span>
                <Button variant="ghost" size="sm" onClick={onClearPriceAlert}>{t('notif.priceAlert.clear')}</Button>
              </div>
            )}
          </div>

          <div className="flex items-center justify-between gap-3">
            <p className="text-sm font-semibold text-fg">{t('notif.center.recent')}</p>
            <Button variant="ghost" size="sm" onClick={onClearNotifications}>{t('notif.center.clear')}</Button>
          </div>
          <div className="flex max-h-64 flex-col gap-2 overflow-auto" data-testid="notification-list">
            {notifications.length === 0 ? (
              <p className="rounded-xl border border-border bg-surface-2/50 p-3 text-sm text-muted">
                {t('notif.center.empty')}
              </p>
            ) : notifications.map((item) => (
              <div key={item.id} className="rounded-xl border border-border bg-surface-2/60 p-3">
                <div className="flex items-center justify-between gap-3">
                  <p className="text-sm font-semibold text-fg">{item.title}</p>
                  <Badge tone={item.tone === 'danger' ? 'down' : item.tone === 'success' ? 'up' : 'primary'}>
                    {t(`notif.tone.${item.tone}` as MessageKey)}
                  </Badge>
                </div>
                <p className="mt-1 text-xs text-muted">{item.body}</p>
                <p className="mt-2 text-[0.7rem] text-muted">{new Date(item.createdAt).toLocaleString()}</p>
              </div>
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}

// ─── Futures order panel ───────────────────────────────────────

function FuturesPanel({
  markets, marketsLoading, prices, phonAvail, usdtAvail, walletLoading, isPriceStale, onTraded,
  realtimeDisconnected,
}: {
  markets: FuturesMarket[];
  marketsLoading: boolean;
  prices: Record<string, string>;
  phonAvail: string;
  usdtAvail: string;
  walletLoading: boolean;
  isPriceStale: (symbol: string | null | undefined) => boolean;
  onTraded: () => void;
  realtimeDisconnected: boolean;
}) {
  const t = useT();
  const [marketIdx, setMarketIdx] = useState(0);
  const [side, setSide] = useState<PositionSide>('long');
  const [marginCurrency, setMarginCurrency] = useState<'PHON' | 'USDT'>('USDT');
  const [margin, setMargin] = useState('100');
  const [leverage, setLeverage] = useState('10');
  const [confirmOpen, setConfirmOpen] = useState(false);
  const { openPosition, busy, error } = useFuturesActions(onTraded);
  const riskAck = useTradingRiskAcknowledgement();

  const market = markets[marketIdx] ?? markets[0] ?? null;
  const price = market ? (prices[market.symbol] ?? '0') : '0';
  const priceStale = market ? isPriceStale(market.symbol) : false;
  const maxLeverage = market?.max_leverage ?? '1';
  const highLeverageThreshold = useMemo(() => {
    try {
      const half = toDecimal(maxLeverage).div(2).ceil();
      return half.lessThanOrEqualTo('20') ? half.toString() : '20';
    } catch {
      return '1';
    }
  }, [maxLeverage]);
  const isHighLeverage = useMemo(() => {
    try {
      return toDecimal(leverage).greaterThan(highLeverageThreshold);
    } catch {
      return false;
    }
  }, [highLeverageThreshold, leverage]);
  const { candles, loading: candlesLoading, isError: candlesError, refetch: refetchCandles } = useCandles(market?.symbol ?? null, '1m');
  const syntheticBook = useSyntheticBook(market?.symbol ?? null);
  const staleReason = t('trade.dataStatus.staleDescription');
  const realtimeReason = t('trade.dataStatus.realtimeDisconnectedDescription');
  const disabledReason = priceStale ? staleReason : realtimeDisconnected ? realtimeReason : undefined;

  useEffect(() => {
    if (marketIdx >= markets.length) setMarketIdx(0);
  }, [marketIdx, markets.length]);

  useEffect(() => {
    try {
      if (toDecimal(leverage).greaterThan(maxLeverage)) {
        setLeverage(toDecimal(maxLeverage).toFixed(0));
      }
    } catch {
      setLeverage('1');
    }
  }, [leverage, maxLeverage]);

  async function submitOpen() {
    if (!market || priceStale || realtimeDisconnected) return;
    await openPosition({ market: market.symbol, side, marginCurrency, marginAmount: margin, leverage });
    setConfirmOpen(false);
  }

  const preview = useMemo(() => {
    try {
      if (!isPositiveAmount(price) || !isPositiveAmount(margin)) return null;
      return computeOpenPosition({
        side, marginCurrency, marginAmount: margin, leverage,
        entryPrice: price, maxLeverage,
      });
    } catch (e) {
      return e instanceof TradingError ? null : null;
    }
  }, [side, marginCurrency, margin, leverage, price, maxLeverage]);

  const avail = marginCurrency === 'USDT' ? usdtAvail : phonAvail;
  const chartLabels = useMemo(() => ({
    loading: t('trade.chart.loading'),
    emptyTitle: t('trade.chart.emptyTitle'),
    emptyDescription: t('trade.chart.emptyDescription'),
    errorTitle: t('trade.chart.errorTitle'),
    errorDescription: t('trade.chart.errorDescription'),
    retry: t('common.retry'),
    oraclePrice: t('trade.markPrice'),
    liquidationPrice: t('trade.liquidationPrice'),
    volume: t('trade.chart.volume'),
  }), [t]);
  const chartDisclosure = market?.symbol === 'PHON_USDT' || market?.base_label === 'PHON'
    ? t('trade.chart.internalReferenceDisclosure')
    : undefined;
  const orderBookLabels = useMemo(() => ({
    loading: t('trade.orderBook.loading'),
    emptyTitle: t('trade.orderBook.emptyTitle'),
    errorTitle: t('trade.orderBook.errorTitle'),
    retry: t('common.retry'),
    asks: t('trade.orderBook.asks'),
    bids: t('trade.orderBook.bids'),
    price: t('trade.price'),
    size: t('trade.quantity'),
  }), [t]);

  return (
    <Card className="flex flex-col gap-3 p-[18px]">
      <h3 className="text-[1.05rem] font-bold text-fg">{t('trade.futuresTitle')}</h3>

      {(marketsLoading || !market) && (
        <div className="rounded-xl border border-border bg-surface-2/60 px-3 py-2 text-sm text-muted">
          {t(marketsLoading ? 'trade.markets.loading' : 'trade.markets.empty')}
        </div>
      )}

      {market && (
        <SegmentedControl<string>
          tone="primary"
          value={market.symbol}
          onChange={(sym) => setMarketIdx(Math.max(0, markets.findIndex(m => m.symbol === sym)))}
          options={markets.map(m => ({
            value: m.symbol,
            label: (
              <>
                <span>{m.base_label}</span>
                <span className="text-[0.7rem] font-normal opacity-80">{formatMoney(prices[m.symbol] ?? '0', 'USDT')}</span>
              </>
            ),
          }))}
        />
      )}

      <SegmentedControl<PositionSide>
        value={side}
        onChange={setSide}
        options={[
          { value: 'long', label: t('trade.longUp'), tone: 'up' },
          { value: 'short', label: t('trade.shortDown'), tone: 'down' },
        ]}
      />

      <Suspense
        fallback={(
          <Card className="flex min-h-[320px] flex-col gap-3 p-4" data-testid="trading-chart-loading">
            <h3 className="text-[1.05rem] font-bold text-fg">{t('trade.chartTitle')}</h3>
            <div className="h-[240px] animate-pulse rounded-2xl bg-surface-2/70" />
            <p className="text-xs text-muted">{t('trade.chart.loading')}</p>
          </Card>
        )}
      >
        <LazyTradingChart
          title={t('trade.chartTitle')}
          subtitle={market?.display_name ?? market?.symbol ?? ''}
          labels={chartLabels}
          candles={candles}
          oraclePrice={price}
          liquidationPrice={preview?.liquidationPrice ?? null}
          loading={candlesLoading}
          error={candlesError}
          onRetry={() => void refetchCandles()}
          pricePrecision={market?.price_precision ?? 6}
          disclosure={chartDisclosure}
        />
      </Suspense>

      <OrderBook
        title={t('trade.orderBook.title')}
        referenceLabel={t('trade.orderBook.referenceBadge')}
        disclosure={t('trade.orderBook.disclosure')}
        labels={orderBookLabels}
        asks={syntheticBook.book?.asks ?? []}
        bids={syntheticBook.book?.bids ?? []}
        loading={syntheticBook.loading}
        error={Boolean(syntheticBook.error)}
        onRetry={() => void syntheticBook.refetch()}
      />

      <div className="field-row">
        <label>{t('trade.marginCurrency')}</label>
        <SegmentedControl<'USDT' | 'PHON'>
          tone="accent"
          size="sm"
          value={marginCurrency}
          onChange={setMarginCurrency}
          options={[
            { value: 'USDT', label: 'USDT' },
            { value: 'PHON', label: 'PHON' },
          ]}
        />
      </div>

      <div className="field-row">
        <label>{t('trade.marginWith', { currency: marginCurrency })}</label>
        <Input
          inputMode="decimal"
          value={margin}
          onChange={e => setMargin(normalizeDecimalInput(e.target.value))}
          className="flex-1 min-w-0 text-right"
        />
      </div>
      <div className="field-hint">{t('wallet.available')}: {formatMoney(avail, marginCurrency)}</div>

      <div className="field-row">
        <label>{t('trade.leverageWith', { value: leverage })}</label>
        <Slider
          value={toDecimal(leverage).toNumber()}
          min={1}
          max={toDecimal(maxLeverage).toNumber()}
          step={1}
          showLabel
          formatLabel={(value) => `${value}x`}
          onChange={(value) => setLeverage(String(value))}
          className="flex-1"
        />
      </div>

      {preview && (
        <div className="flex flex-col gap-1.5 rounded-xl bg-surface-2/60 px-3 py-2.5">
          <Stat label={t('trade.positionSize')} value={`${formatMoney(preview.notional, marginCurrency)} ${marginCurrency}`} />
          <Stat label={t('trade.quantity')} value={formatMoney(preview.quantity, 'PHON')} />
          <Stat label={t('trade.liquidationPrice')} value={formatMoney(preview.liquidationPrice, 'USDT')} tone="down" />
          <Stat label={t('trade.openFee')} value={`${formatMoney(preview.openFee, marginCurrency)} ${marginCurrency}`} />
        </div>
      )}

      <div className="rounded-xl border border-warning/30 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning">
        {t('trade.simWarning')}
      </div>

      {isHighLeverage && (
        <div className="flex flex-col gap-2 rounded-xl border border-warning/40 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning">
          <p>{t('trade.highLeverageWarning')}</p>
          {!riskAck.acknowledged && (
            <Button
              size="sm"
              variant="secondary"
              data-testid="trading-risk-ack"
              disabled={riskAck.busy || riskAck.loading}
              onClick={() => void riskAck.acknowledge()}
            >
              {riskAck.busy ? t('common.processing') : t('trade.riskAckCta')}
            </Button>
          )}
        </div>
      )}

      {error && <p className="card-error">{t(error)}</p>}
      {riskAck.error && <p className="card-error">{t(riskAck.error)}</p>}

      <span className="block" title={disabledReason}>
        <Button
          variant={side === 'long' ? 'success' : 'danger'}
          full
          data-testid="futures-open"
          disabled={busy || walletLoading || !preview || priceStale || realtimeDisconnected || (isHighLeverage && !riskAck.acknowledged)}
          onClick={() => setConfirmOpen(true)}
        >
          {busy ? t('common.processing') : t(side === 'long' ? 'trade.openLongPosition' : 'trade.openShortPosition')}
        </Button>
      </span>

      <ConfirmDialog
        open={confirmOpen}
        title={t('confirm.futuresOpen.title')}
        description={t('confirm.serverPriceNote')}
        tone={side === 'long' ? 'primary' : 'danger'}
        rows={preview ? [
          { label: t('confirm.row.market'), value: market?.display_name ?? market?.symbol ?? '' },
          { label: t('confirm.row.side'), value: t(side === 'long' ? 'trade.long' : 'trade.short') },
          { label: t('confirm.row.leverage'), value: `${leverage}x` },
          { label: t('trade.margin'), value: `${formatMoney(margin, marginCurrency)} ${marginCurrency}` },
          { label: t('trade.positionSize'), value: `${formatMoney(preview.notional, marginCurrency)} ${marginCurrency}` },
          { label: t('trade.liquidationPrice'), value: formatMoney(preview.liquidationPrice, 'USDT'), tone: 'danger' },
          { label: t('trade.openFee'), value: `${formatMoney(preview.openFee, marginCurrency)} ${marginCurrency}` },
        ] : []}
        confirmLabel={t(side === 'long' ? 'trade.openLongPosition' : 'trade.openShortPosition')}
        cancelLabel={t('common.cancel')}
        processingLabel={t('common.processing')}
        busy={busy}
        testId="futures-open"
        onConfirm={() => void submitOpen()}
        onCancel={() => setConfirmOpen(false)}
      />
    </Card>
  );
}

// ─── Spot panel ────────────────────────────────────────────────

function SpotPanel({
  market, price, usdtAvail, phonAvail, priceStale, realtimeDisconnected,
}: {
  market: SpotMarket | null;
  price: string;
  usdtAvail: string;
  phonAvail: string;
  priceStale: boolean;
  realtimeDisconnected: boolean;
}) {
  const t = useT();
  const [tab, setTab] = useState<'buy' | 'sell'>('buy');
  const [amount, setAmount] = useState('10');
  const [confirmOpen, setConfirmOpen] = useState(false);
  const { buy, sell, busy, error } = useSpotActions();
  const [msg, setMsg] = useState<string | null>(null);
  const staleReason = t('trade.dataStatus.staleDescription');
  const realtimeReason = t('trade.dataStatus.realtimeDisconnectedDescription');
  const disabledReason = priceStale ? staleReason : realtimeDisconnected ? realtimeReason : undefined;

  // Estimate via the canonical Decimal spot engine (matches the SQL settlement
  // exactly: same 0.1% fee + 6dp truncation), never JS float arithmetic.
  const estimate = useMemo<string | null>(() => {
    try {
      if (!isPositiveAmount(price) || !isPositiveAmount(amount)) return null;
      return tab === 'buy'
        ? computeSpotBuy({ price, feeRate: '0.001', usdtSpent: amount }).netPhon
        : computeSpotSell({ price, feeRate: '0.001', phonSold: amount }).netUsdt;
    } catch {
      return null;
    }
  }, [amount, tab, price]);

  async function submit() {
    if (priceStale || realtimeDisconnected) return;
    setMsg(null);
    const r = tab === 'buy' ? await buy(amount) : await sell(amount);
    setConfirmOpen(false);
    if (r) {
      setMsg(tab === 'buy'
        ? t('trade.buyDone', { amount: formatMoney(String(r['phon_received']), 'PHON') })
        : t('trade.sellDone', { amount: formatMoney(String(r['usdt_received']), 'USDT') }));
    }
  }

  return (
    <Card className="flex flex-col gap-3 p-[18px]">
      <h3 className="text-[1.05rem] font-bold text-fg">{market?.display_name ?? t('trade.spotTitle')}</h3>
      <div className="text-center text-[1.1rem] font-bold text-primary">
        {t('trade.spotRate', { price: formatMoney(price, 'USDT') })}
      </div>

      <SegmentedControl<'buy' | 'sell'>
        value={tab}
        onChange={setTab}
        options={[
          { value: 'buy', label: t('trade.buy'), tone: 'up' },
          { value: 'sell', label: t('trade.sell'), tone: 'down' },
        ]}
      />

      <div className="field-row">
        <label>{tab === 'buy' ? t('trade.payUsdt') : t('trade.sellPhonLabel')}</label>
        <Input
          inputMode="decimal"
          value={amount}
          onChange={e => setAmount(normalizeDecimalInput(e.target.value))}
          className="flex-1 min-w-0 text-right"
        />
      </div>
      <div className="field-hint">
        {t('wallet.available')}: {tab === 'buy'
          ? formatMoney(usdtAvail, 'USDT')
          : formatMoney(phonAvail, 'PHON')}
      </div>

      <div className="flex flex-col gap-1.5 rounded-xl bg-surface-2/60 px-3 py-2.5">
        <Stat
          label={t('trade.estReceiveFee')}
          value={`${formatMoney(estimate ?? '0', tab === 'buy' ? 'PHON' : 'USDT')} ${tab === 'buy' ? 'PHON' : 'USDT'}`}
        />
      </div>

      {error && <p className="card-error">{t(error)}</p>}
      {msg && <p className="trade-success">{msg}</p>}

      <span className="block" title={disabledReason}>
        <Button
          variant={tab === 'buy' ? 'success' : 'danger'}
          full
          data-testid="spot-submit"
          disabled={busy || !estimate || priceStale || realtimeDisconnected}
          onClick={() => setConfirmOpen(true)}
        >
          {busy ? t('common.processing') : tab === 'buy' ? t('trade.buyPhon') : t('trade.sellPhonBtn')}
        </Button>
      </span>

      <ConfirmDialog
        open={confirmOpen}
        title={t(tab === 'buy' ? 'confirm.spotBuy.title' : 'confirm.spotSell.title')}
        description={t('confirm.serverPriceNote')}
        tone={tab === 'buy' ? 'primary' : 'danger'}
        rows={[
          {
            label: t('confirm.row.pay'),
            value: `${formatMoney(amount, tab === 'buy' ? 'USDT' : 'PHON')} ${tab === 'buy' ? 'USDT' : 'PHON'}`,
          },
          {
            label: t('confirm.row.estReceive'),
            value: `${formatMoney(estimate ?? '0', tab === 'buy' ? 'PHON' : 'USDT')} ${tab === 'buy' ? 'PHON' : 'USDT'}`,
          },
        ]}
        confirmLabel={tab === 'buy' ? t('trade.buyPhon') : t('trade.sellPhonBtn')}
        cancelLabel={t('common.cancel')}
        processingLabel={t('common.processing')}
        busy={busy}
        testId="spot"
        onConfirm={() => void submit()}
        onCancel={() => setConfirmOpen(false)}
      />
    </Card>
  );
}

// ─── Open positions ────────────────────────────────────────────

function OpenPositions({
  positions, prices, isPriceStale, realtimeDisconnected, onClosed,
}: {
  positions: FuturesPosition[];
  prices: Record<string, string>;
  isPriceStale: (symbol: string | null | undefined) => boolean;
  realtimeDisconnected: boolean;
  onClosed: () => void;
}) {
  const t = useT();
  const { closePosition, busy } = useFuturesActions(onClosed);
  const [closing, setClosing] = useState<FuturesPosition | null>(null);
  const open = positions.filter(p => p.status === 'open');
  const history = positions.filter(p => p.status !== 'open').slice(0, 10);
  const staleReason = t('trade.dataStatus.staleDescription');
  const realtimeReason = t('trade.dataStatus.realtimeDisconnectedDescription');

  const closingCcy = (closing?.margin_currency ?? 'USDT') as 'PHON' | 'USDT';
  const closingMark = closing ? (prices[closing.market] ?? closing.entry_price) : '0';
  const closingPnl = closing
    ? computePnl(closing.side, closing.quantity, closing.entry_price, closingMark, closingCcy)
    : '0';

  async function submitClose() {
    if (!closing || isPriceStale(closing.market) || realtimeDisconnected) return;
    await closePosition(closing.id);
    setClosing(null);
  }

  return (
    <section className="positions-section">
      <h2 className="section-title">{t('trade.myPositions')}</h2>

      {open.length === 0 && <div className="empty-state"><span>📈</span>{t('trade.noPositions')}</div>}

      {open.map(pos => {
        const mark = prices[pos.market] ?? pos.entry_price;
        const marginCcy = pos.margin_currency as 'PHON' | 'USDT';
        const uPnl = computePnl(pos.side, pos.quantity, pos.entry_price, mark, marginCcy);
        const pnlNegative = isNegativeAmount(uPnl);
        const positionPriceStale = isPriceStale(pos.market);
        const disabledReason = positionPriceStale ? staleReason : realtimeDisconnected ? realtimeReason : undefined;
        return (
          <Card key={pos.id} className="mb-3 flex flex-col gap-2.5 p-4">
            <div className="flex items-center gap-2">
              <Badge tone={pos.side === 'long' ? 'up' : 'down'}>{t(pos.side === 'long' ? 'trade.long' : 'trade.short')} {pos.leverage}x</Badge>
              <span className="text-sm text-muted">{pos.market}</span>
            </div>
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
              <Stat layout="stack" label={t('trade.margin')} value={`${formatMoney(pos.margin_amount, marginCcy)} ${pos.margin_currency}`} />
              <Stat layout="stack" label={t('trade.entryPrice')} value={formatMoney(pos.entry_price, 'USDT')} />
              <Stat layout="stack" label={t('trade.markPrice')} value={formatMoney(mark, 'USDT')} />
              <Stat layout="stack" label={t('trade.liquidationPrice')} value={formatMoney(pos.liquidation_price, 'USDT')} tone="down" />
            </div>
            <div className={`text-[0.95rem] font-bold ${pnlNegative ? 'text-down' : 'text-up'}`}>
              {t('trade.unrealizedPnl')}: {formatMoney(uPnl, marginCcy, { signed: true })} {pos.margin_currency}
            </div>
            <span className="block" title={disabledReason}>
              <Button
                variant="secondary"
                size="sm"
                data-testid="futures-close"
                disabled={busy || positionPriceStale || realtimeDisconnected}
                onClick={() => setClosing(pos)}
              >
                {t('trade.closePositionBtn')}
              </Button>
            </span>
          </Card>
        );
      })}

      {history.length > 0 && (
        <>
          <h3 className="history-title">{t('trade.recentClosed')}</h3>
          <div className="position-history">
            {history.map(pos => {
              const marginCcy = pos.margin_currency as 'PHON' | 'USDT';
              return (
                <div key={pos.id} className="history-row">
                  <span className={`pos-side ${pos.side}`}>{t(pos.side === 'long' ? 'trade.long' : 'trade.short')}</span>
                  <span>{pos.market}</span>
                  <span className={pos.status === 'liquidated' ? 'badge-liq' : ''}>
                    {pos.status === 'liquidated' ? t('trade.liquidated') : t('trade.closed')}
                  </span>
                  <span className={isNegativeAmount(pos.realized_pnl ?? '0') ? 'loss' : 'profit'}>
                    {formatMoney(pos.realized_pnl ?? '0', marginCcy, { signed: true })}
                  </span>
                </div>
              );
            })}
          </div>
        </>
      )}

      <ConfirmDialog
        open={closing !== null}
        title={t('confirm.futuresClose.title')}
        description={t('confirm.serverPriceNote')}
        tone="danger"
        rows={closing ? [
          { label: t('confirm.row.market'), value: closing.market },
          { label: t('confirm.row.side'), value: t(closing.side === 'long' ? 'trade.long' : 'trade.short') },
          { label: t('trade.entryPrice'), value: formatMoney(closing.entry_price, 'USDT') },
          { label: t('trade.markPrice'), value: formatMoney(closingMark, 'USDT') },
          {
            label: t('trade.unrealizedPnl'),
            value: `${formatMoney(closingPnl, closingCcy, { signed: true })} ${closingCcy}`,
            tone: isNegativeAmount(closingPnl) ? 'danger' : 'default',
          },
        ] : []}
        confirmLabel={t('trade.closePositionBtn')}
        cancelLabel={t('common.cancel')}
        processingLabel={t('common.processing')}
        busy={busy}
        testId="futures-close"
        onConfirm={() => void submitClose()}
        onCancel={() => setClosing(null)}
      />
    </section>
  );
}
