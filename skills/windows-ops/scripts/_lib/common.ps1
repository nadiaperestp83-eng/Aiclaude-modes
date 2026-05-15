# windows-ops common helpers
# Dot-source from any script: . "$PSScriptRoot\_lib\common.ps1"

# Semantic exit codes (matches ATP §7.8)
$script:EXIT_OK           = 0
$script:EXIT_ERROR        = 1
$script:EXIT_USAGE        = 2
$script:EXIT_NOT_FOUND    = 3
$script:EXIT_VALIDATION   = 4
$script:EXIT_PRECONDITION = 5
$script:EXIT_TIMEOUT      = 6
$script:EXIT_UNAVAILABLE  = 7

function Write-Log {
    # All logs to stderr — never pollute stdout
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','PASS','FAIL','DEBUG')]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $color = switch ($Level) {
        'PASS'  { 'Green' }
        'FAIL'  { 'Red' }
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'Cyan' }
        'DEBUG' { 'DarkGray' }
    }
    [Console]::Error.WriteLine("[$Level] $Message")
    # Re-emit colorised version when stderr is a TTY (for human readability)
    if ([Console]::IsErrorRedirected -eq $false) {
        # Can't easily colorise stderr in PS — accept plain text, color reserved for TTY-only contexts
    }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    $line = '=' * 60
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine($line)
    [Console]::Error.WriteLine("  $Title")
    [Console]::Error.WriteLine($line)
}

function Write-Data {
    # Plain data row to stdout — only thing that should go there
    param([Parameter(Mandatory, ValueFromPipeline)][object]$Object)
    process { $Object | Out-String -Stream | Where-Object { $_ -ne '' } | ForEach-Object { [Console]::Out.WriteLine($_) } }
}

function ConvertTo-Bytes12 {
    # Build a 12-byte StartupApproved value: [status][3-byte pad][8-byte FILETIME]
    param(
        [Parameter(Mandatory)][ValidateRange(0,255)][byte]$StatusByte
    )
    $ts = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
    [byte[]](@($StatusByte, 0, 0, 0) + $ts)
}

function Get-StartupApprovedKey {
    # Ensure the StartupApproved key exists; return its registry path
    param(
        [Parameter(Mandatory)][ValidateSet('Run','Run32','StartupFolder')]$Variant,
        [ValidateSet('HKCU','HKLM')]$Hive = 'HKCU'
    )
    $key = "${Hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Variant"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    }
    return $key
}

function Test-IsElevated {
    # Returns true if running as Administrator
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DiskMap {
    # Map physical disk number -> friendly name / type / drive letters
    # Returns array of [PSCustomObject] with Number, Model, BusType, MediaType, FirmwareVersion, SizeGB, DriveLetters
    Get-Disk | ForEach-Object {
        $disk = $_
        $letters = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter) -join ','
        $physical = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Number } | Select-Object -First 1
        [PSCustomObject]@{
            Number           = $disk.Number
            Model            = $disk.FriendlyName
            BusType          = $disk.BusType
            MediaType        = if ($physical) { $physical.MediaType } else { 'Unknown' }
            FirmwareVersion  = $disk.FirmwareVersion
            SizeGB           = [math]::Round($disk.Size / 1GB, 0)
            DriveLetters     = $letters
            HealthStatus     = $disk.HealthStatus
            SerialNumber     = if ($physical) { $physical.SerialNumber } else { $null }
        }
    }
}

function Resolve-HarddiskRef {
    # Resolve a "\Device\HarddiskN" reference to a disk map row
    param([Parameter(Mandatory)][string]$Reference)
    if ($Reference -match 'Harddisk(\d+)' -or $Reference -match '^Disk\s*(\d+)' -or $Reference -match '^(\d+)$') {
        $num = [int]$matches[1]
        return Get-DiskMap | Where-Object { $_.Number -eq $num } | Select-Object -First 1
    }
    return $null
}

function Format-EventMessage {
    # Truncate + collapse whitespace for table display
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Message,
        [int]$MaxLength = 120
    )
    process {
        $cleaned = $Message -replace '\s+', ' '
        if ($cleaned.Length -le $MaxLength) { return $cleaned }
        return $cleaned.Substring(0, $MaxLength - 3) + '...'
    }
}

# Export common state for caller scripts
$script:CommonLoaded = $true
