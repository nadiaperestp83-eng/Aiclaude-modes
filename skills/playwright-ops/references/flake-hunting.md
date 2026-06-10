# Flake Hunting

Systematic diagnosis of flaky Playwright tests. A flaky test is a bug — in the test, the app, or
the environment. Retries buy time to fix it; they are not the fix.

## Triage Workflow

```
Flaky test reported
│
1. Get the evidence
│  └─ trace: 'on-first-retry' in config → download trace from CI artifact
│     └─ npx playwright show-trace path/to/trace.zip
│        (per-action DOM snapshots, network, console, timing)
│
2. Reproduce locally
│  └─ npx playwright test failing.spec.ts --repeat-each=20 --workers=4
│     ├─ Fails alone, repeated        → timing/race within the test
│     ├─ Fails only with --workers>1  → cross-test state leakage
│     └─ Fails only in CI             → environment delta (speed, viewport, headless, locale, TZ)
│
3. Classify against the table below, fix the CAUSE
│
4. Prove the fix
   └─ --repeat-each=50 clean, then watch the "flaky" count in CI reports trend to zero
```

CI flake visibility: HTML report marks retried-then-passed tests as **flaky** — review that list
weekly; it's your queue.

## Common Causes and Fixes

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| Click "worked" but nothing happened | Element re-rendered between locate and click (hydration, list re-sort) | Assert the settled state first: `await expect(row).toBeVisible()` then act; prefer role/text locators that target the final element |
| Assertion passes locally, times out in CI | CI is slower; manual check raced the render | Replace any non-retrying check with web-first `await expect(...)`; raise `expect.timeout` only if the app is legitimately slow |
| `waitForTimeout` sprinkled around | Sleeping instead of waiting for a condition | Delete; wait on the observable effect: `expect(locator)`, `page.waitForURL()`, `page.waitForResponse()` |
| Fails only with multiple workers | Tests share an account/record; one mutates what another reads | Per-worker data: suffix usernames/tenants with `test.info().parallelIndex`; or worker-scoped account fixture |
| First test after auth flaky | storageState saved before login finished | In auth.setup, assert a logged-in signal (`await expect(page.getByTestId('user-menu')).toBeVisible()`) before `storageState({ path })` |
| Animation mid-flight in screenshots/clicks | CSS transitions | `toHaveScreenshot` disables animations by default; for actions, assert post-animation state or set `reducedMotion: 'reduce'` in `use` |
| Time-dependent failures (midnight, month-end, TZ) | Real clock | `await page.clock.setFixedTime(new Date('2026-01-15T10:00:00'))`; pin `timezoneId` and `locale` in `use` |
| Random data collisions | Shared fixtures with hardcoded names | Unique-per-test names: `` `proj-${test.info().testId}` `` |
| Network nondeterminism from third parties | Live external calls | Mock them (`route.fulfill` / HAR replay) — see network-and-api.md |
| Passes in `--headed`, fails headless | Viewport/focus/rendering differences | Pin `viewport` in config; debug headless with traces, not by switching to headed |
| Fails only on retry / second run | Leftover server-side state from first attempt | Make setup idempotent (upsert, not create); clean up in fixture teardown, which runs on failure too |

## Tools Reference

| Tool | Invocation | What it gives you |
|------|-----------|-------------------|
| Trace viewer | `trace: 'on-first-retry'` → `npx playwright show-trace trace.zip` | Time-travel DOM snapshots, network log, console, action timeline — the primary CI forensic tool |
| UI mode | `npx playwright test --ui` | Watch mode + live trace while iterating on a fix |
| Inspector | `PWDEBUG=1 npx playwright test foo.spec.ts` or `await page.pause()` | Step through actions, try locators live |
| Repeat | `--repeat-each=20` | Statistical reproduction |
| Stress | `--workers=4` (or more than usual) | Surfaces isolation bugs |
| Single worker | `--workers=1` | If this "fixes" it, you have cross-test coupling — that's the bug |
| Verbose API log | `DEBUG=pw:api npx playwright test` | Every Playwright call with timing |
| Video | `video: 'retain-on-failure'` | Cheaper than trace to skim; less data |

`trace: 'on'` everywhere is expensive — `'on-first-retry'` is the right default; use
`'retain-on-failure'` if you run without retries.

## Retrying Non-DOM Conditions

Web-first assertions only retry on locators/page. For everything else:

```ts
// Poll an arbitrary async value
await expect.poll(async () => {
  const res = await request.get(`/api/jobs/${id}`);
  return (await res.json()).status;
}, { timeout: 30_000, intervals: [1_000] }).toBe('done');

// Retry a block of assertions/actions together
await expect(async () => {
  const res = await request.get('/health');
  expect(res.status()).toBe(200);
}).toPass({ timeout: 60_000 });
```

Use these for eventual consistency (queues, search indexing, emails) instead of sleep loops.

## Isolation Discipline Checklist

- [ ] No test depends on another test having run (`test.describe.configure({ mode: 'serial' })` is a red flag, not a tool of first resort)
- [ ] Server-side state is created per test (API seeding) or per worker (`parallelIndex`-scoped accounts)
- [ ] Teardown lives in fixtures (runs on failure), not at the end of test bodies
- [ ] `storageState` files saved only after asserting login completed
- [ ] `forbidOnly` on CI; `--repeat-each` smoke before merging new specs
- [ ] Suite passes with `--workers=8 --repeat-each=3` locally before you blame CI

## Quarantine Pattern

While a flake is being fixed, tag it instead of deleting or `.skip`-ing silently:

```ts
test('checkout under load @quarantine', async ({ page }) => { ... });
```

```bash
npx playwright test --grep-invert @quarantine        # main gate
npx playwright test --grep @quarantine               # nightly, non-blocking
```

Track quarantined tests with an issue each; a quarantine list that only grows is a suite dying in
slow motion.
