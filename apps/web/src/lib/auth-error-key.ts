import type { MessageKey } from '@phonara/i18n';
import type { AuthErrorCode } from './auth';

// Form-level validation codes that never reach Supabase, combined with the
// provider-mapped AuthErrorCode. Kept separate from AuthErrorCode because these
// are produced by client-side guards, not by the auth backend.
export type AuthFieldErrorCode =
  | AuthErrorCode
  | 'emailRequired'
  | 'emailInvalid'
  | 'passwordRequired'
  | 'passwordTooShort'
  | 'passwordMismatch';

// Explicit switch (never a template-string key) so the returned value stays a
// statically-checked MessageKey and missing catalog entries fail typecheck.
export function authErrorMessageKey(code: AuthFieldErrorCode): MessageKey {
  switch (code) {
    case 'invalidCredentials':
      return 'auth.entry.errors.invalidCredentials';
    case 'emailInvalid':
      return 'auth.entry.errors.emailInvalid';
    case 'passwordTooShort':
      return 'auth.entry.errors.passwordTooShort';
    case 'network':
      return 'auth.entry.errors.network';
    case 'generic':
      return 'auth.entry.errors.generic';
    case 'emailRequired':
      return 'auth.entry.errors.emailRequired';
    case 'passwordRequired':
      return 'auth.entry.errors.passwordRequired';
    case 'passwordMismatch':
      return 'auth.entry.errors.passwordMismatch';
  }
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function isValidEmail(email: string): boolean {
  return EMAIL_RE.test(email.trim());
}
