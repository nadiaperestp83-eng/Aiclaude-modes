# mac-ops ↔ windows-ops Cross-Reference

Load this when you need to do the same diagnostic on the other OS, or when a household has both Macs and Windows machines and you want consistent verdict output.

The skills mirror each other deliberately — same diagnostic ladder structure, same `[PASS]/[FAIL]/[WARN]/[INFO]` output, same `--json` / `--redact` / `--quiet` / `--verbose` modes. The differences below are the **OS-specific surface** that determined what each skill calls out.

## Diagnostic ladder side-by-side

| Rung | mac-ops | windows-ops | Notes |
|---|---|---|---|
| 1 | Hardware (pmset, SMC events, thermal) | Hardware (WHEA-Logger) | Same purpose, different log surface |
| 2 | Storage (APFS, IO errors via log show, snapshot bloat) | Storage (disk 7/52/153/154, storahci 129) | Both prioritize storage as the highest-yield audit |
| 3 | Panic record (DiagnosticReports/*.{panic,ips}) | Crash record (Event 41 + BugCheck code) | Different file/event formats; same triage flow |
| 4 | Pre-panic timeline | Pre-crash timeline | Identical methodology, different log commands |
| 5 | Startup inventory (Login Items + LaunchAgents + LaunchDaemons + profiles) | Startup inventory (Run keys + Services + Tasks + Folders + GroupPolicy) | macOS has 4 mechanisms; Windows has 5 |
| 6 | Resource pressure (CPU/mem snapshots) | Resource pressure | Same kind of check |
| 7 | **TCC permissions (mac-unique)** | **(no equivalent — Windows uses per-API permission, not centralized)** | The biggest unique-to-mac dimension |
| 8 | Verdict | Verdict | Same shape, different prompts |

mac-ops has 8 rungs vs windows-ops's 7 because TCC (Transparency, Consent, Control) is enough of a distinct failure mode that it earns its own rung. Windows has no equivalent — per-API permissions exist but aren't routed through a single user-visible system.

## Script equivalents

| windows-ops | mac-ops | Notes |
|---|---|---|
| `health-audit.ps1` | `health-audit.sh` | Same orchestrator role |
| `disk-health.ps1` | `disk-health.sh` | APFS instead of NTFS; `diskutil` instead of `Get-Disk` |
| `crash-triage.ps1` | `panic-triage.sh` | Event 41 vs `.panic`/`.ips`; same pre-window query pattern |
| `drive-dependencies.ps1` | `drive-dependencies.sh` | "safe to disconnect?" check on both sides |
| `safe-disable-startup.ps1` | `safe-disable-startup.sh` | `StartupApproved` byte flip vs `launchctl disable`; both reversible |
| `recover-clone.ps1` | `recover-clone.sh` | `robocopy /R:0` vs `rsync --partial --inplace --no-whole-file --append-verify --ignore-errors` |
| `boot-perf.ps1` | `boot-perf.sh` | Diagnostics-Performance log vs unified log |
| — | `tcc-audit.sh` | mac-unique |
| — | `wake-reasons.sh` | mac has pmset log; Windows uses `powercfg` (not as detailed) |
| — | `spotlight-status.sh` | mac-unique (Windows Search has WSearch service but rarely a diagnostic concern) |
| — | `storage-pressure.sh` | mac-unique (APFS snapshots + local TM are the "where did my disk go?" cause) |
| — | `kext-audit.sh` | Windows has WDM drivers; loaded via different mechanism, not panic-prone in the same way |
| — | `firewall-audit.sh` | Windows has its own firewall stack — different audit. Could exist as `windows-ops/firewall-audit.ps1` but isn't yet. |
| — | `network-locations.sh` | mac-unique — Network Locations is a macOS feature |
| — | `sysdiagnose-helper.sh` | mac-unique (Windows has `dxdiag` and `msinfo32` but different scope) |

## Reference doc equivalents

| windows-ops | mac-ops | Notes |
|---|---|---|
| `storage-events.md` | `storage-events.md` | Event IDs catalog vs log-show patterns |
| `bugcheck-codes.md` | `panic-codes.md` | BSOD stop codes vs panic strings + kext provenance |
| `startup-mechanisms.md` | `startup-mechanisms.md` | 5 Windows mechanisms vs 4 macOS |
| `recovery-patterns.md` | `recovery-patterns.md` | BCD/Windows RE vs recoveryOS/Share Disk |
| `remote-diagnostics.md` | `remote-diagnostics.md` | WS-Man/PSRemoting vs SSH |
| — | `tcc-mechanics.md` | mac-unique |
| — | `launchd-deep-dive.md` | mac-unique (Windows has SCM + Task Scheduler, conceptually different) |
| — | `apple-silicon-specifics.md` | mac-unique |

## Conventions in common

- **Verdict-first output**: every script ends with a SUMMARY block + a "Next:" hint pointing at the right drilldown
- **Reversible operations**: `disable` ops always have a corresponding `--enable`; no script destroys data without `--apply`
- **Cardinal rules per OS**:
  - mac-ops: never `fsck_apfs -y` a failing drive
  - windows-ops: never `chkdsk /f` a failing drive
  - Both: image first, repair second
- **JSON output as a contract**: stdout is pure NDJSON; stderr may have noise. Use `2>/dev/null` when piping to `jq`.
- **Opsec mode**: `--redact` masks RFC1918 / CGNAT / link-local / MAC / tailnet names / UUIDs on both skills
- **Cross-platform addresses preserved**: Tailscale's `100.100.100.100` and public DNS resolvers stay visible as diagnostic anchors

## When to use which

| You have... | Use |
|---|---|
| A Windows machine with kernel crashes | `windows-ops/scripts/crash-triage.ps1` |
| A Mac with kernel panics | `mac-ops/scripts/panic-triage.sh` |
| A networking problem on either | `net-ops` (cross-platform) |
| A failing drive on either | mac/windows-ops `disk-health` then `recover-clone` |
| App can't access mic / screen / files on Mac | `mac-ops/scripts/tcc-audit.sh` (no Windows analog) |
| Slow boot on either | mac/windows-ops `boot-perf` |
| Mac wakes at 3am | `mac-ops/scripts/wake-reasons.sh` (no Windows analog — `powercfg /lastwake` is similar but less detailed) |
| Mixed-OS household, same support issue | Run both skills' `health-audit` and diff |

## Differences that matter for diagnosis

1. **Windows tells you BugCheck codes**: `0xEF`, `0xD1`, `0x124` — searchable, classifiable, well-documented
   **macOS gives panic strings**: free-form text, must pattern-match (catalog in `panic-codes.md`)

2. **Windows storage signal is event-ID based**: stable across versions, single-shot grep
   **macOS storage signal is in unified log**: rich but slow to query; `log show --last 30d` takes 30-60s

3. **Windows has 5 startup mechanisms**: registry Run keys, services, scheduled tasks, startup folders, group policy
   **macOS has 4**: Login Items, LaunchAgents (user + system), LaunchDaemons, legacy LoginHook

4. **Windows kernel-extension panics are common**: third-party drivers ship as kexts/WDM
   **macOS Apple Silicon panics are rarer**: kexts deprecated; system extensions run user-mode

5. **macOS has TCC, Windows doesn't**: privacy permissions are a *first-class diagnostic concern* on mac, not on Windows

6. **macOS has APFS snapshots + local TM**: "disk full" is often purgeable space; Windows doesn't have the same hidden-allocation surface

7. **Remote diagnostics**: Windows has PSRemoting / WinRM (rich); macOS is SSH-only (simpler)

## Same diagnostic, different commands

| What | Windows | macOS |
|---|---|---|
| List loaded drivers/kexts | `driverquery` | `kextstat` / `kmutil showloaded` |
| List running services | `Get-Service` | `launchctl print` |
| Check kernel crash log | `Get-WinEvent -Id 41` | `ls /Library/Logs/DiagnosticReports/*.panic` |
| Check disk SMART | `Get-PhysicalDisk` reliability counter | `diskutil info` or `smartctl` (brew) |
| Disable startup app | StartupApproved registry byte | `launchctl disable` |
| Boot to recovery | `Cmd-R` (Mac on Intel) / power button (Apple Silicon) | `Cmd-R` / power button |
| Verbose boot | (always shows on BSOD) | `nvram boot-args="-v"` |
| Reset SMC | Shift-Ctrl-Option-Power 10s (Intel only) | n/a on Apple Silicon (SoC handles it) |

## Cross-references

- `mac-ops/SKILL.md` — the macOS diagnostic skill
- `windows-ops/SKILL.md` — the Windows diagnostic skill
- `net-ops/SKILL.md` — networking layer (both OSes)
