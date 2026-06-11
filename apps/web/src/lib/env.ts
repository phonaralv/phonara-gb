import { z } from 'zod';

// Fail-closed client environment validation. If any required value is missing or
// malformed — or if a service_role key is ever pasted into the anon slot — the
// app throws at module load instead of silently booting with a broken/unsafe
// Supabase client.

function looksLikeServiceRoleKey(key: string): boolean {
  // Legacy Supabase keys are JWTs: header.payload.signature (base64url).
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
  VITE_VAPID_PUBLIC_KEY: z.string().min(1).optional(),
});

const parsed = envSchema.safeParse({
  VITE_SUPABASE_URL: import.meta.env['VITE_SUPABASE_URL'],
  VITE_SUPABASE_ANON_KEY: import.meta.env['VITE_SUPABASE_ANON_KEY'],
  VITE_VAPID_PUBLIC_KEY: import.meta.env['VITE_VAPID_PUBLIC_KEY'],
});

if (!parsed.success) {
  const detail = parsed.error.issues
    .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
    .join('; ');
  throw new Error(`Invalid client environment configuration — ${detail}`);
}

export const env = parsed.data;
