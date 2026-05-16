# Remote macOS Diagnostics

Load this when running mac-ops against a Mac you can't sit in front of — a server, a colleague's machine across town, a family member's iMac. Unlike Windows (which has WinRM, PSRemoting, WS-Man, and the double-hop problem), macOS remote management is **SSH all the way down** plus a few macOS-specific bits.

## Contents

1. [SSH baseline](#ssh-baseline)
2. [Enabling Remote Login from a UI-less context](#enabling-remote-login-from-a-ui-less-context)
3. [Staging the skill on the target](#staging-the-skill-on-the-target)
4. [sudo over SSH](#sudo-over-ssh)
5. [Apple Remote Desktop (ARD) — `kickstart`](#apple-remote-desktop-ard--kickstart)
6. [Screen Sharing (VNC)](#screen-sharing-vnc)
7. [Common failure modes](#common-failure-modes)
8. [Authentication strategies](#authentication-strategies)

## SSH baseline

macOS 13+ ships OpenSSH server out of the box. Enable from:

- **GUI:** System Settings → General → Sharing → toggle "Remote Login"
- **CLI (admin):** `sudo systemsetup -setremotelogin on`
- **Verify:** `sudo systemsetup -getremotelogin`

Connect:

```bash
ssh <user>@<host>
```

Default port 22. Listens on all interfaces by default. To restrict, edit `/etc/ssh/sshd_config`.

## Enabling Remote Login from a UI-less context

If you can't reach System Settings (e.g., headless setup or you're already remote via another channel):

```bash
sudo systemsetup -setremotelogin on
```

`systemsetup` is sandbox-restricted on macOS 12+. If it errors:

```bash
sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist     # macOS 11 and earlier
sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist   # macOS 12+
```

To restrict to specific users (`/etc/ssh/sshd_config`):

```
AllowUsers admin remoteuser
AllowGroups admin remoteoperators
```

Reload sshd:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

## Staging the skill on the target

The pattern: copy the skill folder to the target, then invoke per-script over SSH.

```bash
# Stage
scp -r ~/.claude/skills/mac-ops <user>@<host>:~/mac-ops-staging

# Run a probe
ssh <user>@<host> 'bash ~/mac-ops-staging/scripts/health-audit.sh --json --redact'
```

Or run a single script via stdin without staging:

```bash
ssh <user>@<host> 'bash -s' < ~/.claude/skills/mac-ops/scripts/health-audit.sh -- --json --redact
```

The `--` separates ssh's bash invocation from the script's own args.

### Tarball + ship pattern (when scp+stdin won't work)

```bash
# Local: bundle the skill
tar czf /tmp/mac-ops.tar.gz -C ~/.claude/skills mac-ops

# Send + extract + run
scp /tmp/mac-ops.tar.gz <user>@<host>:/tmp/
ssh <user>@<host> 'cd /tmp && tar xzf mac-ops.tar.gz && bash mac-ops/scripts/health-audit.sh --json'
```

## sudo over SSH

Some diagnostic scripts need sudo (system TCC.db, full LaunchDaemon inspection). Two options:

### Option A: NOPASSWD entry (for trusted automation only)

Add to `/etc/sudoers.d/mac-ops` on the target:

```
remoteuser ALL=(ALL) NOPASSWD: /usr/sbin/sysdiagnose, /usr/bin/log, /usr/sbin/diskutil, /usr/bin/launchctl
```

Restrict the command list — never grant blanket NOPASSWD for all of ALL.

### Option B: TTY-allocated SSH (for interactive runs)

```bash
ssh -t <user>@<host> 'sudo bash ~/mac-ops-staging/scripts/health-audit.sh'
```

`-t` forces a pseudo-terminal so sudo can prompt for the password. You type it on the local terminal; SSH proxies the prompt.

### Option C: stdin-passed password (avoid in real automation)

```bash
echo 'password' | ssh <user>@<host> 'sudo -S bash ~/script.sh'
```

Visible in process listings and shell history. Use only for one-off testing on machines you control.

## Apple Remote Desktop (ARD) — `kickstart`

ARD provides screen sharing, file transfer, and remote commands. It's enabled via the `kickstart` utility:

```bash
# Enable ARD service for all users
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -restart -agent -privs -all

# Restrict to one user
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users <username> -privs -all

# Disable
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -configure -access -off
```

ARD listens on TCP 3283 + 5900. Combine with the macOS firewall to restrict source IPs.

## Screen Sharing (VNC)

macOS's Screen Sharing is VNC-compatible:

- **Enable:** System Settings → General → Sharing → Screen Sharing
- **CLI:** `sudo systemsetup -getremotescreensharing` (read-only on recent macOS)

Default port 5900. Use only over SSH tunnel or VPN — VNC is unencrypted.

SSH-tunnel pattern:

```bash
ssh -L 5900:localhost:5900 <user>@<host>
# Then connect a VNC client to localhost:5900
```

## Common failure modes

### "Permission denied (publickey)"

Server doesn't accept your key. Options:

- Add your key: `ssh-copy-id <user>@<host>`
- Use password auth: `ssh -o PreferredAuthentications=password <user>@<host>` (requires `PasswordAuthentication yes` in sshd_config)

### "Connection refused"

`sshd` not running. SSH into the target via a different channel (Apple Remote Desktop, physical access) and:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

### "Too many authentication failures"

Local SSH agent is trying multiple keys. Force a specific key:

```bash
ssh -i ~/.ssh/specific_key -o IdentitiesOnly=yes <user>@<host>
```

### "Network is unreachable" / "host not found"

DNS or routing problem. Use `net-ops/scripts/reverse-probe.sh` from another machine to confirm reachability.

### "sudo: a terminal is required"

Pass `-t` to ssh:

```bash
ssh -t <user>@<host> 'sudo command'
```

### "Operation not permitted" inside SSH session

The remote shell may lack Full Disk Access. Grant FDA to `/usr/libexec/sshd-keygen-wrapper` or to the user's shell binary in System Settings → Privacy & Security → Full Disk Access.

## Authentication strategies

| Scenario | Strategy |
|---|---|
| Your own personal Mac | SSH key auth + Touch ID for sudo (`auth sufficient pam_tid.so` in `/etc/pam.d/sudo_local`) |
| Family member's Mac, occasional check-ins | SSH key auth + sudoers.d NOPASSWD entry for the diagnostic commands |
| Corporate Mac under MDM | Usually managed via MDM-issued cert. SSH may be disabled or restricted by profile. Coordinate with IT. |
| Server Mac in a datacenter | SSH key auth + dedicated `mac-ops` user with sudoers.d entry for diagnostic commands only |
| One-off colleague's Mac | `ssh-copy-id` once, then run the staging pattern. Remove your key when done. |

## Cross-references

- `net-ops/scripts/ssh-bootstrap.sh` — initial SSH connection helper with key + password fallback
- `net-ops/scripts/reverse-probe.sh` — probe a remote host's reachability
- For Windows equivalent (PSRemoting, WS-Man, double-hop), see `windows-ops/references/remote-diagnostics.md`
