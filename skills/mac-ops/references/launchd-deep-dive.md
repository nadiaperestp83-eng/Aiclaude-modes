# launchd Deep Dive

Load this when designing, debugging, or disabling a launchd service. Covers plist semantics, domain targets, the `disable` vs `bootout` vs `unload` distinction, and the Apple Silicon system extension story.

## Contents

1. [What launchd is](#what-launchd-is)
2. [Plist locations](#plist-locations)
3. [Plist key reference](#plist-key-reference)
4. [Domain targets](#domain-targets) — system / user / gui
5. [disable vs bootout vs unload](#disable-vs-bootout-vs-unload)
6. [Common semantics](#common-semantics) — RunAtLoad, KeepAlive, ThrottleInterval
7. [Why daemons fail to load](#why-daemons-fail-to-load)
8. [System extensions vs kexts](#system-extensions-vs-kexts) — Apple Silicon story
9. [Diagnostic commands](#diagnostic-commands)

## What launchd is

`launchd` is macOS's init system AND its services manager — PID 1. It replaces `init`, `cron`, `at`, `xinetd`, `inetd`, and various startup hooks. Everything that runs as a background process on macOS — Apple's daemons, third-party agents, helper tools — is started, monitored, and (when necessary) restarted by launchd.

A "launchd job" is described by a property list (plist). The plist names the job (Label), tells launchd what to run (ProgramArguments), when to run it (RunAtLoad, KeepAlive, StartCalendarInterval, WatchPaths), and how to handle failures (ThrottleInterval, ExitTimeOut).

## Plist locations

| Path | Scope | Loaded as |
|---|---|---|
| `~/Library/LaunchAgents/*.plist` | Current user only | gui/$UID |
| `/Library/LaunchAgents/*.plist` | Any logged-in user | gui/$UID per user |
| `/Library/LaunchDaemons/*.plist` | System-wide, runs as specified UID (usually root) | system |
| `/System/Library/LaunchAgents/*.plist` | Apple's per-user agents | gui/$UID (read-only) |
| `/System/Library/LaunchDaemons/*.plist` | Apple's daemons | system (read-only) |

**Agent vs Daemon:**
- Agent runs in user context, has access to the GUI, dies when the user logs out
- Daemon runs system-wide, no GUI, survives logout

The most common third-party startup item is a LaunchAgent in `/Library/LaunchAgents/` — system-installed (admin needed to write there) but runs per-logged-in-user.

## Plist key reference

Essential keys:

| Key | Type | Purpose |
|---|---|---|
| `Label` | string | Unique identifier (reverse-DNS by convention, e.g. `com.example.MyDaemon`) |
| `ProgramArguments` | array | argv to exec — `[interpreter, arg1, arg2...]` |
| `Program` | string | (alternative) single binary path; rarely used now |
| `RunAtLoad` | bool | Run once immediately when the job is loaded |
| `KeepAlive` | bool or dict | Restart the process if it exits (see below for dict form) |
| `ThrottleInterval` | int | Minimum seconds between restarts (default 10) |
| `StartCalendarInterval` | dict | Cron-style schedule (Minute, Hour, Day, Weekday, Month) |
| `StartInterval` | int | Run every N seconds |
| `WatchPaths` | array | Run when any of these paths changes |
| `QueueDirectories` | array | Run when any of these dirs becomes non-empty |
| `StandardOutPath` | string | Redirect stdout to this file |
| `StandardErrorPath` | string | Redirect stderr to this file |
| `EnvironmentVariables` | dict | Env vars for the launched process |
| `UserName` | string | UID to run as (daemons only) |
| `GroupName` | string | GID to run as |
| `WorkingDirectory` | string | cwd |
| `Disabled` | bool | Initial disabled state (rarely used — prefer `launchctl disable`) |
| `LimitLoadToSessionType` | string | "Aqua" (logged-in user), "Background", "LoginWindow", "System" |
| `MachServices` | dict | Mach service names this process publishes |
| `Sockets` | dict | Sockets to set up before the program runs |
| `LaunchOnlyOnce` | bool | Once loaded, never re-run |

`KeepAlive` as a dict (more nuanced):

```xml
<key>KeepAlive</key>
<dict>
    <key>SuccessfulExit</key><false/>     <!-- only restart on failure -->
    <key>NetworkState</key><true/>         <!-- only run when network is up -->
    <key>PathState</key>                   <!-- only run while paths exist -->
    <dict>
        <key>/usr/local/bin/foo</key><true/>
    </dict>
    <key>Crashed</key><true/>              <!-- only restart if crashed -->
</dict>
```

## Domain targets

`launchctl` operations take a **domain/label** pair. The domain determines which launchd instance hosts the job.

| Domain | Form | What it covers |
|---|---|---|
| `system` | `system` | Root-level daemons (`/Library/LaunchDaemons/`, `/System/Library/LaunchDaemons/`) |
| `user/<UID>` | `user/501` | A specific user's background tasks (no GUI) |
| `gui/<UID>` | `gui/501` | A specific user's GUI session (most LaunchAgents live here) |
| `pid/<PID>` | `pid/12345` | A single process's environment |

Most operations on user agents target `gui/$UID` because that's where Aqua-session agents run.

## disable vs bootout vs unload

The three commands look interchangeable but aren't. Choose based on intent.

### `launchctl disable <domain>/<label>`

**Effect:** Marks the job as disabled. The mark persists across reboots. The job will not be loaded next time launchd starts.

**Does NOT:** Stop the currently running process.

**Reversible:** Yes — `launchctl enable <domain>/<label>`.

**Use when:** You want to permanently stop a service from auto-starting.

```bash
launchctl disable gui/$UID/com.example.helper
```

### `launchctl bootout <domain>/<label>`

**Effect:** Unloads the currently running job. Stops the process. The job will come back on next reboot UNLESS also `disable`d.

**Reversible:** Implicit — next reboot reloads.

**Use when:** You want to kill the running daemon right now but allow it to come back later.

```bash
launchctl bootout gui/$UID/com.example.helper
```

### `launchctl unload <plist-path>`

**Legacy form** of `bootout`. Takes a path instead of a domain/label. Still works on most macOS versions but deprecated; prefer `bootout`.

### The right combo for "make this stop forever"

```bash
launchctl disable gui/$UID/com.example.helper        # don't reload on next boot
launchctl bootout gui/$UID/com.example.helper         # kill the running process
```

For system daemons:

```bash
sudo launchctl disable system/com.example.daemon
sudo launchctl bootout system/com.example.daemon
```

## Common semantics

### `RunAtLoad=true` + `KeepAlive=false`

Run once at load (typically at user login or system boot). If the process exits, don't restart.

### `RunAtLoad=true` + `KeepAlive=true`

Run at load, restart whenever it exits — "always running" service.

### `RunAtLoad=false` + `StartCalendarInterval`

Don't run at load. Run on a schedule. Equivalent to cron.

### `RunAtLoad=false` + `WatchPaths`

Don't run at load. Run when a specific path is written to. Used for "watch this file for changes".

### `ThrottleInterval`

Minimum seconds between restarts. Default 10. If a job crashes faster than this, launchd will throttle it ("service throttled by N seconds" in the log). High throttling = the daemon is crash-looping.

## Why daemons fail to load

In rough order of frequency:

1. **Plist syntax error** — `plutil -lint /path/to/plist` validates structure
2. **Wrong file ownership** — system daemons must be owned `root:wheel` with mode `644`; LaunchAgents owned by the user (or root)
3. **Wrong permissions** — `chmod 644` on the plist itself
4. **Program path missing** — the binary doesn't exist or isn't executable
5. **Label collision** — another job with the same Label is already loaded
6. **Code signature mismatch** — Apple Silicon enforces signing; ad-hoc signed binaries may need `spctl --add`
7. **TCC denial** — the program needs a TCC permission to work; without it, it crash-loops
8. **Sandbox violation** — sandbox profile denies a syscall the program needs
9. **Missing dependency** — a service it requires hasn't been declared
10. **Throttled** — was crashing too fast; launchd backed off

Check load errors:

```bash
launchctl print gui/$UID/com.example.helper          # detailed state
launchctl print-disabled gui/$UID | grep example     # is it disabled?
log show --predicate 'process == "launchd"' --last 1h --style compact | grep example
```

## System extensions vs kexts

On Apple Silicon, kernel extensions (kexts) are deprecated. Most kernel-level integrations have moved to **System Extensions** — daemons in `/Library/SystemExtensions/` that run in user-mode but have privileged kernel APIs available via XPC.

Key differences:

| Property | Kext | System Extension |
|---|---|---|
| Lives in | `/Library/Extensions` | `/Library/SystemExtensions/<UUID>/<name>.systemextension` |
| Loads via | kextd | `sysextd` |
| Requires reboot | Often | Usually not |
| Apple Silicon | Limited (deprecated) | Fully supported |
| Signing | Notarized + user approved | Notarized + user approved + Family-specific entitlements |

Inventory:

```bash
systemextensionsctl list
```

Disable via the system extension's app removing it, or:

```bash
systemextensionsctl uninstall <team-id> <bundle-id>
```

## Diagnostic commands

```bash
# Print all loaded jobs in user domain
launchctl print gui/$UID | head -40

# Print all loaded jobs in system domain
sudo launchctl print system | head -40

# Specific job's state
launchctl print gui/$UID/com.example.helper

# What's currently disabled?
launchctl print-disabled gui/$UID
sudo launchctl print-disabled system

# Validate a plist
plutil -lint /Library/LaunchAgents/com.example.helper.plist

# Convert plist to readable format
plutil -convert xml1 -o - /Library/LaunchAgents/com.example.helper.plist

# Watch launchd's log for a specific job
log stream --predicate 'process == "launchd" AND eventMessage CONTAINS "com.example"'
```

## Cross-references

- `scripts/startup-audit.sh` — inventory all launchd jobs
- `scripts/safe-disable-startup.sh` — disable + bootout in one step, reversible
- For Windows equivalent (Services + Scheduled Tasks + Run keys), see `windows-ops/references/startup-mechanisms.md`
- For TCC interaction with daemons, see `tcc-mechanics.md`
