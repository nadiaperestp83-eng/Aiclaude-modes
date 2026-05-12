# Boot Persistence on Windows

Process Compose has no built-in `service install` (unlike portless). On Windows, register a Task Scheduler entry.

## Key Constraints

1. Task Scheduler runs with a **minimal PATH** — Python, uv, Git tools, custom binaries won't be found unless we set PATH explicitly
2. Tasks running at boot-before-logon need **LogonType S4U** (no stored password, no interactive logon)
3. Hidden window style avoids console flash on login

## Two-File Pattern

Use a wrapper script that sets the environment, then have Task Scheduler launch the wrapper. Keeps task definition simple and lets you tweak env without re-registering.

### File 1 — `boot-start.ps1` (wrapper)

```powershell
<#
.SYNOPSIS
    Boot-time launcher for Process Compose. Sets PATH and launches headless.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = (Resolve-Path (Join-Path $scriptDir '..')).Path
$pcExe     = Join-Path $root 'bin\process-compose.exe'
$pcYaml    = Join-Path $root 'process-compose.yaml'
$logFile   = Join-Path $root 'logs\process-compose.log'
$bootLog   = Join-Path $root 'logs\boot-start.log'

New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] boot-start invoked. User: $env:USERNAME" | Out-File -FilePath $bootLog -Append

# Build PATH explicitly. Tune for your machine.
$pathParts = @(
    "$root\bin"                                                       # PC + any committed binaries
    "C:\Program Files\Git\usr\bin"                                    # openssl, bash, coreutils
    "C:\Program Files\Git\bin"                                        # git
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313"  # python, pythonw
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\Scripts"  # uv, pip, etc.
    "C:\Program Files (x86)\cloudflared"                              # optional: cloudflared
    "C:\Windows\System32"
    "C:\Windows"
    $env:PATH
)
$env:PATH = ($pathParts -join ';')

# Optional: load secrets from gitignored .env (e.g. API keys)
$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

# Ensure incompatible env vars are unset (example: OAuth-only services that
# refuse to start with stale API keys)
# [Environment]::SetEnvironmentVariable('SOME_API_KEY', $null, 'Process')

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] Starting process-compose..." | Out-File -FilePath $bootLog -Append

# -p 8888    API port (pick something free, avoid 8080 if you have other tools there)
# -t=false   no TUI (headless daemon mode)
# -L         PC's own log file
& $pcExe -p 8888 -t=false -L $logFile up -f $pcYaml

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] process-compose exited code $LASTEXITCODE" | Out-File -FilePath $bootLog -Append
```

### File 2 — `boot-task-install.ps1` (registers the task)

```powershell
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Must be admin to create scheduled tasks
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
}

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root       = (Resolve-Path (Join-Path $scriptDir '..')).Path
$bootScript = Join-Path $scriptDir 'boot-start.ps1'

$taskName = "ProcessCompose-MyStack"   # rename per project

# Idempotent: remove existing if present
Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$bootScript`"" `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# S4U: run at boot as user without interactive logon or stored password
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType S4U `
    -RunLevel Highest

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal `
    -Description "Starts Process Compose at boot."
```

## LogonType Trade-offs

| LogonType | Runs at boot before logon? | Needs password? | Capability |
|---|---|---|---|
| `Interactive` | No — waits for user logon | No | Full user context (UI, network shares) |
| `S4U` | Yes | No | User context but no UI, no network shares |
| `Password` | Yes | Yes (stored encrypted) | Full user context |
| `ServiceAccount` | Yes (as Local System / Network Service) | No | Limited to service account perms — typically can't read user files |

For Process Compose managing user-scoped dev services, **S4U** is usually the right choice: services run as the user (can read `C:\Users\<user>\...`) without requiring an interactive logon.

## Verify After Registration

```powershell
# Check task exists
Get-ScheduledTask -TaskName "ProcessCompose-MyStack" |
    Format-List TaskName, State, Triggers, Principal

# Manually run the task to test before reboot
Start-ScheduledTask -TaskName "ProcessCompose-MyStack"

# Wait, then check PC is up
Start-Sleep -Seconds 10
process-compose -p 8888 process list
```

## Troubleshooting Boot Failures

After a reboot, if services don't come up:

1. **Check the boot log:** `<root>/logs/boot-start.log` — confirm the wrapper actually ran
2. **Check PC's log:** `<root>/logs/process-compose.log` — confirm PC started and look for process-spawn errors
3. **Check Task Scheduler history:** Right-click the task → History tab. Look for failure reasons.
4. **Reproduce manually:** open elevated PS, run `.\scripts\boot-start.ps1` and watch what happens.

Common failures:
- PATH missing a tool → add to `pathParts` array
- Working dir not absolute → ensure all paths in `process-compose.yaml` are absolute
- Secrets not loaded → `.env` file not in expected location
- Port collision (PC API port 8888 occupied) → check `netstat -ano | findstr :8888`

## Pair with portless service install

portless has its own boot task. The two are independent — register both:

```powershell
portless service install              # registers portless's task
.\scripts\boot-task-install.ps1       # registers PC's task

# Verify both
Get-ScheduledTask | Where-Object {
    $_.TaskName -like "*ortless*" -or $_.TaskName -like "*ompose*"
}
```

## Uninstall

```powershell
# In the same script:
Get-ScheduledTask -TaskName "ProcessCompose-MyStack" -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

portless service uninstall
```
