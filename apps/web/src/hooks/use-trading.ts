import { useState, useCallback, useRef } from 'react';
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Tables } from '@phonara/shared-types';
import type { MessageKey } from '@phonara/i18n';
import { useAuth } from '../contexts/auth-context';
import { useRealtime } from './use-realtime';
import { translateError } from '../lib/translate-error';

// Stable id for a single user intent. Rapid double-clicks share the same id
// (the ref is held while a submit is in-flight) so the server dedups both the
// client-side double tap and any cross-tab/network race into one entity.
function newRequestId(): string {
  const c = globalThis.crypto;
  return c?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export type FuturesPosition = Tables<'futures_positions'>;
export type FuturesMarket = Tables<'futures_markets'>;
export type SpotMarket = Tables<'spot_markets'>;
export type StakingPosition = Tables<'staking_positions'>;
export type StakingPool = Tables<'staking_pools'>;
export type OraclePrice = Tables<'oracle_prices'>;

export interface TradingCandle {
  time: number;
  open: string;
  high: string;
  low: string;
  close: string;
  volume: string | null;
}

export interface SyntheticBookLevel {
  price: string;
  size: string;
}

export interface SyntheticBook {
  symbol: string;
  mid: string;
  asks: SyntheticBookLevel[];
  bids: SyntheticBookLevel[];
  disclosure: string;
}

// ─── Query keys ────────────────────────────────────────────────

export const tradingKeys = {
  futuresMarkets: () => ['futures-markets'] as const,
  spotMarkets: () => ['spot-markets'] as const,
  candles: (symbol: string | null, interval: string) => ['candles', symbol, interval] as const,
  syntheticBook: (symbol: string | null) => ['synthetic-book', symbol] as const,
  prices: () => ['prices'] as const,
  futuresPositions: (userId: string | null) => ['futures-positions', userId] as const,
  tradingRiskAcknowledgement: (userId: string | null) => ['trading-risk-acknowledgement', userId] as const,
  stakingPools: () => ['staking-pools'] as const,
  stakingPositions: (userId: string | null) => ['staking-positions', userId] as const,
};

// ─── Market metadata ───────────────────────────────────────────

export function useFuturesMarkets() {
  const { data: markets = [], isLoading: loading, isError, error, refetch } = useQuery({
    queryKey: tradingKeys.futuresMarkets(),
    queryFn: async () => {
      const { data, error: e } = await supabase
        .from('futures_markets')
        .select('*')
        .eq('is_active', true)
        .order('sort_order', { ascending: true });
      if (e) throw e;
      return (data ?? []) as FuturesMarket[];
    },
    staleTime: 5 * 60_000,
    placeholderData: keepPreviousData,
  });

  return { markets, loading, isError, error, refetch };
}

export function useSpotMarkets() {
  const { data: markets = [], isLoading: loading, isError, error, refetch } = useQuery({
    queryKey: tradingKeys.spotMarkets(),
    queryFn: async () => {
      const { data, error: e } = await supabase
        .from('spot_markets')
        .select('*')
        .eq('is_active', true)
        .order('sort_order', { ascending: true });
      if (e) throw e;
      return (data ?? []) as SpotMarket[];
    },
    staleTime: 5 * 60_000,
    placeholderData: keepPreviousData,
  });

  return { markets, loading, isError, error, refetch };
}

export function useCandles(symbol: string | null, interval = '1m') {
  const { data: candles = [], isLoading: loading, isError, error, refetch, isFetching } = useQuery({
    queryKey: tradingKeys.candles(symbol, interval),
    queryFn: async () => {
      const { data, error } = await supabase.rpc('rpc_get_candles', {
        p_symbol: symbol!,
        p_interval: interval,
        p_limit: 200,
      });
      if (error) throw error;
      return (data ?? []) as unknown as TradingCandle[];
    },
    enabled: !!symbol,
    refetchInterval: 30_000,
    staleTime: 10_000,
    placeholderData: keepPreviousData,
  });

  return { candles, loading, isError, error, refetch, isFetching };
}

export function useSyntheticBook(symbol: string | null) {
  const { data: book = null, isLoading: loading, error, refetch } = useQuery({
    queryKey: tradingKeys.syntheticBook(symbol),
    queryFn: async () => {
      const { data, error: e } = await supabase.rpc('rpc_get_synthetic_book', {
        p_symbol: symbol!,
        p_levels: undefined,
      });
      if (e) throw e;
      return data as unknown as SyntheticBook;
    },
    enabled: !!symbol,
    refetchInterval: 30_000,
    staleTime: 10_000,
    placeholderData: keepPreviousData,
  });

  return { book, loading, error, refetch };
}

// ─── Market prices ─────────────────────────────────────────────

export function usePrices() {
  const { data, isError, error, isFetching, dataUpdatedAt, refetch } = useQuery({
    queryKey: tradingKeys.prices(),
    queryFn: async () => {
      const { data, error: e } = await supabase.from('oracle_prices').select('symbol, price, updated_at');
      if (e) throw e;
      const prices: Record<string, string> = {};
      const updatedAt: Record<string, string> = {};
      for (const row of data ?? []) {
        prices[row.symbol] = row.price;
        updatedAt[row.symbol] = row.updated_at;
      }
      return { prices, updatedAt };
    },
    // Realtime invalidation is primary; polling is a slow fallback.
    refetchInterval: 30_000,
    staleTime: 10_000,
  });
  const prices = data?.prices ?? {};
  const oracleUpdatedAt = data?.updatedAt ?? {};
  const oldestOracleUpdate = Object.values(oracleUpdatedAt).reduce((oldest, value) => {
    const time = Date.parse(value);
    return Number.isFinite(time) ? Math.min(oldest, time) : oldest;
  }, Number.POSITIVE_INFINITY);
  const oracleStale = oldestOracleUpdate !== Number.POSITIVE_INFINITY && Date.now() - oldestOracleUpdate > 30_000;

  const qc = useQueryClient();
  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: tradingKeys.prices() });
  }, [qc]);

  useRealtime({
    table: 'oracle_prices',
    invalidate: [tradingKeys.prices()],
  });

  return { prices, refresh, isError, error, isFetching, dataUpdatedAt, refetch, oracleStale };
}

