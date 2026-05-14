# The Diagnostic Ladder

A layered methodology for isolating network faults from the wire up, applicable to Windows, macOS, and Linux. Each rung has a binary outcome that eliminates everything above it — walk in order, do not skip.

## Why Layered Probing Beats Pattern Matching

When a user says "internet is broken," there are roughly 30 plausible causes spanning seven OSI-ish layers. Guessing wastes time. The ladder is a binary-search through the stack: each test eliminates roughly half the remaining suspects.

The most common mistake is jumping straight to layer 6 ("HTTPS doesn't work, must be a cert / proxy / SNI thing") when the real issue is layer 5 (the OS resolver is being hijacked by an orphaned VPN config from a tunnel that hasn't been connected in four days). Discipline prevents this.

## Per-OS Tool Reference

| Rung | Windows | macOS | Linux |
|---|---|---|---|
| 1. Link | `Get-NetAdapter` / `Get-NetIPConfiguration` | `ifconfig` / `networksetup -listallhardwareports` | `ip -br link` / `ip -br addr` |
| 2. ICMP | `Test-Connection 1.1.1.1` | `ping -c 2 1.1.1.1` | `ping -c 2 1.1.1.1` |
| 3. TCP/UDP | `Test-NetConnection -Port 443` + raw UDP via .NET | `nc -zv` + `dig @<ip>` | `bash </dev/tcp/<ip>/443` + `dig @<ip>` |
| 4. DNS infra | `nslookup google.com 1.1.1.1` | `dig @1.1.1.1 google.com` | `dig @1.1.1.1 google.com` |
| 5. OS resolver | `Resolve-DnsName` | `dscacheutil -q host -a name google.com` | `getent hosts google.com` / `resolvectl query` |
| 6. App layer | `Invoke-WebRequest` | `curl -v` | `curl -v` |

## Rung 1 — Link Layer

**Question:** Is there a physical / wireless connection with a valid IP and gateway?

**Pass criteria:** At least one adapter `Up` / `active` / `UP`, has an IPv4 address, has a default gateway.

**Fail → check:** Driver state, cable, wifi association, DHCP lease, static config typo.

**Common gotchas across all OSes:**
- A `169.254.x.x` address (Windows/Linux) or `self-assigned` (macOS) means DHCP failed silently
- Multiple `Up` adapters can have competing default routes; check route metric / priority

## Rung 2 — IP / ICMP Reachability

**Question:** Can packets leave the box and reach the public internet?

**Pass criteria:** Replies in single-digit to low-double-digit milliseconds for at least one public anycast IP.

**Fail → check:** Routing table, firewall rules blocking ICMP outbound, ISP outage, captive portal.

**Watch for:** Some ISPs and corporate firewalls block ICMP entirely while allowing TCP/UDP. If ICMP fails but TCP socket tests pass on rung 3, ICMP is the *only* thing blocked — rare but real, especially on enterprise networks.

## Rung 3 — TCP/UDP Socket Reachability

**Question:** Can specific transport-layer connections complete?

**Critical discriminator:** Test multiple destinations on the same port. If `1.1.1.1:443` fails but `140.82.114.4:443` (github.com) succeeds, the block is **destination-specific**, not a general firewall. Strongly suggests AV with "Encrypted DNS Detection" or per-IP blocklist.

**Raw UDP/53 test is essential.** Most OS-level DNS probes (`Resolve-DnsName`, `dscacheutil`, `getent`) go through the system resolver and inherit every hook in the path. To test UDP/53 itself, use:
- Windows: `dig` (if installed) or a custom `UdpClient` (see `probe.ps1`)
- macOS / Linux: `dig +tries=1 @<server> <host>`

`dig` explicitly bypasses the OS resolver chain. This is what makes it the killer discriminator on Unix systems — same role as `nslookup` on Windows.

## Rung 4 — DNS Infrastructure

**Question:** Does a DNS server actually answer queries?

**Pass criteria:** All three resolvers (default + two public) return a name and address. The IPs may differ (different anycast points) — that's fine.

**Fail → check:** UDP/53 outbound blocked (back to rung 3 raw test), router's DNS forwarder broken, ISP DNS hijack misconfigured.

**Subtle bugs:**
- If the resolver returns only IPv6 (AAAA) records for a site that should have IPv4, the resolver may be misconfigured for record-type ordering — apps preferring A records will hang
- If different resolvers return wildly different IPs (different from anycast variation), you may be facing DNS poisoning or split-horizon weirdness

## Rung 5 — OS Resolver Path (THE INTERESTING LAYER)

**Question:** Does the operating system's name-resolution chain actually return correct addresses?

**THE SMOKING GUN:** Rung 4 passes (bypass tool works) but rung 5 fails (OS resolver times out). The DNS infrastructure is healthy but **something is hooking the system resolver path.**

### Windows suspects

| Hook | Detection |
|---|---|
| **NRPT (Name Resolution Policy Table)** | `Get-DnsClientNrptRule \| Where Namespace -eq '.'` |
| **HOSTS file** | `Get-Content $env:windir\System32\drivers\etc\hosts` |
| **WFP callout driver** | `Get-CimInstance Win32_SystemDriver \| Where Name -match 'wfp\|epfw'` |
| **DNS Client service hooked** | Third-party LSP catalog entries, dependent services |
| **Local 127.0.0.1:53 proxy** | `Get-NetUDPEndpoint -LocalPort 53` |

### macOS suspects

| Hook | Detection |
|---|---|
| **`/etc/resolver/<domain>` files** | `ls /etc/resolver/` — per-domain overrides, classic VPN residue |
| **scutil DNS state** | `scutil --dns` — shows "resolver #N" entries; extras = potential hook |
| **Configuration profiles (MDM)** | `profiles list -type configuration` — can install DNS overrides |
| **mDNSResponder state** | `pgrep -x mDNSResponder` — if dead, all DNS dies |
| **Third-party kext** | `kextstat \| grep -iE 'cisco\|anyconnect\|proton\|mullvad'` |
| **PAC file / proxy** | `scutil --proxy` |

### Linux suspects

| Hook | Detection |
|---|---|
| **`/etc/nsswitch.conf` hosts line** | NSS order excludes `resolve` or `dns` → bypass entirely |
| **systemd-resolved state** | `resolvectl status` — per-link DNS / search domains |
| **`/etc/resolv.conf` symlink** | `readlink /etc/resolv.conf` — should point at the stub on systemd systems |
| **NetworkManager DNS mode** | `/etc/NetworkManager/NetworkManager.conf` `[main] dns=` |
| **dnsmasq instance** | `pgrep -x dnsmasq` + `/etc/dnsmasq.d/` |
| **Local 127.x:53 listener** | `ss -tulnp \| grep :53` |

## Rung 6 — Application Layer

**Question:** Can a real application make a real HTTP request to a real hostname?

**Fail BUT rung 5 passed → check:**

| OS | Most common causes |
|---|---|
| Windows | WinHTTP proxy (`netsh winhttp show proxy`), cert store, TLS, IPv6 preference, app-specific config |
| macOS | System proxy (`scutil --proxy`), keychain cert issues, IPv6 preference, app-specific config |
| Linux | `http_proxy` / `https_proxy` env vars, CA bundle path, IPv6 preference, app-specific config |

## Discriminator Cheat Sheet

| Symptoms | Diagnosis |
|---|---|
| Rung 1 fails | Hardware / driver / wifi association |
| Rungs 1 pass, 2 fails | Routing or ISP |
| Rungs 1-2 pass, 3 fails for all dests | Outbound firewall blocking the port |
| Rungs 1-2 pass, 3 fails for specific dests | Destination-specific filter (AV "Encrypted DNS Detection") |
| Rungs 1-3 pass, 4 fails | DNS server / forwarder broken upstream |
| Rungs 1-4 pass, 5 fails | **OS resolver hook — go to per-OS dns-audit script** |
| Rungs 1-5 pass, 6 fails | Proxy, cert store, TLS, IPv6 preference, app-specific |

## When the Ladder Doesn't Help

Some failures are stateful or intermittent and won't show on a single probe pass:

- **Time-based:** DNS works for 30s then breaks. Loop the probe; watch for transition timestamps.
- **Per-network:** Fails on wifi, works on ethernet. Compare per-interface resolver config on each OS.
- **Per-application:** Browsers fail, system tools work. Look at app-specific resolvers — Chrome / Firefox have their own DoH paths, curl has its own resolver, etc.

For these, augment the ladder with continuous probing and per-interface comparison.
