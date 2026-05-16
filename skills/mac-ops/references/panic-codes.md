# macOS Kernel Panic Codes

Load this when decoding a kernel panic report from `/Library/Logs/DiagnosticReports/`. macOS doesn't use numeric bugcheck codes the way Windows does — instead, panics carry **strings**. The string + the loaded kext list together identify the cause.

## Contents

1. [Panic file formats](#panic-file-formats)
2. [Anatomy of a panic report](#anatomy-of-a-panic-report)
3. [Common panic strings](#common-panic-strings)
4. [Kext provenance — Apple vs third-party](#kext-provenance--apple-vs-third-party)
5. [Apple Silicon panic specifics](#apple-silicon-panic-specifics)
6. [Pre-panic correlation](#pre-panic-correlation)
7. [When there's no panic report](#when-theres-no-panic-report)

## Panic file formats

| Era | Path | Format |
|---|---|---|
| macOS 10.x → 11 | `/Library/Logs/DiagnosticReports/*.panic` | Plain text |
| macOS 12+ | `/Library/Logs/DiagnosticReports/Kernel_*.ips` | JSON header + plain-text body |
| User-mode crashes | `~/Library/Logs/DiagnosticReports/*.ips` | App crashes (not kernel panics) |

`.ips` files have a JSON metadata header on the first line, then the panic body below. To extract the body:

```bash
tail -n +2 /Library/Logs/DiagnosticReports/Kernel-2026-05-15-031422.ips
```

## Anatomy of a panic report

A typical panic report contains:

```
panic(cpu N caller 0x...): "<panic string>"@<source-file>:<line>
Backtrace (CPU N), Frame : Return Address
0xffffffaeb01: 0xffff80019c... addr2line: __ZN16IOPlatformPlugin...
...
Mac OS version: 23F79
Kernel version: Darwin Kernel Version 23.5.0...
Kernel UUID:    ABC...
iBoot version:  iBoot-10151.121.1
secure boot?:   YES
roots installed: 0
Paniclog version: 14

Loaded kexts:
  com.apple.driver.AppleEFIRuntime    1
  com.apple.iokit.IOACPIFamily        1.5
  com.example.product.kext            2.1.7      <— third-party suspect
  ...
```

The **panic string** identifies the failure class. The **call stack** points at the kext / function. The **kext list** narrows the suspect.

## Common panic strings

### Storage / IO

| String fragment | Likely cause | First action |
|---|---|---|
| `"Sleep wake failure in EFI"` | Driver hung crossing sleep/wake | Check USB / BT / GPU driver versions; remove third-party kext |
| `"unresponsive bootstrap subsystem"` | launchd deadlock at boot | Boot safe mode; audit `/Library/LaunchDaemons/` |
| `"VFS error mounting volume"` | Filesystem mount failed | Boot recoveryOS, run `diskutil verifyVolume` |
| `"APFS reaper: ... corruption"` | APFS metadata corruption | Image first; do NOT `fsck_apfs -y` |
| `"IOPlatformPanicAction"` | Hardware-initiated panic (often thermal / power) | Check `pmset -g log` for power events around panic time |

### Memory / pagefault

| Fragment | Cause |
|---|---|
| `"Kernel trap at ... page_fault"` | Kernel-mode memory access fault — driver bug or RAM fault |
| `"double_fault"` | Kernel handler itself crashed during fault handling — very serious |
| `"general_protection"` | Kernel touched invalid memory region |
| `"Kernel data abort"` (Apple Silicon) | Memory access violation in kernel/kext |

### Driver / kext

| Fragment | Cause |
|---|---|
| `"WindowServer panic"` or `"AGXFirmwareKernExt"` | GPU driver fault. Try external display, alternative GPU mode |
| `"Bluetooth panic"` or `"IOBluetoothFamily"` | BT stack issue — unpair recent devices |
| `"AppleACPIPlatform"` | ACPI / firmware interaction — rare but tied to motherboard |
| `"AppleAHCIPort"` / `"AppleNVMeFamily"` | Storage controller. Check disk-health |
| `"IOAudioFamily"` / `"AppleHDA"` | Audio driver. Often triggered by external audio interface |
| `"IOUSBHostFamily"` | USB driver fault — unplug recent USB devices |
| `"IOFireWireFamily"` | FireWire (legacy) — rare on modern Macs |

### Sleep / power

| Fragment | Cause |
|---|---|
| `"Sleep wake failure"` | Driver crossing power state. Look at backtrace for kext name |
| `"Wake transition timed out"` | Specific driver took too long to wake |
| `"smc panic"` (rare) | SMC firmware issue. Reset SMC (Intel only — Apple Silicon doesn't have user-resetable SMC) |

### Watchdog / hang

| Fragment | Cause |
|---|---|
| `"panic_kthread"` | Kernel watchdog timeout — a driver was in infinite loop |
| `"Hard hang on cpu N"` | Specific CPU stuck — possibly hardware |

## Kext provenance — Apple vs third-party

The most important triage: is the panic in an Apple kext, or a third-party kext?

| Prefix | Origin | Diagnostic value |
|---|---|---|
| `com.apple.*` | Apple-shipped | Harder to fix — likely a bug. Check for OS updates. |
| `com.<vendor>.*` (Adobe, Paragon, Eltima, ESET, etc.) | Third-party | **Primary suspect.** Try removing/updating the kext. |

Common third-party kexts that show up in panics:

| Kext label | Vendor | Reason |
|---|---|---|
| `com.eltima.ProductX` | Eltima Software | USB virtualization, often crashes |
| `com.paragon-software.fs.kext.ntfs` | Paragon NTFS | Filesystem driver |
| `com.eset.kext.esets-eset_ctl` | ESET | Anti-virus / firewall |
| `com.kaspersky.kext.*` | Kaspersky | AV |
| `com.driver.AcmeUSB` | Misc. drivers | Various |
| `com.intel.driver.EnergyDriver` | Intel (Boot Camp era) | Power management |

If you see ANY `com.<thirdparty>` kext in the panic kext list, that's your starting point — especially if it appears in the call stack itself, not just the loaded-kext inventory.

Note: many vendors now ship **System Extensions** instead of kexts (especially on Apple Silicon). System extensions show up differently — see `references/launchd-deep-dive.md`.

## Apple Silicon panic specifics

Apple Silicon panics use a slightly different format and include more hardware context. Key differences:

- Panic file naming: `Kernel-YYYY-MM-DD-HHMMSS.panic` and `.ips`
- Backtrace addresses are ARM64
- "secure boot?: YES" line at the bottom (vs Intel's variable response)
- Some panic strings differ — e.g. `"Kernel data abort"` (ARM64) vs `"page_fault"` (x86)
- Apple Silicon has **no** SMC-resettable; recoveryOS handles equivalent reset
- T2 chip references absent on Apple Silicon (T2 was Intel-era; Apple Silicon has equivalent in SoC)

## Pre-panic correlation

The panic record is the symptom. The **events in the 10 minutes before** are usually the cause. Use:

```bash
# Replace TIME with the panic timestamp
log show --start '2026-05-15 03:04:22' --end '2026-05-15 03:14:22' --style compact \
    --predicate '(subsystem == "com.apple.kernel" OR subsystem == "com.apple.iokit") AND (messageType == "Error" OR messageType == "Fault")'
```

What to look for:

- **storage**: IOATAFamily / AppleNVMeFamily errors → IO error cascade
- **driver hang**: repeated identical kernel messages from a single kext
- **assertion held**: a process kept the system from sleeping → eventually hung during forced sleep
- **silence**: no events for >60s before panic → total system freeze (often hardware or kernel deadlock)

The `scripts/panic-triage.sh` script automates this window query.

## When there's no panic report

Two common reasons:

1. **Hard power loss** — kernel didn't get to write the dump. Symptom: Mac restarts unexpectedly, nothing in `/Library/Logs/DiagnosticReports/`. Check `pmset -g log` for "Standby" → sudden "Wake" without preceding "Sleep".
2. **Disk too full** — kernel couldn't allocate space for the panic file. Free up space; ensure root volume has at least a few GB free.

For Apple Silicon: the **system reset record** (which IS preserved across hard power loss) is queryable via:

```bash
log show --predicate 'eventMessage CONTAINS "previous shutdown cause"' --last 30d | head
```

Negative values indicate unclean shutdown:
- `-3` = hard power loss
- `-20` = no associated cause / unexpected
- `-128` = thermal shutdown
- `5` = clean shutdown initiated by user

## Cross-references

- `scripts/panic-triage.sh` — automated panic decode + pre-panic timeline
- For storage-induced panics, see `storage-events.md`
- For Windows BugCheck equivalents, see `windows-ops/references/bugcheck-codes.md`
- For recovery from no-boot post-panic, see `recovery-patterns.md`
