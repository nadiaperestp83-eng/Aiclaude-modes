# PyPI publish recovery playbook

The failure classes `diagnose-publish.sh` recognises, the mechanics behind each,
and the fix. Run the diagnoser first; this is the depth behind its verdict.

## `invalid-publisher` — no matching Trusted Publisher
**Mechanics.** The OIDC token was valid; PyPI found no publisher whose registered
claims match the run. Almost always: a first publish with no *pending publisher*,
or a claim mismatch (workflow filename, environment, renamed repo/owner).

**Fix.** Register the (pending) publisher — see
[trusted-publishing.md](trusted-publishing.md). Compare the run's presented claims
(the action prints them; `diagnose-publish.sh` extracts them) field-by-field
against what you registered. Then `gh run rerun <id> --failed` — no re-tag needed;
the same claims will match once the publisher exists.

## `File already exists` — immutable version
**Mechanics.** PyPI versions are **write-once**. A filename (`pkg-1.2.3-*.whl`)
can never be re-uploaded, *even after you delete the release* — deletion does not
free the name. This is deliberate, to keep installs reproducible.

**Fix.** Bump to a new version (patch is fine), commit the bump across
`pyproject.toml` + `__init__` + lockfile, re-tag, push. `skip-existing: true` on
the action only tolerates a *partial* re-run (some files already up) — it never
replaces an existing file and is not a way to "re-release" a version.

## Job stuck "Waiting" — environment approval
**Mechanics.** `environment: pypi` with required reviewers pauses the job until a
human approves in the run UI. Not a failure — by design.

**Fix.** Approve the deployment (or remove the reviewer requirement if the gate
isn't wanted). The environment claim still binds the publisher either way.

## `environment not allowed/found` — claim mismatch
**Mechanics.** The Trusted Publisher was registered with an Environment name the
job doesn't set, or the job sets one the publisher doesn't list.

**Fix.** Make `jobs.publish.environment` equal the publisher's Environment name
verbatim. Leaving the publisher's Environment blank means the job must NOT set one
— they must agree.

## `403 Forbidden` / `isn't allowed to upload`
**Mechanics.** Credential refused. For OIDC: the identity is publishing to a
project it has no publisher for (or to create a project without a pending
publisher). For tokens: wrong/expired/insufficient scope.

**Fix.** OIDC path — confirm the publisher exists for this exact project. Token
path — rotate the token, re-store the secret, ensure project scope. New project +
OIDC always needs a pending publisher first.

## Built green but not live on PyPI — silent accept
**Mechanics.** The upload returned success but the version isn't queryable
(rejected post-accept, or CDN propagation lag). Without a verify step the run
looks fully green while nothing is installable.

**Fix.** Add the verify-on-PyPI job (polls `https://pypi.org/pypi/<name>/<ver>/json`)
from `assets/publish.yml`. If it was a real rejection, the cause is usually
metadata — fix and bump.

## `twine check` failed — bad metadata
**Mechanics.** The wheel/sdist metadata is malformed (README `content-type`
mismatch, missing fields). Caught before upload by `twine check`.

**Fix.** Correct `[project]` metadata (notably `readme` + its content type),
rebuild, `python -m twine check dist/*` until clean locally. Run it in CI before
the upload step so this never reaches PyPI.

## pip-audit / build gate failed (not a publish failure)
**Mechanics.** The `build` job failed before publish — a dependency CVE
(`pip-audit`), a lock/pyproject divergence (`uv sync --locked`), or a build error.

**Fix.** This is a dependency/build issue, not PyPI. Patch the dep (see
`supply-chain-defense`), re-resolve the lock, or fix the build; the publish never
ran.

## Shipped a broken release — yank, don't delete
**Mechanics.** Deleting a release frees nothing (the version name stays burned
forever) and *breaks* anyone who pinned it. **Yanking** is the right tool: a
yanked version stays installable by an exact pin (`pkg==1.2.3`) so existing
lockfiles keep working, but resolvers skip it for new/range installs.

**Fix.** PyPI → project → Manage → the release → **Yank** (with a reason). Then
publish a fixed **higher** version. Reserve deletion for secrets/PII leaks where
availability is worse than the breakage.

## Account preconditions (fail before you start)
- **2FA is mandatory** on PyPI for all maintainers. Without it you cannot create
  tokens or configure publishers — set it up first.
- **Trusted Publishing needs no token at all**; if you're creating an API token
  "just in case", you probably don't need it (and it's a liability). Prefer a
  **project-scoped** token over account-wide if you must.
- A **pending publisher** is per-project and consumed on first publish; register
  one per new package.

## General recovery loop
```bash
scripts/diagnose-publish.sh <run-id> --repo OWNER/REPO   # name the class
# … apply the fix above …
gh run rerun <run-id> --failed                           # re-run only failed jobs
# (bump+re-tag instead only when the fix changed the artifact, e.g. VERSION_EXISTS)
```
