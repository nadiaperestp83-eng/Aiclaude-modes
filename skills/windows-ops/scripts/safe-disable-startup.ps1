<#
.SYNOPSIS
    Disable (or re-enable) Windows startup entries via the StartupApproved
    registry mechanism — no admin required, fully reversible.

.DESCRIPTION
    Equivalent of Task Manager's "Disable" button: writes a 12-byte binary
    flag to HKCU\...\Explorer\StartupApproved\{Run,Run32,StartupFolder}
    so the entry is skipped at next logon. Works on HKLM entries from a
    non-admin context (overlay applies per-user only).

    For an entry to be disable-able by this script it must exist in one of:
      - HKCU/HKLM\...\CurrentVersion\Run                    (64-bit)
      - HKLM\...\WOW6432Node\Microsoft\...\Run              (32-bit)
      - Startup folders (user + all-users)
    Services and scheduled tasks are NOT touched by this script — those
    need Set-Service / Disable-ScheduledTask respectively.

.PARAMETER Name
    The Run-key value name to disable. Multiple names accepted (positional
    or via pipeline).

.PARAMETER Enable
    Re-enable instead of disable (flips status byte 0x03 -> 0x02).

.PARAMETER List
    List current state of all StartupApproved entries and exit. Ignores -Name.

.PARAMETER Json
    Emit machine-readable JSON of the action taken.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Adobe Creative Cloud'
    Disable a single entry by exact value name.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Granola','MuseHub','CometUpdaterTask*'
    Disable multiple entries; wildcards expand against actual Run-key entries.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -List
    Show current enabled/disabled state of every known startup entry.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Adobe Creative Cloud' -Enable
    Re-enable a previously-disabled entry.

.NOTES
    Exit codes:
      0 success
      2 usage (no names given and not -List)
      3 not found (no matching Run-key entry for the given name)
      4 validation error
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ValueFromPipeline, Position=0)][string[]]$Name,
    [switch]$Enable,
    [switch]$List,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# Map: registry path -> StartupApproved variant for the overlay
$pathVariantMap = @(
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                       Variant = 'Run' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                       Variant = 'Run' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';           Variant = 'Run32' }
)

function Get-RunEntries {
    $entries = @()
    foreach ($m in $pathVariantMap) {
        if (Test-Path $m.Path) {
            (Get-ItemProperty $m.Path -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object {
                    $entries += [PSCustomObject]@{
                        Name    = $_.Name
                        Command = $_.Value
                        Path    = $m.Path
                        Variant = $m.Variant
                    }
                }
        }
    }
    # Startup folder shortcuts use a separate StartupApproved variant
    foreach ($d in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                     "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp")) {
        if (Test-Path $d) {
            Get-ChildItem $d -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
                $entries += [PSCustomObject]@{
                    Name    = $_.Name        # full filename, e.g. "Comet.lnk"
                    Command = $_.FullName
                    Path    = $d
                    Variant = 'StartupFolder'
                }
            }
        }
    }
    return $entries
}

function Get-CurrentState {
    param(
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][ValidateSet('Run','Run32','StartupFolder')][string]$Variant
    )
    $key = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Variant"
    if (-not (Test-Path $key)) { return 'unmanaged' }
    $val = (Get-ItemProperty $key -Name $EntryName -ErrorAction SilentlyContinue).$EntryName
    if (-not $val) { return 'unmanaged' }   # No overlay = uses default (enabled)
    if ($val[0] -eq 0x03) { return 'disabled' }
    elseif ($val[0] -eq 0x02) { return 'enabled' }
    else { return "unknown(0x{0:X2})" -f $val[0] }
}

# ─────────────────────────────────────────────────────────────────────
# Mode: List
# ─────────────────────────────────────────────────────────────────────
if ($List) {
    $allEntries = Get-RunEntries
    foreach ($e in $allEntries) {
        $state = Get-CurrentState -EntryName $e.Name -Variant $e.Variant
        $row = [PSCustomObject]@{
            Name    = $e.Name
            State   = $state
            Variant = $e.Variant
            Source  = (Split-Path $e.Path -Leaf) + '\' + (Split-Path $e.Path -Parent | Split-Path -Leaf)
            Command = $e.Command -replace '"',''
        }
        if ($Json) {
            [Console]::Out.WriteLine(($row | ConvertTo-Json -Compress))
        } else {
            $tag = switch ($state) { 'disabled' {'[X]'} 'enabled' {'[ ]'} default {'[?]'} }
            [Console]::Out.WriteLine(("{0} {1,-40} {2,-7} {3}" -f $tag, $e.Name.Substring(0, [Math]::Min(40, $e.Name.Length)), $state, $e.Variant))
        }
    }
    exit $script:EXIT_OK
}

# ─────────────────────────────────────────────────────────────────────
# Mode: Disable/Enable
# ─────────────────────────────────────────────────────────────────────
if (-not $Name) {
    Write-Log -Level ERROR -Message "Must provide -Name or -List. See -? for help."
    exit $script:EXIT_USAGE
}

$statusByte = if ($Enable) { [byte]0x02 } else { [byte]0x03 }
$action     = if ($Enable) { 'enable' }   else { 'disable' }
$valueBytes = ConvertTo-Bytes12 -StatusByte $statusByte

$allEntries = Get-RunEntries
$matched    = @()

foreach ($pattern in $Name) {
    $hits = $allEntries | Where-Object { $_.Name -like $pattern }
    if (-not $hits) {
        Write-Log -Level WARN -Message "No Run-key entries match pattern: $pattern"
        continue
    }
    foreach ($e in $hits) {
        if ($PSCmdlet.ShouldProcess("$($e.Name) (Variant=$($e.Variant))", "$action via StartupApproved\$($e.Variant)")) {
            try {
                $key = Get-StartupApprovedKey -Variant $e.Variant
                Set-ItemProperty -Path $key -Name $e.Name -Value $valueBytes -Type Binary -Force
                $matched += $e
                $verified = Get-CurrentState -EntryName $e.Name -Variant $e.Variant
                Write-Log -Level PASS -Message "${action}d: $($e.Name)  [$($e.Variant)] -> verified state: $verified"
                if ($Json) {
                    [Console]::Out.WriteLine((@{
                        action   = $action
                        name     = $e.Name
                        variant  = $e.Variant
                        verified = $verified
                    } | ConvertTo-Json -Compress))
                }
            } catch {
                Write-Log -Level FAIL -Message "Failed to $action $($e.Name): $_"
            }
        }
    }
}

if (-not $matched) {
    Write-Log -Level ERROR -Message "No matching entries acted on."
    exit $script:EXIT_NOT_FOUND
}

if (-not $Json -and -not $Quiet) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($matched.Count) entr$(if ($matched.Count -eq 1) {'y'} else {'ies'}) ${action}d. Effect applies at next user logon.")
    [Console]::Error.WriteLine("Re-run with -List to verify.")
}

exit $script:EXIT_OK