// ─── Futures positions ─────────────────────────────────────────

export function useFuturesPositions() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const qc = useQueryClient();

  const { data: positions = [], isLoading: loading, isError, error, isFetching, dataUpdatedAt, refetch } = useQuery({
    queryKey: tradingKeys.futuresPositions(userId),
    queryFn: async () => {
      const { data, error: e } = await supabase
        .from('futures_positions')
        .select('*')
        .eq('user_id', userId!)
        .order('opened_at', { ascending: false })
        .limit(50);
      if (e) throw e;
      return (data ?? []) as FuturesPosition[];
    },
    enabled: !!userId,
  });

  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: tradingKeys.futuresPositions(userId) });
  }, [qc, userId]);

  return { positions, loading, refresh, isError, error, isFetching, dataUpdatedAt, refetch };
}

// ─── Futures actions ───────────────────────────────────────────

export function useFuturesActions(onChange?: () => void) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<MessageKey | null>(null);
  const [lastResult, setLastResult] = useState<Record<string, unknown> | null>(null);
  const openIdRef = useRef<string | null>(null);

  const openPosition = useCallback(async (args: {
    market: string;
    side: 'long' | 'short';
    marginCurrency: 'PHON' | 'USDT';
    marginAmount: string;
    leverage: string;
  }) => {
    const reqId = openIdRef.current ?? (openIdRef.current = newRequestId());
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_open_futures_position', {
        p_market: args.market,
        p_side: args.side,
        p_margin_currency: args.marginCurrency,
        p_margin_amount: args.marginAmount,
        p_leverage: args.leverage,
        p_client_request_id: reqId,
      });
      if (e) throw e;
      setLastResult(data as Record<string, unknown>);
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) {
      setError(translateError(err));
      return null;
    } finally { setBusy(false); openIdRef.current = null; }
  }, [onChange]);

  const closePosition = useCallback(async (positionId: string) => {
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_close_futures_position', {
        p_position_id: positionId,
      });
      if (e) throw e;
      setLastResult(data as Record<string, unknown>);
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) {
      setError(translateError(err));
      return null;
    } finally { setBusy(false); }
  }, [onChange]);

  return { openPosition, closePosition, busy, error, lastResult };
}

