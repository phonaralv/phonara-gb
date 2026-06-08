export * from './database.types';

export const currencies = ['PHON', 'USDT', 'KRW'] as const;

export type Currency = (typeof currencies)[number];

export type LocaleCode = 'ko' | 'en' | 'ja' | 'vi' | 'th';

export type UserRole = 'user' | 'admin';

export type AdminRole = 'owner' | 'finance' | 'risk' | 'support' | 'operator' | 'viewer';

export type LedgerDirection = 'credit' | 'debit' | 'lock' | 'unlock' | 'reverse';

export interface IdempotentCommand {
  readonly idempotencyKey: string;
}
