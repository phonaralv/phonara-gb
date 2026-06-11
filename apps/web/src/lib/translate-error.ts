import type { MessageKey } from '@phonara/i18n';

// Single source of truth that maps stable backend error codes (the strings our
// SQL RPCs `RAISE EXCEPTION` with, plus engine TradingError codes) to i18n keys.
// Ordered most-specific-first because matching is substring-based: e.g.
// `invalid_margin_currency` must be tested before `invalid_margin`.
const ERROR_KEY_MAP: ReadonlyArray<readonly [string, MessageKey]> = [
  ['unauthenticated', 'error.UNAUTHENTICATED'],
  ['rate_limit_exceeded', 'error.RATE_LIMITED'],
  ['consent_required', 'error.CONSENT_REQUIRED'],
  ['system_halted', 'error.SYSTEM_HALTED'],
  ['system_readonly', 'error.SYSTEM_HALTED'],
  ['feature_disabled', 'error.FEATURE_DISABLED'],
  ['market_halted', 'error.MARKET_HALTED'],
  ['stale_price', 'error.NO_PRICE'],
  ['no_price', 'error.NO_PRICE'],
  ['insufficient_available', 'error.INSUFFICIENT_BALANCE'],
  ['insufficient_locked', 'error.INSUFFICIENT_LOCKED'],
  ['invalid_margin_currency', 'error.INVALID_INPUT'],
  ['invalid_margin', 'error.INVALID_MARGIN'],
  ['invalid_leverage', 'error.INVALID_LEVERAGE'],
  ['leverage_too_high', 'error.LEVERAGE_TOO_HIGH'],
  ['position_limit', 'error.POSITION_LIMIT'],
  ['market_oi_cap', 'error.MARKET_OI_CAP'],
  ['duplicate_request', 'error.DUPLICATE_REQUEST'],
  ['invalid_amount', 'error.INVALID_AMOUNT'],
  ['invalid_side', 'error.INVALID_INPUT'],
  ['invalid_price', 'error.INVALID_INPUT'],
  ['not_liquidatable', 'error.NOT_LIQUIDATABLE'],
  ['still_locked', 'error.STILL_LOCKED'],
  ['position_not_found', 'error.POSITION_NOT_FOUND'],
  ['position_not_open', 'error.POSITION_NOT_OPEN'],
  ['market_not_found', 'error.INVALID_INPUT'],
  ['pool_not_found', 'error.INVALID_INPUT'],
  ['already_claimed', 'error.ALREADY_CLAIMED'],
  ['forbidden', 'error.FORBIDDEN'],
  ['house_exposure_cap', 'error.HOUSE_EXPOSURE_CAP'],
  ['stake_out_of_range', 'error.STAKE_OUT_OF_RANGE'],
  ['kyc_insufficient', 'error.KYC_INSUFFICIENT'],
  ['sanctions_blocked', 'error.SANCTIONS_BLOCKED'],
  ['sanctions_pending', 'error.SANCTIONS_PENDING'],
  ['sanctions_stale', 'error.SANCTIONS_PENDING'],
  ['withdrawal_solvency_hold', 'error.WITHDRAWAL_SOLVENCY_HOLD'],
  ['account_activity_frozen', 'error.ACCOUNT_ACTIVITY_FROZEN'],
  ['duplicate_transfer_id', 'error.DUPLICATE_REQUEST'],
];

/**
 * Maps an unknown thrown value (Supabase PostgrestError, Error, TradingError, ...)
 * to a stable, translatable MessageKey. Unrecognized errors return `fallback`
 * (default `error.UNKNOWN`) so the UI never leaks a raw SQL/stack string.
 */
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
