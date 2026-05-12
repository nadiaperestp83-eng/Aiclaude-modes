<#
.SYNOPSIS
    Re-verify SHA-256 of the committed process-compose.exe against recorded EXE_HASH.

.DESCRIPTION
    Run periodically (e.g. monthly, or as a pre-commit hook). Fails loud on mismatch.

.PARAMETER BinDir
    Path to the bin/ directory containing process-compose.exe and EXE_HASH.
    Defaults to ./bin or ../bin.

.EXAMPLE
    .\verify-binary.ps1
#>

[CmdletBinding()]
param(
    [string]$BinDir = $null
)

$ErrorActionPreference = 'Stop'

# Auto-detect bin/
if (-not $BinDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    foreach ($candidate in @(
        (Join-Path $scriptDir '..\bin'),
        (Join-Path (Get-Location) 'bin')
    )) {
        if (Test-Path (Join-Path $candidate 'process-compose.exe')) {
            $BinDir = (Resolve-Path $candidate).Path
            break
        }
    }
}

if (-not $BinDir -or -not (Test-Path $BinDir)) {
    throw "bin/ directory not found - pass -BinDir explicitly"
}

$exePath  = Join-Path $BinDir 'process-compose.exe'
$hashFile = Join-Path $BinDir 'EXE_HASH'

if (-not (Test-Path $exePath))  { throw "process-compose.exe not found in $BinDir" }
if (-not (Test-Path $hashFile)) { throw "EXE_HASH not found in $BinDir (run install-process-compose.ps1 to create it)" }

$expected = (Get-Content $hashFile -Raw).Trim().ToLower()
$actual   = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLower()

Write-Host "Verifying: $exePath" -ForegroundColor Cyan
Write-Host "  Expected: $expected"
Write-Host "  Actual:   $actual"

if ($expected -ne $actual) {
    Write-Host "  Status:   MISMATCH" -ForegroundColor Red
    throw "BINARY VERIFICATION FAILED - do not trust this binary"
}

Write-Host "  Status:   OK" -ForegroundColor Green
