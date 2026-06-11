import { supabase } from './supabase';

export async function sendMagicLink(email: string): Promise<{ error: string | null }> {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: `${window.location.origin}/dashboard`,
    },
  });
  return { error: error?.message ?? null };
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}

export async function getSession() {
  const { data } = await supabase.auth.getSession();
  return data.session;
}

// ─── Email + password auth ──────────────────────────────────────────────────
// Password auth is the primary path (familiar for all users); Magic Link above
// stays as the secondary passwordless option. All helpers below return a typed
// AuthResult so routes never render raw provider error strings — they map a
// stable `code` to an i18n message instead.

export type AuthStatus =
  | 'verify_email'
  | 'magic_link_sent'
  | 'reset_sent'
  | 'password_updated';

export type AuthErrorCode =
  | 'invalidCredentials'
  | 'emailInvalid'
  | 'passwordTooShort'
  | 'network'
  | 'generic';

export type AuthResult =
  | { ok: true; status?: AuthStatus }
  | { ok: false; code: AuthErrorCode };

function mapSupabaseError(error: unknown): AuthErrorCode {
  if (error instanceof TypeError) return 'network';
  const message =
    typeof error === 'object' && error !== null && 'message' in error
      ? String((error as { message: unknown }).message ?? '')
      : '';
  const lower = message.toLowerCase();
  if (
    lower.includes('invalid login credentials') ||
    lower.includes('invalid_grant') ||
    lower.includes('invalid email or password')
  ) {
    return 'invalidCredentials';
  }
  if (lower.includes('email') && (lower.includes('invalid') || lower.includes('valid'))) {
    return 'emailInvalid';
  }
  if (lower.includes('password') && (lower.includes('short') || lower.includes('6 characters'))) {
    return 'passwordTooShort';
  }
  if (lower.includes('network') || lower.includes('fetch') || lower.includes('failed to fetch')) {
    return 'network';
  }
  return 'generic';
}

function dashboardRedirect(): string | undefined {
  return typeof window !== 'undefined' ? `${window.location.origin}/dashboard` : undefined;
}

function resetRedirect(): string | undefined {
  return typeof window !== 'undefined' ? `${window.location.origin}/reset-password` : undefined;
}

export async function signInWithPassword(email: string, password: string): Promise<AuthResult> {
  try {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return { ok: false, code: mapSupabaseError(error) };
    return { ok: true };
  } catch (error) {
    return { ok: false, code: mapSupabaseError(error) };
  }
}

export async function signUpWithPassword(email: string, password: string): Promise<AuthResult> {
  try {
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: dashboardRedirect() },
    });
    if (error) return { ok: false, code: mapSupabaseError(error) };
    // When email confirmation is required Supabase returns no session — show the
    // verify-email state. When confirmation is disabled a session is returned
    // immediately and the caller can route straight to the dashboard.
    if (data.session) return { ok: true };
    return { ok: true, status: 'verify_email' };
  } catch (error) {
    return { ok: false, code: mapSupabaseError(error) };
  }
}

export async function sendPasswordReset(email: string): Promise<AuthResult> {
  try {
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: resetRedirect(),
    });
    if (error) return { ok: false, code: mapSupabaseError(error) };
    return { ok: true, status: 'reset_sent' };
  } catch (error) {
    return { ok: false, code: mapSupabaseError(error) };
  }
}

export async function updatePassword(password: string): Promise<AuthResult> {
  try {
    const { error } = await supabase.auth.updateUser({ password });
    if (error) return { ok: false, code: mapSupabaseError(error) };
    return { ok: true, status: 'password_updated' };
  } catch (error) {
    return { ok: false, code: mapSupabaseError(error) };
  }
}
