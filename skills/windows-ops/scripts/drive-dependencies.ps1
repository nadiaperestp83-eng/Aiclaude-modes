<#
.SYNOPSIS
    Find every system mechanism referencing a target drive letter or
    disk number. The "is it safe to disconnect?" check.

.DESCRIPTION
    Before physically removing a failing drive (or setting it Offline),
    audit what's pointing at it: pagefile location, Windows Search index,
    scheduled tasks, services, user-profile symlinks/junctions, startup
    folder shortcuts, mounted volume mount points, and any drive
    references in the Windows Run keys.

    Default output is a human-readable table. -Json emits structured.

    Exit codes:
      0 success
      2 usage
      3 not found (no such drive)

.PARAMETER DriveLetter
    Single drive letter (e.g. 'Y'). Case-insensitive.

.PARAMETER DiskNumber
    Physical disk number (from Get-Disk). The script resolves all drive
    letters mounted on that disk and checks each.

.PARAMETER Json
    Machine-readable JSON output.

.EXAMPLE
    scripts/drive-dependencies.ps1 -DriveLetter Y
    Audit all system references to Y: drive.

.EXAMPLE
    scripts/drive-dependencies.ps1 -DiskNumber 1
    Audit all references to drive letters on physical disk 1.

.EXAMPLE
    scripts/drive-dependencies.ps1 -DriveLetter Y -Json | jq '.dependencies[]'
    Machine-readable output for downstream tooling.

.NOTES
    Output verdict at end:
      SAFE TO DISCONNECT — no critical references found
      WARNINGS — some references found but none boot-critical
      DO NOT DISCONNECT — boot-critical reference (pagefile, system, etc.)
#>

[CmdletBinding(DefaultParameterSetName='Letter')]
param(
    [Parameter(Mandatory, ParameterSetName='Letter', Position=0)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    [Parameter(Mandatory, ParameterSetName='Number')]
    [ValidateRange(0, 99)]
    [int]$DiskNumber,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# Resolve target drive letter(s)
if ($PSCmdlet.ParameterSetName -eq 'Number') {
    $parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    if (-not $parts) {
        Write-Log -Level FAIL -Message "No partitions found on disk $DiskNumber"
        exit $script:EXIT_NOT_FOUND
    }
    $targetLetters = @($parts | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter)" })
    if (-not $targetLetters) {
        Write-Log -Level WARN -Message "Disk $DiskNumber has no mounted drive letters (still audit-worthy for system-volume refs)"
        $targetLetters = @()
    }
} else {
    $targetLetters = @($DriveLetter.ToUpper())
    # Verify the drive exists
    if (-not (Get-PSDrive -PSProvider FileSystem -Name $DriveLetter.ToUpper() -ErrorAction SilentlyContinue)) {
        Write-Log -Level WARN -Message "Drive ${DriveLetter}: not currently mounted — auditing references anyway"
    }
}

# Build a drive-letter regex that doesn't false-positive on URL schemes
# (e.g. the 'e:' in 'file:'). Require the letter to be either at string
# start, or preceded by a non-alpha character, and followed by `:\` or `:/`.
$letterPattern = if ($targetLetters) {
    $letters = ($targetLetters | ForEach-Object { [regex]::Escape($_) }) -join '|'
    "(?:^|[^A-Za-z])($letters):[\\/]"
} else { '__NOMATCH__' }

# Force case-sensitive match so lowercase 'e' inside 'file:' won't match 'E:'
function Test-DrivePath {
    param([string]$Text)
    if (-not $Text) { return $false }
    return [regex]::IsMatch($Text, $letterPattern)
}

$findings = New-Object System.Collections.Generic.List[hashtable]

function Add-Dependency {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('critical','warn','info')]$Severity
    )
    $findings.Add(@{ category=$Category; name=$Name; target=$Target; severity=$Severity })
}

if (-not $Json) {
    Write-Section "Drive dependency audit: $($targetLetters -join ', ')"
}

