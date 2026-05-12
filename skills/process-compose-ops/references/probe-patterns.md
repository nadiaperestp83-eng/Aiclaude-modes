# Readiness Probe Patterns

Concrete probe recipes by stack. Used in `process-compose.yaml`'s `readiness_probe` field.

## Python web servers (Django, Flask, FastAPI)

### Has a health endpoint

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8000
    path: /health/
  initial_delay_seconds: 5
  period_seconds: 10
  timeout_seconds: 3
  failure_threshold: 3
```

### No health endpoint (use any 200-returning path)

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8000
    path: /            # bare root; whatever returns 200
  initial_delay_seconds: 10  # Django often takes 5-15s to come up
  period_seconds: 10
  failure_threshold: 3
```

### Auth-required app

If `/` returns 302 redirecting to login, that's still healthy (server is up). Probe a path that handles redirects:

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8000
    path: /
    # PC follows redirects; 200/302/301 all count as healthy
  initial_delay_seconds: 10
```

### Long-running startup (DB migrations, model loading)

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8000
    path: /ready
  initial_delay_seconds: 30      # give Django apps with migrations ~30s
  period_seconds: 15
  timeout_seconds: 5
  failure_threshold: 5            # tolerant during warmup
availability:
  restart: always
  backoff_seconds: 10             # longer backoff matching startup cost
```

## Go binaries

Most Go web servers come up in < 1 second:

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8080
    path: /
  initial_delay_seconds: 1
  period_seconds: 5
  failure_threshold: 3
```

## Node.js / Express / Next.js

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 3000
    path: /
  initial_delay_seconds: 5         # Next.js cold start
  period_seconds: 10
  timeout_seconds: 3
```

For dev servers (`next dev`), the initial route may not be ready immediately. Use a known static asset path or `_next/static/` if the home route is dynamic.

## Static file servers (`python -m http.server`)

```yaml
readiness_probe:
  http_get:
    host: localhost
    port: 8000
    path: /
  initial_delay_seconds: 1
  period_seconds: 5
```

## TCP-only services (databases, message queues, custom protocols)

```yaml
readiness_probe:
  tcp_socket:
    host: localhost
    port: 5432
  initial_delay_seconds: 5
  period_seconds: 10
  failure_threshold: 3
```

## Stuff that doesn't expose ports (daemons, watchers, cron-like)

Use `exec` probe with a custom check, or skip probes entirely:

```yaml
# Option A — exec probe checks daemon's pid file or self-reported status
readiness_probe:
  exec:
    command: "test -f /var/run/myd.pid"
  initial_delay_seconds: 5
  period_seconds: 30

# Option B — no probe at all; depends_on only uses process_started
# (no readiness_probe block, just availability config)
availability:
  restart: always
```

## When the probe is failing — debugging

1. **Check the actual port:** does the service really bind that port? `netstat -ano | grep :8000` (Linux/Mac: `lsof -i :8000`)
2. **Check the actual path:** does `curl -i http://localhost:8000/health` return 2xx/3xx? PC follows redirects but doesn't accept 4xx/5xx as healthy.
3. **Check initial_delay_seconds:** does the service take longer than this to come up?
4. **Check failure_threshold:** is the service flaky, returning 5xx intermittently?

## Anti-patterns

```yaml
# BAD: probing a path that requires auth and returns 401
readiness_probe:
  http_get: { port: 8000, path: /api/users/me }

# BAD: probing a path that 404s during startup but eventually 200s
# (the probe sees 404 → marks Not Ready → never recovers)
readiness_probe:
  http_get: { port: 8000, path: /admin/some-resource }

# BAD: zero initial_delay_seconds — guarantees first probe sees connection refused
readiness_probe:
  http_get: { port: 8000, path: / }
  initial_delay_seconds: 0    # don't do this
```

## See Also

- `dependency-patterns.md` for using readiness probes with `depends_on`
- Upstream docs: https://f1bonacc1.github.io/process-compose/health/
