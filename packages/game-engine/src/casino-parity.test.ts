import { describe, expect, it } from 'vitest';
import { floatStream } from './fairness/float';
import { crashDefinition } from './games/crash';
import { diceDefinition } from './games/dice';
import { hiloDefinition } from './games/hilo';
import { limboDefinition } from './games/limbo';
import { minesDefinition } from './games/mines';
import { plinkoDefinition } from './games/plinko';
import type { GameDefinition } from './registry';

const SERVER_SEED = 'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb';
const CLIENT_SEED = 'parity_client';
const NONCE = 1;

async function resultFor<Selection, Result>(
  definition: GameDefinition<Selection, Result>,
  selection: Selection,
): Promise<Result> {
  const floats = await floatStream(SERVER_SEED, CLIENT_SEED, NONCE, definition.floatCount);
  return definition.resultFromFloats(floats, selection);
}

describe('casino TS parity vectors', () => {
  it('locks Dice over/under constants', async () => {
    await expect(resultFor(diceDefinition, { target: '50.00', direction: 'over' })).resolves.toEqual({
      roll: 18.37,
      won: false,
    });
    await expect(resultFor(diceDefinition, { target: '25.00', direction: 'under' })).resolves.toEqual({
      roll: 18.37,
      won: true,
    });
  });

  it('locks Limbo target constants', async () => {
    await expect(resultFor(limboDefinition, { target: '2.00' })).resolves.toEqual({
      resultMultiplier: 1.21,
      won: false,
    });
    await expect(resultFor(limboDefinition, { target: '5.00' })).resolves.toEqual({
      resultMultiplier: 1.21,
      won: false,
    });
  });

  it('locks Crash auto-cashout constants', async () => {
    await expect(resultFor(crashDefinition, { autoCashout: '2.00' })).resolves.toEqual({
      crashMultiplier: 1.21,
      cashedOut: false,
      cashoutMultiplier: 0,
    });
    await expect(resultFor(crashDefinition, { autoCashout: '5.00' })).resolves.toEqual({
      crashMultiplier: 1.21,
      cashedOut: false,
      cashoutMultiplier: 0,
    });
  });

  it('locks Mines position constants', async () => {
    await expect(
      resultFor(minesDefinition, { mineCount: 3, revealedCells: [0, 1, 2] }),
    ).resolves.toEqual({
      minePositions: [6, 0, 4],
      hitMine: true,
    });
    await expect(resultFor(minesDefinition, { mineCount: 24, revealedCells: [0] })).resolves.toEqual({
      minePositions: [6, 0, 4, 5, 13, 19, 11, 8, 20, 14, 16, 21, 24, 1, 3, 10, 17, 9, 12, 18, 2, 7, 23, 15],
      hitMine: true,
    });
  });

  it('locks HiLo card path constants', async () => {
    await expect(resultFor(hiloDefinition, { startCard: 7, guesses: ['higher'] })).resolves.toEqual({
      cards: [7, 3],
      rounds: [{ card: 7, guess: 'higher', correct: false, multiplier: 0 }],
      won: false,
    });
    await expect(
      resultFor(hiloDefinition, { startCard: null, guesses: ['skip', 'higher', 'lower'] }),
    ).resolves.toEqual({
      cards: [3, 6, 12, 4],
      rounds: [
        { card: 3, guess: 'skip', correct: true, multiplier: 1 },
        { card: 6, guess: 'higher', correct: true, multiplier: 1.83 },
        { card: 12, guess: 'lower', correct: true, multiplier: 2.14 },
      ],
      won: true,
    });
  });

  it('locks Plinko path constants', async () => {
    await expect(resultFor(plinkoDefinition, { rows: 12, risk: 'low' })).resolves.toEqual({
      path: [0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1],
      bucket: 5,
      bucketMultiplier: '0.9',
    });
    await expect(resultFor(plinkoDefinition, { rows: 16, risk: 'high' })).resolves.toEqual({
      path: [0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1],
      bucket: 7,
      bucketMultiplier: '0.3',
    });
  });
});
