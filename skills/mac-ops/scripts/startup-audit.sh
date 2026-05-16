#!/usr/bin/env bash
# mac-ops :: startup-audit.sh
# Inventory every auto-start mechanism on this Mac.
#
# Covers:
#   - System Settings → Login Items (user-visible)
#   - User LaunchAgents     ~/Library/LaunchAgents
#   - System LaunchAgents   /Library/LaunchAgents
#   - System LaunchDaemons  /Library/LaunchDaemons
#   - Apple LaunchAgents    /System/Library/LaunchAgents (system-managed, usually skip)
#   - Privileged helpers    /Library/PrivilegedHelperTools
#   - Legacy LoginHook      `sudo defaults read com.apple.loginwindow LoginHook`

set -u

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  --json           Emit NDJSON
  --redact         Mask private addrs / hostnames
  --verbose        Include /System/Library/LaunchAgents (Apple's own — usually noise)
  --quiet          Suppress section banners

Reports total counts per mechanism + per-entry detail. To DISABLE an entry,
use scripts/safe-disable-startup.sh.
EOF
            exit 0 ;;
    esac
done

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

# ----------------------------------------------------------------------------
section "1. LOGIN ITEMS (System Settings → General → Login Items)"
# ----------------------------------------------------------------------------
if items=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
    set output to ""
    repeat with li in (every login item)
        set output to output & (name of li) & "|" & (path of li) & "|" & (hidden of li) & linefeed
    end repeat
    return output
end tell
APPLESCRIPT
); then
    if [[ -z "$items" ]]; then
        log_pass "Login Items count" "0"
    else
        count=$(echo "$items" | grep -c '|' || echo 0)
        log_info "Login Items count" "$count"
        note "  Items (name | path | hidden):"
        echo "$items" | sed 's/^/    /'
    fi
else
    log_warn "Login Items" "could not query System Events (TCC may be denying Automation)"
fi

