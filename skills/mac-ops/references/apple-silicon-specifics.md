# Apple Silicon Specifics

Load this when working on M1/M2/M3/M4 Macs and the diagnostic behavior differs from Intel. Apple Silicon changed enough fundamental boot, security, and panic surface that some Intel-era assumptions don't carry over.

## Contents

1. [Detecting Apple Silicon](#detecting-apple-silicon)
2. [Boot recovery](#boot-recovery)
3. [Security policy](#security-policy)
4. [Kexts vs system extensions](#kexts-vs-system-extensions)
5. [Panic format differences](#panic-format-differences)
6. [SMC / Secure Enclave](#smc--secure-enclave)
7. [Battery + power](#battery--power)
8. [What carried over unchanged](#what-carried-over-unchanged)

## Detecting Apple Silicon

```bash
uname -m              # arm64 → Apple Silicon, x86_64 → Intel
sysctl -n machdep.cpu.brand_string
sysctl -n hw.model    # e.g. "Mac15,3"
```

For scripts that need to branch:

```bash
if [[ "$(uname -m)" == "arm64" ]]; then
    # Apple Silicon path
fi
```

The mac-ops common.sh provides `is_apple_silicon` as a function.

## Boot recovery

**Intel:**
- `Cmd-R` at boot → recoveryOS
- `Cmd-Shift-R` → Internet Recovery (downloads recoveryOS)
- `Cmd-Option-P-R` → reset NVRAM
- `Cmd-Option-Shift-Cmd-R` → factory original macOS
- Shift → Safe Boot
- `Cmd-S` → single-user mode
- `Cmd-V` → verbose boot
- `T` → Target Disk Mode (FireWire/Thunderbolt)

**Apple Silicon (M1+):**
- Hold power button at boot → "Loading startup options" → choose Options
- All recovery modes accessed from the startup options screen, not from boot-key combos
- **No** single-user mode
- **No** NVRAM reset key combo (NVRAM behavior is different; `sudo nvram -c` from running macOS)
- Safe Boot: hold power, then hold Shift while choosing volume
- Verbose Boot: enable via `nvram boot-args="-v"` from running macOS
- Share Disk (Apple Silicon's Target Disk Mode equivalent): recoveryOS → Utilities → Share Disk

## Security policy

Apple Silicon introduces **per-volume security policy** via the **Local Policy Object**. This controls:

- Whether kernel extensions can load at all
- Whether unsigned kernel extensions are allowed
- Whether the OS can be booted in reduced security mode

Inspect (recoveryOS only):

```bash
bputil -d            # display
```

Modify (recoveryOS, requires admin auth):

```bash
bputil -k            # allow kernel extensions
bputil --set-local-boot-policy-version <version>
```

Three tiers:

| Tier | Description | What it gates |
|---|---|---|
| **Full Security** | Default. Only Apple-signed code, only the version of macOS this Mac was installed with | Maximum security; no kext loading |
| **Reduced Security** | Allow installer-signed kexts; allow third-party kernel extensions | Required to load any kext on Apple Silicon |
| **Permissive Security** | Boot any signed code; allow ad-hoc signed | Used by developers; do not run permissively in normal use |

To install a third-party kext on Apple Silicon, you must:

1. Boot to recoveryOS
2. Run `bputil` to set Reduced Security
3. Approve "Allow user management of kernel extensions"
4. Boot normally
5. Install the kext
6. Approve in System Settings → Privacy & Security
7. Reboot

This is by design — kext loading is significantly harder on Apple Silicon than on Intel.

## Kexts vs system extensions

**Intel:**
- Kexts in `/Library/Extensions/` + `/System/Library/Extensions/`
- Loaded via `kextload` / `kextd`
- Inspect with `kextstat`

**Apple Silicon:**
- Kexts deprecated; most things have moved to **System Extensions** in `/Library/SystemExtensions/<UUID>/`
- Run in user-mode with privileged-API XPC channels
- Inspect with `systemextensionsctl list`
- Loaded via `sysextd`
- Kexts still possible (Reduced Security mode) but discouraged

For diagnostic scripts:

| Concern | Intel | Apple Silicon |
|---|---|---|
| Inventory kexts | `kextstat -l` | `kmutil showloaded` |
| Inventory system extensions | `systemextensionsctl list` | `systemextensionsctl list` |
| Kext load failures | `log show ... process == "kextd"` | `log show ... process == "kmutil"` |

The `scripts/kext-audit.sh` script handles both paths.

## Panic format differences

| Concern | Intel | Apple Silicon |
|---|---|---|
| Panic file extension | `.panic` (legacy) + `.ips` | `.ips` only on recent macOS |
| Stack trace addressing | x86_64 | ARM64 |
| Common panic string | `page_fault`, `general_protection` | `Kernel data abort`, `panic_kthread` |
| iBoot version line | absent | present (`iBoot-XXXXXXX.XX.X`) |
| "secure boot?" line | present | present |
| SMC dump in panic | sometimes | absent (no user-accessible SMC) |

When triaging panics on Apple Silicon:

1. Backtrace addresses are ARM64, so symbolication is different
2. Many Intel-era kext crashes can't happen (those kexts won't load)
3. Boot policy version + secure boot state should appear at the bottom of the report

## SMC / Secure Enclave

**Intel:**
- SMC (System Management Controller) is a separate chip controlling power, thermals, lid sensor, etc.
- User-resetable: shut down → hold Shift+Control+Option+Power for 10 seconds
- SMC events appear in unified log
- Panics can reference SMC state

**Apple Silicon:**
- SMC functions absorbed into the SoC (T2-equivalent functionality)
- **Not user-resetable** in the traditional sense
- Power button hold + recoveryOS handles equivalent "reset" via firmware reload
- Secure Enclave is the SoC's secure coprocessor (replaces both SMC + T2 Secure Enclave)

For "reset SMC" troubleshooting on Apple Silicon: simply shut down, wait 30s, power on. There's no equivalent reset combo; the SoC handles its own state.

## Battery + power

`pmset -g` behavior is largely identical but:

- Apple Silicon has **standby** that's deeper than Intel's
- Power Nap is on by default on Apple Silicon laptops (System Settings → Battery → Options)
- Dark wake budget is more aggressive
- `kernel_task` CPU on Apple Silicon is **not** a thermal proxy the way it was on Intel — instead, SoC-level throttling happens silently

Battery health:

```bash
system_profiler SPPowerDataType | grep -E "Cycle Count|Condition|Maximum Capacity"
```

Apple Silicon laptops support a "Maximum Capacity" metric out of the box. Intel Macs require third-party utilities (coconutBattery) for that data.

## What carried over unchanged

Don't over-correct. These work identically on Apple Silicon:

- `launchd` plist semantics
- TCC database structure and location
- APFS commands (`diskutil apfs ...`)
- `log show` queries
- `pmset -g log` format (largely)
- Network settings (`networksetup`, `scutil`)
- Time Machine (`tmutil`)
- Spotlight (`mdutil`)
- SSH server configuration
- Configuration profiles
- DiagnosticReports location

The big-shift areas are: kexts, security policy, boot recovery UX, SMC, and panic format. Almost everything else stayed put.

## Cross-references

- `scripts/kext-audit.sh` — handles both Intel kexts and Apple Silicon system extensions
- `scripts/panic-triage.sh` — handles both `.panic` and `.ips` formats
- For boot recovery procedures, see `recovery-patterns.md`
- For panic decoding, see `panic-codes.md`
