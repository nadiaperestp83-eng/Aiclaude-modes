# Fixtures and Page Object Architecture

How to structure Playwright Test suites with fixtures as the composition mechanism and page
objects as thin locator/action wrappers.

## Built-in Fixtures

| Fixture | Type | Scope | Notes |
|---------|------|-------|-------|
| `page` | `Page` | test | Fresh isolated page per test |
| `context` | `BrowserContext` | test | Fresh context per test — cookies/storage isolated |
| `browser` | `Browser` | worker | Shared across tests in a worker |
| `browserName` | `string` | worker | `'chromium' \| 'firefox' \| 'webkit'` |
| `request` | `APIRequestContext` | test | HTTP client honoring `baseURL` / `extraHTTPHeaders` |

## Custom Fixtures: the Full Shape

```ts
import { test as base } from '@playwright/test';

type TestFixtures = {
  todoPage: TodoPage;        // test-scoped
  defaultItem: string;       // option
};
type WorkerFixtures = {
  account: { username: string; password: string };  // worker-scoped
};

export const test = base.extend<TestFixtures, WorkerFixtures>({
  // Option — overridable per project via projects[].use
  defaultItem: ['Something nice', { option: true }],

  // Test-scoped fixture with setup + teardown
  todoPage: async ({ page, defaultItem }, use) => {
    const todoPage = new TodoPage(page);
    await todoPage.goto();
    await todoPage.addToDo(defaultItem);
    await use(todoPage);              // <-- test body executes here
    await todoPage.removeAll();       // teardown runs even if test fails
  },

  // Worker-scoped — once per worker process; second generic param
  account: [async ({ browser }, use, workerInfo) => {
    const username = 'user-' + workerInfo.workerIndex;
    const password = await createAccount(username);   // expensive, do once
    await use({ username, password });
    await deleteAccount(username);
  }, { scope: 'worker' }],
});

export { expect } from '@playwright/test';
```

Key mechanics:

- **Lazy**: a fixture only runs if the test (or another fixture) references it.
- **Composable**: fixtures depend on other fixtures by destructuring them.
- **Teardown order**: reverse of setup, runs even on failure — replaces brittle `afterEach` chains.
- The two generic params of `extend<TestFixtures, WorkerFixtures>` map to test scope and worker
  scope respectively. Worker fixtures cannot depend on test fixtures.

## Fixture Options Reference

| Option | Effect |
|--------|--------|
| `{ scope: 'worker' }` | One instance per worker process |
| `{ auto: true }` | Runs for every test without being referenced — global hooks |
| `{ option: true }` | Value is a project-configurable option |
| `{ timeout: 60_000 }` | Separate timeout for slow fixture setup |
| `{ box: true }` | Hide fixture from report/errors (or `box: 'self'` to hide just its step) |
| `{ title: 'my fixture' }` | Custom name in reports |

### Automatic fixtures as global hooks

```ts
export const test = base.extend<{ forEachTest: void }, { forEachWorker: void }>({
  // beforeEach/afterEach equivalent, but reusable across files
  forEachTest: [async ({ page }, use) => {
    await page.goto('/');         // before each test
    await use();
    // after each test
  }, { auto: true }],

  // once per worker
  forEachWorker: [async ({}, use) => {
    console.log(`Worker ${test.info().workerIndex} starting`);
    await use();
  }, { scope: 'worker', auto: true }],
});
```

### Overriding built-ins

```ts
export const test = base.extend({
  page: async ({ page }, use) => {
    await page.goto('/dashboard');   // every test starts on dashboard
    await use(page);
  },
  // Override storageState to come from a worker fixture (per-worker auth)
  storageState: ({ workerStorageState }, use) => use(workerStorageState),
});
```

## mergeTests: Composing Fixture Modules

Keep fixture concerns in separate modules and merge at the edge:

```ts
// fixtures/db.ts        -> export const test = base.extend<{ db: Db }>({...})
// fixtures/a11y.ts      -> export const test = base.extend<{ axe: Axe }>({...})

// fixtures/index.ts
import { mergeTests, mergeExpects } from '@playwright/test';
import { test as dbTest } from './db';
import { test as a11yTest } from './a11y';

export const test = mergeTests(dbTest, a11yTest);
export { expect } from '@playwright/test';
```

Tests import `test`/`expect` from your fixtures module, never from `@playwright/test` directly —
one import path to rule them all.

## Page Objects: Modern Recommendation

### POM-as-fixture (preferred)

The page object is a plain class; the **fixture** owns construction and navigation:

```ts
// pages/checkout-page.ts
import { type Page, type Locator, expect } from '@playwright/test';

export class CheckoutPage {
  readonly page: Page;
  readonly cardNumber: Locator;
  readonly payButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.cardNumber = page.getByLabel('Card number');
    this.payButton = page.getByRole('button', { name: 'Pay now' });
  }

  async goto() {
    await this.page.goto('/checkout');
  }

  async pay(card: string) {
    await this.cardNumber.fill(card);
    await this.payButton.click();
  }
}
```

```ts
// a test
test('pays with valid card', async ({ checkoutPage, page }) => {
  await checkoutPage.pay('4242 4242 4242 4242');
  await expect(page.getByRole('heading', { name: 'Order confirmed' })).toBeVisible();
});
```

### Rules for healthy page objects

| Rule | Why |
|------|-----|
| Store `Locator`s, never element handles | Locators are lazy + auto-retrying; handles go stale |
| Expose actions + locators; keep assertions in tests (or custom `expect` matchers) | Tests stay readable as specs; POMs stay reusable |
| No `waitForTimeout` / try-catch flow control inside POMs | Hides flake; actions already auto-wait |
| Constructor takes `Page` (or a `Locator` root for component objects) only | Keeps them trivially fixture-injectable |
| Prefer small per-screen objects over one God object | Cheap to compose via fixtures |

### When to skip POMs entirely

Small suites (< ~20 tests) over stable UIs often read better with raw `getByRole` calls inline.
POMs earn their keep when the same screen appears in many tests or locators churn. Don't build the
abstraction before the duplication exists.

## Hooks vs Fixtures

| Need | Use |
|------|-----|
| Shared setup local to one file | `test.beforeEach` is fine |
| Shared setup across files | Fixture (auto or named) |
| Expensive once-per-run setup | Project dependencies (setup project) — not `globalSetup`, which skips fixtures/tracing |
| Once-per-worker setup | Worker-scoped fixture |

`test.beforeAll` runs **once per worker**, not once per run — a classic surprise. For true
once-per-run work, use a setup project with `dependencies`.
