import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests', fullyParallel: true, use: { baseURL: 'http://127.0.0.1:1425' },
  webServer: { command: 'node scripts/serve.mjs', url: 'http://127.0.0.1:1425', reuseExistingServer: false },
});
