import { useQuery } from '@tanstack/react-query';
import { useAuth } from '../contexts/auth-context';
import { supabase } from '../lib/supabase';

export function useIsAdmin() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;

  const { data: isAdmin = false, isLoading } = useQuery({
    queryKey: ['admin-check', userId],
    queryFn: async () => {
      const { data } = await supabase
        .from('profiles')
        .select('role')
        .eq('id', userId!)
        .single();
      return data?.role === 'admin';
    },
    enabled: !!userId,
    staleTime: 60_000,
  });

  return { isAdmin, loading: isLoading && !!userId };
}
