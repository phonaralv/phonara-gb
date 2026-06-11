import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

// ─────────────────────────────────────────────────────────────────────────────
// Release-readiness gate (rule 80-release-readiness).
// Blocks debug/test residue from shipping to production. Enforced in
// `bun run check` and CI so it is impossible to merge a build that is not
// "deploy-now" clean.
//
// Escape hatch: append `release-allow` (with a short reason) to an intentional
// line, e.g. `someDevOnlyCall(); // release-allow: dev diagnostics`.
// `console.*` is additionally allowed automatically when the call (or its
// enclosing line up to 2 lines above) is guarded by `import.meta.env.DEV`.
// ─────────────────────────────────────────────────────────────────────────────

const TS_ROOTS = ['apps', 'packages'];
const SQL_ROOTS = ['supabase/migrations', 'supabase/tests'];
const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', '.turbo', 'coverage', '.vite']);
const SKIP_FILE = /\.(test|spec)\.(ts|tsx)$/;
const ALLOW_MARKER = 'release-allow';
const DEV_GUARD = 'import.meta.env.DEV';

interface Rule {
  name: string;
  re: RegExp;
  devGuardable?: boolean;
}

const RULES: Rule[] = [
  { name: 'console statement', re: /console\.(log|debug|info|warn|error)\s*\(/, devGuardable: true },
  { name: 'debugger statement', re: /(^|[^.\w])debugger\b/ },
  { name: 'TODO/FIXME marker', re: /\b(TODO|FIXME|HACK|XXX)\b/ },
  { name: 'focused test', re: /\b(describe|it|test)\.only\s*\(/ },
  { name: 'placeholder copy', re: /추후 구현|미구현|샘플 데이터|테스트 모드|test mode|dummy data|lorem ipsum/i },
];

function collectTs(dir: string): string[] {
  let out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      if (!SKIP_DIRS.has(entry)) out = out.concat(collectTs(path));
    } else if (/\.(ts|tsx)$/.test(entry) && !SKIP_FILE.test(entry)) {
      out.push(path.replaceAll('\\', '/'));
    }
  }
  return out;
}

function collectSql(dir: string): string[] {
  let out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      if (!SKIP_DIRS.has(entry)) out = out.concat(collectSql(path));
    } else if (entry.endsWith('.sql')) {
      out.push(path.replaceAll('\\', '/'));
    }
  }
  return out;
}

function scanFile(file: string, violations: string[]): void {
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    if (line.includes(ALLOW_MARKER)) return;
    for (const rule of RULES) {
      if (!rule.re.test(line)) continue;
      if (rule.devGuardable) {
        const window = [lines[i - 2] ?? '', lines[i - 1] ?? '', line];
        if (window.some((l) => l.includes(DEV_GUARD))) continue;
      }
      violations.push(`${file}:${i + 1}  [${rule.name}]  ${line.trim()}`);
    }
  });
}

const violations: string[] = [];

for (const root of TS_ROOTS) {
  for (const file of collectTs(root)) {
    scanFile(file, violations);
  }
}

for (const root of SQL_ROOTS) {
  for (const file of collectSql(root)) {
    scanFile(file, violations);
  }
}

if (violations.length > 0) {
  process.stderr.write(
    `Release-readiness gate failed (${violations.length} issue(s)):\n` +
      violations.join('\n') +
      `\n\nRemove the debug/test residue, gate it behind \`${DEV_GUARD}\`, ` +
      `or append \`${ALLOW_MARKER}: <reason>\` to an intentional line.\n`,
  );
  process.exit(1);
}

process.stdout.write(
  `check:release OK - no debug/test residue in ${[...TS_ROOTS, ...SQL_ROOTS].join(', ')}\n`,
);
