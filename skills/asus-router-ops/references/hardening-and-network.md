# Hardening, Segmentation, AiMesh & QoS — deep dive

Load for the rationale behind the hardening checklist, network segmentation design, AiMesh
backhaul tuning, dual-WAN, and JFFS script placement gotchas.

## Hardening rationale (why each step)

| Step | Threat it closes |
|------|------------------|
| Change admin + WiFi password | Default-credential takeover (botnets scan for these) |
| Disable WPS | PIN brute force / Pixie Dust |
| Disable UPnP | Malware silently opening inbound ports |
| Explicit port forward, no DMZ | DMZ forwards *all* ports to one host — total exposure |
| No remote WAN admin | Internet-facing admin panel = credential-stuffing target |
| AiProtection two-way IPS | Inbound exploit + outbound C2 / data exfil detection |
| Guest isolation | Stops a compromised visitor device reaching the LAN |
| Firewall logging | Detection + forensics |
| BCP38/84 ingress filtering | Source-address spoofing / reflection-attack participation |

### DNS rebinding protection trade-off

Rebinding protection blocks responses that resolve to private/local IPs — defeating an
attacker who tricks the browser into talking to your LAN. But it also breaks legitimate
local services that resolve to RFC1918 addresses (Plex, Home Assistant, NAS web UIs).
**Whitelist the specific domains** that need to resolve locally rather than turning the
protection off entirely.

## Network segmentation design

| Tier | Placement | Cross-talk |
|------|-----------|------------|
| Main LAN | Trusted devices (laptops, phones) | Full intranet |
| IoT | Cameras, smart plugs, TVs | **No** access to main LAN; internet only |
| Guest | Visitors | No intranet; bandwidth-capped |
| Lab/DMZ-ish | Experimental hosts | Quarantined |

Implementation varies by model — higher-end ASUS routers expose VLAN/multiple isolated
SSIDs; others rely on guest-network isolation. The principle: an IoT device's compromise
must not reach your laptop.

**mDNS/Bonjour caveat:** smart-home discovery (Chromecast, AirPlay, HomeKit) uses mDNS,
which doesn't cross subnets/VLANs by default. If you segment IoT away from clients, you may
need a controlled mDNS reflector/repeater — scope it to the minimum needed, don't blanket-allow.

## AiMesh deployment

| Concern | Guidance |
|---------|----------|
| **Backhaul** | Wired backhaul is best. If wireless, use a dedicated/DFS 5GHz channel, not a congested one |
| **Node placement** | Within solid signal of the parent — too far hurts more than no node |
| **Channel/width** | Avoid congested channels; wider channels = more throughput but more interference |
| **Firmware** | Same family on all nodes (don't mix stock + Merlin) |
| **AiProtection/QoS across mesh** | Settings apply mesh-wide; verify they propagate to nodes |
| **Guest on mesh** | Enable deliberately; "Access Intranet" behavior must be consistent per node |

## QoS & traffic management

| Mode | Use for |
|------|---------|
| **Adaptive QoS** | General prioritization (gaming/streaming/WFH) with app categories |
| **Bandwidth limiter** | Hard per-device caps (guest, kids' devices) |
| **Game acceleration** | Latency-sensitive traffic prioritization |

QoS and AiProtection share the Trend Micro engine on many models — enabling one may affect
throughput on lower-end hardware.

## Dual-WAN

| Mode | Behavior |
|------|----------|
| Failover | Secondary WAN takes over when primary drops |
| Load balance | Distributes sessions across both WANs (ratio configurable) |

Define a failback policy and test by physically unplugging the primary during a low-usage window.

## JFFS script placement gotchas (Merlin)

- Enable **JFFS custom scripts and configs** before scripts will run.
- Scripts live in `/jffs/scripts/` and must be `chmod +x` with a `#!/bin/sh` shebang.
- **`firewall-start`** is the right place for custom iptables rules — it re-runs every time
  the firewall rebuilds (which happens on many config changes), so rules added here survive.
  Adding iptables rules elsewhere risks them being flushed.
- Make rules **idempotent** — check/delete before insert (`iptables -D ... 2>/dev/null;
  iptables -I ...`) so re-runs don't stack duplicates.
- `nvram commit` writes flash — commit only when persistence is needed, not in loops.
- Test rules with the router console open; a bad rule can drop your management session.

## Verification toolkit

| Check | How |
|-------|-----|
| DNS encryption working | DNS leak test site; confirm resolver = your DoT/DoH provider |
| Firewall rule active | `iptables -L -n -v` (Merlin SSH) |
| nvram value | `nvram get <key>` |
| Guest isolation | From guest SSID, attempt to reach a LAN host — should fail |
| Failover | Unplug primary WAN, watch system log for switch |
| VPN tunnel up | Check assigned IP / provider's "are you connected" page |
