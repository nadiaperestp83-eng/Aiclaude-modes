<#
.SYNOPSIS
    Measure Windows boot performance from the Diagnostics-Performance
    log. Surfaces which boots were slow and what specifically dragged
    each one down.

.DESCRIPTION
    The Microsoft-Windows-Diagnostics-Performance/Operational log records
    detailed timing for every boot event (boot main path, post-boot,
    total) and flags individual components that exceeded the system's
    "fast boot" threshold:

      Event 100 — "Windows successfully booted in X ms"
                  Contains: BootTime, BootMainPathTime, BootPostBootTime,
                  IsDegradation, IncidentTime
      Event 101 — "App took longer than usual to start"
      Event 102 — "Driver took longer than usual to start"
      Event 103 — "Service took longer than usual to start"

    Reading this log requires Administrator. Without admin, the script
    falls back to a kernel-event-based inference using Event 12 (kernel
    start) and Event 6005 (event log service started) — coarser but
    still useful for trend detection.

.PARAMETER LastN
    Number of recent boots to report. Default: 10.

.PARAMETER Json
    Machine-readable JSON output.

.EXAMPLE
    scripts/boot-perf.ps1
    Show the last 10 boots with their durations and degradation flags.

.EXAMPLE
    scripts/boot-perf.ps1 -LastN 30 -Json | jq '.boots[] | select(.degraded)'
    Filter to only degraded boots from machine-readable output.

.NOTES
    Exit codes:
      0 success
      5 precondition (no boot events found at all)
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 100)][int]$LastN = 10,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

$elevated = Test-IsElevated
$boots = New-Object System.Collections.Generic.List[hashtable]
$slowComponents = New-Object System.Collections.Generic.List[hashtable]
$source = 'diagnostics-perf'

# ─────────────────────────────────────────────────────────────────────
# Primary: Diagnostics-Performance log (requires admin)
# ─────────────────────────────────────────────────────────────────────
try {
    $perfEvents = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' `
        -ErrorAction Stop |
        Where-Object { $_.Id -in @(100, 101, 102, 103) }

    foreach ($e in $perfEvents | Where-Object { $_.Id -eq 100 }) {
        # Properties layout (Event 100):
        #   [1] BootTime
        #   [4] BootMainPathTime
        #   [5] BootPostBootTime
        #   [6] BootIsDegradation
        try {
            $bootTotal = [int64]$e.Properties[1].Value
            $bootMain  = [int64]$e.Properties[4].Value
            $bootPost  = [int64]$e.Properties[5].Value
            $degraded  = [bool]$e.Properties[6].Value
        } catch {
            $bootTotal = -1; $bootMain = -1; $bootPost = -1; $degraded = $false
        }
        $boots.Add(@{
            time            = $e.TimeCreated.ToString('o')
            bootTotalSec    = if ($bootTotal -gt 0) { [math]::Round($bootTotal / 1000, 1) } else { -1 }
            bootMainSec     = if ($bootMain  -gt 0) { [math]::Round($bootMain  / 1000, 1) } else { -1 }
            bootPostSec     = if ($bootPost  -gt 0) { [math]::Round($bootPost  / 1000, 1) } else { -1 }
            degraded        = $degraded
        })
    }

    # Slow components — events 101/102/103
    foreach ($e in $perfEvents | Where-Object { $_.Id -in @(101, 102, 103) }) {
        $kind = switch ($e.Id) { 101 {'app'} 102 {'driver'} 103 {'service'} }
        # Property layout varies by event id; the friendly name + delay are
        # usually accessible by reading the rendered message string.
        $msg = ($e.Message -replace '\s+', ' ')
        $delaySec = $null
        if ($msg -match '(\d+) ms') {
            $delaySec = [math]::Round([int]$matches[1] / 1000, 1)
        }
        # Name extraction varies; try common patterns
        $name = '(unknown)'
        if ($msg -match '"([^"]+)"') { $name = $matches[1] }
        elseif ($msg -match 'Name\s*:\s*(\S+)') { $name = $matches[1] }
        $slowComponents.Add(@{
            time     = $e.TimeCreated.ToString('o')
            kind     = $kind
            name     = $name
            delaySec = $delaySec
            message  = (Format-EventMessage -Message $msg -MaxLength 200)
        })
    }
}
catch {
    $source = 'kernel-events'
    if (-not $elevated) {
        Write-Log -Level WARN -Message "Cannot read Diagnostics-Performance log (admin required). Falling back to coarse kernel-event timing."
    } else {
        Write-Log -Level WARN -Message "Diagnostics-Performance log unavailable: $_"
    }

    # ─────────────────────────────────────────────────────────────────
    # Fallback: kernel event 12 (start) + 6005 (event log started)
    # Gap = approximate "kernel → services running" time. Not full boot
    # to usable desktop but a useful trend metric.
    # ─────────────────────────────────────────────────────────────────
    try {
        $kernelStarts = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=12; ProviderName='Microsoft-Windows-Kernel-General'
        } -MaxEvents 30 -ErrorAction SilentlyContinue
        $logStarts = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=6005
        } -MaxEvents 30 -ErrorAction SilentlyContinue

        foreach ($k in $kernelStarts) {
            # Find the 6005 closest after this 12 (within 5 min)
            $matchingLog = $logStarts | Where-Object {
                $_.TimeCreated -gt $k.TimeCreated -and ($_.TimeCreated - $k.TimeCreated).TotalSeconds -lt 300
            } | Sort-Object TimeCreated | Select-Object -First 1

            if ($matchingLog) {
                $delta = ($matchingLog.TimeCreated - $k.TimeCreated).TotalSeconds
                $boots.Add(@{
                    time           = $k.TimeCreated.ToString('o')
                    bootTotalSec   = -1   # not available without diagnostics-perf
                    bootMainSec    = [math]::Round($delta, 1)
                    bootPostSec    = -1
                    degraded       = $false
                    note           = 'inferred from kernel start -> event log start; not full boot duration'
                })
            }
        }
    } catch {}
}

