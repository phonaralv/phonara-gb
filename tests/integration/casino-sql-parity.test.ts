import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import {
  crashDefinition,
  diceDefinition,
  diceMultiplier,
  hiloDefinition,
  limboDefinition,
  minesDefinition,
  minesMultiplier,
  plinkoDefinition,
  type GameCode,
} from '@phonara/game-engine';
import { floatStream } from '../../packages/game-engine/src/fairness/float';
import type { GameDefinition } from '../../packages/game-engine/src/registry';

type Selection = Record<string, unknown>;

interface CaseDef {
  game: GameCode;
  selection: Selection;
}

interface SqlCase extends CaseDef {
  index: number;
  serverSeed: string;
  clientSeed: string;
  nonce: number;
}

const SQL_PARITY_ENABLED = process.env.PHONARA_SQL_PARITY === '1';
const CASES_PER_GAME = 1000;

const CASE_DEFS: CaseDef[] = [
  { game: 'crash', selection: { autoCashout: '1.10' } },
  { game: 'limbo', selection: { target: '1.10' } },
  { game: 'dice', selection: { target: '50.00', direction: 'over' } },
  { game: 'mines', selection: { mineCount: 3, revealedCells: [0, 1, 2] } },
  { game: 'hilo', selection: { startCard: null, guesses: ['skip', 'higher', 'lower'] } },
  { game: 'plinko', selection: { rows: 12, risk: 'medium' } },
];

const DEFINITIONS: Record<GameCode, GameDefinition<unknown, unknown>> = {
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

function sqlQuote(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function buildCases(): SqlCase[] {
  const cases: SqlCase[] = [];
  let index = 0;
  for (const def of CASE_DEFS) {
    for (let i = 0; i < CASES_PER_GAME; i += 1) {
      const serverSeed = createHash('sha256')
        .update(`part-c:${def.game}:${i}`)
        .digest('hex');
      cases.push({
        ...def,
        index,
        serverSeed,
        clientSeed: `part_c_client_${def.game}_${i % 97}`,
        nonce: (i % 251) + 1,
      });
      index += 1;
    }
  }
  return cases;
}

function buildSql(cases: SqlCase[]): string {
  const values = cases
    .map((item) =>
      [
        item.index,
        `${sqlQuote(item.game)}::game_code`,
        sqlQuote(item.serverSeed),
        sqlQuote(item.clientSeed),
        item.nonce,
        `${sqlQuote(JSON.stringify(item.selection))}::jsonb`,
      ].join(', '),
    )
    .map((row) => `(${row})`)
    .join(',\n');

  return `
SET search_path = public, pg_temp;
WITH cases(idx, game, server_seed, client_seed, nonce, selection) AS (
  VALUES
${values}
)
SELECT idx::TEXT || E'\\t' || _game_result(game, server_seed, client_seed, nonce, selection)::TEXT
FROM cases
ORDER BY idx;
`;
}

function runSql(sql: string): string {
  const result = spawnSync(
    'docker',
    [
      'exec',
      '-i',
      'supabase_db_yocjhjsdwoijfdrehzoq',
      'psql',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-At',
    ],
    { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || 'SQL parity query failed');
  }
  return result.stdout;
}

function payoutMultiplier(game: GameCode, selection: Selection, result: unknown): string {
  if (game === 'dice') {
    const dice = result as { won: boolean };
    if (!dice.won) return '0.000000';
    return diceMultiplier(
      Number(selection['target']),
      selection['direction'] as 'over' | 'under',
    ).toFixed(6);
  }
  if (game === 'crash') {
    return (result as { cashedOut: boolean }).cashedOut
      ? Number(selection['autoCashout']).toFixed(6)
      : '0.000000';
  }
  if (game === 'limbo') {
    return (result as { won: boolean }).won ? Number(selection['target']).toFixed(6) : '0.000000';
  }
  if (game === 'mines') {
    const mines = result as { hitMine: boolean };
    const revealedCells = selection['revealedCells'] as number[];
    if (mines.hitMine || revealedCells.length === 0) return '0.000000';
    return minesMultiplier(Number(selection['mineCount']), revealedCells.length).toFixed(6);
  }
  if (game === 'hilo') {
    const hilo = result as { won: boolean; rounds: Array<{ multiplier: number }> };
    if (!hilo.won || hilo.rounds.length === 0) return '0.000000';
    return (hilo.rounds.at(-1)?.multiplier ?? 0).toFixed(6);
  }
  const plinko = result as { bucketMultiplier: string };
  return Number(plinko.bucketMultiplier).toFixed(6);
}

describe.runIf(SQL_PARITY_ENABLED)('casino TS to SQL parity', () => {
  it('matches _game_result for 6 games across 1000 seeds each', async () => {
    const cases = buildCases();
    const sqlOutput = runSql(buildSql(cases));
    const sqlResults = new Map<number, { result: unknown; payout_multiplier: string }>();

    for (const line of sqlOutput.trim().split('\n')) {
      const [indexText, jsonText] = line.split('\t');
      if (indexText === undefined || jsonText === undefined) continue;
      sqlResults.set(Number(indexText), JSON.parse(jsonText));
    }

    expect(sqlResults.size).toBe(cases.length);

    for (const item of cases) {
      const definition = DEFINITIONS[item.game];
      const floats = await floatStream(
        item.serverSeed,
        item.clientSeed,
        item.nonce,
        definition.floatCount,
      );
      const result = definition.resultFromFloats(floats, item.selection);
      const sqlResult = sqlResults.get(item.index);

      expect(sqlResult, `${item.game} case ${item.index} SQL result exists`).toBeDefined();
      expect(
        stableStringify(sqlResult?.result),
        `${item.game} case ${item.index} result parity`,
      ).toBe(stableStringify(result));
      expect(
        sqlResult?.payout_multiplier,
        `${item.game} case ${item.index} payout multiplier parity`,
      ).toBe(payoutMultiplier(item.game, item.selection, result));
    }
  }, 120_000);
});

describe.skipIf(SQL_PARITY_ENABLED)('casino TS to SQL parity', () => {
  it('is enabled with PHONARA_SQL_PARITY=1 when local Supabase is running', () => {
    expect(SQL_PARITY_ENABLED).toBe(false);
  });
});
