# Local & manual publishing — uv, twine, build backends

For a one-off release, a non-GitHub CI, or an emergency upload. **CI should still
use OIDC** ([trusted-publishing.md](trusted-publishing.md)); this is the manual
path. Never hand-roll the HTTP upload.

## Build first (backend-agnostic)

`pyproject.toml` declares a build backend in `[build-system]`. Common ones:
`hatchling`, `setuptools`, `flit-core`, `pdm-backend`, `maturin` (Rust ext),
`scikit-build-core` (C/C++). The build command is the same regardless:

```bash
uv build                 # → dist/<pkg>-<ver>.tar.gz (sdist) + …-py3-none-any.whl
# or the PyPA-canonical:
python -m build          # needs: pip install build
```

Always validate before upload:

```bash
python -m twine check dist/*     # metadata/README sanity — catches the common reject
```

## Publish with uv (preferred in 2026)

```bash
# OIDC if running in a supported CI, otherwise prompts / uses configured creds
uv publish --trusted-publishing automatic

# token path — token via env, never inline (shell history leak)
UV_PUBLISH_TOKEN="pypi-…" uv publish

# TestPyPI
uv publish --publish-url https://test.pypi.org/legacy/
```

`uv publish` uploads whatever is in `dist/`. Build then publish; `uv` does not
re-resolve or rebuild at publish time.

## Publish with twine (canonical fallback)

```bash
python -m twine upload dist/*                                   # PyPI
python -m twine upload --repository testpypi dist/*             # TestPyPI (see .pypirc)
python -m twine upload --skip-existing dist/*                   # tolerate partial re-run
```

The GitHub Action wraps twine internally — so CI and local share the same upload
engine and validation.

## `~/.pypirc` (token storage for the manual path)

```ini
[distutils]
index-servers =
    pypi
    testpypi

[pypi]
  username = __token__
  password = pypi-AgEI…           # a PyPI API token; username is literally __token__

[testpypi]
  repository = https://test.pypi.org/legacy/
  username = __token__
  password = pypi-AgEN…           # a SEPARATE TestPyPI token
```

`chmod 600 ~/.pypirc`. Prefer a **project-scoped** token (PyPI → project →
Settings → API tokens) over an account-wide one. Rotate periodically; a token is a
long-lived bearer credential — exactly what OIDC exists to eliminate.

## When to use which

| Situation | Tool |
|---|---|
| CI/CD release | OIDC + `gh-action-pypi-publish` (not this file) |
| Local one-off, uv project | `uv build` + `uv publish` |
| Local one-off, non-uv | `python -m build` + `python -m twine upload` |
| Metadata validation (any path) | `twine check` |
| Dry run | TestPyPI via `--publish-url` / `--repository testpypi` |

## References
- uv publish: https://docs.astral.sh/uv/guides/publish/
- twine: https://twine.readthedocs.io/
- build: https://build.pypa.io/
- Packaging guide: https://packaging.python.org/en/latest/tutorials/packaging-projects/
