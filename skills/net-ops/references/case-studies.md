# Case Studies

Worked examples of network diagnostics that motivated this skill. Each case includes the initial symptoms, the diagnostic path, the dead ends, and the final cause. Identifying details are scrubbed; technical details that reproduce the diagnostic value are preserved.

## Case 1: The Proton VPN Ghost (Windows)

### Initial Report

> "Internet not working on my Windows desktop. It wasn't working on wifi earlier today so I switched to ethernet — but problems persisted."

That last sentence is a load-bearing clue: switching physical interface didn't help. That rules out the NIC, driver, cable, and wifi association in a single observation. Whatever is broken lives at the OS layer or above.

### Diagnostic Path

**Rung 1 (link):** Ethernet `Up`, valid private IP, valid default gateway. ✓

**Rung 2 (ICMP):** Ping `1.1.1.1`, `8.8.8.8`, gateway — all <5ms. ✓

**Rung 3 (sockets):** First test misread — `Resolve-DnsName -Server 1.1.1.1` timed out, which felt like UDP/53 was blocked. **Mistake.** Should have gone straight to raw UDP to disambiguate. When raw UDP/53 was eventually tested, it returned a 124-byte DNS response in milliseconds. Lesson: `Resolve-DnsName` uses the Windows DNS Client API even when `-Server` is specified — it's not a clean probe of the network.

**Rung 3 (sockets, second pass):**
- TCP/53 to 1.1.1.1 → works
- Raw UDP/53 to 1.1.1.1 → works (124-byte reply)
- TCP/443 to 1.1.1.1 → **fails**
- TCP/443 to 8.8.8.8 → **fails**
- TCP/443 to 140.82.114.4 (github.com) → works
- TCP/443 to 13.107.42.14 (microsoft.com) → works

**Discriminator:** Destination-specific HTTPS block. Known public DoH resolver IPs are firewalled on 443; everything else works. **Smell of AV "Encrypted DNS Detection."** Confirmed by `Get-CimInstance -Namespace root/SecurityCenter2`: ESET Security + ESET Firewall both active, and `epfwwfp` WFP callout driver loaded.

This was filed as a **secondary concern** — not the cause of the main symptom (general DNS failure for browsers). Important not to chase the first interesting finding when it doesn't match the headline symptom.

**Rung 4 (nslookup):** `nslookup google.com` against router, 1.1.1.1, and 8.8.8.8 — all returned addresses immediately. ✓

**Rung 5 (DNS Client API):** `Resolve-DnsName google.com -Type A` → timeout. `Invoke-WebRequest https://www.google.com` → "The remote name could not be resolved."

**The smoking gun.** Rung 4 passed perfectly; rung 5 failed identically across all targets. Everything app-level fails because every app uses the DNS Client API. nslookup works because it has its own resolver.

### The False Lead

First suspicion: ICS. Port 53 was held by `svchost` PID `3928`, which turned out to be the `SharedAccess` service. Stopped it; the service bounced back on a new PID, and DNS resolution did not recover. ICS was a red herring — it was running but its sharing configuration was empty, meaning it wasn't actually doing anything harmful. Lesson: **don't disable a service just because it looks suspicious; verify it's actually causing the symptom first.**

### The Second False Lead

Next suspicion: ESET's WFP driver. The driver was present and active, and the destination-specific HTTPS block looked like classic AV protocol filtering. But: AV protocol filtering normally affects HTTPS, not DNS Client API calls. Before pausing ESET, ran `Get-DnsClientNrptRule`.

### The Answer

```
Namespace                         NameServers
---------                         -----------
.                                 10.2.0.1
```

A catch-all NRPT rule routing every DNS query to `10.2.0.1`. The rule's `Comment` field: **"Force all DNS requests via Proton VPN"** — verbatim from Proton's source code. The IP `10.2.0.1` is Proton's in-tunnel DNS gateway, only reachable while connected to their VPN.

Removed the single rule. Flushed DNS cache. Re-tested:
- `Resolve-DnsName google.com` → instant success, returned A records
- `Invoke-WebRequest https://www.google.com` → HTTP 200, full page body

### Forensics

Checked `C:\Program Files\Proton\VPN\Install.log.txt`: Proton VPN installation confirmed (current Inno Setup log entry showed the latest installed version). Service binaries present (`ProtonVPNService.exe`, `ProtonVPN.WireGuardService.exe`), all in `Stopped` state at time of diagnosis. The last active VPN session timestamp (per `ServiceData\WireGuard\log.bin`) predated the issue report by several days — DNS had been silently broken since the last disconnect, masked by occasional cache hits and apps that handle DNS failure gracefully.

**Likely trigger:** Sleep or hibernate during an active Proton WireGuard session. Proton's disconnect cleanup hook didn't fire, and the NRPT rule outlived the tunnel.

### Lessons

1. **Always run `Get-DnsClientNrptRule` before suspecting WFP/AV.** It's a one-line check that resolves 90% of "DNS infrastructure works but apps fail" cases.
2. **Don't conflate `Resolve-DnsName` with a network probe.** It uses the system DNS Client API and inherits every hook in the path. Use raw UDP for actual network-layer DNS testing.
3. **Multiple anomalies don't mean multiple bugs.** ESET's DoH IP block was a real and separate finding, but it wasn't the cause of the headline symptom. Stay focused on what matches the user's actual complaint.
4. **The `Comment` field on NRPT rules is gold.** VPN clients tend to write self-identifying strings. Read them before assuming malice.
5. **Interface-switch ineffective = OS-layer cause.** When wifi → ethernet doesn't fix it, the diagnostic search space contracts dramatically.

## Case 2: Template for Future Entries

When you diagnose a new case worth remembering, add a section here with:
- Initial report (verbatim if possible)
- Diagnostic path (rung-by-rung)
- False leads (the ones you chased before finding the real cause — these are the educational part)
- The actual cause
- Forensics (how/when/why it got into that state)
- Lessons (1-3 reusable observations)

Cases worth adding:
- A Mullvad-residue case (different IP, otherwise structurally identical to Proton)
- A corporate AnyConnect leak case
- A genuine ESET "Encrypted DNS Detection" case where pausing AV was the fix
- An IPv6-preference-with-broken-v6 slowness case
- A Winsock LSP corruption case
