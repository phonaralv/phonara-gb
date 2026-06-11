import { defineConfig } from 'vitest/config';
import path from 'path';

const root = path.resolve(__dirname);

export default defineConfig({
  resolve: {
    alias: {
      '@phonara/shared-types': path.resolve(root, 'packages/shared-types/src'),
      '@phonara/money': path.resolve(root, 'packages/money/src'),
      '@phonara/wallet-ledger': path.resolve(root, 'packages/wallet-ledger/src'),
      '@phonara/trading-engine': path.resolve(root, 'packages/trading-engine/src'),
      '@phonara/game-engine': path.resolve(root, 'packages/game-engine/src'),
      '@phonara/i18n': path.resolve(root, 'packages/i18n/src'),
    },
  },
  test: {
    globals: false,
    environment: 'node',
    include: ['packages/**/*.test.ts', 'tests/**/*.test.ts'],
    server: {
      deps: {
        inline: ['decimal.js'],
      },
    },
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json-summary'],
      include: ['packages/*/src/**/*.ts'],
      exclude: ['packages/*/src/**/*.test.ts', 'packages/*/src/**/*.d.ts'],
    },
  },
});
