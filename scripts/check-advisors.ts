import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// ─────────────────────────────────────────────────────────────────────────────
// Supabase advisor gate (rules 00 / 10 / 25): the security advisor must be clean
// (0 ERROR) before any DB change is considered done. This queries the Supabase
// Management API for the security + performance advisors and fails the build on
// ANY ERROR-level lint. WARN/INFO are reported but do not fail (many client
// `rpc_*` WARNs are by design — they guard internally on auth.uid()/_is_admin()).
//
// Single-project lock (rule 20): this script may ONLY ever query the locked ref.
//
// Auth: needs `SUPABASE_ACCESS_TOKEN` (a personal/CI access token). When it is
// absent (local devs, fork PRs) the gate SKIPS with a warning and exits 0, so it
// never blocks offline work; CI provides the secret so the gate is enforced there.
// ─────────────────────────────────────────────────────────────────────────────

const LOCKED_REF = 'yocjhjsdwoijfdrehzoq';

function lockedRef(): string {
  const ref = process.env.SUPABASE_PROJECT_ID?.trim() || readConfigRef() || LOCKED_REF;
  if (ref !== LOCKED_REF) {
    process.stderr.write(
      `check:advisors: refusing to query project "${ref}". ` +
        `This repo is locked to "${LOCKED_REF}" (rule 20-supabase-safety).\n`,
    );
    process.exit(1);
  }
  return ref;
}

function readConfigRef(): string | null {
  try {
    const toml = readFileSync(join('supabase', 'config.toml'), 'utf8');
    const m = toml.match(/project_id\s*=\s*"([^"]+)"/);
    return m?.[1] ?? null;
  } catch {
    return null;
  }
}

interface Lint {
  name: string;
  title?: string;
  level: 'ERROR' | 'WARN' | 'INFO';
  detail?: string;
  remediation?: string;
}

async function fetchAdvisor(ref: string, token: string, type: 'security' | 'performance'): Promise<Lint[]> {
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/advisors/${type}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`${type} advisor request failed: ${res.status} ${res.statusText} — ${await res.text()}`);
  }
  const data = (await res.json()) as { lints?: Lint[]; result?: { lints?: Lint[] } };
  return data.lints ?? data.result?.lints ?? [];
}

async function main(): Promise<void> {
  const ref = lockedRef();
  const token = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  if (!token) {
    process.stderr.write(
      'check:advisors SKIPPED — SUPABASE_ACCESS_TOKEN is not set.\n' +
        '  Set it in .env (see .env.example) or run `supabase login` and copy the PAT.\n' +
        '  CI must provide this secret so the gate is enforced; local skip exits 0 but is NOT a pass.\n',
    );
    return;
  }

  const [security, performance] = await Promise.all([
    fetchAdvisor(ref, token, 'security'),
    fetchAdvisor(ref, token, 'performance'),
  ]);
  const all = [
    ...security.map((l) => ({ ...l, advisor: 'security' as const })),
    ...performance.map((l) => ({ ...l, advisor: 'performance' as const })),
  ];

  const errors = all.filter((l) => l.level === 'ERROR');
  const warns = all.filter((l) => l.level === 'WARN');
  const infos = all.filter((l) => l.level === 'INFO');

  const countByName = (items: Lint[]): Map<string, number> => {
    const m = new Map<string, number>();
    for (const item of items) {
      const key = item.name ?? 'unknown';
      m.set(key, (m.get(key) ?? 0) + 1);
    }
    return m;
  };

  process.stdout.write(
    `check:advisors — ${errors.length} ERROR, ${warns.length} WARN, ${infos.length} INFO ` +
      `(project ${ref})\n`,
  );

  if (warns.length > 0) {
    process.stdout.write('  WARN breakdown:\n');
    for (const [name, count] of [...countByName(warns)].sort((a, b) => b[1] - a[1])) {
      process.stdout.write(`    ${count}x ${name}\n`);
    }
  }

  if (infos.length > 0) {
    process.stdout.write('  INFO breakdown:\n');
    for (const [name, count] of [...countByName(infos)].sort((a, b) => b[1] - a[1])) {
      process.stdout.write(`    ${count}x ${name}\n`);
    }
  }

  process.stdout.write(
    '  Scope note: this queries the REMOTE linked project. Local-only migrations ' +
      '(000025–000044) are not validated until Wave 12 post-push.\n',
  );

  if (errors.length > 0) {
    process.stderr.write('\nSupabase advisor gate FAILED — ERROR-level lint(s):\n');
    for (const e of errors) {
      process.stderr.write(`  [${e.advisor}] ${e.name}: ${e.detail ?? e.title ?? ''}\n`);
      if (e.remediation) process.stderr.write(`    → ${e.remediation}\n`);
    }
    process.exit(1);
  }

  process.stdout.write('check:advisors OK — security advisor has 0 ERROR.\n');
}

main().catch((err: unknown) => {
  process.stderr.write(`check:advisors errored: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
