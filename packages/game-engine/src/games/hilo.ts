import Decimal from 'decimal.js';
import { z } from 'zod';
import { registerGame, type GameDefinition } from '../registry';
import { requireFloat } from '../lib/require-float';

export type HiLoGuess = 'higher' | 'lower' | 'skip';

export const HILO_MAX_GUESSES = 10;

export interface HiLoSelection {
  startCard: number | null;
  guesses: HiLoGuess[];
}

export interface HiLoRound {
  card: number;
  guess: HiLoGuess;
  correct: boolean;
  multiplier: number;
}

export interface HiLoResult {
  cards: number[];
  rounds: HiLoRound[];
  won: boolean;
}

function cardFromFloat(f: number): number {
  return Math.floor(f * 13) + 1;
}

function hiloMultiplier(card: number, guess: HiLoGuess): number {
  if (guess === 'skip') return 1;
  const p = guess === 'higher' ? (13 - card) / 13 : (card - 1) / 13;
  if (p <= 0) return 0;
  return Math.floor(99 / p) / 100;
}

const hiloDefinition: GameDefinition<HiLoSelection, HiLoResult> = {
  code: 'hilo',
  betSchema: z.object({
    startCard: z.number().int().min(1).max(13).nullable(),
    guesses: z.array(z.enum(['higher', 'lower', 'skip'])).max(HILO_MAX_GUESSES),
  }),
  floatCount: 1 + HILO_MAX_GUESSES,

  resultFromFloats(floats, selection): HiLoResult {
    let floatIdx = 0;
    const startCard =
      selection.startCard ?? cardFromFloat(requireFloat(floats, floatIdx++));
    const cards: number[] = [startCard];
    const rounds: HiLoRound[] = [];
    let cumMult = 1;
    let won = selection.guesses.length > 0;

    for (const guess of selection.guesses) {
      const currentCard = cards[cards.length - 1]!;
      const nextCard = cardFromFloat(requireFloat(floats, floatIdx++));
      cards.push(nextCard);

      if (guess === 'skip') {
        rounds.push({ card: currentCard, guess, correct: true, multiplier: cumMult });
        continue;
      }

      const correct =
        guess === 'higher' ? nextCard > currentCard : nextCard < currentCard;
      const stepMult = hiloMultiplier(currentCard, guess);
      cumMult = correct ? Math.floor(cumMult * stepMult * 100) / 100 : 0;

      rounds.push({ card: currentCard, guess, correct, multiplier: cumMult });

      if (!correct) {
        won = false;
        break;
      }
    }

    return { cards, rounds, won };
  },

  settle(stake, _selection, result) {
    if (!result.won || result.rounds.length === 0) {
      return { payout: new Decimal('0'), houseEdgeLeg: stake };
    }
    const lastRound = result.rounds[result.rounds.length - 1];
    const mult = new Decimal((lastRound?.multiplier ?? 1).toFixed(2));
    const payout = stake.mul(mult);
    const houseEdgeLeg = stake.minus(payout);
    return { payout, houseEdgeLeg };
  },
};

registerGame(hiloDefinition);
export { hiloDefinition };
