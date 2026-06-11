import { createClient } from '@supabase/supabase-js';
import type { Database } from '@phonara/shared-types';
import { env } from './env';

export const supabase = createClient<Database>(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
  },
});
