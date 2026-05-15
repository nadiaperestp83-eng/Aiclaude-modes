# Storage Event ID Catalog

Load this when investigating disk errors, storage controller resets, or correlating I/O failures to a specific drive. The `System` log carries the bulk of storage signal; the `Microsoft-Windows-Storage-*` operational logs add detail when Windows-side debug logging is enabled (rare on workstations).

## Contents

1. [`disk` provider events](#disk-provider-events) — the most common storage signal
2. [`storahci` provider events](#storahci-provider-events) — AHCI/NVMe driver layer
3. [`Disk` provider variants](#disk-provider-variants) — newer Windows 11 split provider names
4. [`partmgr` and `volmgr`](#partmgr-and-volmgr) — partition / volume layer (less common signal)
5. [`Ntfs` provider events](#ntfs-provider-events) — filesystem-layer errors
6. [Query recipes](#query-recipes) — `Get-WinEvent` patterns for each scenario
7. [Reading the message bodies](#reading-the-message-bodies) — extracting `\Device\HarddiskN` and LBA values
8. [Severity triage](#severity-triage) — count thresholds that indicate failure

## `disk` provider events

Source: Windows kernel-mode disk driver. The classical signal for HDD/SSD failures. These events have been stable across Windows 7 → 11.

| ID | Level | Meaning | Significance |
|----|-------|---------|--------------|
| **7** | Warning | The device, \Device\HarddiskN\DR1, has a bad block. | **HIGH** — sectors are going bad. Single events occur on healthy drives during normal wear; >50 in a month indicates active failure. |
| **9** | Warning | The device, \Device\HarddiskN, did not respond within the timeout period. | **HIGH** — drive hung on an I/O request. Frequently precedes controller reset (storahci 129). |
| **11** | Error | The driver detected a controller error on \Device\HarddiskN. | **HIGH** — driver-level error during I/O. Usually paired with disk hardware errors. |
| **15** | Warning | The device, \Device\HarddiskN, is not ready for access yet. | Boot-time only. Drive slow to spin up / negotiate link. Common with failing/aged HDDs. |
| **51** | Warning | An error was detected on device \Device\HarddiskN\DRn during a paging operation. | **HIGH** — failed I/O on a page file or page-mapped file. Direct cause of BSOD `0x50` (PAGE_FAULT_IN_NONPAGED_AREA) when paging fails. |
| **52** | Informational | Write cache enabled on \Device\HarddiskN. | None — informational, posted at boot. |
| **153** | Warning | The IO operation at logical block address 0x{LBA} for Disk N was retried. | Medium — single retry can be transient. >20/month suggests failing drive. |
| **154** | Error | The IO operation at logical block address 0x{LBA} for Disk N failed due to a hardware error. | **HIGH** — Windows' explicit hardware verdict on a specific block. Even single events warrant investigation. |
| **157** | Warning | Disk N has been surprise removed. | USB/eSATA drive yanked while in use. Expected when expected. |

## `storahci` provider events

Source: AHCI/NVMe storage driver. Captures controller-level issues and the lower-level "drive stopped responding" signal that precedes most storage-induced crashes.

| ID | Level | Meaning | Significance |
|----|-------|---------|--------------|
| **129** | Warning | Reset to device, \Device\RaidPortN, was issued. | **HIGH** — controller reset because the drive on port N stopped responding. Healthy = zero events. >5/month = active failure. |
| **131** | Error | Storage device on \Device\RaidPortN doesn't support a feature required by the driver. | Rare — usually firmware bug or unsupported drive. |
| **132** | Warning | Storage device on \Device\RaidPortN was removed without warning. | Surprise removal at the AHCI layer. Cabling or power issue if the drive shouldn't have left. |
| **134** | Error | Storage device on \Device\RaidPortN failed initial setup. | Boot-time. Drive not detected / not ready. Pair with disk Event 15. |

### Mapping `\Device\RaidPortN` to a drive

`RaidPortN` refers to the AHCI controller port number, not the drive number directly. Numbering starts at 0 in most BIOSes but Windows can renumber based on enumeration order. The most reliable mapping:

```powershell
# Pair each disk with its bus address (controller, port, target)
Get-PhysicalDisk | ForEach-Object {
    $bus = Get-CimInstance Win32_DiskDrive | Where-Object { $_.SerialNumber -eq $_.SerialNumber } |
        Select-Object -First 1 SCSIBus, SCSIPort, SCSITargetId, SCSILogicalUnit
    [PSCustomObject]@{
        Drive = $_.FriendlyName
        BusType = $_.BusType
        DeviceId = $_.DeviceId
    }
}
```

In practice the count of resets is the actionable signal, not the precise port mapping — if `RaidPortN` only ever appears for one specific port and the disk error events name a specific Disk number, those two together identify the drive.

## `Disk` provider variants

Windows 11 introduced a newer split provider naming for some storage events. When `disk` events are absent but a drive is suspect, also query:

| Provider | Notes |
|----------|-------|
| `Microsoft-Windows-Disk` | Newer (Win11) — usually mirrors `disk` events. Some Insider builds emit here exclusively. |
| `Microsoft-Windows-Ntfs` | Filesystem-layer; covers MFT corruption and chkdsk runs. |
| `Microsoft-Windows-Storage-Storport/Operational` | Low-level storage port driver. Usually empty on consumer Windows; populated when storport tracing enabled. |
| `Microsoft-Windows-Kernel-IO/Operational` | I/O subsystem; populated when kernel I/O tracing enabled (rare). |

## `partmgr` and `volmgr`

| Provider | ID | Meaning |
|----------|----|---------|
| `partmgr` | 6 | Volume guid path change — partition table modified. |
| `partmgr` | 7 | Failed to open device — frequent on drives with persistent failures, otherwise rare. |
| `volmgr` | 162 | Crash dump initialization failed. Important: this means the next crash won't write a dump even if `CrashDumpEnabled=7`. |
| `volmgr` | 46 | Crash dump file could not be created (disk full or no pagefile). |

`volmgr` Event 162 is high-value: pair it with the absence of `MEMORY.DMP` to explain why crash dumps aren't being captured.

## `Ntfs` provider events

NTFS-layer corruption usually shows up here. Most events are benign (boot-time mount logging); the meaningful ones:

| ID | Meaning | Significance |
|----|---------|--------------|
| 55 | A corruption was discovered in the file system structure on volume X. | **HIGH** — runs of these on the same volume indicate metadata corruption. Often triggered by underlying disk errors. |
| 98 | Volume X is not properly formatted. | Boot-time on a drive that's failing badly enough to not present a valid FS. |
| 130 | A transaction failed because the corresponding log records have already been allocated. | Filesystem log overflow — usually under heavy load on a failing/slow drive. |
| 137 | The default transaction resource manager on volume X failed to start. | Boot-time, on volumes with severely corrupt $LogFile. |

## Query recipes

### All disk error events in last 30 days, grouped by ID

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='disk'
    StartTime=(Get-Date).AddDays(-30)
} | Group-Object Id | Select-Object Count, Name | Sort-Object Count -Descending
```

### All storage controller resets, sorted by time

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='storahci'
    Id=129
    StartTime=(Get-Date).AddDays(-60)
} | Select-Object TimeCreated, Message | Sort-Object TimeCreated
```

### Errors targeting a specific physical disk

```powershell
$diskNumber = 1
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName='disk'
    StartTime=(Get-Date).AddDays(-60)
} | Where-Object { $_.Message -match "Harddisk$diskNumber\b" }
```

### Combined storage signal in time window before a crash

```powershell
$crashTime = [datetime]'2026-05-15 00:57:50'
$window = $crashTime.AddMinutes(-10)
Get-WinEvent -FilterHashtable @{
    LogName='System'
    StartTime=$window
    EndTime=$crashTime
    ProviderName=@('disk','storahci','Ntfs','partmgr','volmgr','Microsoft-Windows-Kernel-Power')
} | Sort-Object TimeCreated | Select-Object TimeCreated, ProviderName, Id,
    @{N='Message';E={($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(120, $_.Message.Length))}}
```

## Reading the message bodies

The `Message` field carries the device path and (for events 153/154) the failing LBA. Extraction patterns:

```powershell
# Harddisk number from a disk event message
if ($event.Message -match '\\Device\\Harddisk(\d+)') { $diskNum = $matches[1] }

# RaidPort number from a storahci 129 message
if ($event.Message -match '\\Device\\RaidPort(\d+)') { $portNum = $matches[1] }

# Failing LBA from a disk 153/154 message
if ($event.Message -match 'logical block address 0x([0-9a-f]+)') { $lba = [Convert]::ToInt64($matches[1], 16) }
```

A failing LBA pattern is occasionally diagnostic: clusters of failures at sequential LBAs suggest physical head/track damage on an HDD or a single failing flash block on an SSD. Random scattered LBAs across the drive are usually controller-level issues (cable, firmware, controller chip).

## Severity triage

Rules of thumb for what error counts mean over a 30-day window:

| Drive type | Disk Event 7 (bad block) | Disk Event 154 (hw error) | storahci 129 (reset) | Verdict |
|------------|--------------------------|---------------------------|----------------------|---------|
| HDD (any) | 0–5 | 0–2 | 0 | Healthy |
| HDD (any) | 6–50 | 0–10 | 0–2 | Watch — back up irreplaceable data |
| HDD (any) | >50 OR | >10 OR | >2 | **Failing — replace** |
| SSD (any) | 0 | 0 | 0 | Healthy |
| SSD (any) | 1–10 | 0–5 | 0–1 | Watch — check SMART for wear |
| SSD (any) | >10 OR | >5 OR | >1 | **Failing — replace** |

SSDs have stricter thresholds because they don't develop bad blocks during normal wear the way HDDs do — any disk Event 7 on an SSD is meaningful, where on an HDD a few per month is within normal aging.

A drive showing 1000+ events per category in 30 days is in late-stage failure. The skill's verdict block should call this out unambiguously.
