import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const roots = ['apps', 'packages'];
const koreanPattern = /[ㄱ-ㅎㅏ-ㅣ가-힣]/;

// The i18n catalog is the single source of Korean copy. Static HTML fallbacks
// that ship outside the JS bundle cannot import the catalog, so they are
// allowed to inline Korean ONLY when they also inline the English counterpart
// and resolve the locale at runtime. Each such file is verified below to
// contain BOTH locales, so dropping either side re-triggers a failure.
const allowedFiles = new Set(['packages/i18n/src/index.ts']);
const bilingualHtmlFiles: { file: string; mustContain: string[] }[] = [
  {
    file: 'apps/web/public/offline.html',
    // Korean + English offline copy must both be present (runtime locale switch).
    mustContain: ['네트워크 연결 없음', 'No network connection'],
  },
];

function collectFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      if (['dist', 'node_modules'].includes(entry)) return [];
      return collectFiles(path);
    }
    return /\.(ts|tsx|html)$/.test(entry) ? [path.replaceAll('\\', '/')] : [];
  });
}

const bilingualSet = new Set(bilingualHtmlFiles.map((b) => b.file));

const violations = roots.flatMap((root) => collectFiles(root)).filter((file) => {
  if (allowedFiles.has(file) || bilingualSet.has(file)) return false;
  return koreanPattern.test(readFileSync(file, 'utf8'));
});

if (violations.length > 0) {
  throw new Error(`Hardcoded Korean text outside locale files:\n${violations.join('\n')}`);
}

// Verify each declared bilingual fallback still carries every required locale.
const bilingualViolations = bilingualHtmlFiles.flatMap(({ file, mustContain }) => {
  const content = readFileSync(file, 'utf8');
  return mustContain
    .filter((needle) => !content.includes(needle))
    .map((needle) => `${file} is missing required localized copy: "${needle}"`);
});

if (bilingualViolations.length > 0) {
  throw new Error(`Bilingual fallback coverage failed:\n${bilingualViolations.join('\n')}`);
}
