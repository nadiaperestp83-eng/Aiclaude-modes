# Cookies and Authentication

For private, members-only, age-gated, or "Sign in to confirm you're not a bot"
content. Authentication is also the highest-risk feature in yt-dlp: it ties bulk
download behaviour to an identifiable account.

## `--cookies-from-browser` (first choice)

```bash
yt-dlp --cookies-from-browser firefox URL
yt-dlp --cookies-from-browser "firefox:profile-name" URL    # specific profile
yt-dlp --cookies-from-browser "brave+gnomekeyring" URL      # explicit keyring (Linux)
```

Reads cookies straight from a browser profile on disk. Full syntax:
`BROWSER[+KEYRING][:PROFILE][::CONTAINER]`. Supported browsers include `firefox`,
`chrome`, `chromium`, `edge`, `brave`, `opera`, `vivaldi`, `safari`, `whale`.

### The browser matrix (what actually works)

| Browser | Status |
|---|---|
| **Firefox** | Most reliable everywhere — plain SQLite cookie store. **Default choice.** |
| Chrome/Edge/Brave on **Windows** | Chrome 127+ **app-bound encryption** ties cookie decryption to the browser binary — extraction usually fails. Don't fight it; use Firefox or `cookies.txt`. |
| Chrome on macOS/Linux | Generally works (keychain/keyring prompt possible); close the browser first — a running Chrome locks the cookie DB |
| Safari | Works on macOS; needs Full Disk Access for the terminal |

## `--cookies cookies.txt` (the fallback that always works)

```bash
yt-dlp --cookies cookies.txt URL
```

A Netscape-format cookie export (browser extensions like "Get cookies.txt
LOCALLY" produce it, or `yt-dlp --cookies-from-browser firefox --cookies out.txt
--skip-download URL` converts browser → file once on a machine where extraction
works, for use on servers).

Treat the file as a **credential**: it grants full account access. Never commit
it; `chmod 600`; rotate by re-exporting. Note YouTube rotates session cookies
aggressively — exported cookie files go stale in days-to-weeks, so headless boxes
need a refresh procedure, not a one-time export.

## Account-ban avoidance (read before any authenticated bulk run)

Authenticated + high-volume + fast is the exact signature platforms ban for. The
account in the cookies is the blast radius.

1. **Use a throwaway account** for anything bulk. Never a personal/work account.
2. **Always pair auth with politeness flags**: `--sleep-requests 1
   --sleep-interval 5 --max-sleep-interval 15 --limit-rate 4M`.
3. **Don't parallelize across the same account/IP** (multiple yt-dlp processes
   sharing cookies multiplies the signature).
4. Prefer unauthenticated access whenever the content allows it — most public
   content needs no cookies at all; only add them when an error demands it.

## Username/password (`-u`/`-p`) — mostly dead

Direct login triggers 2FA/anti-bot challenges on major platforms and is
unsupported for YouTube. Cookies are the auth mechanism; treat `-u/-p` as legacy
for the few small sites where it still works.

## "Sign in to confirm you're not a bot"

Not strictly an auth wall — an IP-reputation challenge (heavy on datacenter/VPS
IPs). Options, in order:

1. `--cookies-from-browser firefox` — a logged-in session usually passes.
2. Run from a residential IP (or proxy through one: `--proxy`).
3. Update yt-dlp — client-impersonation fixes for this challenge ship regularly.

See [failure-triage.md](failure-triage.md) for the full error → cause ladder.
