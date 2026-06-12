# Failure Triage

The arms-race reality: platforms change player code and access rules continuously;
yt-dlp ships countermeasures near-monthly. **Most failures are version failures.**
Triage in this order — each step is cheaper than the one below it.

## Step 0 — version check (always first)

```bash
bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --live
```

Exit `10` → update (`uv tool upgrade yt-dlp`, or `yt-dlp -U` for the standalone
binary) and **re-run the original command before any further debugging**. Errors
in the "outdated" class below are *expected* on a stale build; debugging them is
wasted time.

## Step 1 — reproduce verbosely

```bash
yt-dlp -v URL 2>&1 | tail -40
```

Read the actual extractor error, not the summary line. `-v` also prints the
version, install type (pip/binary), and whether ffmpeg was found — three triage
answers for free.

## Error → cause map

### The "outdated yt-dlp" class (update fixes it)

| Symptom | What's happening |
|---|---|
| `nsig extraction failed: Some formats may be missing` | YouTube changed its player JS; the throttling-token solver broke. Formats vanish AND remaining ones may crawl at ~50-100 KB/s |
| `Signature extraction failed` | Same family, older mechanism |
| `ERROR: Unable to extract <anything>` on a major site | Extractor broke against a site change |
| Downloads suddenly throttled to dial-up speeds | Broken nsig solve — the platform serves, but slowly |
| Formats that existed last week are gone | Player-client behaviour changed; newer yt-dlp rotates clients |

These are **not** network problems, **not** your command, **not** rate limits.
Update first.

### Missing formats / "No supported JavaScript runtime could be found"

The 2026 evolution of the nsig arms race: yt-dlp now solves YouTube's player
JS through an **external JS runtime** (the EJS system); runtime-less extraction
is deprecated and silently degrades the format list — often to a single low-res
premuxed file. Only **deno** is auto-enabled; node and bun need opt-in:

```bash
yt-dlp --js-runtimes node URL      # use an installed node (verify: -v shows "JS runtimes: node-…")
# or install deno (auto-detected, zero config): https://deno.com
```

Measured effect on the same video: no runtime → premuxed format 18 (360p);
with a runtime → the full 395+251 (AV1+Opus) ladder. If formats look thin on a
fresh machine, this — not the extractor — is usually why.

#### Choosing a runtime (a security decision, not a convenience one)

Whatever runtime you pick will execute obfuscated JavaScript fetched from the
network on every invocation. Two risks trade off: *install risk* (a new binary
on the machine) vs *execution risk* (what privileges that code runs with).

| | deno | node opt-in |
|---|---|---|
| New dependency | yes — one static signed binary, no install scripts, no dep tree | no (if already installed) |
| Sandbox | default-deny: no fs/net/env unless granted — why yt-dlp trusts it by default | **none** — full user privileges |
| Exposure shape | one-time, auditable at install | standing, re-occurs every invocation, compounds with automation |

**Decision rule:** anything unattended (the `--break-on-existing` channel-sync
cron, scheduled STT pipelines) → **deno**, no exceptions — recurring unattended
execution of network-fetched code must be sandboxed. Occasional interactive
use → a *per-invocation* `--js-runtimes node` grant is defensible; do NOT
persist it in a config file, because persisted defaults silently become the
unattended path when automation arrives later.

Install deno with supply-chain discipline — cooldown-checked and version-pinned:

```bash
# 1. pick the newest release >=7 days old (skip day-zero releases):
curl -fsSL "https://api.github.com/repos/denoland/deno/releases?per_page=5" \
  | jq -r '.[] | select(.prerelease|not) | "\(.tag_name) \(.published_at)"'
# 2. install that exact version and pin it (Windows; see deno.com for others):
winget install --id DenoLand.Deno --version <X.Y.Z> --exact
winget pin add --id DenoLand.Deno --version <X.Y.Z>
# 3. verify yt-dlp picked it up:
bash skills/ytdlp-ops/scripts/check-ytdlp-version.sh --live --json | jq -r '.data.js_runtime'
```

### HTTP 403 Forbidden

1. Stale build (above) — update first.
2. **Non-YouTube site that plays fine in a browser** — TLS-fingerprint blocking
   (Cloudflare and friends sniff the client hello). Fix:

   ```bash
   yt-dlp --impersonate chrome URL
   yt-dlp --list-impersonate-targets        # what this install can mimic
   ```

   Needs the curl_cffi extra — standalone binaries include it; pip/uv installs
   need `uv tool install "yt-dlp[default,curl-cffi]"`. An empty target list
   means the extra is missing.
3. IP reputation — datacenter/VPS IPs are heavily challenged. Try a residential
   IP or `--proxy socks5://...`.
4. Stale cookies — re-export / re-extract (`--cookies-from-browser firefox`).
5. Mid-download 403 on fragments — URLs expired (very slow download or paused
   run); just re-run, `.part` files resume.

### "Sign in to confirm you're not a bot"

IP-reputation challenge. In order: logged-in cookies
(`--cookies-from-browser firefox`), residential IP/proxy, update (client
impersonation fixes ship regularly). See
[auth-cookies.md](auth-cookies.md).

### HTTP 429 / rate limited

You're sending too much, too fast, from one address:

```bash
--sleep-requests 1 --sleep-interval 5 --max-sleep-interval 15 --limit-rate 4M
```

Reduce `--concurrent-fragments` to 1, stop parallel processes against the same
host, and back off for hours, not seconds. Archives make resumption free.

### Geo blocks ("not available in your country")

`--proxy URL` through an allowed region is the real fix. The legacy
`--geo-bypass`/`--xff` header spoofing rarely works on major platforms anymore —
don't burn time on it.

### Private / deleted / members-only

`Private video`, `Video unavailable`, `Join this channel` — access problems, not
bugs. Cookies from an account *with that access* (member, accepted viewer) or
nothing. In batch runs, `--ignore-errors` keeps one dead video from killing the
job.

### "Requested format is not available"

Your `-f` hard filter matched nothing (catalog changed, or per-client format
availability shifted). `yt-dlp -F URL` to see today's offerings; switch to `-S`
sorting which cannot fail this way
([format-selection.md](format-selection.md)).

### ffmpeg-related: `merging of multiple formats` / `ffmpeg not found`

yt-dlp needs ffmpeg on PATH for merge/remux/extract-audio. Point at a specific
build with `--ffmpeg-location PATH`. Verify what the build can do with
ffmpeg-ops `capability-scan.sh`.

## Escape hatch: `--extractor-args`

Per-extractor overrides, e.g. forcing alternative player clients:

```bash
yt-dlp --extractor-args "youtube:player_client=default,web_safari" URL
```

**Staleness warning:** valid client names and their behaviour churn faster than
any doc — treat specific values found in forum posts (including this file's
example) as expired until verified against the current
[yt-dlp wiki/extractor docs](https://github.com/yt-dlp/yt-dlp/wiki). Reach for
this only after an update didn't fix it.

## When it's genuinely upstream

Current version + verbose log showing an extractor exception + reproducible on a
clean network → check the [issue tracker](https://github.com/yt-dlp/yt-dlp/issues)
(it's almost certainly already filed; platform-wide breakages get hundreds of
duplicates within hours). Pin your pipeline to "wait for the next release", not
to workarounds scraped from the thread.
