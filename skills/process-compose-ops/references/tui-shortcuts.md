# TUI Shortcuts Cheatsheet

Launch:

```bash
process-compose attach              # connect to the default port (8080)
process-compose -p 8888 attach      # connect to a non-default API port
```

If you launched PC with `-t=false` (headless), `attach` is how you bring up the TUI later. Quitting the TUI with `q` does **not** stop PC.

## Layout

```
┌──────────────────────────────────────────────────────────────┐
│  Version + Project info                                       │
│  Resources (RAM, CPU)                                         │
├──────────────────────────────────────────────────────────────┤
│  PROCESS LIST (focused by default)                           │
│  PID  NAME           NS  STATUS    AGE  HEALTH  RESTARTS  EX │
│  ...                                                         │
├──────────────────────────────────────────────────────────────┤
│  LOG PANE (logs for selected process)                        │
│  [timestamp] log line                                        │
│  [timestamp] log line                                        │
├──────────────────────────────────────────────────────────────┤
│  F1 Shortcuts  F2 Scale  F3 Find  F4 Maximize  ...           │
└──────────────────────────────────────────────────────────────┘
```

## Navigation

| Key | Action |
|---|---|
| `↑` / `↓` | Move process selection up/down |
| `k` / `j` | Same (vim-style) |
| `Tab` | Move focus between process list and log pane |
| `Home` / `End` | Jump to first / last process |
| `Page Up` / `Page Down` | Page through process list |

## Pane controls

| Key | Action |
|---|---|
| `F4` | Maximize current pane (toggle — second press un-maximizes) |
| `F5` | Toggle log follow (unfollow lets you scroll history) |
| `F6` | Toggle log wrap |
| `Ctrl-S` | Toggle "select on" — clicks select process |

## Process control (selected process)

| Key | Action |
|---|---|
| `r` | Restart |
| `s` | Stop (graceful — SIGTERM) |
| `t` | Start (if stopped) |
| `Ctrl-D` | Disable the process (won't auto-restart) |
| `Ctrl-E` | Re-enable a disabled process |

## Search / filter

| Key | Action |
|---|---|
| `/` | Open filter input (filter process list by name) |
| `F3` | Find in logs (search current log pane) |
| `n` / `N` | Next / previous match in logs |
| `Esc` | Clear filter / cancel input |

## Sorting

| Key | Action |
|---|---|
| `Ctrl-N` | Sort by Name |
| `Ctrl-T` | Sort by Status |
| `Ctrl-A` | Sort by Age |
| `Ctrl-H` | Sort by Health |
| `R` (uppercase) | Reverse current sort |

## Status column legend

| Status | Meaning |
|---|---|
| `Running` | Process is up |
| `Ready` | `readiness_probe` passing (only shown if probe defined) |
| `Not Ready` | Probe failing; PC will keep checking |
| `Restarting` | Between restart attempts (`backoff_seconds`) |
| `Completed` | Exited successfully (only for non-restart processes) |
| `Failed` | Exited with error and out of restart budget |
| `Pending` | Waiting on `depends_on` to be satisfied |
| `Disabled` | Manually disabled or `disabled: true` in YAML |
| `Skipped` | A dependency failed so this process was skipped |

## Exit

| Key | Action |
|---|---|
| `q` | Quit TUI (PC keeps running headless) |
| `Ctrl-C` | Same |
| `?` | Show help overlay |

## Headless workflow (no TUI)

If you don't want the TUI but need to peek at state:

```bash
# Process list
process-compose -p 8888 process list

# Logs for one process
process-compose -p 8888 process logs my-service --follow
process-compose -p 8888 process logs my-service        # one-shot, no follow

# Control without TUI
process-compose -p 8888 process restart my-service
process-compose -p 8888 process stop my-service
process-compose -p 8888 process start my-service
```

## See Also

- Schema reference for `is_foreground`, `is_tty`, `disable_ansi_colors` which affect log rendering in the TUI
- Upstream docs: https://f1bonacc1.github.io/process-compose/tui/
