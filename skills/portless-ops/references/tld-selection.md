# TLD Selection for portless

The TLD is a per-proxy setting — every alias resolves as `<name>.<tld>`. Choose with care: changing the TLD later means re-registering every alias.

## Quick Reference

| TLD | Resolution | OAuth-safe | Best for |
|---|---|---|---|
| `.localhost` (default) | Native in Chrome/Firefox/Edge; needs `/etc/hosts` on Safari | ❌ Rejected by Google/Apple | Solo dev, no OAuth |
| `.test` | IANA-reserved (RFC 6761) | ✅ Yes | Recommended default — safe everywhere |
| `.lab` | Not reserved (no DNS collision in practice) | Provider-dependent | Personal/distinctive naming |
| `.dev` | Google-owned, HSTS-preloaded (forces HTTPS) | ✅ Yes | OAuth-heavy projects |
| `.app` | Google-owned, HSTS-preloaded | ✅ Yes | Similar to `.dev` |
| `.local` | mDNS — **conflicts with Bonjour/Avahi** | Provider-dependent | LAN mode only (`--lan`) |
| Anything you own (e.g. `.local.mycorp.dev`) | Whatever you configure | ✅ Yes | Teams, enterprise |

## Decision Flow

```
Do you need OAuth (Google/Apple/Facebook)?
├── Yes
│   ├── Do you control a real domain? → use a subdomain of it (best)
│   └── No                            → use .dev or .test (good)
└── No
    ├── Solo dev, no special needs   → .test (recommended) or .localhost
    └── Personal preference           → .lab or any short distinctive TLD
```

## Detailed Notes

### `.localhost` (default)

- Auto-resolves to `127.0.0.1` in all modern browsers (RFC 6761)
- **Safari** needs `/etc/hosts` entries — run `portless hosts sync`
- Rejected by **Google OAuth** (not in their bundled Public Suffix List)
- Rejected by **Apple** (no localhost or IP addresses at all)
- Accepted by **Microsoft / GitHub** with caveats

### `.test` (recommended for general use)

- IANA-reserved for testing per RFC 6761
- No real DNS will ever resolve `.test`, so no collision risk
- Accepted by every OAuth provider that respects the Public Suffix List
- Requires `/etc/hosts` entries (portless auto-syncs)

### `.dev` / `.app` (Google-owned)

- Public Suffix List entries — provider-accepted
- **HSTS-preloaded by Google** — browsers force HTTPS, so plain HTTP doesn't work
- Portless defaults to HTTPS so this is fine
- Slight cost: every browser hit issues an HSTS check (negligible in dev)

### `.local` (avoid for non-LAN use)

- mDNS uses `.local` for Bonjour / Avahi auto-discovery
- Using `--tld local` without `--lan` mode confuses macOS in particular
- **Only use** when you intend LAN sharing — portless's `--lan` mode actually advertises `<name>.local` over mDNS

### Custom owned domain

The most defensible option for OAuth and team setups:

```bash
# You own example.com. Set up DNS:
*.local.example.com   A   127.0.0.1

# Then portless:
portless proxy start --tld local.example.com
portless myapp next dev
# → https://myapp.local.example.com
```

- OAuth providers see a real, resolvable domain
- Other devs on your team can resolve too (real DNS, no /etc/hosts edits)
- Apple's strict server-side resolution check passes
- Zero risk of accidentally hitting a real domain you don't own

### `.lab` (or any short distinctive TLD)

- Not in the IANA root zone, not reserved
- Won't ever resolve publicly, so no collision risk in practice
- Short and memorable for personal use
- **Won't work for OAuth** — Google/Apple require Public Suffix List domains
- Good for personal dev when you don't need OAuth or external services

## Change Procedure

If you need to change TLD (e.g. you started on `.localhost`, now need OAuth):

```bash
# Stop proxy
portless proxy stop

# Wipe routes (because `portless alias --remove` appends the active TLD,
# making it impossible to remove old-TLD aliases cleanly)
rm ~/.portless/routes.json

# Restart with new TLD
portless proxy start --tld test --port 443

# Re-register aliases against new TLD
portless alias myapp 8000 --force
portless alias api    8001 --force
```

Update any bookmarks, OAuth provider configs, and `NEXTAUTH_URL` / `AUTH_URL` / `BASE_URL` environment variables.

## See Also

- `references/upstream-oauth.md` — per-provider OAuth setup
- `references/upstream-portless.md` — full CLI reference (search "tld" or "--tld")
- `references/integration-patterns.md` — combining portless with process supervisors