# ─────────────────────────────────────────────────────────────────────
# 1. Pagefile location
# ─────────────────────────────────────────────────────────────────────
try {
    $pagefiles = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    foreach ($pf in $pagefiles) {
        if (Test-DrivePath $pf.Name) {
            Add-Dependency -Category 'pagefile' -Name $pf.Name -Target $pf.Name -Severity 'critical'
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 2. Windows Search index data directory
# ─────────────────────────────────────────────────────────────────────
try {
    $idxDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name DataDirectory -ErrorAction SilentlyContinue).DataDirectory
    if (Test-DrivePath $idxDir) {
        Add-Dependency -Category 'search-index' -Name 'Windows.edb' -Target $idxDir -Severity 'warn'
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 3. Windows Search indexed scopes (paths in the crawl scope)
# ─────────────────────────────────────────────────────────────────────
try {
    $scopeKey = 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\WorkingSetRules'
    if (Test-Path $scopeKey) {
        Get-ChildItem $scopeKey -ErrorAction SilentlyContinue | ForEach-Object {
            $url = (Get-ItemProperty $_.PSPath -Name URL -ErrorAction SilentlyContinue).URL
            if (Test-DrivePath $url) {
                Add-Dependency -Category 'search-scope' -Name 'Indexed path' -Target $url -Severity 'warn'
            }
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 4. Scheduled tasks
# ─────────────────────────────────────────────────────────────────────
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        $task = $_
        foreach ($action in $task.Actions) {
            $strs = @($action.Execute, $action.Arguments, $action.WorkingDirectory) -join ' '
            if (Test-DrivePath $strs) {
                Add-Dependency -Category 'scheduled-task' -Name $task.TaskName -Target ($strs.Trim()) -Severity 'warn'
                break
            }
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 5. Services with binary path on target drive
# ─────────────────────────────────────────────────────────────────────
try {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-DrivePath $_.PathName) {
            $sev = if ($_.StartMode -eq 'Auto') { 'critical' } else { 'warn' }
            Add-Dependency -Category 'service' -Name $_.Name -Target $_.PathName -Severity $sev
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 6. User profile symlinks/junctions pointing at target
# ─────────────────────────────────────────────────────────────────────
try {
    Get-ChildItem $env:USERPROFILE -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object {
            if ($_.Target -and (Test-DrivePath ($_.Target -join ' '))) {
                Add-Dependency -Category 'profile-symlink' -Name $_.Name -Target ($_.Target -join '; ') -Severity 'warn'
            }
        }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 7. Startup folder shortcuts targeting drive
# ─────────────────────────────────────────────────────────────────────
try {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($d in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                     "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp")) {
        if (Test-Path $d) {
            Get-ChildItem $d -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
                $sc = $shell.CreateShortcut($_.FullName)
                $combined = @($sc.TargetPath, $sc.WorkingDirectory, $sc.Arguments) -join ' '
                if (Test-DrivePath $combined) {
                    Add-Dependency -Category 'startup-shortcut' -Name $_.Name -Target $sc.TargetPath -Severity 'warn'
                }
            }
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# 8. Registry Run-key entries pointing at drive
# ─────────────────────────────────────────────────────────────────────
$runPaths = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($p in $runPaths) {
    if (Test-Path $p) {
        (Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' -and (Test-DrivePath $_.Value) } |
            ForEach-Object {
                Add-Dependency -Category 'run-key' -Name $_.Name -Target $_.Value -Severity 'warn'
            }
    }
}

# ─────────────────────────────────────────────────────────────────────
# 9. Volume mount points (a folder on C: that mounts the target volume)
# ─────────────────────────────────────────────────────────────────────
try {
    $partitions = Get-Partition -ErrorAction SilentlyContinue | Where-Object {
        $_.DriveLetter -and $targetLetters -contains "$($_.DriveLetter)"
    }
    foreach ($p in $partitions) {
        $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if ($vol -and $vol.AccessPaths) {
            foreach ($path in $vol.AccessPaths) {
                if ($path -match '^[A-Z]:\\' -and $path -notmatch "^${($p.DriveLetter)}:") {
                    Add-Dependency -Category 'mount-point' -Name "$($p.DriveLetter): mounted at" -Target $path -Severity 'warn'
                }
            }
        }
    }
} catch {}

# ─────────────────────────────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────────────────────────────
$criticalCount = ($findings | Where-Object { $_.severity -eq 'critical' }).Count
$warnCount     = ($findings | Where-Object { $_.severity -eq 'warn' }).Count
$infoCount     = ($findings | Where-Object { $_.severity -eq 'info' }).Count

$verdict = if ($criticalCount -gt 0) {
    'DO NOT DISCONNECT — boot-critical references found'
} elseif ($warnCount -gt 0) {
    'WARNINGS — some references found; review before disconnecting'
} else {
    'SAFE TO DISCONNECT — no system dependencies on this drive'
}

if ($Json) {
    @{
        targetLetters = $targetLetters
        dependencies  = $findings
        critical      = $criticalCount
        warnings      = $warnCount
        verdict       = $verdict
    } | ConvertTo-Json -Depth 5 | ForEach-Object { [Console]::Out.WriteLine($_) }
} else {
    if (-not $findings) {
        [Console]::Out.WriteLine("")
        [Console]::Out.WriteLine("  No dependencies found.")
    } else {
        [Console]::Out.WriteLine("")
        $findings | Sort-Object { $_.category } | ForEach-Object {
            $tag = switch ($_.severity) { 'critical' {'[CRITICAL]'} 'warn' {'[WARN]    '} default {'[INFO]    '} }
            [Console]::Out.WriteLine(("  {0}  {1,-18}  {2,-40}  {3}" -f $tag, $_.category, $_.name.Substring(0,[Math]::Min(40,$_.name.Length)), $_.target.Substring(0,[Math]::Min(80,$_.target.Length))))
        }
    }
    Write-Section "VERDICT"
    [Console]::Out.WriteLine("  $verdict")
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("  Critical: $criticalCount    Warnings: $warnCount")
}

if ($criticalCount -gt 0) { exit $script:EXIT_VALIDATION }
exit $script:EXIT_OK
