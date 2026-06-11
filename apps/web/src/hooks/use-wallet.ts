import { useCallback } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Tables } from '@phonara/shared-types';
import type { MessageKey } from '@phonara/i18n';
import { useAuth } from '../contexts/auth-context';
import { useRealtime } from './use-realtime';
import { translateError } from '../lib/translate-error';

type Wallet = Tables<'wallets'>;
type LedgerEntry = Tables<'wallet_ledger'>;

// ─── Query keys ────────────────────────────────────────────────

export const walletKeys = {
  all: (userId: string | null) => ['wallet', userId] as const,
  ledger: (userId: string | null, limit: number) => ['ledger', userId, limit] as const,
};

// ─── Wallet ────────────────────────────────────────────────────

export function useWallet() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;

  const { data: wallet = null, isLoading: loading, error: rawError } = useQuery({
    queryKey: walletKeys.all(userId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('wallets')
        .select('*')
        .eq('user_id', userId!)
        .single();
      if (error) throw error;
      return data as Wallet;
    },
    enabled: !!userId,
  });

  useRealtime({
    table: 'wallets',
    filter: userId ? `user_id=eq.${userId}` : undefined,
    invalidate: [walletKeys.all(userId)],
    enabled: !!userId,
  });

  const error: MessageKey | null = rawError ? translateError(rawError) : null;
  return { wallet, loading, error };
}

// ─── Ledger ────────────────────────────────────────────────────

export function useLedger(limit = 30) {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const qc = useQueryClient();

  const { data: entries = [], isLoading: loading, error: rawError, refetch } = useQuery({
    queryKey: walletKeys.ledger(userId, limit),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('wallet_ledger')
        .select('*')
        .eq('user_id', userId!)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as LedgerEntry[];
    },
    enabled: !!userId,
  });

  useRealtime({
    table: 'wallet_ledger',
    filter: userId ? `user_id=eq.${userId}` : undefined,
    invalidate: [walletKeys.ledger(userId, limit)],
    enabled: !!userId,
  });

  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: walletKeys.ledger(userId, limit) });
  }, [qc, userId, limit]);

  const error: MessageKey | null = rawError ? translateError(rawError) : null;
  return { entries, loading, error, refetch, refresh };
}
