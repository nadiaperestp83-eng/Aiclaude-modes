<#
.SYNOPSIS
    Safely clone data from a failing drive to a healthy target using
    robocopy with retry=0 (skip bad sectors fast, don't pound on them).

.DESCRIPTION
    When a drive is dying, the worst thing you can do is repeatedly retry
    reads on failing sectors — every retry stresses the drive further and
    can finish it off. This script wraps robocopy with the right flags:

      /R:0       no retries on read failures
      /W:0       no wait between retries (n/a with R:0 but explicit)
      /MIR       mirror (delete files at target that don't exist at source)
      /XJ        skip junction points (don't follow recursive mounts)
      /COPY:DAT  copy Data, Attributes, Timestamps (skip ACL/Owner — faster)
      /MT:8      8 threads (default is 8 anyway, explicit for clarity)
      /R:0 /W:0  total retry budget zero — fail fast on bad blocks
      /LOG       full log of what failed
      /TEE       output to console + log

    A separate "failed files" log captures the specific paths that couldn't
    be read, so the user can decide what to do with those (often: try
    again later with ddrescue, or accept the loss).

    The script can resume — robocopy /MIR is idempotent. Re-run after a
    crash and it picks up where it left off (modulo files that have
    already been mirrored).

.PARAMETER Source
    Source path (failing drive). Required.

.PARAMETER Destination
    Target path (healthy drive with enough space). Required.

.PARAMETER NoMirror
    Use /COPY instead of /MIR. Use this when the destination already has
    other content you want preserved.

.PARAMETER MaxRetries
    Retry budget per file. Default 0 (no retries — recommended for failing
    drives). Set to 1 only if you accept that retries may damage the
    drive further.

.PARAMETER LogDir
    Where to write the clone log and failed-files log. Default: TEMP.

.PARAMETER DryRun
    Use robocopy /L to list what would be copied without copying. Useful
    for planning capacity.

.EXAMPLE
    scripts/recover-clone.ps1 -Source Y:\ -Destination Z:\backup-of-Y
    Full mirror clone with zero retries (safest for failing drive).

.EXAMPLE
    scripts/recover-clone.ps1 -Source Y:\important -Destination Z:\rescue -NoMirror
    Copy a specific folder without mirroring (won't delete destination files).

.EXAMPLE
    scripts/recover-clone.ps1 -Source Y:\ -Destination Z:\backup -DryRun
    Enumerate without copying — check capacity, file counts.

.NOTES
    Exit codes (robocopy's are remapped to ATP semantics):
      0  success — no files needed copying, or all copied OK
      1  partial — some files copied, some failed
      3  not found — source path doesn't exist
      4  validation — destination has less free space than source data
      5  precondition — robocopy not found
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position=0)][string]$Source,
    [Parameter(Mandatory, Position=1)][string]$Destination,
    [switch]$NoMirror,
    [ValidateRange(0,5)][int]$MaxRetries = 0,
    [string]$LogDir = $env:TEMP,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# Preflight
$robo = Get-Command robocopy.exe -ErrorAction SilentlyContinue
if (-not $robo) {
    Write-Log -Level FAIL -Message "robocopy.exe not on PATH (should be present on all Windows installs)"
    exit $script:EXIT_PRECONDITION
}

if (-not (Test-Path $Source)) {
    Write-Log -Level FAIL -Message "Source not found: $Source"
    exit $script:EXIT_NOT_FOUND
}

# Capacity preflight
try {
    $srcUsedGB = [math]::Round((Get-ChildItem $Source -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1GB, 1)
} catch { $srcUsedGB = -1 }

$destDriveLetter = $Destination.Substring(0, 1).ToUpper()
$destDrive = Get-PSDrive -PSProvider FileSystem -Name $destDriveLetter -ErrorAction SilentlyContinue
if ($destDrive) {
    $destFreeGB = [math]::Round($destDrive.Free / 1GB, 1)
    Write-Log -Level INFO -Message "Source data: $srcUsedGB GB  |  Destination free: $destFreeGB GB"
    if ($srcUsedGB -gt 0 -and $destFreeGB -lt $srcUsedGB) {
        Write-Log -Level FAIL -Message "Destination has $destFreeGB GB free; source is $srcUsedGB GB. Insufficient space."
        exit $script:EXIT_VALIDATION
    }
}

# Timestamps and log paths
$stamp     = (Get-Date).ToString('yyyyMMdd-HHmmss')
$cloneLog  = Join-Path $LogDir "recover-clone-$stamp.log"
$failedLog = Join-Path $LogDir "recover-clone-failed-$stamp.log"

# Build robocopy command
$roboArgs = @($Source, $Destination)
if ($NoMirror) {
    $roboArgs += '/E'           # subdirectories incl. empty
} else {
    $roboArgs += '/MIR'         # mirror
}
$roboArgs += '/XJ'              # skip junction points
$roboArgs += '/COPY:DAT'        # data, attributes, timestamps (skip ACL for speed)
$roboArgs += '/DCOPY:T'         # also copy directory timestamps
$roboArgs += "/R:$MaxRetries"
$roboArgs += '/W:0'
$roboArgs += '/MT:8'            # 8 threads
$roboArgs += '/V'               # verbose — list skipped files
$roboArgs += '/BYTES'           # report sizes in bytes (cleaner for parsing)
$roboArgs += '/NP'              # no per-file progress (cleaner log)
$roboArgs += "/LOG:$cloneLog"
$roboArgs += '/TEE'             # console + log
if ($DryRun) {
    $roboArgs += '/L'           # list only — no actual copy
    Write-Log -Level INFO -Message "DRY-RUN — robocopy /L will enumerate without copying"
}

Write-Log -Level INFO -Message "Logs:  $cloneLog"
Write-Log -Level INFO -Message "Robocopy: robocopy $($roboArgs -join ' ')"

if (-not $PSCmdlet.ShouldProcess("$Source -> $Destination", "robocopy clone")) {
    Write-Log -Level INFO -Message "WhatIf: would run but skipped due to -WhatIf"
    exit $script:EXIT_OK
}

# Run robocopy
$start = Get-Date
& robocopy.exe @roboArgs
$roboExit = $LASTEXITCODE
$end = Get-Date

# Decode robocopy exit code
# 0      — no files copied (nothing to do)
# 1      — files copied OK
# 2      — extra files/dirs detected (not an error in /MIR mode)
# 4      — mismatches detected
# 8      — failures — files could not be copied
# 16     — fatal error
# Combinations possible (bitmask). >=8 means errors.
$elapsed = [math]::Round(($end - $start).TotalMinutes, 1)
Write-Log -Level INFO -Message "Elapsed: $elapsed min  |  Robocopy exit: $roboExit"

# Extract failed files from log
if (Test-Path $cloneLog) {
    $failedFiles = Select-String -Path $cloneLog -Pattern 'ERROR \d+ \(0x[0-9A-Fa-f]+\)' -ErrorAction SilentlyContinue
    if ($failedFiles) {
        $failedFiles | ForEach-Object { $_.Line } | Set-Content -Path $failedLog
        Write-Log -Level WARN -Message "$($failedFiles.Count) file(s) failed to copy — see: $failedLog"
    }
}

# Map robocopy exit to ATP semantics
if ($roboExit -ge 16) {
    Write-Log -Level FAIL -Message "Fatal robocopy error — review $cloneLog"
    exit $script:EXIT_ERROR
} elseif ($roboExit -ge 8) {
    Write-Log -Level WARN -Message "Some files could not be copied (drive-failure or permission). Clone is partial."
    exit 1   # partial success per ATP
} else {
    Write-Log -Level PASS -Message "Clone complete. Robocopy code $roboExit (no errors)."
    exit $script:EXIT_OK
}
