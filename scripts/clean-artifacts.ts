import { existsSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const rootTargets = [
  '.turbo',
  '.vite',
  'blob-report',
  'coverage',
  'playwright-report',
  'test-results',
];

const workspaceArtifactNames = [
  '.turbo',
  '.vite',
  'build',
  'coverage',
  'dist',
  'node_modules/.cache',
  'node_modules/.vite',
  'playwright-report',
  'test-results',
  'tsconfig.tsbuildinfo',
  'tsconfig.app.tsbuildinfo',
  'tsconfig.node.tsbuildinfo',
];

const workspaceRoots = ['apps', 'packages'];

function workspaceTargets() {
  return workspaceRoots.flatMap((root) => {
    if (!existsSync(root)) {
      return [];
    }

    return readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .flatMap((entry) =>
        workspaceArtifactNames.map((artifact) => join(root, entry.name, artifact)),
      );
  });
}

const targets = [...rootTargets, ...workspaceTargets()];

for (const target of targets) {
  rmSync(target, { recursive: true, force: true });
}
