# Trusted Publishing (OIDC) — setup, claims, environments

The 2026 default for publishing to PyPI from CI. No stored token; GitHub mints a
short-lived OIDC token per run, PyPI exchanges it for an upload credential, and
PEP 740 attestations sign the build provenance.

## How the exchange works

1. The publish job declares `permissions: id-token: write`.
2. GitHub mints an OIDC JWT whose **claims** describe the run: `repository`,
   `repository_owner`, `workflow_ref` (→ the workflow filename), `environment`,
   `ref`, `sub`.
3. `pypa/gh-action-pypi-publish` sends that JWT to PyPI's mint endpoint.
4. PyPI looks for a **Trusted Publisher** whose registered fields match the
   claims. Match → a short-lived API token scoped to that project. No match →
   `invalid-publisher`.

The whole security model is "the claims must match a publisher you registered."
Four fields must line up **exactly**:

| Claim | Registered as | Common mismatch |
|---|---|---|
| `repository_owner` | Owner | org vs personal account |
| `repository` | Repository name | renamed repo |
| `workflow_ref` | Workflow name | the **filename** `publish.yml`, not the `name:` field |
| `environment` | Environment name | job has no `environment:`, or a different one |

## Two registration paths

### Project publisher (project already exists on PyPI)
PyPI → your project → **Settings → Publishing → Add a new publisher**. Use this
for every release *after* the first.

### Pending publisher (FIRST publish — project doesn't exist yet)
You cannot add a project publisher to a project that doesn't exist. Register a
**pending publisher** at the account level **before** the first upload:

> https://pypi.org/manage/account/publishing/ → "Add a pending publisher"
>
> - **PyPI Project Name** — the dist name (`pyproject.toml` `[project].name`)
> - **Owner** / **Repository name** — GitHub `owner` / `repo`
> - **Workflow name** — the filename, e.g. `publish.yml`
> - **Environment name** — must equal the job's `environment:` (e.g. `pypi`)

On the first successful publish it auto-converts to a normal project publisher.
**This is the single most common first-release failure** — every release builds
green but nothing reaches PyPI because this step was skipped.

## The environment gate (defense-in-depth)

Put `environment: pypi` on the publish job. In **Settings → Environments → pypi**
add **Required reviewers**. Now every release pauses for a human click, even if
CI or the repo is compromised — OIDC proves *what* is publishing, the environment
gate decides *whether*. The environment name is also one of the four matched
claims, so it doubles as a publisher binding.

## TestPyPI {#testpypi}

`test.pypi.org` is a **separate instance** — separate account, separate project
namespace, **separate pending-publisher registration**. To dry-run:

```yaml
- uses: pypa/gh-action-pypi-publish@<sha>  # vX
  with:
    attestations: true
    repository-url: https://test.pypi.org/legacy/
```

Register the pending publisher on TestPyPI (same four fields) and install from it
with `pip install -i https://test.pypi.org/simple/ <pkg>`. TestPyPI prunes old
releases and is not a reliability guarantee — use it for the metadata/flow
rehearsal, not as a staging registry.

## Migrating an existing token-based workflow to OIDC

1. Add a Trusted Publisher (or pending publisher) for the project on PyPI.
2. In the publish job: add `permissions: id-token: write` (+ `contents: read`),
   and **remove** `password: ${{ secrets.PYPI_API_TOKEN }}` from the
   `gh-action-pypi-publish` step. Do not pass both — a token present alongside
   OIDC is what `publish-preflight.sh` flags.
3. Add `environment: pypi` and (recommended) required reviewers.
4. Delete the now-unused `PYPI_API_TOKEN` secret and revoke the token on PyPI.

## Verifying provenance (consumer side)

Attestations are only worth emitting if someone can check them. As a consumer:

- **PyPI project page** shows a "provenance"/attestation badge linking the release
  to the exact repo + workflow run that built it — a quick human check that a
  release came from the expected source.
- **`gh attestation verify <artifact> --repo OWNER/REPO`** verifies a downloaded
  wheel/sdist against its signed provenance from the command line.
- `pip` does **not** verify attestations at install time yet (2026) — provenance
  is currently an audit/forensic control, not an install-time gate. Don't assume
  `pip install` checks it.

## References
- PyPI Trusted Publishers: https://docs.pypi.org/trusted-publishers/
- Troubleshooting (the `invalid-publisher` page): https://docs.pypi.org/trusted-publishers/troubleshooting/
- PEP 740 (attestations): https://peps.python.org/pep-0740/
- Action: https://github.com/pypa/gh-action-pypi-publish
