import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  fullyParallel: true,
  reporter: 'list',
  // Provisions a funded/consented test user against the local Supabase stack and
  // writes tests/e2e/.auth.json for the core-flow spec to inject.
  globalSetup: './tests/e2e/global-setup.ts',
  use: {
    baseURL: 'http://127.0.0.1:3000',
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: [
    {
      command: 'tsx scripts/e2e-dev-server.ts web 3000',
      url: 'http://127.0.0.1:3000',
      reuseExistingServer: false,
      timeout: 120_000,
      // Pin the dev server to the LOCAL Supabase stack so E2E never targets a
      // remote project, regardless of ambient shell env or .env files.
      env: {
        VITE_SUPABASE_URL: 'http://127.0.0.1:54444',
        VITE_SUPABASE_ANON_KEY: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
      },
    },
    {
      command: 'tsx scripts/e2e-dev-server.ts admin 3001',
      url: 'http://127.0.0.1:3001',
      reuseExistingServer: false,
      timeout: 120_000,
      env: {
        VITE_SUPABASE_URL: 'http://127.0.0.1:54444',
        VITE_SUPABASE_ANON_KEY: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
      },
    },
  ],
});
