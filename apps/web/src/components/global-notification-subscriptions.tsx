import { useCallback, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import Decimal from 'decimal.js';
import { useAuth } from '../contexts/auth-context';
import { useT } from '../lib/i18n';
import { supabase } from '../lib/supabase';
import { useRealtime } from '../hooks/use-realtime';
import { useFuturesPositions, tradingKeys } from '../hooks/use-trading';
import {
  positionStatusRef,
  priceRef,
  useNotificationStore,
} from '../stores/notifications';

function compareDecimal(left: string, right: string): number | null {
  try {
    const a = new Decimal(left);
    const b = new Decimal(right);
    if (!a.isFinite() || !b.isFinite()) return null;
    return a.cmp(b);
  } catch {
    return null;
  }
}

/**
 * App-wide realtime notification subscriptions. Mounted from __root so alerts
 * fire on any route, not only /trade.
 */
export function GlobalNotificationSubscriptions() {
  const t = useT();
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const priceAlert = useNotificationStore((s) => s.priceAlert);
  const emitNotification = useNotificationStore((s) => s.emitNotification);
  const markPriceAlertTriggered = useNotificationStore((s) => s.markPriceAlertTriggered);
  const seedPositionBaselines = useNotificationStore((s) => s.seedPositionBaselines);
  const resetBaselinesForUser = useNotificationStore((s) => s.resetBaselinesForUser);
  const { positions } = useFuturesPositions();
  const priceAlertSymbol = priceAlert?.symbol ?? null;

  const { data: fallbackPrice } = useQuery({
    queryKey: ['global-price-alert-price', priceAlertSymbol],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('oracle_prices')
        .select('symbol,price')
        .eq('symbol', priceAlertSymbol!)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    enabled: !!priceAlert?.enabled && !!priceAlertSymbol,
    refetchInterval: 3_000,
    staleTime: 1_000,
  });

  useEffect(() => {
    resetBaselinesForUser();
  }, [resetBaselinesForUser, userId]);

  useEffect(() => {
    if (!userId) return;
    seedPositionBaselines(positions);
  }, [positions, seedPositionBaselines, userId]);

  const handlePriceAlertChange = useCallback((row: { symbol?: string; price?: string }): void => {
    if (!row.symbol || !row.price) return;
    const previous = priceRef.current.get(row.symbol);
    priceRef.current.set(row.symbol, row.price);
    if (!priceAlert?.enabled || priceAlert.triggered || priceAlert.symbol !== row.symbol) return;

    const currentCompare = compareDecimal(row.price, priceAlert.target);
    if (currentCompare === null) return;
    const previousCompare = previous ? compareDecimal(previous, priceAlert.target) : null;
    const crossedAbove = priceAlert.direction === 'above'
      && currentCompare >= 0
      && (previousCompare === null || previousCompare < 0);
    const crossedBelow = priceAlert.direction === 'below'
      && currentCompare <= 0
      && (previousCompare === null || previousCompare > 0);
    if (!crossedAbove && !crossedBelow) return;

    markPriceAlertTriggered(row.symbol);
    emitNotification({
      id: `price:${row.symbol}:${priceAlert.direction}:${priceAlert.target}`,
      tone: 'warning',
      title: t('notif.priceAlert.title'),
      body: t('notif.priceAlert.body', {
        symbol: row.symbol,
        price: row.price,
        target: priceAlert.target,
      }),
    });
  }, [emitNotification, markPriceAlertTriggered, priceAlert, t]);

  useEffect(() => {
    if (fallbackPrice) handlePriceAlertChange(fallbackPrice);
  }, [fallbackPrice, handlePriceAlertChange]);

  useRealtime({
    table: 'futures_positions',
    filter: userId ? `user_id=eq.${userId}` : undefined,
    event: '*',
    enabled: !!userId,
    invalidate: [tradingKeys.futuresPositions(userId)],
    onChange: (payload: unknown) => {
      const row = (payload as { new?: { id?: string; status?: string; market?: string } }).new;
      if (!row?.id || !row.status) return;
      const previous = positionStatusRef.current.get(row.id);
      if (previous === row.status) return;
      positionStatusRef.current.set(row.id, row.status);
      if (!previous) return;

      if (row.status === 'liquidated') {
        emitNotification({
          id: `position:${row.id}:liquidated`,
          tone: 'danger',
          title: t('notif.liquidated.title'),
          body: t('notif.liquidated.body', { market: row.market ?? '' }),
        });
      } else if (row.status === 'closed') {
        emitNotification({
          id: `position:${row.id}:closed`,
          tone: 'success',
          title: t('notif.closed.title'),
          body: t('notif.closed.body', { market: row.market ?? '' }),
        });
      }
    },
  });

  useRealtime({
    table: 'oracle_prices',
    event: 'UPDATE',
    enabled: !!priceAlert?.enabled,
    onChange: (payload: unknown) => {
      const row = (payload as { new?: { symbol?: string; price?: string } }).new;
      if (row) handlePriceAlertChange(row);
    },
  });

  return null;
}