export function useTradingRiskAcknowledgement() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<MessageKey | null>(null);

  const { data: acknowledged = false, isLoading: loading } = useQuery({
    queryKey: tradingKeys.tradingRiskAcknowledgement(userId),
    queryFn: async () => {
      const { data } = await supabase
        .from('user_consents')
        .select('accepted')
        .eq('user_id', userId!)
        .eq('doc_type', 'trading_risk_acknowledgement')
        .order('accepted_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      return data?.accepted === true;
    },
    enabled: !!userId,
    staleTime: 60_000,
  });

  const acknowledge = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const { error: e } = await supabase.rpc('rpc_record_consent', {
        p_doc_type: 'trading_risk_acknowledgement',
        p_doc_version: '1.0',
        p_accepted: true,
        p_ip_address: undefined,
        p_user_agent: globalThis.navigator?.userAgent,
        p_locale: globalThis.navigator?.language?.startsWith('ko') ? 'ko' : 'en',
      });
      if (e) throw e;
      await qc.invalidateQueries({ queryKey: tradingKeys.tradingRiskAcknowledgement(userId) });
      return true;
    } catch (err) {
      setError(translateError(err));
      return false;
    } finally {
      setBusy(false);
    }
  }, [qc, userId]);

  return { acknowledged, acknowledge, busy, error, loading };
}

// ─── Spot actions ──────────────────────────────────────────────

export function useSpotActions(onChange?: () => void) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<MessageKey | null>(null);
  const buyIdRef = useRef<string | null>(null);
  const sellIdRef = useRef<string | null>(null);

  const buy = useCallback(async (usdtSpent: string) => {
    const reqId = buyIdRef.current ?? (buyIdRef.current = newRequestId());
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_spot_market_buy', { p_usdt_spent: usdtSpent, p_client_request_id: reqId });
      if (e) throw e;
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) { setError(translateError(err)); return null; }
    finally { setBusy(false); buyIdRef.current = null; }
  }, [onChange]);

  const sell = useCallback(async (phonSold: string) => {
    const reqId = sellIdRef.current ?? (sellIdRef.current = newRequestId());
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_spot_market_sell', { p_phon_sold: phonSold, p_client_request_id: reqId });
      if (e) throw e;
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) { setError(translateError(err)); return null; }
    finally { setBusy(false); sellIdRef.current = null; }
  }, [onChange]);

  return { buy, sell, busy, error };
}

// ─── Staking ───────────────────────────────────────────────────

export function useStakingPools() {
  const { data: pools = [] } = useQuery({
    queryKey: tradingKeys.stakingPools(),
    queryFn: async () => {
      const { data } = await supabase
        .from('staking_pools')
        .select('*')
        .eq('is_active', true);
      return ((data ?? []) as StakingPool[]).sort((a, b) => a.lock_days - b.lock_days);
    },
    staleTime: 60_000,
  });
  return pools;
}

export function useStakingPositions() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const qc = useQueryClient();

  const { data: positions = [], isLoading: loading, isError, error, isFetching, dataUpdatedAt, refetch } = useQuery({
    queryKey: tradingKeys.stakingPositions(userId),
    queryFn: async () => {
      const { data, error: e } = await supabase
        .from('staking_positions')
        .select('*')
        .eq('user_id', userId!)
        .order('staked_at', { ascending: false });
      if (e) throw e;
      return (data ?? []) as StakingPosition[];
    },
    enabled: !!userId,
  });

  useRealtime({
    table: 'staking_positions',
    filter: userId ? `user_id=eq.${userId}` : undefined,
    invalidate: [tradingKeys.stakingPositions(userId)],
    enabled: !!userId,
  });

  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: tradingKeys.stakingPositions(userId) });
  }, [qc, userId]);

  return { positions, loading, refresh, isError, error, isFetching, dataUpdatedAt, refetch };
}

export function useStakingActions(onChange?: () => void) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<MessageKey | null>(null);
  const stakeIdRef = useRef<string | null>(null);

  const stake = useCallback(async (term: string, amount: string) => {
    const reqId = stakeIdRef.current ?? (stakeIdRef.current = newRequestId());
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_stake_phon', { p_term: term, p_amount: amount, p_client_request_id: reqId });
      if (e) throw e;
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) { setError(translateError(err)); return null; }
    finally { setBusy(false); stakeIdRef.current = null; }
  }, [onChange]);

  const unstake = useCallback(async (positionId: string) => {
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_unstake_phon', { p_position_id: positionId });
      if (e) throw e;
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) { setError(translateError(err)); return null; }
    finally { setBusy(false); }
  }, [onChange]);

  const claim = useCallback(async (positionId: string) => {
    setBusy(true); setError(null);
    try {
      const { data, error: e } = await supabase.rpc('rpc_claim_staking_reward', { p_position_id: positionId });
      if (e) throw e;
      onChange?.();
      return data as Record<string, unknown>;
    } catch (err) { setError(translateError(err)); return null; }
    finally { setBusy(false); }
  }, [onChange]);

  return { stake, unstake, claim, busy, error };
}

// ─── Error translation ─────────────────────────────────────────
// Maps a raw RPC exception to a stable i18n message key.
