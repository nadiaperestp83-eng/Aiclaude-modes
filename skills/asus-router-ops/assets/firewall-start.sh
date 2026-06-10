#!/bin/sh
# Asuswrt-Merlin custom firewall rules — copy to /jffs/scripts/firewall-start
#
# This is an ASSET TEMPLATE for a router, not an agent-run script. It runs on the
# router every time Merlin (re)builds the firewall, so rules added here survive
# firewall restarts. Adapt the ADAPT: lines, then on the router:
#   chmod +x /jffs/scripts/firewall-start
# (Requires JFFS custom scripts enabled: Administration > System.)
#
# RULES MUST BE IDEMPOTENT: delete-then-insert so re-runs don't stack duplicates.
# Test with the router console open — a bad rule can drop your management session.

LOG_PREFIX="custom-fw"

# Helper: insert a rule only after removing any existing identical one.
# Usage: reinsert <table?> <chain> <rule...>
reinsert_filter() {
  chain="$1"; shift
  iptables -D "$chain" "$@" 2>/dev/null
  iptables -I "$chain" "$@"
}

# --- Example 1: drop + log inbound from a known-bad subnet (ADAPT or remove) ---
# reinsert_filter INPUT -s 203.0.113.0/24 -j DROP

# --- Example 2: isolate an IoT subnet from the main LAN (ADAPT subnets) ---
# Assumes IoT on 192.168.50.0/24, main LAN on 192.168.1.0/24.
# Block IoT -> LAN, but allow established replies LAN -> IoT.
# reinsert_filter FORWARD -i br0 -s 192.168.50.0/24 -d 192.168.1.0/24 \
#   -m state --state NEW -j DROP

# --- Example 3: allow a specific LAN host to reach an IoT device (exception) ---
# reinsert_filter FORWARD -s 192.168.1.10 -d 192.168.50.20 -j ACCEPT

# --- Example 4: rate-limit + log SSH brute force on the LAN admin port (ADAPT) ---
# reinsert_filter INPUT -p tcp --dport 22 -m state --state NEW \
#   -m recent --set --name SSHPROBE
# reinsert_filter INPUT -p tcp --dport 22 -m state --state NEW \
#   -m recent --update --seconds 60 --hitcount 5 --name SSHPROBE \
#   -j LOG --log-prefix "${LOG_PREFIX}-ssh-bruteforce: "
# reinsert_filter INPUT -p tcp --dport 22 -m state --state NEW \
#   -m recent --update --seconds 60 --hitcount 5 --name SSHPROBE -j DROP

# All examples are commented out by default — uncomment and ADAPT the ones you need.
exit 0
