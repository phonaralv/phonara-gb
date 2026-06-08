import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { Tables } from '@phonara/shared-types';

type Wallet = Tables<'wallets'>;
type LedgerEntry = Tables<'wallet_ledger'>;

export function useWallet() {
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    supabase.auth.getUser().then(async ({ data }) => {
      if (!data.user || cancelled) return;
      const { data: w, error: e } = await supabase
        .from('wallets')
        .select('*')
        .eq('user_id', data.user.id)
        .single();
      if (!cancelled) {
        if (e) setError(e.message);
        else setWallet(w);
        setLoading(false);
      }
    });
    return () => { cancelled = true; };
  }, []);

  return { wallet, loading, error };
}

export function useLedger(limit = 30) {
  const [entries, setEntries] = useState<LedgerEntry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    supabase.auth.getUser().then(async ({ data }) => {
      if (!data.user || cancelled) return;
      const { data: rows } = await supabase
        .from('wallet_ledger')
        .select('*')
        .eq('user_id', data.user.id)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (!cancelled) {
        setEntries(rows ?? []);
        setLoading(false);
      }
    });
    return () => { cancelled = true; };
  }, [limit]);

  return { entries, loading };
}
