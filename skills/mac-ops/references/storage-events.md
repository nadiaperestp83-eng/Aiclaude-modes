# macOS Storage Events Catalog

Load this when investigating disk errors, IO failures, or correlating storage problems to a specific device. Unlike Windows (which has stable numeric event IDs), macOS surfaces storage signal through the **unified logging system** (`log show`) and the **AppleSystemPolicy** / **IOKit** subsystems. Event vocabulary is freer-form, so we match by substrings.

## Contents

1. [Where storage signal lives](#where-storage-signal-lives)
2. [Critical message fragments](#critical-message-fragments) — what to grep for
3. [IOKit subsystem events](#iokit-subsystem-events)
4. [APFS-specific events](#apfs-specific-events)
5. [`disk arbitration` messages](#disk-arbitration-messages)
6. [Query recipes](#query-recipes) — `log show` patterns
7. [Severity triage](#severity-triage) — count thresholds

## Where storage signal lives

| Source | Tool | Notes |
|---|---|---|
| Unified log | `log show` | All recent storage signal; can filter by subsystem |
| Per-device counters | `diskutil info /dev/diskN` | Reliability counters where exposed |
| SMART | `diskutil info` reports Verified/Failing only; `smartctl -a` (smartmontools) for attributes | NVMe often blank — check with vendor utility |
| Disk arbitration daemon | `log show --predicate 'process == "diskarbitrationd"'` | Mount/unmount events, eject failures |
| APFS | `diskutil apfs list` and `diskutil verifyVolume` | Read-only verify is safe even on failing disks |
| fsck | `fsck_apfs -n /dev/diskN` (verify-only — never `-y`) | NEVER `-y` on a failing drive |

## Critical message fragments

Substrings to grep for in the unified log. The presence of any of these is a **strong signal**:

| Fragment | Significance |
|---|---|
| `I/O error` | Read or write failed at IOKit layer |
| `media error` | Disk media (sector / NAND) reported uncorrectable failure |
| `device timeout` | Drive didn't respond within driver's timeout window |
| `NVMe Controller is unresponsive` | NVMe controller hang — drive becoming unreachable |
| `AppleAHCIPort` + `error` | SATA controller-level error |
| `failed to mount` | filesystem-level mount failure |
| `Failed to set up disk` | early-boot disk setup failure |
| `Detected stale snapshot` | APFS snapshot tree corruption |
| `corrupt b-tree` | APFS metadata corruption — serious |
| `APFS_MODULE_RESET` | APFS driver had to reset internal state |
| `EXC_RESOURCE` + `MEMORY` related to mds | Spotlight indexer crashed under memory pressure |

## IOKit subsystem events

```bash
log show --last 30d --style compact \
    --predicate 'subsystem == "com.apple.iokit" AND messageType == "Error"' \
    2>/dev/null | head -50
```

Most failing-drive evidence appears here. Look at the `sender` (kext name) — `AppleNVMeFamily`, `AppleAHCIPort`, `IOSCSITargetDevice` identify which protocol layer is reporting.

## APFS-specific events

```bash
log show --last 30d --style compact \
    --predicate 'eventMessage CONTAINS "apfs" AND (messageType == "Error" OR messageType == "Fault")'
```

APFS error categories worth knowing:

| Pattern | Cause |
|---|---|
| `apfs_log_op_warn_or_err` | Logged operation hit an error condition |
| `apfs_volume_mounted: error` | Volume failed to mount — usually corruption or hardware |
| `apfs_jhash_lookup_object: object not found` | B-tree corruption — run verifyVolume |
| `apfs_snap_metadata_create_with_xid` errors | Snapshot creation failed — usually disk-full or hardware |

## `disk arbitration` messages

```bash
log show --last 7d --style compact --predicate 'process == "diskarbitrationd"'
```

Useful for:
- **Eject failures**: who's holding the volume open
- **Surprise removal**: USB / Thunderbolt drives yanked
- **Repeated mount failures**: filesystem flaky or disk failing during mount

## Query recipes

### Last 30 days of storage errors with sample messages

```bash
log show --last 30d --style compact \
    --predicate '(subsystem == "com.apple.iokit" OR subsystem == "com.apple.kernel") AND (eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "media error" OR eventMessage CONTAINS[c] "device timeout")'
```

### Per-day error count (visualize as histogram)

```bash
log show --last 30d --style syslog \
    --predicate 'eventMessage CONTAINS[c] "I/O error"' 2>/dev/null \
    | awk '{print $1, $2}' | sort | uniq -c | tail -30
```

### Correlate IO errors to a specific physical disk

```bash
log show --last 7d --style compact \
    --predicate 'eventMessage CONTAINS "diskN"'   # replace N
```

### Surface APFS corruption indicators

```bash
log show --last 30d --style compact \
    --predicate 'eventMessage CONTAINS[c] "corrupt" OR eventMessage CONTAINS[c] "b-tree" OR eventMessage CONTAINS[c] "checksum"'
```

## Severity triage

Counts that suggest action. Always cross-reference with SMART status and `diskutil verifyVolume`.

| Event class | Healthy SSD (30d) | Healthy HDD (30d) | Worrying | Active failure |
|---|---|---|---|---|
| IO error | 0 | 0-1 | 5+ | 20+ |
| Media error | 0 | 0 | any | 5+ |
| Device timeout | 0 | 0-1 | 3+ | 10+ |
| APFS Error/Fault | 0-2 | 0-2 | 5+ | 15+ |
| diskarbitrationd eject failures | 0 | 0 | depends | repeated on same volume |

**HDDs** produce more noise than SSDs even when healthy — spinning disks have inherent retry behavior. Adjust thresholds upward for HDD media.

## Cardinal rules

1. **Image first, repair second.** A drive throwing errors is one write away from worse. Get data off it before any repair.
2. **Never `fsck_apfs -y`** on a failing drive — `-y` answers Yes to repairs, which writes back. Use `-n` (no-op verify) only.
3. **Don't trust SMART "Verified"** when the log is screaming. macOS's `diskutil info` SMART status reports only Pass/Fail at a high level; the unified log is the truth.
4. **Don't pound a failing drive with retries.** Use `rsync --partial --inplace --no-whole-file --append-verify --ignore-errors` to skip past unreadable sectors fast.

## Cross-references

- For Windows equivalent vocabulary, see `windows-ops/references/storage-events.md` (`disk` provider events 7/52/153/154, `storahci` 129)
- For recovery workflow, see `recovery-patterns.md`
- For volume dependency mapping before eject, see `scripts/drive-dependencies.sh`
