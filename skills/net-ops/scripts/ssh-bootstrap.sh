#!/usr/bin/env bash
# net-ops :: ssh-bootstrap.sh
# Establish an SSH session to any target (Windows / macOS / Linux) using
# password auth via sshpass. Reads password from stdin so it never appears
# in argv / shell history. Auto-detects target OS and emits the right
# invocation pattern for follow-up commands.
#
# Usage:
#   echo 'password' | scripts/ssh-bootstrap.sh user@host
#   scripts/ssh-bootstrap.sh user@host    # interactive prompt

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 user@host" >&2
    exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not found. Install:" >&2
    echo "  macOS:   brew install hudochenkov/sshpass/sshpass" >&2
    echo "  Linux:   apt install sshpass / dnf install sshpass" >&2
    exit 1
fi

# Read password — from stdin if piped, else prompt
if [[ -t 0 ]]; then
    read -rsp "Password for $TARGET: " PASSWORD
    echo
else
    read -r PASSWORD
fi
export SSHPASS="$PASSWORD"

# Quick connectivity check (also accepts host key on first contact).
# Use a probe that works on all three: `uname -s` on Unix, fails on cmd.exe
# but succeeds on Windows OpenSSH default shell when it's pwsh/powershell.
echo "Probing $TARGET ..."
PROBE=$(sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$TARGET" \
    'uname -s 2>/dev/null || cmd /c ver 2>nul || ver' 2>&1 | tr -d '\r')

echo "  Response: $(echo "$PROBE" | head -3 | tr '\n' ' | ')"

# Detect OS family from probe output
OS=""
case "$PROBE" in
    *Darwin*)         OS="macos" ;;
    *Linux*)          OS="linux" ;;
    *Microsoft*|*Windows*) OS="windows" ;;
esac

if [[ -z "$OS" ]]; then
    echo
    echo "Could not auto-detect OS. Treating as unknown — defaulting to bash transport."
    OS="unknown"
fi

echo "Detected OS family: $OS"

# Per-OS smoke test
case "$OS" in
    windows)
        echo
        echo "Testing PowerShell -EncodedCommand transport ..."
        TEST_PS='Write-Output ("PS ready :: " + $PSVersionTable.PSVersion.ToString())'
        B64=$(printf '%s' "$TEST_PS" | iconv -t UTF-16LE | base64)
        sshpass -e ssh "$TARGET" "powershell -NoProfile -EncodedCommand $B64" 2>&1 | tail -3
        ;;
    macos|linux|unknown)
        echo
        echo "Testing bash transport ..."
        sshpass -e ssh "$TARGET" 'bash -c "echo BASH_OK :: \$(bash --version | head -1)"' 2>&1 | tail -2
        ;;
esac

# Per-OS invocation hints
echo
echo "---"
case "$OS" in
    windows)
        cat <<EOF
Ready (Windows target). Run a PowerShell script via:

  PS_SCRIPT=\$(cat skills/net-ops/scripts/windows/probe.ps1)
  B64=\$(printf '%s' "\$PS_SCRIPT" | iconv -t UTF-16LE | base64)
  SSHPASS='<password>' sshpass -e ssh $TARGET "powershell -NoProfile -EncodedCommand \$B64"

Drilldown scripts: nrpt-audit.ps1, nrpt-clean.ps1

For zero-friction follow-up, install your pubkey on the target:
  Windows admin path: %ProgramData%\\ssh\\administrators_authorized_keys
  Windows user path:  %USERPROFILE%\\.ssh\\authorized_keys
EOF
        ;;
    macos)
        cat <<EOF
Ready (macOS target). Run a bash script via:

  SSHPASS='<password>' sshpass -e ssh $TARGET 'bash -s' < skills/net-ops/scripts/macos/probe.sh

Drilldown scripts: macos/dns-audit.sh, macos/resolver-clean.sh

Persistent access: ssh-copy-id $TARGET
EOF
        ;;
    linux)
        cat <<EOF
Ready (Linux target). Run a bash script via:

  SSHPASS='<password>' sshpass -e ssh $TARGET 'bash -s' < skills/net-ops/scripts/linux/probe.sh

Drilldown scripts: linux/dns-audit.sh, linux/resolved-reset.sh

Persistent access: ssh-copy-id $TARGET
EOF
        ;;
    *)
        echo "Generic SSH ready. Run commands directly."
        ;;
esac
