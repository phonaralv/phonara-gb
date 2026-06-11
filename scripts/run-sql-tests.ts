import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// Runs every supabase/tests/*.sql file against a Postgres database.
// Each test file wraps itself in BEGIN ... ROLLBACK, so it leaves no residue.
//
// Execution strategy (auto-detected):
//   1. If `psql` is on PATH (CI installs postgresql-client) -> run psql directly
//      against SUPABASE_DB_URL.
//   2. Otherwise, if a local `supabase_db_*` Docker container is running
//      (local `supabase start`) -> pipe each file into that container's psql.
//
// Connection string for the psql path resolves from SUPABASE_DB_URL, falling
// back to the local Supabase default.
const dbUrl =
  process.env.SUPABASE_DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54442/postgres';

const testsDir = join(process.cwd(), 'supabase', 'tests');

if (!existsSync(testsDir)) {
  console.error(`No SQL tests directory at ${testsDir}`);
  process.exit(1);
}

const files = readdirSync(testsDir)
  .filter((f) => f.endsWith('.sql'))
  .sort();

if (files.length === 0) {
  console.error('No *.sql test files found in supabase/tests/');
  process.exit(1);
}

function hasPsql(): boolean {
  const probe = spawnSync('psql', ['--version'], { stdio: 'ignore' });
  return probe.status === 0;
}

function findSupabaseDbContainer(): string | null {
  const probe = spawnSync('docker', ['ps', '--format', '{{.Names}}'], { encoding: 'utf8' });
  if (probe.status !== 0 || !probe.stdout) return null;
  const match = probe.stdout
    .split(/\r?\n/)
    .map((s) => s.trim())
    .find((name) => name.startsWith('supabase_db_'));
  return match ?? null;
}

type Runner = (sqlPath: string) => ReturnType<typeof spawnSync>;

let runner: Runner;
let mode: string;

if (hasPsql()) {
  mode = `psql (${dbUrl})`;
  runner = (sqlPath: string) =>
    spawnSync('psql', [dbUrl, '-v', 'ON_ERROR_STOP=1', '-f', sqlPath], { stdio: 'inherit' });
} else {
  const container = findSupabaseDbContainer();
  if (!container) {
    console.error(
      'Neither `psql` nor a running `supabase_db_*` Docker container was found.\n' +
        'Install postgresql-client, or run `supabase start` for the local Docker fallback.',
    );
    process.exit(1);
  }
  mode = `docker exec ${container} psql`;
  runner = (sqlPath: string) => {
    const sql = readFileSync(sqlPath, 'utf8');
    return spawnSync(
      'docker',
      ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
      { input: sql, stdio: ['pipe', 'inherit', 'inherit'] },
    );
  };
}

console.log(`Running SQL tests via: ${mode}`);

let failed = 0;

for (const file of files) {
  const path = join(testsDir, file);
  console.log(`\n=== Running ${file} ===`);
  const result = runner(path);
  if (result.status !== 0) {
    console.error(`FAILED: ${file} (exit ${result.status ?? 'unknown'})`);
    failed += 1;
  } else {
    console.log(`PASSED: ${file}`);
  }
}

if (failed > 0) {
  console.error(`\n${failed} SQL test file(s) failed.`);
  process.exit(1);
}

console.log(`\nAll ${files.length} SQL test file(s) passed.`);
