# TCC (Transparency, Consent, Control) Mechanics

Load this when an app silently fails to access screen recording, microphone, camera, files, Accessibility, or another app. TCC is macOS's privacy permissions database — every Allow/Deny grant ever made lives in `TCC.db` and silently controls what apps can do.

## Contents

1. [What TCC is](#what-tcc-is)
2. [Database locations](#database-locations)
3. [Service catalog](#service-catalog) — every kTCCService* string
4. [Schema](#schema) — the `access` table
5. [auth_value semantics](#auth_value-semantics)
6. [Reading TCC.db](#reading-tccdb)
7. [Resetting grants](#resetting-grants) — `tccutil`
8. [The Full Disk Access requirement](#the-full-disk-access-requirement)
9. [SIP and TCC](#sip-and-tcc)
10. [Common failure modes](#common-failure-modes)

## What TCC is

TCC is the framework macOS uses for **per-app, per-resource** privacy controls. When an app tries to read your contacts, record the screen, listen on the mic, or send keystrokes to another app, the request goes through TCC. TCC either:

1. Looks up an existing grant → silently allow or deny
2. Has no grant → show a system prompt, record the user's answer

Once recorded, the grant persists across reboots until the user revokes it (System Settings → Privacy & Security) or `tccutil reset` is run.

The "silent denial" mode is the diagnostic pain: an app that previously worked stops working, the user remembers no prompt, and TCC quietly returns "not permitted" to the app's APIs. The app reports "feature unavailable" without explaining why.

## Database locations

```
~/Library/Application Support/com.apple.TCC/TCC.db    User-scope grants (per-user)
/Library/Application Support/com.apple.TCC/TCC.db     System-scope grants (machine-wide)
```

Both are SQLite databases. Both are protected by SIP/Full Disk Access — your terminal needs FDA to read them.

To grant FDA to your terminal:
1. System Settings → Privacy & Security → Full Disk Access → +
2. Choose `/Applications/Utilities/Terminal.app` (or your terminal of choice)
3. Restart the terminal session

## Service catalog

Every grant is for a (service, client) pair. The service string starts with `kTCCService`. Common ones:

| Service string | What it gates | User-facing name |
|---|---|---|
| `kTCCServiceScreenCapture` | Screen recording, screenshots | Screen Recording |
| `kTCCServiceMicrophone` | Audio input | Microphone |
| `kTCCServiceCamera` | Video input | Camera |
| `kTCCServiceAccessibility` | Synthetic input events, control other apps | Accessibility |
| `kTCCServiceSystemPolicyAllFiles` | Read all files (Time Machine, backup apps) | Full Disk Access |
| `kTCCServicePostEvent` | Generate synthetic input events | (part of Accessibility) |
| `kTCCServiceListenEvent` | Listen to global input events | Input Monitoring |
| `kTCCServiceAppleEvents` | Control another app via AppleScript | Automation |
| `kTCCServicePhotos` | Photos library access | Photos |
| `kTCCServiceContactsFull` | Read all contacts | Contacts (full) |
| `kTCCServiceContactsLimited` | Limited contacts access | Contacts (limited) |
| `kTCCServiceCalendar` | Calendar events | Calendars |
| `kTCCServiceReminders` | Reminders | Reminders |
| `kTCCServiceMotion` | Motion / fitness data | Motion & Fitness |
| `kTCCServiceMediaLibrary` | Apple Music library | Apple Music |
| `kTCCServiceSpeechRecognition` | On-device speech recognition | Speech Recognition |
| `kTCCServiceLocation` | Geolocation | Location Services (separate UI) |
| `kTCCServiceSystemPolicyDesktopFolder` | Desktop folder | Files & Folders → Desktop |
| `kTCCServiceSystemPolicyDocumentsFolder` | Documents folder | Files & Folders → Documents |
| `kTCCServiceSystemPolicyDownloadsFolder` | Downloads folder | Files & Folders → Downloads |
| `kTCCServiceSystemPolicyRemovableVolumes` | External volumes | Files & Folders → Removable Volumes |
| `kTCCServiceSystemPolicyNetworkVolumes` | Network mounts | Files & Folders → Network Volumes |
| `kTCCServiceFileProviderDomain` | File provider extensions | (none — system) |
| `kTCCServiceUbiquity` | iCloud Drive sync | (managed by iCloud) |
| `kTCCServiceDeveloperTool` | Run unsigned binaries | Developer Tools |
| `kTCCServicePrototype3Rights` | Future feature placeholder | (not user-facing) |

## Schema

The `access` table (simplified):

```sql
CREATE TABLE access (
    service TEXT NOT NULL,           -- kTCCService* string
    client TEXT NOT NULL,            -- bundle ID or path
    client_type INTEGER NOT NULL,    -- 0=bundle ID, 1=absolute path
    auth_value INTEGER NOT NULL,     -- 0=deny, 1=unknown, 2=allow, 3=limited
    auth_reason INTEGER NOT NULL,    -- why was this set (user prompt, MDM, etc.)
    auth_version INTEGER NOT NULL,
    csreq BLOB,                       -- code signature requirement
    policy_id INTEGER,
    indirect_object_identifier_type INTEGER,
    indirect_object_identifier TEXT,
    indirect_object_code_identity BLOB,
    flags INTEGER,
    last_modified INTEGER NOT NULL,  -- unix epoch
    pid INTEGER,
    pid_version INTEGER,
    boot_uuid TEXT,
    last_reminded INTEGER
    -- newer macOS versions add columns; the above is the stable core
);
```

`auth_reason` values worth knowing:

- `0` = not set
- `1` = error (something went wrong, default-deny)
- `2` = user denied at prompt
- `3` = user consent
- `4` = system set
- `5` = service policy (the deny was structural, not user)
- `6` = MDM policy

## auth_value semantics

| Value | Meaning |
|---|---|
| `0` | **Denied**. App requests fail silently with permission error. |
| `1` | Unknown / not yet asked. Next request triggers a prompt. |
| `2` | **Allowed**. App requests succeed. |
| `3` | **Limited**. Used for partial Photos access (specific albums) and similar. |

## Reading TCC.db

```bash
# Allowed grants on this user
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, datetime(last_modified, 'unixepoch') FROM access WHERE auth_value = 2"

# Denials (the diagnostic gold mine)
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, datetime(last_modified, 'unixepoch') FROM access WHERE auth_value = 0"

# A specific app's grants
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, auth_value FROM access WHERE client = 'com.tinyspeck.slackmacgap'"
```

System TCC.db needs sudo and FDA:

```bash
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access"
```

## Resetting grants

`tccutil` resets a (service, client) pair back to "Unknown" — the next request prompts the user again. This is the **correct fix** for "Slack lost Screen Recording after macOS update":

```bash
# Reset by service + bundle ID
tccutil reset ScreenCapture com.tinyspeck.slackmacgap

# Reset ALL services for a specific bundle ID (rare; use with care)
tccutil reset All com.tinyspeck.slackmacgap

# Reset ALL apps for a specific service (nuclear)
tccutil reset ScreenCapture
```

Service-name shorthand for `tccutil` strips the `kTCCService` prefix:

| Full service string | tccutil shorthand |
|---|---|
| `kTCCServiceScreenCapture` | `ScreenCapture` |
| `kTCCServiceMicrophone` | `Microphone` |
| `kTCCServiceCamera` | `Camera` |
| `kTCCServiceAccessibility` | `Accessibility` |
| `kTCCServiceSystemPolicyAllFiles` | `SystemPolicyAllFiles` |
| `kTCCServiceAppleEvents` | `AppleEvents` |

## The Full Disk Access requirement

Many TCC operations require **the calling process** itself to have Full Disk Access. This is the bootstrap problem:

- `cat ~/Library/Application\ Support/com.apple.TCC/TCC.db` → `Permission denied` unless your shell has FDA
- A backup app trying to back up `~/Library/` needs FDA
- A monitoring agent trying to read `~/Library/Logs/` may need FDA

Two-step grant:
1. System Settings → Privacy & Security → Full Disk Access
2. Add the binary (e.g. `/Applications/Utilities/Terminal.app`)
3. Quit and restart the app — grants only apply on new launch

## SIP and TCC

System Integrity Protection (SIP) protects TCC.db itself from tampering. With SIP enabled (default):

- You cannot edit TCC.db directly even as root — the kernel will reject the write
- `tccutil reset` is the only sanctioned way to clear grants
- Some tools (security research, blue-team scripts) require SIP disabled to inspect/modify TCC. **Don't disable SIP** on a production Mac.

SIP status:

```bash
csrutil status
# "System Integrity Protection status: enabled."
```

## Common failure modes

### "Slack can't record my screen" (the canonical case)

1. macOS updated; TCC schema gained new rows or service moved
2. Slack's screen-recording grant became Unknown or Denied
3. Slack's UI shows the feature as "Unavailable"
4. Fix:
   - System Settings → Privacy & Security → Screen Recording → toggle Slack OFF, then ON
   - Or: `tccutil reset ScreenCapture com.tinyspeck.slackmacgap` then re-open Slack

### "Terminal can't read TCC.db"

Your terminal lacks Full Disk Access. Grant it as above.

### "Automation grant won't stick"

`kTCCServiceAppleEvents` requires BOTH apps to have a grant — the controller AND the target. Adding only the controller is a common mistake.

### "An app I uninstalled still appears in Privacy & Security"

The TCC entry persists after the app is removed. Click `-` in the System Settings list to remove, or run `tccutil reset` on the bundle ID.

### "Reset doesn't reprompt"

`tccutil reset` sets to Unknown but the app needs to re-request. Quit and relaunch the app to trigger the re-prompt.

### "MDM-managed grants"

If the Mac is managed by MDM (configuration profile), some TCC grants are forced and cannot be revoked by the user. `auth_reason = 6` indicates an MDM-set grant. Removing the configuration profile (with admin authorization) is the only way to free the grant.

## Cross-references

- `scripts/tcc-audit.sh` — reads both TCC.dbs with filtering
- For configuration profile inspection, see `scripts/startup-audit.sh` (Section 7)
- For Windows equivalent (none — Windows handles permissions per-API, not centralized), see `windows-ops`
