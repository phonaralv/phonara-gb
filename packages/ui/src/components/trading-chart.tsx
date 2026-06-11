import { useEffect, useMemo, useRef, useState, forwardRef, type HTMLAttributes } from 'react';
import { toDecimal } from '@phonara/money';
import type * as LightweightChartsModule from 'lightweight-charts';
import { cn } from '../lib/cn';
import { Button } from './button';
import { Card } from './card';
import { Skeleton } from './skeleton';

type LightweightCharts = typeof LightweightChartsModule;
type ChartApi = ReturnType<LightweightCharts['createChart']>;
type LineSeriesApi = LightweightChartsModule.ISeriesApi<'Line'>;
type CandlestickSeriesApi = LightweightChartsModule.ISeriesApi<'Candlestick'>;
type HistogramSeriesApi = LightweightChartsModule.ISeriesApi<'Histogram'>;
type PriceLineApi = ReturnType<LineSeriesApi['createPriceLine']>;
type ChartSeriesApi = LineSeriesApi | CandlestickSeriesApi;

export interface TradingChartPoint {
  time: number;
  value: string;
}

export interface TradingChartCandle {
  time: number;
  open: string;
  high: string;
  low: string;
  close: string;
  volume?: string | null;
}

export interface TradingChartLabels {
  loading: string;
  emptyTitle: string;
  emptyDescription?: string;
  errorTitle: string;
  errorDescription?: string;
  retry?: string;
  oraclePrice: string;
  liquidationPrice: string;
  volume?: string;
}

export interface TradingChartProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: string;
  subtitle?: string;
  labels: TradingChartLabels;
  points?: TradingChartPoint[];
  candles?: TradingChartCandle[];
  oraclePrice: string;
  liquidationPrice?: string | null;
  loading?: boolean;
  error?: boolean;
  onRetry?: () => void;
  approachThreshold?: string;
  pricePrecision?: number;
  disclosure?: string;
}