# Trim to LastN
$boots = $boots | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First $LastN

# ─────────────────────────────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────────────────────────────
if ($Json) {
    @{
        source         = $source
        elevated       = $elevated
        boots          = $boots
        slowComponents = $slowComponents | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First 30
    } | ConvertTo-Json -Depth 5 | ForEach-Object { [Console]::Out.WriteLine($_) }
    exit $script:EXIT_OK
}

Write-Section "Boot performance — last $LastN boots ($source)"

if (-not $boots) {
    Write-Log -Level FAIL -Message "No boot events found"
    exit $script:EXIT_PRECONDITION
}

if ($source -eq 'diagnostics-perf') {
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine(("  {0,-20}  {1,8}  {2,8}  {3,8}  {4}" -f 'Time', 'Total', 'Main', 'PostBoot', 'Status'))
    [Console]::Out.WriteLine(("  {0,-20}  {1,8}  {2,8}  {3,8}  {4}" -f ('-' * 20), ('-' * 8), ('-' * 8), ('-' * 8), ('-' * 12)))
    foreach ($b in $boots) {
        $t = ([DateTime]$b.time).ToString('yyyy-MM-dd HH:mm')
        $tot = if ($b.bootTotalSec -gt 0) { "$($b.bootTotalSec)s" } else { '?' }
        $main = if ($b.bootMainSec -gt 0) { "$($b.bootMainSec)s" } else { '?' }
        $post = if ($b.bootPostSec -gt 0) { "$($b.bootPostSec)s" } else { '?' }
        $status = if ($b.degraded) { '[DEGRADED]' } else { '[OK]' }
        [Console]::Out.WriteLine(("  {0,-20}  {1,8}  {2,8}  {3,8}  {4}" -f $t, $tot, $main, $post, $status))
    }

    # Average + median calc on healthy boots
    $healthy = $boots | Where-Object { -not $_.degraded -and $_.bootTotalSec -gt 0 }
    if ($healthy.Count -ge 3) {
        $avg = [math]::Round(($healthy | Measure-Object bootTotalSec -Average).Average, 1)
        $sorted = $healthy | Sort-Object bootTotalSec
        $median = $sorted[[math]::Floor($sorted.Count / 2)].bootTotalSec
        [Console]::Out.WriteLine("")
        [Console]::Out.WriteLine("  Healthy-boot average: ${avg}s    median: ${median}s    ($($healthy.Count) of $($boots.Count) boots)")
    }
} else {
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  Note: $($boots[0].note)")
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine(("  {0,-20}  {1,12}" -f 'Time', 'Kernel→LogSvc'))
    [Console]::Out.WriteLine(("  {0,-20}  {1,12}" -f ('-' * 20), ('-' * 12)))
    foreach ($b in $boots) {
        $t = ([DateTime]$b.time).ToString('yyyy-MM-dd HH:mm')
        [Console]::Out.WriteLine(("  {0,-20}  {1,12}" -f $t, "$($b.bootMainSec)s"))
    }
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  For full boot timing including BootMainPath + BootPostBoot phases,")
    [Console]::Out.WriteLine("  re-run as Administrator. The Diagnostics-Performance log requires elevation.")
}

# Slow components
$recentSlow = $slowComponents | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First 10
if ($recentSlow) {
    Write-Section "Slow components flagged at recent boots"
    foreach ($s in $recentSlow) {
        $t = ([DateTime]$s.time).ToString('yyyy-MM-dd HH:mm')
        $delay = if ($s.delaySec) { "$($s.delaySec)s" } else { '?' }
        [Console]::Out.WriteLine(("  {0}  [{1,-7}]  {2,-8}  {3}" -f $t, $s.kind, $delay, $s.name))
    }
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  These components exceeded the system's 'fast boot' threshold at the boots shown.")
    [Console]::Out.WriteLine("  Repeat offenders are prime candidates for disabling via safe-disable-startup.ps1")
    [Console]::Out.WriteLine("  (apps) or Set-Service -StartupType Manual (services) or Disable-ScheduledTask.")
}

exit $script:EXIT_OK
