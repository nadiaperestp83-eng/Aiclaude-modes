# macOS Startup Mechanisms

Load this when doing a full startup audit, hunting auto-launch hooks across multiple mechanisms, or implementing disable-without-sudo for user-scope items.

macOS has **four primary** startup mechanisms plus a handful of less-common ones. System Settings → General → Login Items shows only the first one. The rest are invisible to most users.

## Contents

1. [The five mechanisms](#the-five-mechanisms)
2. [Login Items (System Settings)](#login-items-system-settings)
3. [User LaunchAgents](#user-launchagents)
4. [System LaunchAgents](#system-launchagents)
5. [System LaunchDaemons](#system-launchdaemons)
6. [Legacy LoginHook](#legacy-loginhook)
7. [Configuration profiles](#configuration-profiles)
8. [Vendor patterns](#vendor-patterns)
9. [Disable strategies](#disable-strategies)
10. [Order of execution](#order-of-execution)

## The five mechanisms

| # | Mechanism | Scope | User-visible | Admin needed to write |
|---|---|---|---|---|
| 1 | Login Items | Per-user, on login | Yes (System Settings) | No |
| 2 | User LaunchAgents | Per-user, on login | No | No |
| 3 | System LaunchAgents | Per-user, on login (any user) | No | Yes |
| 4 | System LaunchDaemons | System-wide, on boot | No | Yes |
| 5 | Legacy LoginHook | Per-user, on login (single script) | No | Yes |

Modern macOS has effectively retired LoginHook in favor of LaunchAgents but it's still honored when present.

## Login Items (System Settings)

**Path:** Stored in `~/Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm` (binary plist — opaque).

**Inspect:** AppleScript via System Events:

```applescript
tell application "System Events"
    name of every login item
end tell
```

```bash
osascript -e 'tell application "System Events" to name of every login item'
```

**Disable:**

```bash
osascript -e 'tell application "System Events" to delete login item "AppName"'
```

No sudo needed; this is per-user.

**Vendor patterns to look for:**
- "Adobe Creative Cloud" — added by most Adobe app installers
- "Microsoft AutoUpdate" — Office installs
- "Setapp" — if user uses Setapp app subscription
- "Granola", "Notion", "Slack", "Dropbox" — common productivity apps

## User LaunchAgents

**Path:** `~/Library/LaunchAgents/*.plist`

**Loaded by:** `launchd` in the user's GUI session (`gui/$UID`) at login.

**Inspect:**

```bash
ls ~/Library/LaunchAgents
# For a specific agent:
plutil -p ~/Library/LaunchAgents/com.example.helper.plist
```

**Disable (no sudo):**

```bash
launchctl disable gui/$UID/com.example.helper        # persistent
launchctl bootout gui/$UID/com.example.helper        # kill now
```

**Common offenders:**
- `com.google.GoogleUpdater.wake` — Google's update agent (runs every few hours)
- `com.google.keystone.agent` — Older Google updater
- `com.adobe.ccxprocess` — Adobe CC helper
- `com.valvesoftware.steamclean` — Steam cleanup
- `com.docker.helper` — Docker Desktop user-side helper

## System LaunchAgents

**Path:** `/Library/LaunchAgents/*.plist`

**Loaded by:** Same as user LaunchAgents (`gui/$UID`) at login — but plists live in the system path so admin is needed to install them. They still run **per-user**.

**Inspect / disable:** Same as user LaunchAgents:

```bash
launchctl disable gui/$UID/com.example.system-agent     # no sudo needed
                                                         # for disable, even
                                                         # though plist is in
                                                         # /Library/LaunchAgents
```

This is the key insight: even though writing to `/Library/LaunchAgents/` requires admin, **disabling** an existing agent for your own session does not. The disable state is per-user.

**Common offenders:**
- `com.adobe.AdobeCreativeCloud` — Adobe CC
- `com.eset.esets_gui` — ESET tray app
- `us.zoom.updater.login.check` — Zoom updater
- `com.microsoft.update.agent` — Microsoft AutoUpdate

## System LaunchDaemons

**Path:** `/Library/LaunchDaemons/*.plist`

**Loaded by:** `launchd` system instance (`system`) at boot. Run as the UID specified in the plist (often `root`).

**Inspect:**

```bash
ls /Library/LaunchDaemons
sudo launchctl print system | head -40
```

**Disable (requires sudo):**

```bash
sudo launchctl disable system/com.example.daemon
sudo launchctl bootout system/com.example.daemon
```

**Common offenders:**
- `com.docker.socket`, `com.docker.vmnetd` — Docker
- `com.adobe.acc.installer.v2` — Adobe Creative Cloud installer
- `com.microsoft.autoupdate.helper` — MS AutoUpdate
- `us.zoom.ZoomDaemon` — Zoom
- `com.cloudflare.1dot1dot1dot1.macos.warp.daemon` — Cloudflare WARP
- `com.google.GoogleUpdater.wake.system` — Google updater

## Legacy LoginHook

A single executable that runs on every login. Pre-LaunchAgent era.

**Inspect:**

```bash
sudo defaults read com.apple.loginwindow LoginHook
sudo defaults read com.apple.loginwindow LogoutHook
```

**Remove:**

```bash
sudo defaults delete com.apple.loginwindow LoginHook
sudo defaults delete com.apple.loginwindow LogoutHook
```

LoginHook is rarely used today — if you find one, it likely originates from old enterprise scripts or mac-vintage admin tooling. Replace with a proper LaunchAgent.

## Configuration profiles

MDM-managed Macs may have configuration profiles that add:

- Login items
- Network filters (DNS, proxies)
- LaunchDaemons / LaunchAgents
- TCC grants

**Inspect:**

```bash
profiles list -type configuration                  # user-scope
sudo profiles list -type configuration             # all profiles
sudo profiles show -type configuration             # full payloads
```

Profile-managed items can **override** user choices and may re-apply automatically. Removing profile-managed items requires either:

1. The profile's removal password (set by the MDM admin)
2. MDM disenrollment

Coordinate with IT before removing managed items.

## Vendor patterns

A startup audit usually finds the same handful of vendors leaking auto-start hooks across multiple mechanisms:

### Adobe Creative Cloud

Installs items in:
- Login Items (Adobe Creative Cloud)
- User LaunchAgent (`com.adobe.ccxprocess`)
- System LaunchAgent (`com.adobe.AdobeCreativeCloud`)
- System LaunchDaemon (`com.adobe.acc.installer.v2`)
- Privileged helper (`/Library/PrivilegedHelperTools/com.adobe.acc.installer.v2`)

To fully stop Adobe auto-launch, **disable all five**. Killing one doesn't stop the others.

### Microsoft Office

Installs:
- Login Items (Microsoft Defender if installed)
- System LaunchAgent (`com.microsoft.update.agent`)
- System LaunchDaemon (`com.microsoft.autoupdate.helper`)
- Privileged helper (`com.microsoft.autoupdate.helper`)

### Docker Desktop

Installs:
- Login Items (Docker.app)
- User LaunchAgent (`com.docker.helper`)
- System LaunchDaemons (`com.docker.socket`, `com.docker.vmnetd`)
- Privileged helpers (`com.docker.socket`, `com.docker.vmnetd`)

### Google Drive / Chrome

- Login Items (Google Drive)
- User LaunchAgent (`com.google.GoogleUpdater.wake`)
- User LaunchAgent (`com.google.keystone.agent` — legacy)
- System LaunchDaemon (`com.google.GoogleUpdater.wake.system`)

### Zoom

- System LaunchAgent (`us.zoom.updater.login.check`, `us.zoom.updater`)
- System LaunchDaemon (`us.zoom.ZoomDaemon`)
- Privileged helper (`us.zoom.ZoomDaemon`)

### Cisco AnyConnect / Secure Client

- System LaunchAgent (`com.cisco.anyconnect.gui`)
- System LaunchDaemon (`com.cisco.anyconnect.vpnagentd`)
- Multiple kexts / system extensions
- Configuration profile (often)

Cisco is notable for installing across nearly every mechanism plus its own system extension.

## Disable strategies

### Strategy 1: System Settings (UI)

Quickest for Login Items. System Settings → General → Login Items. Toggle off, or click `-` to remove.

### Strategy 2: `safe-disable-startup.sh` (this skill)

Handles all four mechanisms (Login Items + 3 launchd tiers) in one command:

```bash
scripts/safe-disable-startup.sh -n 'com.adobe.*'
scripts/safe-disable-startup.sh -n 'com.adobe.*' --apply
```

Default is dry-run. `--apply` performs the disable. `--enable` reverses.

### Strategy 3: Direct `launchctl`

For surgical control:

```bash
# User agent (no sudo)
launchctl disable gui/$UID/com.example.helper
launchctl bootout gui/$UID/com.example.helper

# System daemon (sudo)
sudo launchctl disable system/com.example.daemon
sudo launchctl bootout system/com.example.daemon
```

### Strategy 4: Delete the plist (irreversible)

Don't do this. Disabling preserves the file for future re-enable; deleting requires reinstall.

## Order of execution

Roughly:

```
EFI → boot.efi → kernel → launchd (PID 1)
                              │
                              ├── system domain LaunchDaemons load (/Library/LaunchDaemons + /System/...)
                              │
                              └── loginwindow → user enters credentials → gui/$UID domain starts
                                                                            │
                                                                            ├── gui/$UID LaunchAgents load
                                                                            │
                                                                            └── Login Items fire
```

Login Items run **after** LaunchAgents — so a LaunchAgent failing won't be visible at the login UI, but a Login Item failing might be.

## Cross-references

- `scripts/startup-audit.sh` — full inventory across all mechanisms
- `scripts/safe-disable-startup.sh` — reversible disable
- For Windows equivalents (Run keys, Services, Scheduled Tasks, Startup folder), see `windows-ops/references/startup-mechanisms.md`
- For launchd plist semantics, see `launchd-deep-dive.md`
- For configuration profile inspection, see `tcc-mechanics.md` (profiles also gate TCC)
