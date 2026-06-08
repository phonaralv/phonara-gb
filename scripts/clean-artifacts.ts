import { rmSync } from 'node:fs';

const targets = ['coverage', 'playwright-report', 'test-results'];

for (const target of targets) {
  rmSync(target, { recursive: true, force: true });
}
