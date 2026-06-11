import { useEffect, useRef, useState } from 'react';
import { useQueryClient, type QueryKey } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

type PostgresEvent = 'INSERT' | 'UPDATE' | 'DELETE' | '*';
export type RealtimeConnectionStatus = 'disabled' | 'connecting' | 'subscribed' | 'closed' | 'channel_error' | 'timed_out';

export interface UseRealtimeResult {
  status: RealtimeConnectionStatus;
  connected: boolean;
}

interface UseRealtimeOptions {
  /** Public table name to subscribe to. */
  table: string;
  /** PostgREST filter, e.g. `user_id=eq.<uuid>`. */
  filter?: string;
  event?: PostgresEvent;
  /** Query keys to invalidate when a change arrives. */
  invalidate?: QueryKey[];
  /** Imperative side effect on each change. */
  onChange?: (payload: unknown) => void;
  /** Disable the subscription (e.g. while unauthenticated). */
  enabled?: boolean;
}

/**
 * Subscribe to Supabase Realtime postgres_changes and invalidate the given
 * query keys on each event. Re-subscribes only when the channel identity
 * (table/filter/event/enabled) changes — callbacks are read via latest closure.
 */
export function useRealtime({
  table,
  filter,
  event = '*',
  invalidate,
  onChange,
  enabled = true,
}: UseRealtimeOptions): UseRealtimeResult {
  const qc = useQueryClient();
  const onChangeRef = useRef(onChange);
  const invalidateRef = useRef(invalidate);
  const [status, setStatus] = useState<RealtimeConnectionStatus>(enabled ? 'connecting' : 'disabled');

  useEffect(() => {
    onChangeRef.current = onChange;
    invalidateRef.current = invalidate;
  }, [onChange, invalidate]);

  useEffect(() => {
    if (!enabled) {
      setStatus('disabled');
      return;
    }

    setStatus('connecting');

    const channel = supabase
      .channel(`rt:${table}:${filter ?? 'all'}:${event}`)
      .on(
        'postgres_changes',
        { event, schema: 'public', table, ...(filter ? { filter } : {}) } as never,
        (payload: unknown) => {
          onChangeRef.current?.(payload);
          invalidateRef.current?.forEach((key) => {
            void qc.invalidateQueries({ queryKey: key });
          });
        },
      )
      .subscribe((nextStatus) => {
        if (nextStatus === 'SUBSCRIBED') setStatus('subscribed');
        else if (nextStatus === 'CHANNEL_ERROR') setStatus('channel_error');
        else if (nextStatus === 'TIMED_OUT') setStatus('timed_out');
        else if (nextStatus === 'CLOSED') setStatus('closed');
      });

    return () => {
      void supabase.removeChannel(channel);
    };
    // Callback refs keep side effects fresh without resubscribe churn.
  }, [qc, table, filter, event, enabled]);

  return { status, connected: status === 'subscribed' };
}
