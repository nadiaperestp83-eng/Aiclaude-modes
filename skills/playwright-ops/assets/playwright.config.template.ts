/**
 * Production Playwright config template.
 *
 * Copy to playwright.config.ts and adjust the marked sections.
 * Conventions baked in:
 *   - blob reporter on CI (shard-mergeable), html locally
 *   - trace on first retry (flake forensics at near-zero cost)
 *   - auth via a `setup` project + storageState (login once, reuse everywhere)
 *   - webServer boots the app and waits for it — no sleeps in CI scripts
 */
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',

  // Run tests within files in parallel too (also gives per-test shard balancing).
  // Set false only if tests within a file are intentionally ordered.
  fullyParallel: true,

  // A stray `test.only` committed to CI silently skips the suite — make it a build failure.
  forbidOnly: !!process.env.CI,

  // Retries are flake telemetry, not a fix: retried-then-passed tests show as
  // "flaky" in the report. Keep 0 locally so you feel flakes immediately.
  retries: process.env.CI ? 2 : 0,

  // Small CI runners (2-core GitHub hosted) thrash with parallel browser workers.
  // Scale horizontally with --shard instead. Locally, default = ~half the cores.
  workers: process.env.CI ? 1 : undefined,

  // blob -> uploaded per shard, merged with `npx playwright merge-reports`.
  reporter: process.env.CI
    ? [['blob'], ['github']]
    : [['html', { open: 'on-failure' }]],

  // Per-action timeout defaults are usually fine; raise the global test timeout
  // only for genuinely long flows (or per-test via test.slow()).
  timeout: 30_000,
  expect: {
    timeout: 5_000,
    // Global visual-comparison tolerances; override per assertion when needed.
    toHaveScreenshot: {
      maxDiffPixels: 100,
      // animations: 'disabled' is already the default for screenshots
    },
  },

  use: {
    // All page.goto('/relative') and request.get('/api/...') resolve against this.
    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',

    // Trace on first retry: the failing run gets full DOM snapshots + network log.
    // Use 'retain-on-failure' instead if you run with retries: 0.
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    // video is mostly redundant with traces; enable only if your team skims videos.
    // video: 'retain-on-failure',

    // Determinism: pin what the OS would otherwise decide for you.
    locale: 'en-US',
    timezoneId: 'UTC',
    // viewport comes from the device preset per project below.

    // Attribute used by page.getByTestId(); align with your frontend convention.
    testIdAttribute: 'data-testid',

    // Uncomment if a service worker swallows your route() mocks:
    // serviceWorkers: 'block',
  },

  projects: [
    // --- Auth setup: runs first, saves storage state for the browser projects ---
    // tests/auth.setup.ts logs in and calls
    //   page.context().storageState({ path: 'playwright/.auth/user.json' })
    // Keep playwright/.auth/ in .gitignore.
    { name: 'setup', testMatch: /.*\.setup\.ts/ },

    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },

    // Enable per browser-support matrix. Remember: each enabled project must be
    // installed in CI (npx playwright install --with-deps firefox webkit).
    // {
    //   name: 'firefox',
    //   use: { ...devices['Desktop Firefox'], storageState: 'playwright/.auth/user.json' },
    //   dependencies: ['setup'],
    // },
    // {
    //   name: 'webkit',
    //   use: { ...devices['Desktop Safari'], storageState: 'playwright/.auth/user.json' },
    //   dependencies: ['setup'],
    // },

    // Mobile viewport smoke pass.
    // {
    //   name: 'mobile-chrome',
    //   use: { ...devices['Pixel 7'], storageState: 'playwright/.auth/user.json' },
    //   dependencies: ['setup'],
    //   grep: /@smoke/,
    // },

    // Unauthenticated flows (login page itself, public pages) — no storageState.
    // {
    //   name: 'chromium-no-auth',
    //   use: { ...devices['Desktop Chrome'] },
    //   testMatch: /.*\.public\.spec\.ts/,
    // },
  ],

  // Playwright boots your app and polls `url` until it responds — replaces
  // "npm start & sleep 15" hacks in CI scripts.
  webServer: {
    command: process.env.CI ? 'npm run build && npm run start' : 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe', // surface app logs in CI output when boot fails
  },
  // Multiple servers? webServer also accepts an array: [{ api }, { frontend }].
});
