# Supply-Chain Verification for Process Compose

Process Compose ships as a single Go binary via GitHub Releases with SHA-256 checksums. This is structurally safer than npm/PyPI packages but still requires verification before use.

## Why bother

Even with Go's `go.sum` model:
- The compiled binary is what runs, not the source — must verify the binary matches what was built from verified source
- GitHub Releases artifacts can theoretically be tampered if repo permissions are compromised
- Checksums file is on GitHub Releases too, so without a separate signature, you're trusting GitHub auth integrity
- No GPG signing on Process Compose releases (as of v1.110.0) — relies entirely on GitHub Release access controls

## The Procedure

### 1. Download from official release

```bash
VER="v1.110.0"   # pin a specific tag
BASE="https://github.com/F1bonacc1/process-compose/releases/download/$VER"

curl -fsSL -o pc.zip                       "$BASE/process-compose_windows_amd64.zip"
curl -fsSL -o process-compose_checksums.txt "$BASE/process-compose_checksums.txt"
```

### 2. Verify hash BEFORE extraction

```bash
EXPECTED=$(grep "process-compose_windows_amd64.zip" process-compose_checksums.txt | awk '{print $1}')
ACTUAL=$(sha256sum pc.zip | awk '{print $1}')

[ "$EXPECTED" = "$ACTUAL" ] || { echo "HASH MISMATCH - ABORT"; exit 1; }
```

**Never** extract or run the binary before this check passes.

### 3. Extract, record the binary's own hash

```bash
unzip pc.zip
EXE_HASH=$(sha256sum process-compose.exe | awk '{print $1}')
echo "$EXE_HASH" > bin/EXE_HASH
```

This is the hash you re-verify on future installs to confirm the binary in your repo hasn't been tampered.

### 4. Commit binary + checksums to repo

```bash
git add bin/process-compose.exe \
        bin/process-compose_checksums.txt \
        bin/VERSION                              # contains "v1.110.0"
git commit -m "feat: pin process-compose $VER, verified SHA-256"
```

### 5. Document the verification

Write a `bin/VERIFICATION.md`:

```markdown
# Binary Verification

## process-compose.exe — v1.110.0

- Pinned: 2026-MM-DD
- Source: https://github.com/F1bonacc1/process-compose/releases/tag/v1.110.0
- ZIP SHA-256:    018c660f...        (matched checksums.txt)
- EXE SHA-256:    2e2a09a9...858637  (recorded for re-verification)
- Runtime check:  "Process Compose v1.110.0, Commit cd7f6af"

Trust anchor: GitHub Releases (HTTPS, requires repo write access to tamper).
Limitation: No GPG signing on Process Compose releases.
```

## Re-verification

Periodically — or as part of CI — re-hash the committed binary and confirm it matches the recorded value:

```powershell
# Windows
$expected = (Get-Content bin/EXE_HASH).Trim()
$actual   = (Get-FileHash bin/process-compose.exe -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "binary tampered" }
```

```bash
# Unix
expected=$(cat bin/EXE_HASH | tr -d '[:space:]')
actual=$(sha256sum bin/process-compose.exe | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "binary tampered"; exit 1; }
```

## Upgrade Procedure

To bump versions:

1. Run the download + verify procedure above with the new version tag
2. Replace `bin/process-compose.exe`, `bin/process-compose_checksums.txt`, `bin/VERSION`, `bin/EXE_HASH`
3. Update `VERIFICATION.md` with new hashes + date
4. Run a parallel test (non-prod port) before cutting over
5. Single PR with all of the above; review before merge

## What's NOT Covered

The verification confirms **you got the binary the project intended to publish**. It does NOT cover:

- Compromise of the project's source code (would need full source audit)
- Compromise of the build environment (GoReleaser + GitHub Actions infrastructure)
- The Go modules the binary was compiled with (transitive dependency risk)

For deeper supply-chain analysis: tools like `osv-scanner`, `govulncheck`, or commercial tools (Socket.dev, Snyk) inspect the **source** dependency tree. Use those upstream of the verification step.

## See Also

- `boot-persistence-windows.md` for how to launch the verified binary at boot
- The repo's own AGENTS.md should document the pinned version policy
