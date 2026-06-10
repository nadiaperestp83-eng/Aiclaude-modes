# CI Patterns (GitHub Actions)

Runnable workflows for Playwright in CI, from single-job to sharded fleets. Adapt paths/commands
for other CI providers — the shape is identical.

## Baseline Workflow

```yaml
# .github/workflows/playwright.yml
name: Playwright Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  test:
    timeout-minutes: 60
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v5
        with:
          node-version: lts/*
      - name: Install dependencies
        run: npm ci
      - name: Install Playwright browsers
        run: npx playwright install --with-deps chromium
      - name: Run Playwright tests
        run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}          # upload report on failure too
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 30
```

Notes:

- Install only the browsers your projects use (`chromium` above) — saves minutes per run.
- `if: ${{ !cancelled() }}` keeps the report when tests fail; that's when you need it.
- Secrets via `env:` on the test step (`E2E_USER: ${{ secrets.E2E_USER }}`), never committed.

## Container vs install-deps

| Approach | Pros | Cons |
|----------|------|------|
| `npx playwright install --with-deps` on the runner | Simple; matches local dev | OS-level rendering drifts with runner image updates — visual baselines can churn |
| `container: mcr.microsoft.com/playwright:v1.52.0-jammy` | Pinned browser + OS rendering; reproducible visual tests; no install step | Slightly slower job start; must bump tag with `@playwright/test` |

**Always pin the container tag to your exact `@playwright/test` version** — a mismatch produces
"Executable doesn't exist" or subtle behavior skew.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: mcr.microsoft.com/playwright:v1.52.0-jammy
    steps:
      - uses: actions/checkout@v5
      - run: npm ci
      - run: npx playwright test
        env:
          HOME: /root      # workaround for firefox in containers
```

## Caching Browsers (non-container path)

```yaml
- name: Get Playwright version
  id: pw-version
  run: echo "version=$(node -p "require('@playwright/test/package.json').version")" >> "$GITHUB_OUTPUT"
- uses: actions/cache@v4
  id: pw-cache
  with:
    path: ~/.cache/ms-playwright
    key: playwright-${{ runner.os }}-${{ steps.pw-version.outputs.version }}
- run: npx playwright install --with-deps chromium
  if: steps.pw-cache.outputs.cache-hit != 'true'
- run: npx playwright install-deps chromium     # OS deps aren't cached
  if: steps.pw-cache.outputs.cache-hit == 'true'
```

## Sharding with Blob Reports + Merge

Config side — blob on CI shards, html locally:

```ts
// playwright.config.ts
reporter: process.env.CI ? 'blob' : 'html',
fullyParallel: true,   // shards split per-test instead of per-file -> better balance
```

```yaml
jobs:
  playwright-tests:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false                  # let every shard finish; see ALL failures
      matrix:
        shardIndex: [1, 2, 3, 4]
        shardTotal: [4]
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v5
        with: { node-version: lts/* }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npx playwright test --shard=${{ matrix.shardIndex }}/${{ matrix.shardTotal }}
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: blob-report-${{ matrix.shardIndex }}
          path: blob-report
          retention-days: 1

  merge-reports:
    if: ${{ !cancelled() }}
    needs: [playwright-tests]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v5
        with: { node-version: lts/* }
      - run: npm ci
      - uses: actions/download-artifact@v4
        with:
          path: all-blob-reports
          pattern: blob-report-*
          merge-multiple: true
      - run: npx playwright merge-reports --reporter html ./all-blob-reports
      - uses: actions/upload-artifact@v4
        with:
          name: html-report--attempt-${{ github.run_attempt }}
          path: playwright-report
          retention-days: 14
```

`merge-reports` accepts multiple reporters: `--reporter html,github` annotates the PR while also
producing the browsable report.

## Fail-Fast vs Full-Suite

| Context | Strategy |
|---------|----------|
| PR validation | `fail-fast: false` on the matrix + `maxFailures: 10` (or `--max-failures`) per shard. Developers fix everything in one round-trip instead of whack-a-mole |
| Smoke gate before deploy | Fail fast — `--grep @smoke`, no retries, abort pipeline on first failure |
| Nightly full regression | Full suite, retries on, no fail-fast; route the merged report to the team channel |

## Reporters

| Reporter | Use |
|----------|-----|
| `html` | Local + merged CI artifact — the daily driver |
| `blob` | Shard intermediate; only input for `merge-reports` |
| `junit` | Test-management ingestion (Jenkins, Azure DevOps, TestRail): `['junit', { outputFile: 'results.xml' }]` |
| `github` | Inline PR annotations on failures |
| `list` / `dot` / `line` | Console verbosity choices |

Multiple at once:

```ts
reporter: process.env.CI
  ? [['blob'], ['github']]
  : [['html', { open: 'on-failure' }]],
```

## webServer in CI

```ts
webServer: {
  command: 'npm run build && npm run start',
  url: 'http://localhost:3000',
  reuseExistingServer: !process.env.CI,   // CI always boots fresh
  timeout: 120_000,
  stdout: 'pipe',                          // surface server logs in CI output
},
```

Playwright waits for `url` to respond before running tests — no `sleep 10` hacks. Multiple
servers (API + frontend) can be given as an array.

## CI Hardening Checklist

- [ ] `forbidOnly: !!process.env.CI` — a stray `test.only` fails the build instead of silently skipping the suite
- [ ] `retries: 2` on CI + `trace: 'on-first-retry'`
- [ ] `workers: 1` per shard on small runners (2-core GitHub runners thrash above that); scale via shards
- [ ] Report artifacts uploaded with `if: ${{ !cancelled() }}`
- [ ] Browser install scoped to actual projects
- [ ] Container tag or browser cache keyed to the Playwright version
- [ ] Visual-test baselines generated in the same environment CI runs (see SKILL.md Visual Testing)
