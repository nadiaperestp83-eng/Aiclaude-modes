# Windows BugCheck Code Catalog

Load this when decoding Event 41 Properties[0] (the BugCheck code), analyzing minidump files, or matching a BSOD stop code to a likely cause. Codes here are the ones that actually appear on workstations; the full list is in Microsoft's documentation but most are kernel-internal or driver-specific corner cases.

## Contents

1. [How to read Event 41](#how-to-read-event-41)
2. [Most common stop codes](#most-common-stop-codes) — by frequency on real workstations
3. [Hardware-pointer codes](#hardware-pointer-codes) — when the bugcheck points at silicon
4. [Driver-pointer codes](#driver-pointer-codes) — when a kernel-mode driver is at fault
5. [Storage-pointer codes](#storage-pointer-codes) — bugchecks induced by failing disks
6. [Power / sleep codes](#power--sleep-codes)
7. [Code 0x0 (no bugcheck)](#code-0x0-no-bugcheck) — the special case
8. [Decoding bugcheck parameters](#decoding-bugcheck-parameters)
9. [Cross-reference: symptom → likely codes](#cross-reference-symptom--likely-codes)

## How to read Event 41

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 5 |
    Select-Object TimeCreated,
        @{N='BugCheckCode'; E={ '0x{0:X}' -f $_.Properties[0].Value }},
        @{N='Param1'; E={ '0x{0:X}' -f $_.Properties[1].Value }},
        @{N='Param2'; E={ '0x{0:X}' -f $_.Properties[2].Value }},
        @{N='Param3'; E={ '0x{0:X}' -f $_.Properties[3].Value }},
        @{N='Param4'; E={ '0x{0:X}' -f $_.Properties[4].Value }},
        @{N='SleepInProgress'; E={ $_.Properties[5].Value }},
        @{N='PowerButtonTime'; E={ $_.Properties[6].Value }}
```

`Properties[0]` is the BugCheck code (the "stop code" in BSOD blue screen). `Properties[1-4]` are the four parameters whose meaning depends on the code. `Properties[5]` flags crashes during sleep transitions. `Properties[6]` is non-zero if the power button was held (manual force-shutdown vs spontaneous crash).

**Critical gotcha**: people frequently quote `Properties[1]` as "the BugCheck code" — it isn't. That's BugcheckParameter1. The actual code is at index `0`.

## Most common stop codes

Frequency on real workstations, descending:

| Hex | Name | Typical cause | Investigation entry point |
|-----|------|---------------|---------------------------|
| `0x0` | (no bugcheck recorded) | Hard power loss / total hang / hardware-level failure | See [Code 0x0](#code-0x0-no-bugcheck) below |
| `0xD1` | DRIVER_IRQL_NOT_LESS_OR_EQUAL | Driver accessed bad memory at high IRQL | Param4 = driver address; symbol lookup |
| `0x3B` | SYSTEM_SERVICE_EXCEPTION | Exception in a kernel service call | Param2 = faulting address |
| `0x7E` | SYSTEM_THREAD_EXCEPTION_NOT_HANDLED | Driver thread threw unhandled exception | Param1 = exception code; Param2 = address |
| `0x50` | PAGE_FAULT_IN_NONPAGED_AREA | Bad memory OR storage I/O failed for pageable code | Param1 = referenced address; check disk Event 51 same timeframe |
| `0xEF` | CRITICAL_PROCESS_DIED | A critical system process (csrss/services/wininit) terminated | Param1 = EPROCESS address (needs dump for process name) |
| `0x124` | WHEA_UNCORRECTABLE_ERROR | Hardware-level CPU/cache/PCIe error | Cross-reference WHEA-Logger events same timeframe |
| `0x1E` | KMODE_EXCEPTION_NOT_HANDLED | Kernel-mode unhandled exception | Param1 = exception; Param2 = faulting address |
| `0x9F` | DRIVER_POWER_STATE_FAILURE | Driver hung during sleep/wake | Param1 = transition type (1=sleep, 2=resume, 3=device, 4=node) |
| `0xA` | IRQL_NOT_LESS_OR_EQUAL | Like 0xD1 but caller usually pageable code | Param4 = caller address |
| `0x1A` | MEMORY_MANAGEMENT | Memory manager corruption | Param1 = subcode (0x41201 = PFN list corruption, 0x41284 = PTE corruption) |
| `0xC1` | SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION | Driver Verifier caught buffer overrun | Param1 = pool address; only fires with Verifier enabled |
| `0x139` | KERNEL_SECURITY_CHECK_FAILURE | Stack/pool corruption detected | Param1 = subcode (3 = invalid stack guard, 0xA = corrupt LIST_ENTRY) |
| `0xC2` | BAD_POOL_CALLER | Driver freed bad pool / freed twice | Param1 = subcode |

## Hardware-pointer codes

When you see these, suspect the hardware first. Software/driver fixes are unlikely to help.

| Hex | Name | What it means |
|-----|------|---------------|
| `0x124` | WHEA_UNCORRECTABLE_ERROR | CPU machine check, ECC failure, PCIe link fault. Run memtest, check thermals, audit recent hardware changes. |
| `0xF4` | CRITICAL_OBJECT_TERMINATION | Critical process exited — often storage-induced when paging fails. |
| `0x9C` | MACHINE_CHECK_EXCEPTION | CPU detected uncorrectable hardware fault. Param2 = machine check bank. Almost always CPU/RAM. |
| `0x18B` | SECURE_KERNEL_ERROR | VBS/Credential Guard hardware enforcement failure. CPU/TPM. |

For `0x124`, the WHEA-Logger entries in the same minute give the actual MCA bank and error type. Without those it's hard to localise further than "hardware error."

## Driver-pointer codes

Most common on workstations. The fixable category — driver update / rollback usually resolves.

| Hex | Name | Typical culprit drivers |
|-----|------|-------------------------|
| `0xD1` | DRIVER_IRQL_NOT_LESS_OR_EQUAL | Network drivers, antivirus, VPN drivers |
| `0x7E` | SYSTEM_THREAD_EXCEPTION_NOT_HANDLED | GPU drivers (nvlddmkm, igdkmd64, amdkmdag), audio drivers |
| `0x9F` | DRIVER_POWER_STATE_FAILURE | USB, GPU, network (anything that has power states) |
| `0xC4` | DRIVER_VERIFIER_DETECTED_VIOLATION | Whatever driver Verifier was watching |
| `0x101` | CLOCK_WATCHDOG_TIMEOUT | Usually CPU/chipset driver, or hardware. Param1 = stalled CPU number. |

**Identifying the driver**: minidump analysis with WinDbg's `!analyze -v` is the canonical method. Without a dump, look for warnings from the driver's provider name in the System log within the same minute as the crash:

```powershell
# Provider names commonly associated with these crashes
Get-WinEvent -FilterHashtable @{
    LogName='System'
    ProviderName=@('nvlddmkm','igdkmd64','amdkmdag','e1rexpress','RTKVHD','iaStorAVC','Disk','storahci')
    StartTime=(Get-Date).AddDays(-7)
    Level=@(1,2,3)
}
```

## Storage-pointer codes

These bugchecks are typically caused by storage failures, not the kernel/drivers per se. The actual fix is usually replacing the disk.

| Hex | Name | Why storage causes it |
|-----|------|-----------------------|
| `0x50` | PAGE_FAULT_IN_NONPAGED_AREA | Page file I/O failed → kernel can't read paged-out memory |
| `0x77` | KERNEL_STACK_INPAGE_ERROR | Paged-out kernel stack couldn't be read back. Param2 = I/O status. |
| `0x7A` | KERNEL_DATA_INPAGE_ERROR | Paged-out kernel data couldn't be read back. Param3 = I/O status code. |
| `0xC4` (subcode 0x91) | Driver Verifier — DPC routine exceeded time limit | Often disk driver waiting on hung disk |
| `0xF4` | CRITICAL_OBJECT_TERMINATION | A critical process couldn't read its executable pages (storage failed) |
| `0xEF` | CRITICAL_PROCESS_DIED | Variant of above — paging failure kills csrss/services/wininit |

For storage-induced bugchecks, the I/O status code at Param3 (for `0x7A`) or Param2 (for `0x77`) is informative:

| I/O Status | Meaning |
|------------|---------|
| `0xC000009C` | STATUS_DEVICE_DATA_ERROR — bad sector |
| `0xC000009D` | STATUS_DEVICE_NOT_CONNECTED — drive vanished |
| `0xC000016A` | STATUS_DISK_OPERATION_FAILED — generic disk failure |
| `0xC0000185` | STATUS_IO_DEVICE_ERROR — I/O device error |

Cross-reference with disk Event 51 / 154 (`disk` provider, hardware error events) in the same timeframe. The two together definitively pin the cause to a specific drive.

## Power / sleep codes

| Hex | Name | When |
|-----|------|------|
| `0x9F` | DRIVER_POWER_STATE_FAILURE | Driver hung during sleep transition. Param1 = phase. |
| `0xA0` | INTERNAL_POWER_ERROR | Power manager internal error |
| `0x9E` | USER_MODE_HEALTH_MONITOR | Clustering / fault-tolerance code path (rare on workstations) |
| `0xEF` (during resume) | CRITICAL_PROCESS_DIED | Critical process didn't survive sleep — often paging-storage related |
| `0x101` | CLOCK_WATCHDOG_TIMEOUT | CPU didn't tick — sometimes ACPI/chipset-driver-induced during sleep |

For `0x9F` with Param1=3 (device sleep): Param4 points to the device object that hung. WinDbg can decode this; without dump access the device class can sometimes be inferred from the System log's last successful device-state events before the crash.

## Code 0x0 (no bugcheck)

When `Properties[0]` is `0x0` and all four parameters are also `0`, **Windows recorded no bugcheck**. The crash record exists only because the kernel saw an unclean shutdown on the next boot. This means one of:

- **Hard power loss** — PSU dropout, power cable yanked, mains cut. Most common cause on desktops.
- **Total hardware lockup** — CPU/chipset entered a state where the kernel couldn't even execute the bugcheck path.
- **Manual power button hold** — user force-shutdown a hung machine.

Discriminator: `Properties[6]` (PowerButtonTimestamp):

- `0` → no power button input recorded → likely power loss or hardware lockup
- Non-zero → power button was pressed → user-initiated force shutdown of a hung machine

Critically: **no minidump will exist** for `0x0` crashes. There's no point hunting for `MEMORY.DMP` — the system was gone before it could write. Investigation has to use circumstantial evidence: System log events in the minutes before the crash, recent hardware changes, thermal logs, etc.

The repeated occurrence of `0x0` crashes on the same machine is a strong signal for:
1. Failing PSU (power transients under load)
2. Failing/loose storage cable (storage drops → kernel hangs → user power-cycles)
3. Thermal shutdown (CPU/GPU hits TjMax)
4. Failing RAM (kernel hang or instant total corruption)

## Decoding bugcheck parameters

The four parameters' meaning depends on the BugCheck code. The Microsoft docs list each code's parameter semantics; the common patterns:

| Position | Typical content for hardware-related codes | Typical content for driver-related codes |
|----------|---------------------------------------------|------------------------------------------|
| Param1 | Subcode / error class / referenced address | Faulting address |
| Param2 | I/O status / IRQL level | Calling function address |
| Param3 | Error-specific | Process/thread context |
| Param4 | Caller address | Driver image base address |

Parameter values that look like `0xFFFFxxxxxxxxxxxx` (high bits set) are kernel-mode addresses. Decoding them to a driver name requires dump analysis with proper symbols.

Parameter values that look like `0x000000xxxx` (low value) are usually subcodes — look these up in the Microsoft documentation for the specific BugCheck.

## Cross-reference: symptom → likely codes

| User-reported symptom | Most likely BugCheck codes | First investigation step |
|------------------------|---------------------------|--------------------------|
| "Random crashes, no pattern" | `0x124`, `0x1A`, `0x101` | Check WHEA events, run memtest |
| "Crashes during gaming" | `0x116`, `0x117`, `0x7E` (nvlddmkm/amdkmdag) | GPU driver, GPU thermals, PSU |
| "Crashes on sleep/wake" | `0x9F`, `0xA0`, `0xEF` | Param1 of 0x9F = transition phase |
| "Crashes with USB device plugged" | `0xD1`, `0x9F` (Param1=3) | USB driver / device driver |
| "Crashes during file copy / heavy IO" | `0x7A`, `0x50`, `0xF4`, `0xEF` | Check storage event 7/154 + storahci 129 |
| "Random reboot, no dump" | `0x0` | Check storahci 129 in minutes before; check WHEA |
| "Crashes after BIOS update" | Various | Likely chipset driver mismatch; roll back BIOS or update chipset |
| "Crashes after Windows Update" | `0xD1`, `0x7E`, `0x3B` | Identify recently-updated driver; roll back |
| "Crashes only at boot" | `0x7B`, `0xED`, `0x74` | Boot-critical drivers or storage |

## When to escalate to WinDbg

The Windows-side analysis the skill performs (BugCheck code + Properties + correlating events) handles ~70% of crashes. For the remaining 30% — driver bugs, complex memory corruption, hardware quirks — WinDbg with proper symbols is essential:

```powershell
# Verify symbol path
$env:_NT_SYMBOL_PATH = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"

# Then open the dump in WinDbg and run:
#   !analyze -v
#   lm   (list modules)
#   .bugcheck   (recap bugcheck)
#   k   (stack trace)
```

That's a deeper investigation than this skill's scope; `windows-ops` produces the verdict that says "go look at the dump with WinDbg" for the cases that warrant it.
