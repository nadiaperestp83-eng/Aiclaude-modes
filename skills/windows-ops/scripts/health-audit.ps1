<#
.SYNOPSIS
    Comprehensive Windows workstation health audit. Produces a verdict.

.DESCRIPTION
    Walks the diagnostic ladder: hardware errors, storage health per disk,
    recent crashes with BugCheck codes, top resource consumers, startup
    inventory across all five mechanisms. Emits [PASS]/[FAIL]/[WARN]
    markers per check and a final verdict block.

    Stdout is data only (a text report by default, or NDJSON when -Json).
    Stderr carries progress and section headers.

.PARAMETER Days
    How many days back to scan event logs. Default: 30.

.PARAMETER Json
    Emit machine-readable NDJSON to stdout (one finding per line).

.PARAMETER Quiet
    Suppress section headers on stderr. Findings still emit.

.EXAMPLE
    scripts/health-audit.ps1
    Run the full audit, scanning the last 30 days.

.EXAMPLE
    scripts/health-audit.ps1 -Days 7
    Quick audit covering only the last week.

.EXAMPLE
    scripts/health-audit.ps1 -Json | ConvertFrom-Json
    Pipe machine-readable output to a JSON consumer.

.EXAMPLE
    scripts/health-audit.ps1 -Json > audit.ndjson
    Save audit findings as NDJSON for later processing.

.NOTES
    Exit codes:
      0 success — audit completed, no critical findings
      1 general error during audit
      2 usage error (bad arguments)
      4 critical finding (failing drive, recent unexplained crashes)
      5 missing precondition (PowerShell version, required module)
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 365)][int]$Days = 30,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

$Findings = New-Object System.Collections.Generic.List[hashtable]

function Add-Finding {
    param(
        [Parameter(Mandatory)][ValidateSet('pass','warn','fail','info')]$Level,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Detail,
        [hashtable]$Data = @{}
    )
    $f = @{
        level    = $Level
        category = $Category
        subject  = $Subject
        detail   = $Detail
        data     = $Data
        ts       = (Get-Date).ToString('o')
    }
    $Findings.Add($f)
    if (-not $Quiet -or $Level -in @('warn','fail')) {
        $tag = $Level.ToUpper()
        [Console]::Error.WriteLine("[$tag] $Category :: $Subject -> $Detail")
    }
    if ($Json) {
        [Console]::Out.WriteLine(($f | ConvertTo-Json -Compress -Depth 5))
    }
}

# ─────────────────────────────────────────────────────────────────────
# Section: Hardware errors (WHEA)
# ─────────────────────────────────────────────────────────────────────
if (-not $Quiet) { Write-Section "1. Hardware errors (WHEA)" }

try {
    $whea = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='Microsoft-Windows-WHEA-Logger'
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    $wheaError = $whea | Where-Object { $_.Level -le 2 }   # Critical/Error
    $wheaWarn  = $whea | Where-Object { $_.Level -eq 3 }   # Warning
    if ($wheaError) {
        Add-Finding -Level fail -Category 'hardware' -Subject 'WHEA errors' `
            -Detail "$($wheaError.Count) uncorrectable hardware error(s) in last $Days days" `
            -Data @{ count = $wheaError.Count; first = $wheaError[0].TimeCreated.ToString('o') }
    } elseif ($wheaWarn) {
        Add-Finding -Level warn -Category 'hardware' -Subject 'WHEA warnings' `
            -Detail "$($wheaWarn.Count) corrected hardware event(s) — usually benign but trending"
    } else {
        Add-Finding -Level pass -Category 'hardware' -Subject 'WHEA' `
            -Detail "No hardware errors logged in last $Days days"
    }
} catch {
    Add-Finding -Level warn -Category 'hardware' -Subject 'WHEA query' -Detail "Failed: $_"
}

# ─────────────────────────────────────────────────────────────────────
# Section: Storage health per disk
# ─────────────────────────────────────────────────────────────────────
if (-not $Quiet) { Write-Section "2. Storage health per disk" }

$diskMap = Get-DiskMap
foreach ($d in $diskMap) {
    if (-not $Quiet) {
        [Console]::Error.WriteLine("  Disk $($d.Number): $($d.Model) [$($d.MediaType), $($d.BusType), $($d.SizeGB) GB, $($d.DriveLetters)]")
    }
}

# Aggregate disk errors across the time window
# Event messages use TWO formats for naming the affected disk:
#   - Event 7/15/51:        "\Device\Harddisk<N>\DR..."
#   - Event 153/154:        "...for Disk <N> (PDO name: \Device\...)"
# Match both so per-disk counts cover the full set.
try {
    $diskErrs = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='disk'
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    $errsByDisk = @{}
    foreach ($e in $diskErrs) {
        $n = $null
        if     ($e.Message -match 'Harddisk(\d+)')         { $n = $matches[1] }
        elseif ($e.Message -match '\bfor Disk (\d+)\b')    { $n = $matches[1] }
        if ($null -eq $n) { continue }
        if (-not $errsByDisk.ContainsKey($n)) { $errsByDisk[$n] = @{} }
        $id = "$($e.Id)"
        if ($errsByDisk[$n].ContainsKey($id)) {
            $errsByDisk[$n][$id] = $errsByDisk[$n][$id] + 1
        } else {
            $errsByDisk[$n][$id] = 1
        }
    }
} catch { $errsByDisk = @{} }

