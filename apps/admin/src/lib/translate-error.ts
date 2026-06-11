import type { MessageKey } from '@phonara/i18n';

const ERROR_KEY_MAP: ReadonlyArray<readonly [string, MessageKey]> = [
  ['unauthenticated', 'error.UNAUTHENTICATED'],
  ['feature_disabled', 'error.FEATURE_DISABLED'],
  ['self_approval_forbidden', 'error.SELF_APPROVAL_FORBIDDEN'],
  ['deposit_request_not_pending', 'error.DEPOSIT_REQUEST_NOT_PENDING'],
  ['forbidden', 'error.FORBIDDEN'],
  ['reason_required', 'error.INVALID_INPUT'],
  ['append_only_violation', 'error.FORBIDDEN'],
];

export function translateError(err: unknown, fallback: MessageKey = 'error.UNKNOWN'): MessageKey {
  const raw = err instanceof Error
    ? err.message
    : typeof err === 'object' && err !== null
      ? [
        'message' in err ? String(err.message) : '',
        'details' in err ? String(err.details) : '',
        'hint' in err ? String(err.hint) : '',
        'code' in err ? String(err.code) : '',
      ].join(' ')
      : String(err);
  const msg = raw.toLowerCase();
  for (const [needle, key] of ERROR_KEY_MAP) {
    if (msg.includes(needle)) return key;
  }
  return fallback;
}