function token(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function toChartNumber(value: string): number | null {
  try {
    const decimal = toDecimal(value);
    if (!decimal.isFinite() || decimal.isNegative() || decimal.isZero()) return null;
    return decimal.toNumber();
  } catch {
    return null;
  }
}

function isApproachingLiquidation(
  oraclePrice: string,
  liquidationPrice: string | null | undefined,
  threshold: string,
): boolean {
  if (!liquidationPrice) return false;
  try {
    const oracle = toDecimal(oraclePrice);
    const liquidation = toDecimal(liquidationPrice);
    if (oracle.isZero() || oracle.isNegative() || liquidation.isNegative() || liquidation.isZero()) {
      return false;
    }
    return oracle.minus(liquidation).abs().div(oracle).lessThanOrEqualTo(toDecimal(threshold));
  } catch {
    return false;
  }
}

function normalizeCandles(candles: TradingChartCandle[]) {
  return candles
    .map((candle) => {
      const open = toChartNumber(candle.open);
      const high = toChartNumber(candle.high);
      const low = toChartNumber(candle.low);
      const close = toChartNumber(candle.close);
      if (open === null || high === null || low === null || close === null) return null;
      return { time: candle.time as never, open, high, low, close };
    })
    .filter((candle): candle is { time: never; open: number; high: number; low: number; close: number } => candle !== null);
}

function normalizePoints(points: TradingChartPoint[]) {
  return points
    .map((point) => {
      const value = toChartNumber(point.value);
      return value === null ? null : { time: point.time as never, value };
    })
    .filter((point): point is { time: never; value: number } => point !== null);
}

function normalizeVolume(candles: TradingChartCandle[], border: string, muted: string) {
  return candles
    .map((candle) => {
      const value = candle.volume ? toChartNumber(candle.volume) : 0;
      return value === null ? null : {
        time: candle.time as never,
        value,
        color: value === 0 ? border : muted,
      };
    })
    .filter((point): point is { time: never; value: number; color: string } => point !== null);
}

function createChartApi(mod: LightweightCharts, container: HTMLDivElement): ChartApi {
  const fg = token('--color-fg');
  const muted = token('--color-muted');
  const surface = token('--color-surface');
  const border = token('--color-border-strong');

  return mod.createChart(container, {
    width: container.clientWidth,
    height: container.clientHeight,
    autoSize: true,
    layout: {
      background: { type: mod.ColorType.Solid, color: surface },
      textColor: muted,
      attributionLogo: false,
    },
    grid: {
      vertLines: { color: border },
      horzLines: { color: border },
    },
    rightPriceScale: {
      borderColor: border,
      textColor: fg,
    },
    timeScale: {
      borderColor: border,
      timeVisible: true,
      secondsVisible: false,
    },
    crosshair: {
      mode: mod.CrosshairMode.Normal,
    },
    handleScroll: false,
    handleScale: false,
  });
}

function createDataSeries(
  mod: LightweightCharts,
  chart: ChartApi,
  mode: 'candles' | 'line',
  pricePrecision: number,
): ChartSeriesApi {
  return mode === 'candles'
    ? chart.addSeries(mod.CandlestickSeries, {
      upColor: token('--color-up'),
      downColor: token('--color-down'),
      borderUpColor: token('--color-up'),
      borderDownColor: token('--color-down'),
      wickUpColor: token('--color-up'),
      wickDownColor: token('--color-down'),
      priceFormat: { type: 'price', precision: pricePrecision, minMove: 1 / (10 ** pricePrecision) },
    })
    : chart.addSeries(mod.LineSeries, {
      color: token('--color-primary'),
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: false,
      priceFormat: { type: 'price', precision: pricePrecision, minMove: 1 / (10 ** pricePrecision) },
    });
}

function createVolumeSeries(mod: LightweightCharts, chart: ChartApi): HistogramSeriesApi {
  const volumeSeries = chart.addSeries(mod.HistogramSeries, {
    priceScaleId: 'volume',
    priceFormat: { type: 'volume' },
    lastValueVisible: false,
    priceLineVisible: false,
  });
  chart.priceScale('volume').applyOptions({
    scaleMargins: { top: 0.8, bottom: 0 },
  });
  return volumeSeries;
}

export const TradingChart = forwardRef<HTMLDivElement, TradingChartProps>(function TradingChart(
  {
    title,
    subtitle,
    labels,
    points,
    candles,
    oraclePrice,
    liquidationPrice,
    loading = false,
    error: externalError = false,
    onRetry,
    approachThreshold = '0.02',
    pricePrecision = 6,
    disclosure,
    className,
    ...props
  },
  ref,
) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const moduleRef = useRef<LightweightCharts | null>(null);
  const chartRef = useRef<ChartApi | null>(null);
  const seriesRef = useRef<ChartSeriesApi | null>(null);
  const seriesModeRef = useRef<'candles' | 'line' | null>(null);
  const volumeSeriesRef = useRef<HistogramSeriesApi | null>(null);
  const oracleLineRef = useRef<PriceLineApi | null>(null);
  const liquidationLineRef = useRef<PriceLineApi | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const [error, setError] = useState(false);
  const [chartReady, setChartReady] = useState(false);
  const [retryKey, setRetryKey] = useState(0);

  const hasOracle = toChartNumber(oraclePrice) !== null;
  const chartPoints = useMemo(() => points ?? [], [points]);
  const chartCandles = useMemo(() => candles ?? [], [candles]);
  const validCandles = useMemo(() => normalizeCandles(chartCandles), [chartCandles]);
  const validPoints = useMemo(() => normalizePoints(chartPoints), [chartPoints]);
  const displayError = externalError || error;
  const isEmpty = !loading && !displayError && (!hasOracle || (chartPoints.length === 0 && chartCandles.length === 0));

  useEffect(() => {
    if (loading || isEmpty || !containerRef.current) return undefined;

    let cancelled = false;
    setError(false);
    setChartReady(false);

    void import('lightweight-charts')
      .then((mod) => {
        if (cancelled || !containerRef.current) return;
        moduleRef.current = mod;
        chartRef.current = createChartApi(mod, containerRef.current);
        resizeObserverRef.current = new ResizeObserver(() => {
          if (!containerRef.current || !chartRef.current) return;
          chartRef.current.applyOptions({
            width: containerRef.current.clientWidth,
            height: containerRef.current.clientHeight,
          });
        });
        resizeObserverRef.current.observe(containerRef.current);
        setChartReady(true);
      })
      .catch(() => {
        if (!cancelled) setError(true);
      });

    return () => {
      cancelled = true;
      resizeObserverRef.current?.disconnect();
      resizeObserverRef.current = null;
      oracleLineRef.current = null;
      liquidationLineRef.current = null;
      volumeSeriesRef.current = null;
      seriesRef.current = null;
      seriesModeRef.current = null;
      chartRef.current?.remove();
      chartRef.current = null;
      setChartReady(false);
    };
  }, [isEmpty, loading, retryKey]);

  useEffect(() => {
    const mod = moduleRef.current;
    const chart = chartRef.current;
    if (!chartReady || !mod || !chart || displayError) return;

    const mode = validCandles.length > 0 ? 'candles' : 'line';
    if (!seriesRef.current || seriesModeRef.current !== mode) {
      seriesRef.current = createDataSeries(mod, chart, mode, pricePrecision);
      seriesModeRef.current = mode;
    }

    if (mode === 'candles') {
      (seriesRef.current as CandlestickSeriesApi).setData(validCandles);
      const volumePoints = normalizeVolume(chartCandles, token('--color-border-strong'), token('--color-muted'));
      if (volumePoints.length > 0) {
        const volumeSeries = volumeSeriesRef.current ?? createVolumeSeries(mod, chart);
        volumeSeriesRef.current = volumeSeries;
        volumeSeries.setData(volumePoints);
      }
    } else {
      (seriesRef.current as LineSeriesApi).setData(validPoints);
    }

    if (validCandles.length > 0 || validPoints.length > 0) {
      chart.timeScale().fitContent();
    }
  }, [chartCandles, chartReady, displayError, pricePrecision, validCandles, validPoints]);

  useEffect(() => {
    const mod = moduleRef.current;
    const series = seriesRef.current;
    if (!chartReady || !mod || !series || displayError) return;

    const oracle = toChartNumber(oraclePrice);
    if (oracleLineRef.current) {
      series.removePriceLine(oracleLineRef.current);
      oracleLineRef.current = null;
    }
    if (oracle !== null) {
      oracleLineRef.current = series.createPriceLine({
        price: oracle,
        color: token('--color-primary'),
        lineWidth: 2,
        lineStyle: mod.LineStyle.Solid,
        axisLabelVisible: true,
        title: labels.oraclePrice,
      });
    }

    const liquidation = liquidationPrice ? toChartNumber(liquidationPrice) : null;
    if (liquidationLineRef.current) {
      series.removePriceLine(liquidationLineRef.current);
      liquidationLineRef.current = null;
    }
    if (liquidation !== null) {
      liquidationLineRef.current = series.createPriceLine({
        price: liquidation,
        color: token('--color-down'),
        lineWidth: 2,
        lineStyle: mod.LineStyle.Dashed,
        axisLabelVisible: true,
        title: labels.liquidationPrice,
      });
    }
  }, [chartReady, displayError, labels.liquidationPrice, labels.oraclePrice, liquidationPrice, oraclePrice]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    if (isApproachingLiquidation(oraclePrice, liquidationPrice, approachThreshold)) {
      container.dataset['approachingLiquidation'] = 'true';
    } else {
      delete container.dataset['approachingLiquidation'];
    }
  }, [approachThreshold, liquidationPrice, oraclePrice]);

  return (
    <Card
      ref={ref}
      className={cn('flex min-h-[320px] flex-col gap-3 p-4', className)}
      data-testid="trading-chart"
      {...props}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-[1.05rem] font-bold text-fg">{title}</h3>
          {subtitle && <p className="mt-1 text-xs text-muted">{subtitle}</p>}
          {disclosure && <p className="mt-1 text-xs text-warning">{disclosure}</p>}
        </div>
      </div>

      {loading && (
        <div className="grid flex-1 gap-3" data-testid="trading-chart-loading">
          <Skeleton className="h-[220px] w-full" />
          <p className="text-xs text-muted">{labels.loading}</p>
        </div>
      )}

      {!loading && isEmpty && (
        <div
          className="flex flex-1 flex-col items-center justify-center rounded-2xl border border-border bg-surface-2/40 p-6 text-center"
          data-testid="trading-chart-empty"
        >
          <p className="font-semibold text-fg">{labels.emptyTitle}</p>
          {labels.emptyDescription && <p className="mt-2 text-sm text-muted">{labels.emptyDescription}</p>}
        </div>
      )}

      {!loading && displayError && (
        <div
          className="flex flex-1 flex-col items-center justify-center rounded-2xl border border-down/40 bg-down/10 p-6 text-center"
          role="alert"
          data-testid="trading-chart-error"
        >
          <p className="font-semibold text-fg">{labels.errorTitle}</p>
          {labels.errorDescription && <p className="mt-2 text-sm text-muted">{labels.errorDescription}</p>}
          {labels.retry && (
            <Button
              className="mt-4"
              size="sm"
              variant="danger"
              onClick={() => {
                setRetryKey((value) => value + 1);
                onRetry?.();
              }}
            >
              {labels.retry}
            </Button>
          )}
        </div>
      )}

      {!loading && !isEmpty && !displayError && (
        <div
          ref={containerRef}
          className="relative min-h-[240px] flex-1 overflow-hidden rounded-2xl border border-border bg-surface [&[data-approaching-liquidation='true']]:animate-pulse [&[data-approaching-liquidation='true']]:border-down/70"
          data-testid="trading-chart-success"
        />
      )}
    </Card>
  );
});

TradingChart.displayName = 'TradingChart';
