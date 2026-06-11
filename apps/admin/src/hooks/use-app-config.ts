import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

interface AppConfigRow {
  key: string;
  value: string;
  description: string;
  updated_at: string;
}

export function useAppConfig() {
  return useQuery({
    queryKey: ['app-config'],
    queryFn: async () => {
      const { data, error } = await supabase.from('app_config').select('*');
      if (error) throw error;
      const map: Record<string, string> = {};
      for (const row of (data ?? []) as AppConfigRow[]) {
        map[row.key] = row.value;
      }
      return map;
    },
    staleTime: 10_000,
    refetchInterval: 30_000,
  });
}

export function useRefreshConfig() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: ['app-config'] });
}
