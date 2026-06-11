import { memo, forwardRef, type HTMLAttributes } from 'react';
import { toDecimal } from '@phonara/money';
import { cn } from '../lib/cn';
import { Button } from './button';
import { Card } from './card';
import { Skeleton } from './skeleton';

export interface OrderBookLevel {
  price: string;
  size: string;
}

export interface OrderBookLabels {
  loading: string;
  emptyTitle: string;
  errorTitle: string;
  retry?: string;
  asks: string;
  bids: string;
  price: string;
  size: string;
}

export interface OrderBookProps extends HTMLAttributes<HTMLDivElement> {
  title: string;
  referenceLabel?: string;
  disclosure: string;
  labels: OrderBookLabels;
  asks: OrderBookLevel[];
  bids: OrderBookLevel[];
  loading?: boolean;
  error?: boolean;
  onRetry?: () => void;
}

function maxSize(levels: OrderBookLevel[]): string {
  return levels.reduce((max, level) => {
    try {
      const value = toDecimal(level.size);
      return value.greaterThan(max) ? value : max;
    } catch {
      return max;
    }
  }, toDecimal('0')).toString();
}

function depthPercent(size: string, max: string): string {
  try {
    const denominator = toDecimal(max);
    if (denominator.isZero()) return '0%';
    return `${toDecimal(size).div(denominator).mul(100).toFixed(2)}%`;
  } catch {
    return '0%';
  }
}

const Row = memo(function Row({
  level,
  max,
  tone,
}: {
  level: OrderBookLevel;
  max: string;
  tone: 'ask' | 'bid';
}) {
  return (
    <div className="relative grid grid-cols-2 overflow-hidden rounded-lg px-2 py-1.5 text-xs">
      <span
        className={cn(
          'absolute inset-y-0 right-0 opacity-20',
          tone === 'ask' ? 'bg-down' : 'bg-up',
        )}
        style={{ width: depthPercent(level.size, max) }}
      />
      <span className={cn('relative font-medium', tone === 'ask' ? 'text-down' : 'text-up')}>{level.price}</span>
      <span className="relative text-right text-fg">{level.size}</span>
    </div>
  );
});

export const OrderBook = forwardRef<HTMLDivElement, OrderBookProps>(function OrderBook(
  {
    title,
    referenceLabel,
    disclosure,
    labels,
    asks,
    bids,
    loading = false,
    error = false,
    onRetry,
    className,
    ...props
  },
  ref,
) {
  const isEmpty = !loading && !error && asks.length === 0 && bids.length === 0;
  const max = maxSize([...asks, ...bids]);

  return (
    <Card ref={ref} className={cn('flex flex-col gap-3 p-4', className)} data-testid="order-book" {...props}>
      <div>
        <div className="flex items-center gap-2">
          <h3 className="text-[1.05rem] font-bold text-fg">{title}</h3>
          {referenceLabel && (
            <span className="rounded-full border border-warning/40 bg-warning/10 px-2 py-0.5 text-[0.7rem] font-semibold text-warning">
              {referenceLabel}
            </span>
          )}
        </div>
        <p className="mt-1 text-xs leading-5 text-warning">{disclosure}</p>
      </div>

      {loading && (
        <div className="grid gap-2" data-testid="order-book-loading">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
        </div>
      )}

      {isEmpty && (
        <div className="rounded-2xl border border-border bg-surface-2/40 p-4 text-center" data-testid="order-book-empty">
          <p className="font-semibold text-fg">{labels.emptyTitle}</p>
        </div>
      )}

      {!loading && error && (
        <div className="rounded-2xl border border-down/40 bg-down/10 p-4 text-center" role="alert" data-testid="order-book-error">
          <p className="font-semibold text-fg">{labels.errorTitle}</p>
          {labels.retry && onRetry && (
            <Button className="mt-3" size="sm" variant="danger" onClick={onRetry}>
              {labels.retry}
            </Button>
          )}
        </div>
      )}

      {!loading && !error && !isEmpty && (
        <div className="grid gap-3" data-testid="order-book-success">
          <div>
            <div className="mb-1 grid grid-cols-2 px-2 text-[0.7rem] uppercase tracking-wide text-muted">
              <span>{labels.price}</span>
              <span className="text-right">{labels.size}</span>
            </div>
            <div className="grid gap-1" aria-label={labels.asks}>
              {asks.slice().reverse().map((level) => (
                <Row key={`ask-${level.price}`} level={level} max={max} tone="ask" />
              ))}
            </div>
          </div>
          <div className="h-px bg-border" />
          <div className="grid gap-1" aria-label={labels.bids}>
            {bids.map((level) => (
              <Row key={`bid-${level.price}`} level={level} max={max} tone="bid" />
            ))}
          </div>
        </div>
      )}
    </Card>
  );
});

OrderBook.displayName = 'OrderBook';
