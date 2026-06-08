export type GameCode = 'crash' | 'limbo' | 'dice' | 'mines' | 'hilo' | 'plinko';

export interface ProvablyFairDraft {
  readonly game: GameCode;
  readonly serverSeedHash: string;
  readonly clientSeed: string;
  readonly nonce: number;
}

export const gameEngineStatus = 'scaffold-only' as const;