# ----------------------------------------------------------------------------
section "2. USER LAUNCHAGENTS  (~/Library/LaunchAgents)"
# ----------------------------------------------------------------------------
agents_dir="$HOME/Library/LaunchAgents"
if [[ -d "$agents_dir" ]]; then
    count=$(find "$agents_dir" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
    log_info "User LaunchAgents count" "$count"
    if [[ "$count" -gt 0 ]]; then
        note "  Plists (label · RunAtLoad · KeepAlive · path):"
        for p in "$agents_dir"/*.plist; do
            [[ -f "$p" ]] || continue
            # Try PlistBuddy first; fall back to plutil; fall back to filename
            label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p" 2>/dev/null) || label=""
            [[ -z "$label" ]] && { label=$(plutil -extract Label raw -o - "$p" 2>/dev/null) || label=""; }
            [[ -z "$label" ]] && label="$(basename "$p" .plist) (label unread)"
            run_at_load=$(plutil -extract RunAtLoad raw -o - "$p" 2>/dev/null) || run_at_load=""
            [[ -z "$run_at_load" ]] && run_at_load="no"
            keep_alive=$(plutil -extract KeepAlive raw -o - "$p" 2>/dev/null) || keep_alive=""
            [[ -z "$keep_alive" ]] && keep_alive="no"
            prog=$(plutil -extract ProgramArguments.0 raw -o - "$p" 2>/dev/null) || prog=""
            if [[ -z "$prog" ]]; then
                prog=$(plutil -extract Program raw -o - "$p" 2>/dev/null) || prog=""
            fi
            [[ -z "$prog" ]] && prog="(no Program/ProgramArguments)"
            printf "    %-45s · RunAtLoad=%s · KeepAlive=%s\n      %s\n" "$label" "$run_at_load" "$keep_alive" "$prog"
        done
    fi
else
    log_info "User LaunchAgents directory" "absent"
fi

# ----------------------------------------------------------------------------
section "3. SYSTEM LAUNCHAGENTS  (/Library/LaunchAgents)"
# ----------------------------------------------------------------------------
sys_agents_dir="/Library/LaunchAgents"
if [[ -d "$sys_agents_dir" ]]; then
    count=$(find "$sys_agents_dir" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
    log_info "System LaunchAgents count" "$count"
    if [[ "$count" -gt 0 ]]; then
        note "  Plists (label · vendor-pattern hint):"
        for p in "$sys_agents_dir"/*.plist; do
            [[ -f "$p" ]] || continue
            label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p" 2>/dev/null) || label=""
            [[ -z "$label" ]] && { label=$(plutil -extract Label raw -o - "$p" 2>/dev/null) || label=""; }
            [[ -z "$label" ]] && label="$(basename "$p" .plist) (label unread)"
            hint=""
            case "$label" in
                com.adobe.*)        hint="Adobe (Creative Cloud helpers)" ;;
                com.docker.*)       hint="Docker Desktop" ;;
                com.microsoft.*)    hint="Microsoft (Office / Edge / Teams)" ;;
                com.google.*)       hint="Google (Chrome / Drive)" ;;
                com.dropbox.*)      hint="Dropbox" ;;
                com.cisco.*)        hint="Cisco (AnyConnect / WebEx)" ;;
                com.paragon-*)      hint="Paragon (NTFS / ExtFS)" ;;
                org.openvpn.*)      hint="OpenVPN / Tunnelblick" ;;
                com.tailscale.*)    hint="Tailscale" ;;
                io.nextdns.*)       hint="NextDNS" ;;
                ch.protonvpn.*)     hint="Proton VPN" ;;
            esac
            printf "    %-50s%s\n" "$label" "${hint:+— $hint}"
        done
    fi
fi

# ----------------------------------------------------------------------------
section "4. SYSTEM LAUNCHDAEMONS  (/Library/LaunchDaemons)"
# ----------------------------------------------------------------------------
daemons_dir="/Library/LaunchDaemons"
if [[ -d "$daemons_dir" ]]; then
    count=$(find "$daemons_dir" -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
    log_info "System LaunchDaemons count" "$count"
    if [[ "$count" -gt 0 ]]; then
        note "  Plists (label):"
        for p in "$daemons_dir"/*.plist; do
            [[ -f "$p" ]] || continue
            label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$p" 2>/dev/null) || label=""
            [[ -z "$label" ]] && { label=$(plutil -extract Label raw -o - "$p" 2>/dev/null) || label=""; }
            [[ -z "$label" ]] && label="$(basename "$p" .plist) (label unread)"
            printf "    %s\n" "$label"
        done
    fi
fi

# ----------------------------------------------------------------------------
section "5. PRIVILEGED HELPER TOOLS"
# ----------------------------------------------------------------------------
helpers_dir="/Library/PrivilegedHelperTools"
if [[ -d "$helpers_dir" ]]; then
    count=$(find "$helpers_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 5 ]]; then
        log_warn "Privileged helper tools" "$count — may include orphans from uninstalled apps"
    else
        log_info "Privileged helper tools" "$count"
    fi
    if [[ "$count" -gt 0 ]]; then
        note "  Helpers:"
        find "$helpers_dir" -maxdepth 1 -type f 2>/dev/null | sed 's/^/    /'
    fi
fi

# ----------------------------------------------------------------------------
section "6. LEGACY LoginHook (rarely used these days)"
# ----------------------------------------------------------------------------
if hook=$(sudo -n defaults read com.apple.loginwindow LoginHook 2>/dev/null); then
    log_warn "LoginHook present" "$hook"
else
    log_pass "LoginHook" "none (or sudo declined)"
fi

# ----------------------------------------------------------------------------
section "7. CONFIGURATION PROFILES (may add login items / restrictions)"
# ----------------------------------------------------------------------------
if profile_count=$(profiles list -type configuration 2>/dev/null | grep -c "attribute:"); then
    profile_count="${profile_count:-0}"
    if [[ "$profile_count" -gt 0 ]]; then
        log_info "Configuration profiles (user)" "$profile_count"
        note "  Run 'sudo profiles list -type configuration' for system-wide profile list."
    else
        log_pass "Configuration profiles (user)" "0"
    fi
fi

# ----------------------------------------------------------------------------
section "8. /System/Library/LaunchAgents  (Apple's own — usually noise)"
# ----------------------------------------------------------------------------
if [[ "$VERBOSE" -eq 1 ]]; then
    apple_agents=$(find /System/Library/LaunchAgents -maxdepth 1 -name "*.plist" 2>/dev/null | wc -l | tr -d ' ')
    log_info "Apple-managed LaunchAgents" "$apple_agents (system-protected; informational only)"
else
    note "  (skipped — pass --verbose to include Apple-managed agents)"
fi

# ----------------------------------------------------------------------------
emit_summary

if [[ "$JSON_MODE" -eq 0 ]]; then
    echo
    note "  To DISABLE an entry: scripts/safe-disable-startup.sh -n <pattern>"
    note "  To RE-ENABLE:        scripts/safe-disable-startup.sh -n <pattern> --enable"
fi
