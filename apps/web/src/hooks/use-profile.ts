import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { Tables } from '@phonara/shared-types';
import { useAuth } from '../contexts/auth-context';

type Profile = Tables<'profiles'>;

export function useProfile() {
  const { session } = useAuth();
  const userId = session?.user.id ?? null;

  const { data: profile = null, isLoading: loading } = useQuery({
    queryKey: ['profile', userId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', userId!)
        .single();
      if (error) throw error;
      return data as Profile;
    },
    enabled: !!userId,
  });

  return { profile, loading, kycVerified: profile?.kyc_tier === 'id_verified' };
}