# storahci controller resets
try {
    $resets = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='storahci'
        Id=129
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    $resetCount = if ($resets) { $resets.Count } else { 0 }
} catch { $resetCount = 0 }

# Per-disk verdict
$failingDisks = @()
foreach ($d in $diskMap) {
    $n = "$($d.Number)"
    $errs = if ($errsByDisk.ContainsKey($n)) { $errsByDisk[$n] } else { @{} }
    $event7   = if ($errs.ContainsKey('7'))   { $errs['7']   } else { 0 }
    $event154 = if ($errs.ContainsKey('154')) { $errs['154'] } else { 0 }
    $event51  = if ($errs.ContainsKey('51'))  { $errs['51']  } else { 0 }

    $isSsd = $d.MediaType -eq 'SSD'
    $threshold7   = if ($isSsd) { 10 }  else { 50 }
    $threshold154 = if ($isSsd) { 5 }   else { 10 }

    if ($event7 -gt $threshold7 -or $event154 -gt $threshold154 -or $event51 -gt 5) {
        Add-Finding -Level fail -Category 'storage' -Subject "Disk $n ($($d.Model))" `
            -Detail "Failing: Event7=$event7, Event154=$event154, Event51=$event51 over $Days days" `
            -Data @{ diskNumber=$d.Number; model=$d.Model; driveLetters=$d.DriveLetters;
                     event7=$event7; event154=$event154; event51=$event51 }
        $failingDisks += $d
    } elseif ($event7 -gt 5 -or $event154 -gt 2) {
        Add-Finding -Level warn -Category 'storage' -Subject "Disk $n ($($d.Model))" `
            -Detail "Watchlist: Event7=$event7, Event154=$event154 — back up important data" `
            -Data @{ diskNumber=$d.Number; event7=$event7; event154=$event154 }
    } else {
        Add-Finding -Level pass -Category 'storage' -Subject "Disk $n ($($d.Model))" `
            -Detail "Clean — 0 hardware errors over $Days days"
    }
}

if ($resetCount -gt 5) {
    Add-Finding -Level fail -Category 'storage' -Subject 'Controller resets' `
        -Detail "$resetCount storahci controller resets in last $Days days — active storage failure"
} elseif ($resetCount -gt 0) {
    Add-Finding -Level warn -Category 'storage' -Subject 'Controller resets' `
        -Detail "$resetCount storahci controller resets — drive intermittently unresponsive"
} else {
    Add-Finding -Level pass -Category 'storage' -Subject 'Controller resets' `
        -Detail "No storahci resets in last $Days days"
}

# ─────────────────────────────────────────────────────────────────────
# Section: Crash history
# ─────────────────────────────────────────────────────────────────────
if (-not $Quiet) { Write-Section "3. Crash history" }

try {
    $crashes = Get-WinEvent -FilterHashtable @{
        LogName='System'
        Id=41
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    if ($crashes) {
        $hardShutdowns = 0
        foreach ($c in $crashes) {
            $bcCode  = $c.Properties[0].Value
            $param1  = $c.Properties[1].Value
            $pwrBtn  = if ($c.Properties.Count -gt 6) { $c.Properties[6].Value } else { 0 }
            $bcHex   = '0x{0:X}' -f $bcCode

            if ($bcCode -eq 0) {
                $hardShutdowns++
                $why = if ($pwrBtn -ne 0) { 'power button held (hang)' } else { 'hard power loss or total hardware lockup' }
                Add-Finding -Level fail -Category 'crash' -Subject $c.TimeCreated.ToString('yyyy-MM-dd HH:mm') `
                    -Detail "BugCheck=0x0 (no bugcheck recorded) — $why" `
                    -Data @{ time=$c.TimeCreated.ToString('o'); bugcheck=$bcHex; powerButtonHeld=($pwrBtn -ne 0) }
            } else {
                Add-Finding -Level warn -Category 'crash' -Subject $c.TimeCreated.ToString('yyyy-MM-dd HH:mm') `
                    -Detail "BugCheck=$bcHex Param1=0x$('{0:X}' -f $param1)" `
                    -Data @{ time=$c.TimeCreated.ToString('o'); bugcheck=$bcHex; param1=('0x{0:X}' -f $param1) }
            }
        }
        if ($hardShutdowns -ge 2) {
            Add-Finding -Level fail -Category 'crash' -Subject 'Pattern' `
                -Detail "$hardShutdowns unclean shutdowns with no bugcheck — investigate PSU, thermals, storage cabling"
        }
    } else {
        Add-Finding -Level pass -Category 'crash' -Subject 'Crash log' -Detail "No Event 41 (Kernel-Power) crashes in last $Days days"
    }
} catch {
    Add-Finding -Level warn -Category 'crash' -Subject 'Crash query' -Detail "Failed: $_"
}

# Crash dump configuration
try {
    $dumpCfg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
    $hasMinidumps = (Test-Path 'C:\Windows\Minidump\*.dmp')
    $hasMemoryDmp = (Test-Path 'C:\Windows\MEMORY.DMP')

    if ($dumpCfg.CrashDumpEnabled -eq 0) {
        Add-Finding -Level warn -Category 'crash' -Subject 'Dump config' -Detail "CrashDumpEnabled=0 — no dumps will be written on crash"
    } elseif (-not $hasMinidumps -and -not $hasMemoryDmp -and $crashes) {
        Add-Finding -Level warn -Category 'crash' -Subject 'Dump config' -Detail "Crashes recorded but no dump files exist — pagefile may be too small or crashes were power-loss"
    } else {
        $level = if ($dumpCfg.CrashDumpEnabled -eq 7) { 'pass' } else { 'info' }
        Add-Finding -Level $level -Category 'crash' -Subject 'Dump config' -Detail "CrashDumpEnabled=$($dumpCfg.CrashDumpEnabled)"
    }
} catch {
    Add-Finding -Level warn -Category 'crash' -Subject 'Dump config' -Detail "Failed to read CrashControl key: $_"
}

# ─────────────────────────────────────────────────────────────────────
# Section: Startup inventory
# ─────────────────────────────────────────────────────────────────────
if (-not $Quiet) { Write-Section "4. Startup inventory" }

$runPaths = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)
$runEntries = 0
foreach ($p in $runPaths) {
    if (Test-Path $p) {
        $props = (Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' }
        $runEntries += @($props).Count
    }
}

$autoSvcs = (Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running'
}).Count

$logonTasks = (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.State -ne 'Disabled' -and ($_.Triggers.CimClass.CimClassName -match 'Logon|Boot')
}).Count

$startupFolderCount = 0
foreach ($d in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                 "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp")) {
    if (Test-Path $d) { $startupFolderCount += (Get-ChildItem $d -Filter *.lnk -ErrorAction SilentlyContinue).Count }
}

$totalStartup = $runEntries + $autoSvcs + $logonTasks + $startupFolderCount
$level = if ($totalStartup -gt 60) { 'warn' } elseif ($totalStartup -gt 100) { 'fail' } else { 'pass' }
Add-Finding -Level $level -Category 'startup' -Subject 'Total auto-launch items' `
    -Detail "$totalStartup ($runEntries Run + $autoSvcs services + $logonTasks tasks + $startupFolderCount shortcuts)" `
    -Data @{ runEntries=$runEntries; autoServices=$autoSvcs; logonTasks=$logonTasks; startupFolderShortcuts=$startupFolderCount }

# ─────────────────────────────────────────────────────────────────────
# Section: Resource pressure (right now)
# ─────────────────────────────────────────────────────────────────────
if (-not $Quiet) { Write-Section "5. Resource pressure (right now)" }

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $memUsedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    $level = if ($memUsedPct -gt 90) { 'warn' } elseif ($memUsedPct -gt 80) { 'info' } else { 'pass' }
    Add-Finding -Level $level -Category 'resource' -Subject 'Memory' -Detail "$memUsedPct% used"
} catch {}

# Top 5 processes by accumulated CPU
try {
    $topCpu = Get-Process | Where-Object { $_.CPU -gt 30 } | Sort-Object CPU -Descending | Select-Object -First 5
    foreach ($p in $topCpu) {
        Add-Finding -Level info -Category 'resource' -Subject "Top CPU: $($p.ProcessName)" `
            -Detail "$([math]::Round($p.CPU,0))s CPU, $([math]::Round($p.WorkingSet/1MB,0)) MB"
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# Verdict
# ─────────────────────────────────────────────────────────────────────
$failCount = ($Findings | Where-Object { $_.level -eq 'fail' }).Count
$warnCount = ($Findings | Where-Object { $_.level -eq 'warn' }).Count
$passCount = ($Findings | Where-Object { $_.level -eq 'pass' }).Count

if (-not $Json) {
    Write-Section "VERDICT"
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  Findings: $failCount FAIL, $warnCount WARN, $passCount PASS")
    [Console]::Out.WriteLine("")
    if ($failingDisks) {
        [Console]::Out.WriteLine("  FAILING DRIVES:")
        foreach ($d in $failingDisks) {
            [Console]::Out.WriteLine("    - Disk $($d.Number): $($d.Model) [$($d.DriveLetters)]")
        }
        [Console]::Out.WriteLine("")
        [Console]::Out.WriteLine("  Recommended actions:")
        [Console]::Out.WriteLine("    1. Back up data from failing drive(s) immediately")
        [Console]::Out.WriteLine("    2. Physically disconnect or set Offline via diskpart")
        [Console]::Out.WriteLine("    3. Replace drive before further use")
    } elseif ($failCount -gt 0) {
        [Console]::Out.WriteLine("  Critical findings present. See [FAIL] markers above.")
    } else {
        [Console]::Out.WriteLine("  No critical findings. System health within normal bounds.")
    }
    [Console]::Out.WriteLine("")
}

# Exit code semantics
if ($failCount -gt 0) { exit $script:EXIT_VALIDATION }
exit $script:EXIT_OK
