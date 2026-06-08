import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const roots = ['apps', 'packages'];
const koreanPattern = /[ㄱ-ㅎㅏ-ㅣ가-힣]/;
const allowedFiles = new Set(['packages/i18n/src/index.ts']);

function collectFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      if (['dist', 'node_modules'].includes(entry)) return [];
      return collectFiles(path);
    }
    return /\.(ts|tsx)$/.test(entry) ? [path.replaceAll('\\', '/')] : [];
  });
}

const violations = roots.flatMap((root) => collectFiles(root)).filter((file) => {
  if (allowedFiles.has(file)) return false;
  return koreanPattern.test(readFileSync(file, 'utf8'));
});

if (violations.length > 0) {
  throw new Error(`Hardcoded Korean text outside locale files:\n${violations.join('\n')}`);
}
