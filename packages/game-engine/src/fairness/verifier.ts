import { hashServerSeed } from './seed';
import { floatStream } from './float';
import { crashDefinition } from '../games/crash';
import { diceDefinition } from '../games/dice';
import { hiloDefinition } from '../games/hilo';
import { limboDefinition } from '../games/limbo';
import { minesDefinition } from '../games/mines';
import { plinkoDefinition } from '../games/plinko';
import type { GameDefinition } from '../registry';

export type GameCode = 'crash' | 'limbo' | 'dice' | 'mines' | 'hilo' | 'plinko';

export interface VerifyInput {
  game: GameCode;
  serverSeed: string;
  serverSeedHash: string;
  clientSeed: string;
  nonce: number;
  /** Bet parameters used by the game-specific deterministic result function. */
  selection?: unknown;
  /** Expected result from DB (for assertion) */
  expectedResult?: Record<string, unknown>;
}

export interface VerifyResult {
  seedHashMatch: boolean;
  floats: number[];
  recomputedResult: unknown | null;
  /** True if expectedResult was provided and matched the recomputed result */
  resultMatch: boolean | null;
}

const GAME_DEFINITIONS: Record<GameCode, GameDefinition<unknown, unknown>> = {
  crash: crashDefinition as GameDefinition<unknown, unknown>,
  limbo: limboDefinition as GameDefinition<unknown, unknown>,
  dice: diceDefinition as GameDefinition<unknown, unknown>,
  mines: minesDefinition as GameDefinition<unknown, unknown>,
  hilo: hiloDefinition as GameDefinition<unknown, unknown>,
  plinko: plinkoDefinition as GameDefinition<unknown, unknown>,
};

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) =>
      a.localeCompare(b),
    );
    return `{${entries
      .map(([key, nested]) => `${JSON.stringify(key)}:${stableStringify(nested)}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export function recomputeResult(
  game: GameCode,
  floats: number[],
  selection: unknown,
): unknown {
  return GAME_DEFINITIONS[game].resultFromFloats(floats, selection);
}

/**
 * verifyRound — client-side provably-fair verification.
 *
 * Steps:
 *   1. Hash the revealed server seed and compare to committed hash.
 *   2. Re-derive the float stream from {serverSeed, clientSeed, nonce}.
 *   3. Optionally compare re-derived result to the stored result.
 *
 * This function is the same one used in the FairnessVerifier UI component and
 * can be embedded directly in the browser — zero external dependencies.
 */
export async function verifyRound(input: VerifyInput): Promise<VerifyResult> {
  const { serverSeed, serverSeedHash, clientSeed, nonce, game, expectedResult } = input;

  // 1. Verify hash commitment
  const computedHash = await hashServerSeed(serverSeed);
  const seedHashMatch = computedHash === serverSeedHash;

  // 2. Re-derive the full float stream required by the registered game.
  const floats = await floatStream(serverSeed, clientSeed, nonce, GAME_DEFINITIONS[game].floatCount);

  // 3. Recompute the deterministic game result and compare it with the stored result.
  const recomputedResult =
    input.selection === undefined ? null : recomputeResult(game, floats, input.selection);
  let resultMatch: boolean | null = null;
  if (expectedResult !== undefined && recomputedResult !== null) {
    resultMatch = stableStringify(recomputedResult) === stableStringify(expectedResult);
  }

  return { seedHashMatch, floats, recomputedResult, resultMatch };
}
