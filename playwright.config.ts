import { defineConfig } from '@playwright/test'

// The smoke test of spec 15 (D23). Vitest runs test/**/*.test.ts. Playwright runs only the
// *.spec.ts files in test/smoke. Electron needs no browser download.
export default defineConfig({
  outputDir: 'test-results',
  reporter: 'list',
  retries: 0,
  testDir: 'test/smoke',
  testMatch: '*.spec.ts',
  timeout: 90_000,
  workers: 1,
})
