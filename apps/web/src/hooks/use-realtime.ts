import { useEffect, useRef } from 'react';
import { useQueryClient, type QueryKey } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

type PostgresEvent = 'INSERT' | 'UPDATE' | 'DELETE' | '*';

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
}: UseRealtimeOptions): void {
  const qc = useQueryClient();
  const onChangeRef = useRef(onChange);
  const invalidateRef = useRef(invalidate);

  useEffect(() => {
    onChangeRef.current = onChange;
    invalidateRef.current = invalidate;
  }, [onChange, invalidate]);

  useEffect(() => {
    if (!enabled) return;

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
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
    // Callback refs keep side effects fresh without resubscribe churn.
  }, [qc, table, filter, event, enabled]);
}
