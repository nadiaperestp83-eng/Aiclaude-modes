# Windows Specifics for portless

Things that bite on Windows but work transparently on macOS/Linux.

## OpenSSL Required for Cert Generation

Portless uses OpenSSL to generate the local CA on first run. Without it:

```
Error: openssl failed: spawnSync openssl ENOENT
```

### Fix — Add Git for Windows's bundled OpenSSL to PATH

Git for Windows ships a usable OpenSSL at `C:\Program Files\Git\usr\bin\openssl.exe`. Add it to your user PATH permanently:

```powershell
$gitBin = "C:\Program Files\Git\usr\bin"
$current = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($current -notlike "*$gitBin*") {
    [Environment]::SetEnvironmentVariable("PATH", "$gitBin;$current", "User")
}

# Verify
openssl version
```

For Task Scheduler / boot-time launches, the PATH must be set in the wrapper script (Task Scheduler runs with minimal PATH by default).

### Alternative — install standalone OpenSSL

```powershell
winget install -e --id ShiningLight.OpenSSL.Light
# or
scoop install openssl
```

## CA Trust via certutil

`portless trust` calls Windows's `certutil.exe` to add the portless CA to the system trust store. Side effects:

- **Affects browsers using the system store** (Chrome, Edge, Firefox-with-Windows-certs) — they will trust `*.<tld>` certs after `portless trust`
- **Does NOT affect curl on Windows** — curl ships its own CA bundle and ignores the system store
- **Does NOT affect Firefox by default** — Firefox uses its own NSS cert store unless you set `security.enterprise_roots.enabled=true` in `about:config`

`portless trust` may prompt the UAC dialog; without admin elevation it may silently fail to add system-wide trust. Run from an elevated PowerShell for reliable installation.

## curl vs Browser Cert Handling

Symptom: `curl https://myapp.test/` returns HTTP code 000, but the browser loads `https://myapp.test/` fine with a green padlock.

Reason: curl uses its own CA bundle, browsers use the OS trust store.

Three workarounds for curl on Windows:

```bash
# 1. Skip verification (quickest, fine for local dev)
curl -k https://myapp.test/

# 2. Point curl at portless's CA explicitly
curl --cacert "$env:USERPROFILE/.portless/ca.pem" https://myapp.test/

# 3. Add the portless CA to curl's bundle (one-time setup)
# Locate curl's CA bundle (varies by install):
curl-config --ca   # if curl-config is available
# Or check $env:CURL_CA_BUNDLE or the bundle at the curl install dir

# Then append portless's CA to it:
type "$env:USERPROFILE\.portless\ca.pem" >> "C:\path\to\curl\bin\curl-ca-bundle.crt"
```

For most dev workflows just use `-k` — it's the fastest path.

## Boot Persistence — Task Scheduler

`portless service install` registers a Task Scheduler entry that runs the proxy at system startup. Notes:

- Runs as **SYSTEM** (not your user account) — fine because portless only needs to bind ports and read its own state dir
- The state dir defaults to `%USERPROFILE%\.portless\` — Task Scheduler running as SYSTEM might not see it. Override with `PORTLESS_STATE_DIR` env if needed.
- Uninstall: `portless service uninstall` or `portless clean` (also removes the task)

For Process Compose's boot task, see `process-compose-ops` skill's `boot-persistence-windows.md`.

## /etc/hosts on Windows

Windows uses `C:\Windows\System32\drivers\etc\hosts`. `portless hosts sync` writes to it — requires admin elevation.

If portless isn't auto-syncing:

```powershell
# Check what's in hosts
notepad C:\Windows\System32\drivers\etc\hosts

# Force a re-sync (run as admin)
portless hosts sync
```

## Port 443 Without sudo

On macOS/Linux, binding port 443 requires `sudo` (portless auto-elevates). On Windows, no elevation is required to bind privileged ports for the current user — portless just binds them directly.

Caveat: if **another service is already bound to 443** (IIS, Skype, Caddy from old setup), portless will fail to start with `EADDRINUSE`. Find the culprit:

```powershell
netstat -ano | findstr ":443 "
# Look at the PID, then:
Get-Process -Id <pid>
```

Stop the conflicting service or pick a different port (`--port 1355`).

## PowerShell 5.1 vs 7+

PowerShell 5.1 (the default Windows PowerShell that ships with Windows) lacks some newer flags that PowerShell 7 has. Examples that bite:

```powershell
# PS 7+: -SkipCertificateCheck
Invoke-WebRequest -Uri https://x.lab -SkipCertificateCheck
# PS 5.1: parameter not recognized → use curl.exe -k instead

# PS 7+: ternary operator
$x = $foo ? "yes" : "no"
# PS 5.1: parse error → use if-else

# PS 7+: pipeline parallel
... | ForEach-Object -Parallel { ... }
# PS 5.1: -Parallel not available
```

If a script needs PS 7+ features, the shebang doesn't help on Windows — invoke explicitly with `pwsh` instead of `powershell`:

```powershell
pwsh -File .\myscript.ps1
```

## Cleanup

```powershell
# Stop proxy + uninstall boot task + clear state
portless clean

# Verify clean state
Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
# Should return nothing if portless was the only thing on 443
```

`portless clean` removes the portless CA from the trust store too, so browsers will see warnings again until you re-trust.
