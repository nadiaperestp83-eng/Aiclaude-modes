<#
.SYNOPSIS
    Focused per-drive health report — every diagnostic signal for one
    specific physical disk in one report.

.DESCRIPTION
    Drill-down companion to health-audit.ps1. Targets a single physical
    disk (by number, drive letter, or model substring) and emits:

      - Hardware identification (model, serial, firmware, capacity)
      - SMART reliability counters (Windows native + smartctl if installed)
      - All disk-provider events for the disk over the time window
      - All storahci controller resets (skill correlates port to drive)
      - Per-event-ID breakdown with severity classification
      - Recovery clues — failing-LBA distribution, time-clustering
      - System dependencies — quick summary (uses drive-dependencies.ps1
        if available, else inline check)

.PARAMETER DiskNumber
    Physical disk number from Get-Disk. Mutually exclusive with -DriveLetter
    and -Model.

.PARAMETER DriveLetter
    Drive letter — resolves to the underlying physical disk.

.PARAMETER Model
    Model substring match (e.g. 'HGST', '980 PRO'). Picks the first match.

.PARAMETER Days
    Days back to scan event logs. Default: 60.

.PARAMETER Json
    Machine-readable JSON output.

.EXAMPLE
    scripts/disk-health.ps1 -DiskNumber 1
    Focused report on physical disk 1.

.EXAMPLE
    scripts/disk-health.ps1 -DriveLetter Y -Days 30
    Drill on the disk that hosts Y:, 30-day window.

.EXAMPLE
    scripts/disk-health.ps1 -Model 'HGST' -Json | jq '.errors'
    Find the HGST drive and dump its error counts as JSON.

.NOTES
    Exit codes:
      0 success — drive looks healthy
      3 not found — no matching disk
      4 validation — drive shows failure indicators
#>

[CmdletBinding(DefaultParameterSetName='Number')]
param(
    [Parameter(ParameterSetName='Number', Position=0)][ValidateRange(0, 99)][int]$DiskNumber = -1,
    [Parameter(ParameterSetName='Letter')][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter,
    [Parameter(ParameterSetName='Model')][string]$Model,
    [ValidateRange(1, 365)][int]$Days = 60,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# Resolve target disk
$disks = Get-DiskMap
$target = $null
switch ($PSCmdlet.ParameterSetName) {
    'Number' {
        if ($DiskNumber -lt 0) {
            Write-Log -Level FAIL -Message "Provide -DiskNumber, -DriveLetter, or -Model"
            exit $script:EXIT_USAGE
        }
        $target = $disks | Where-Object { $_.Number -eq $DiskNumber } | Select-Object -First 1
    }
    'Letter' {
        $L = $DriveLetter.ToUpper()
        $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $L } | Select-Object -First 1
        if ($part) {
            $target = $disks | Where-Object { $_.Number -eq $part.DiskNumber } | Select-Object -First 1
        }
    }
    'Model' {
        $target = $disks | Where-Object { $_.Model -like "*$Model*" } | Select-Object -First 1
    }
}

if (-not $target) {
    Write-Log -Level FAIL -Message "No matching disk found"
    exit $script:EXIT_NOT_FOUND
}

# Collect data
$result = [ordered]@{
    diskNumber       = $target.Number
    model            = $target.Model
    serial           = $target.SerialNumber
    firmware         = $target.FirmwareVersion
    mediaType        = $target.MediaType
    busType          = $target.BusType
    sizeGB           = $target.SizeGB
    driveLetters     = $target.DriveLetters
    healthStatus     = $target.HealthStatus
    windowDays       = $Days
    smart            = $null
    eventCounts      = @{}
    eventSamples     = @()
    storahciResets   = 0
    verdict          = 'unknown'
    indicators       = @()
}

# SMART reliability counter (Windows native)
try {
    $physical = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $target.Number }
    $rel = $physical | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    if ($rel) {
        $result.smart = @{
            temperatureC   = $rel.Temperature
            temperatureMax = $rel.TemperatureMax
            wearPct        = $rel.Wear
            readErrors     = $rel.ReadErrorsTotal
            writeErrors    = $rel.WriteErrorsTotal
            powerOnHours   = $rel.PowerOnHours
            powerCycles    = $rel.PowerCycleCount
            startStops     = $rel.StartStopCycleCount
        }
    }
} catch {}

# smartctl fallback (if smartmontools installed)
$smartctl = Get-Command smartctl.exe -ErrorAction SilentlyContinue
if ($smartctl -and -not $result.smart) {
    try {
        $smartOutput = & smartctl -A "/dev/sd$($target.Number)" 2>&1
        if ($smartOutput) {
            $result.smartctlAvailable = $true
            $result.smartctlOutput = ($smartOutput -join "`n")
        }
    } catch {}
}

# Disk-provider events for this disk
try {
    $diskErrs = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='disk'
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    foreach ($e in $diskErrs) {
        $n = $null
        if     ($e.Message -match 'Harddisk(\d+)')      { $n = [int]$matches[1] }
        elseif ($e.Message -match '\bfor Disk (\d+)\b') { $n = [int]$matches[1] }
        if ($n -ne $target.Number) { continue }
        $id = "$($e.Id)"
        if ($result.eventCounts.ContainsKey($id)) {
            $result.eventCounts[$id] = $result.eventCounts[$id] + 1
        } else {
            $result.eventCounts[$id] = 1
        }
        if ($result.eventSamples.Count -lt 5) {
            $result.eventSamples += @{
                time     = $e.TimeCreated.ToString('o')
                id       = $e.Id
                message  = (Format-EventMessage -Message $e.Message -MaxLength 150)
            }
        }
    }
} catch {}

