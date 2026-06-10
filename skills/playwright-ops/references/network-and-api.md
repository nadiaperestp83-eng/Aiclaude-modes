# Network Mocking and API Testing

Intercepting browser traffic, replaying HAR recordings, testing APIs directly, and the hybrid
seed-via-API / assert-via-UI pattern.

## Route Interception: page.route()

```ts
// Stub an endpoint entirely
await page.route('*/**/api/v1/fruits', async route => {
  await route.fulfill({ json: [{ name: 'Strawberry', id: 21 }] });
});

// Must be registered BEFORE the navigation/action that triggers the request
await page.goto('/');
```

| Method | Effect |
|--------|--------|
| `route.fulfill({ json, status, headers, body, path })` | Respond without hitting the network |
| `route.fetch()` | Execute the real request, get the response for modification |
| `route.continue({ headers, postData, url })` | Pass through, optionally modified |
| `route.abort('failed')` | Simulate network failure |
| `route.fallback()` | Defer to the next matching handler (handlers run last-registered-first) |

### Modify a real response

```ts
await page.route('*/**/api/v1/fruits', async route => {
  const response = await route.fetch();
  const json = await response.json();
  json.push({ name: 'Loquat', id: 100 });
  await route.fulfill({ response, json });   // real status/headers, patched body
});
```

### Failure-mode tests

```ts
await page.route('**/api/orders', route => route.fulfill({ status: 500 }));
await page.route('**/*.{png,jpg,jpeg}', route => route.abort());   // block heavy assets
await context.setOffline(true);                                     // whole-context offline
```

### Scope and ordering gotchas

- `page.route` applies to that page; `context.route` to every page in the context (use in a
  fixture for suite-wide stubs).
- Patterns: glob (`**/api/**`), RegExp, or predicate function. Glob matches the **full URL**.
- `await page.unroute(pattern)` removes handlers; `page.unrouteAll()` clears them.
- Service workers can bypass routing — set `serviceWorkers: 'block'` in `use` if your app
  registers one and mocks mysteriously don't fire.

## HAR Record and Replay

Best for "many endpoints, realistic payloads" — record once against the real backend, replay
hermetically.

```ts
// Record (update: true hits the real network and refreshes the file)
await page.routeFromHAR('./hars/fruits.har', {
  url: '*/**/api/v1/**',
  update: true,
});

// Replay (default update: false serves from the file; unmatched requests are aborted)
await page.routeFromHAR('./hars/fruits.har', { url: '*/**/api/v1/**' });
```

CLI recording:

```bash
npx playwright open --save-har=example.har --save-har-glob="**/api/**" https://example.com
```

Workflow: re-run recording tests with `update: true` whenever the API contract changes, commit the
HAR + extracted bodies (`.txt`/`.json` sidecars are editable by hand for edge cases).

## API Testing: request / APIRequestContext

The `request` fixture is an HTTP client honoring config `baseURL` and `extraHTTPHeaders` — no
browser involved, so it's fast.

```ts
// playwright.config.ts
use: {
  baseURL: 'https://api.github.com',
  extraHTTPHeaders: {
    'Accept': 'application/vnd.github.v3+json',
    'Authorization': `token ${process.env.API_TOKEN}`,
  },
},
```

```ts
test('creates a bug report', async ({ request }) => {
  const newIssue = await request.post(`/repos/${USER}/${REPO}/issues`, {
    data: { title: '[Bug] report 1', body: 'Bug description' },
  });
  expect(newIssue.ok()).toBeTruthy();

  const issues = await request.get(`/repos/${USER}/${REPO}/issues`);
  expect(await issues.json()).toContainEqual(
    expect.objectContaining({ title: '[Bug] report 1' }),
  );
});
```

Standalone context (different base URL, custom auth, use in setup scripts):

```ts
import { request } from '@playwright/test';

const api = await request.newContext({ baseURL: 'https://api.example.com' });
await api.post('/seed', { data: {...} });
await api.dispose();   // always dispose manually created contexts
```

`request.post` options: `data` (JSON), `form` (urlencoded), `multipart` (file upload),
`params` (query), `headers`, `failOnStatusCode`.

## Hybrid: Seed via API, Assert via UI

UI-driven setup is the slowest, flakiest part of most suites. Replace it:

```ts
test('renders the new project card', async ({ request, page }) => {
  // Arrange — fast, deterministic, server-side
  const res = await request.post('/api/projects', { data: { name: 'Apollo' } });
  expect(res.ok()).toBeTruthy();
  const { id } = await res.json();

  // Act + Assert — the only part that needs a browser
  await page.goto(`/projects/${id}`);
  await expect(page.getByRole('heading', { name: 'Apollo' })).toBeVisible();
});
```

Notes:

- The `request` fixture shares `storageState` with the browser context, so an authenticated UI
  session usually authenticates API calls too. For a different principal, create a separate
  `request.newContext({ storageState: 'playwright/.auth/admin.json' })`.
- Postcondition checks invert it: act in the UI, verify via `request.get` that the server really
  persisted the thing.
- Cleanup belongs in fixtures (teardown after `use()`) or `afterAll` API calls — not in the test
  body where a failure skips it.

## What to Mock vs Exercise

| Dependency | Default |
|------------|---------|
| Third-party SaaS (payments, analytics, maps) | **Mock** (`route.fulfill` / HAR). You can't control their data or uptime, and you don't want test purchases |
| Your own backend | **Real** — that's the integration you're paying E2E tests to verify |
| Your backend, in a frontend-only project | Mock deliberately and label the project (`name: 'ui-isolated'`) so coverage claims stay honest |
| Time / randomness | `page.clock.install()` / `page.clock.setFixedTime(...)` for time-dependent UI |

## WebSocket Mocking

```ts
await page.routeWebSocket('wss://example.com/ws', ws => {
  ws.onMessage(message => {
    if (message === 'request') ws.send('response');
  });
});
```

By default the intercepted socket never reaches the server; call `ws.connectToServer()` inside the
handler to proxy with selective message rewriting.
