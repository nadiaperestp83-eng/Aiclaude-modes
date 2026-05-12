# process-compose.yaml Schema Reference

Comprehensive reference for the YAML schema (`version: "0.5"`). Annotated with field semantics, defaults, and gotchas.

## Top-level

```yaml
version: "0.5"               # required; current schema version

log_level: info              # debug | info | warn | error  (default: info)
log_length: 1000             # lines retained in TUI's in-memory log buffer
log_no_color: false          # disable ANSI colour in log file
log_timestamps: true         # prepend ISO-8601 timestamp to each line
log_truncate: false          # truncate logs on startup instead of appending

processes:                   # required; map of process-name → spec
  <name>:
    ...                      # see Process Spec below

environment:                 # OPTIONAL global env vars applied to every process
  - "GLOBAL_VAR=value"
```

## Process Spec

### Required

```yaml
command: "string"            # shell command to execute (no shell interpolation
                             # unless explicitly wrapped — see "command quoting"
                             # below)
```

### Recommended

```yaml
working_dir: "/abs/path"     # cwd; otherwise inherits PC's cwd
environment:                 # array of KEY=value strings
  - "ENV_VAR=value"
  - "PYTHONUNBUFFERED=1"
```

### Lifecycle

```yaml
availability:
  restart: always            # always | exit_on_failure | on_failure | no
  backoff_seconds: 5         # delay before next restart attempt
  max_restarts: 20           # absolute cap; 0 = unlimited
  exit_on_skipped: false     # treat skipped-by-dep failure as exit
  schedule: "0 2 * * *"      # cron schedule for periodic execution
                             # (mutually exclusive with restart: always)

shutdown:
  signal: 15                 # SIGTERM (default) or 9 for SIGKILL
  timeout_seconds: 30        # SIGKILL escalation deadline
  command: "graceful-cli stop"  # optional pre-stop command
```

### Health checks

```yaml
readiness_probe:             # marks process "Ready" for depends_on
  http_get:
    host: localhost
    port: 8000
    path: /health            # bare "/" is fine if no health endpoint
    scheme: HTTP             # HTTP (default) or HTTPS
  # OR alternative probe types:
  # exec:
  #   command: "curl -f http://localhost:8000/health"
  # tcp_socket:
  #   host: localhost
  #   port: 8000
  initial_delay_seconds: 5   # wait before first probe
  period_seconds: 10         # interval between probes
  timeout_seconds: 3         # per-probe timeout
  success_threshold: 1       # consecutive successes to mark Ready
  failure_threshold: 3       # consecutive failures to mark Not Ready

liveness_probe:              # restarts process if probe fails
  ...                        # same shape as readiness_probe
```

### Dependencies

```yaml
depends_on:
  database:
    condition: process_healthy   # wait until database's readiness_probe passes
  migrations:
    condition: process_completed_successfully   # wait for one-shot init
```

Conditions:

| Condition | Wait until... | Use when |
|---|---|---|
| `process_started` | Dependency spawned (PID exists) | Weakest; use only when ordering matters but readiness doesn't |
| `process_healthy` | Dependency's readiness_probe passes | Strongest; preferred for runtime services |
| `process_completed` | Dependency exited (any code) | One-shot init that may fail |
| `process_completed_successfully` | Dependency exited 0 | One-shot init that must succeed |

### Logging

```yaml
log_location: "logs/myapp.log"   # relative to PC's cwd or absolute path
log_max_size_kb: 0               # rotation threshold; 0 = no rotation
log_max_backups: 0               # rotated files to retain
log_max_age_days: 0              # age-based rotation
log_compress: false              # gzip rotated logs
```

### Identity / grouping

```yaml
namespace: "backend"         # group processes; --namespace flag filters by it
replicas: 3                  # spawn N independent copies (named myapp@0, @1, @2)
disabled: false              # exclude from `up` without deleting the spec
is_daemon: false             # set true for processes that fork and exit
                             # (e.g. systemd-style daemons)
```

### Visibility

```yaml
is_foreground: false         # show full output in TUI immediately
is_tty: false                # allocate a PTY (interactive processes)
disable_ansi_colors: false   # strip ANSI from this process's logs
```

## Command Quoting

YAML loves to surprise here. Three reliable patterns:

```yaml
# Pattern 1 — simple command, no quotes anywhere
command: pythonw manage.py runserver 0.0.0.0:8000

# Pattern 2 — single-quoted (literal, no escapes processed)
command: 'pythonw "C:\Program Files\foo\app.py" --port 8000'

# Pattern 3 — double-quoted (escapes processed, watch the backslashes)
command: "pythonw -m my_module"

# Pattern 4 — wrap the exe path in double quotes inside a single-quoted string
command: '"C:/Program Files/Git/usr/bin/bash.exe" --login script.sh'
```

**Windows PATH env vars must be single-quoted** to escape backslashes:

```yaml
environment:
  # WRONG: double quotes try to interpret \P, \U, etc. as escape codes
  # - "PATH=C:\Program Files\Git\usr\bin;..."

  # RIGHT:
  - 'PATH=C:\Program Files\Git\usr\bin;C:\Users\me\AppData\Local\Programs\Python\Python313'
```

## File Composition

You can split config across files and merge:

```bash
process-compose up -f base.yaml -f overrides.yaml -f local.yaml
```

Later files override earlier ones. Useful pattern: base config in repo + per-machine overrides in gitignored `local.yaml`.

## Validation

```bash
process-compose up -f process-compose.yaml --dry-run
# → "Validated N configured processes from M files."
```

Run before committing. Catches:
- YAML parse errors (escape issues, indentation)
- Missing required fields
- Invalid restart policy values
- Circular depends_on chains

## Hot Reload

```bash
process-compose -p 8888 project update -f process-compose.yaml
```

Reloads the config in a running PC instance. Added processes start; removed processes stop; changed processes restart.
