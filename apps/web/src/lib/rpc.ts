import { supabase } from './supabase';
import type { Database } from '@phonara/shared-types';

export type RpcName = keyof Database['public']['Functions'];
export type RpcArgs<N extends RpcName> = Database['public']['Functions'][N]['Args'];
export type RpcReturns<N extends RpcName> = Database['public']['Functions'][N]['Returns'];

/**
 * Stable error codes our SECURITY DEFINER RPCs RAISE. The DB never returns a
 * raw SQL error to clients for these — they are translated to i18n keys
 * (`error.<CODE>`) in the UI layer.
 */
export const RPC_ERROR_CODES = [
  'UNAUTHENTICATED',
  'FORBIDDEN',
  'INSUFFICIENT_BALANCE',
  'RATE_LIMITED',
  'CONSENT_REQUIRED',
  'MARKET_HALTED',
  'SYSTEM_HALTED',
  'ALREADY_CLAIMED',
  'INVALID_AMOUNT',
  'INVALID_INPUT',
  'POSITION_NOT_FOUND',
] as const;

export type RpcErrorCode = (typeof RPC_ERROR_CODES)[number] | 'UNKNOWN';

const KNOWN = new Set<string>(RPC_ERROR_CODES);

function parseErrorCode(message: string): RpcErrorCode {
  const head = message.trim().split(/[\s:]/)[0] ?? '';
  if (KNOWN.has(head)) return head as RpcErrorCode;
  for (const code of RPC_ERROR_CODES) {
    if (message.includes(code)) return code;
  }
  return 'UNKNOWN';
}

export class RpcError extends Error {
  readonly code: RpcErrorCode;
  readonly raw: unknown;
  constructor(code: RpcErrorCode, message: string, raw?: unknown) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.raw = raw;
  }
  /** i18n key for user-facing copy. */
  get i18nKey(): `error.${RpcErrorCode}` {
    return `error.${this.code}`;
  }
}

/**
 * Single typed entry point for every PostgREST RPC. Maps the DB exception
 * message to a stable {@link RpcErrorCode} so the UI can translate it without
 * leaking raw SQL strings to the user.
 */
export async function callRpc<N extends RpcName>(fn: N, args: RpcArgs<N>): Promise<RpcReturns<N>> {
  const { data, error } = await supabase.rpc(fn, args as never);
  if (error) {
    throw new RpcError(parseErrorCode(error.message), error.message, error);
  }
  return data as RpcReturns<N>;
}
