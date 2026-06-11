import { z } from 'zod';

function looksLikeServiceRoleKey(key: string): boolean {
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  const payload = parts[1];
  if (!payload) return false;
  try {
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    const claims = JSON.parse(json) as { role?: string };
    return claims.role === 'service_role';
  } catch {
    return false;
  }
}

const envSchema = z.object({
  VITE_SUPABASE_URL: z.string().url('VITE_SUPABASE_URL must be a valid URL'),
  VITE_SUPABASE_ANON_KEY: z
    .string()
    .min(1, 'VITE_SUPABASE_ANON_KEY is required')
    .refine(
      (key) => !looksLikeServiceRoleKey(key),
      'VITE_SUPABASE_ANON_KEY must not be a service_role key (server-only secret)',
    ),
});

const parsed = envSchema.safeParse({
  VITE_SUPABASE_URL: import.meta.env['VITE_SUPABASE_URL'],
  VITE_SUPABASE_ANON_KEY: import.meta.env['VITE_SUPABASE_ANON_KEY'],
});

if (!parsed.success) {
  const detail = parsed.error.issues
    .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
    .join('; ');
  throw new Error(`Invalid admin environment configuration — ${detail}`);
}

export const env = parsed.data;