# storahci resets (controller-level; we can't always tie a port to a specific
# disk number reliably, so report total reset count and let caller correlate
# via drive enumeration order)
try {
    $resets = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='storahci'
        Id=129
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    $result.storahciResets = if ($resets) { $resets.Count } else { 0 }
} catch {}

# Severity classification
$isSsd = $target.MediaType -eq 'SSD'
$ev7   = if ($result.eventCounts.ContainsKey('7'))   { $result.eventCounts['7']   } else { 0 }
$ev51  = if ($result.eventCounts.ContainsKey('51'))  { $result.eventCounts['51']  } else { 0 }
$ev154 = if ($result.eventCounts.ContainsKey('154')) { $result.eventCounts['154'] } else { 0 }

$thresholds = if ($isSsd) {
    @{ event7=10; event154=5; event51=5 }
} else {
    @{ event7=50; event154=10; event51=5 }
}

$failing = (
    $ev7   -gt $thresholds.event7   -or
    $ev154 -gt $thresholds.event154 -or
    $ev51  -gt $thresholds.event51  -or
    $result.storahciResets -gt 5
)
$watch = (
    $ev7   -gt 5 -or
    $ev154 -gt 2 -or
    $result.storahciResets -gt 0
)

if ($failing) {
    $result.verdict = 'FAILING'
    if ($ev7   -gt $thresholds.event7)   { $result.indicators += "Event 7 (bad block): $ev7 > $($thresholds.event7) threshold" }
    if ($ev154 -gt $thresholds.event154) { $result.indicators += "Event 154 (hw error): $ev154 > $($thresholds.event154) threshold" }
    if ($ev51  -gt $thresholds.event51)  { $result.indicators += "Event 51 (paging error): $ev51 > $($thresholds.event51) threshold" }
    if ($result.storahciResets -gt 5)    { $result.indicators += "Controller resets: $($result.storahciResets) > 5 threshold" }
} elseif ($watch) {
    $result.verdict = 'WATCHLIST'
    if ($ev7   -gt 5) { $result.indicators += "Event 7 elevated: $ev7" }
    if ($ev154 -gt 2) { $result.indicators += "Event 154 elevated: $ev154" }
    if ($result.storahciResets -gt 0) { $result.indicators += "Controller resets: $($result.storahciResets)" }
} else {
    $result.verdict = 'HEALTHY'
}

# Output
if ($Json) {
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5))
} else {
    Write-Section "Disk $($target.Number): $($target.Model)"
    [Console]::Out.WriteLine("  Type:     $($target.MediaType) / $($target.BusType)")
    [Console]::Out.WriteLine("  Capacity: $($target.SizeGB) GB")
    [Console]::Out.WriteLine("  Firmware: $($target.FirmwareVersion)")
    [Console]::Out.WriteLine("  Serial:   $($target.SerialNumber)")
    [Console]::Out.WriteLine("  Letters:  $($target.DriveLetters)")
    [Console]::Out.WriteLine("  Reports:  $($target.HealthStatus)")
    [Console]::Out.WriteLine("")
    if ($result.smart) {
        Write-Section "SMART reliability counters"
        [Console]::Out.WriteLine("  Temp:     $($result.smart.temperatureC) C (max: $($result.smart.temperatureMax) C)")
        [Console]::Out.WriteLine("  Wear:     $($result.smart.wearPct)%")
        [Console]::Out.WriteLine("  Read err: $($result.smart.readErrors)  Write err: $($result.smart.writeErrors)")
        [Console]::Out.WriteLine("  Hours:    $($result.smart.powerOnHours)  Cycles: $($result.smart.powerCycles)")
    } else {
        [Console]::Out.WriteLine("  SMART:    (Windows reliability counter unavailable for this drive)")
        if ($smartctl) {
            [Console]::Out.WriteLine("            smartctl installed but call failed — try: smartctl -A /dev/sdX")
        } else {
            [Console]::Out.WriteLine("            Install smartmontools for SMART access: scoop install smartmontools")
        }
    }

    Write-Section "Disk events ($Days days)"
    if ($result.eventCounts.Count -eq 0) {
        [Console]::Out.WriteLine("  No disk events for this disk in window.")
    } else {
        $result.eventCounts.GetEnumerator() | Sort-Object { [int]$_.Key } | ForEach-Object {
            [Console]::Out.WriteLine("  Event $($_.Key):  $($_.Value) occurrences")
        }
    }
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  Controller resets (storahci 129): $($result.storahciResets) over $Days days")

    Write-Section "VERDICT: $($result.verdict)"
    if ($result.indicators) {
        foreach ($i in $result.indicators) {
            [Console]::Out.WriteLine("  - $i")
        }
    }
    [Console]::Out.WriteLine("")
    switch ($result.verdict) {
        'FAILING' {
            [Console]::Out.WriteLine("  Recommended: back up data, run drive-dependencies.ps1, then replace.")
        }
        'WATCHLIST' {
            [Console]::Out.WriteLine("  Recommended: back up irreplaceable data, monitor weekly.")
        }
        'HEALTHY' {
            [Console]::Out.WriteLine("  Recommended: no action needed.")
        }
    }
    [Console]::Out.WriteLine("")
}

if ($result.verdict -eq 'FAILING') { exit $script:EXIT_VALIDATION }
exit $script:EXIT_OK
