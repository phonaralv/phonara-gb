import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Tables } from '@phonara/shared-types';

type AuditLog = Tables<'audit_logs'>;

export function useAuditLogs(limit = 50) {
  return useQuery({
    queryKey: ['audit-logs', limit],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('audit_logs')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(limit);
      if (error) throw error;
      return (data ?? []) as AuditLog[];
    },
    staleTime: 15_000,
    refetchInterval: 30_000,
  });
}
