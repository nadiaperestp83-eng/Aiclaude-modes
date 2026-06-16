# OKF Format Reference

Distilled rules for the **Open Knowledge Format (OKF) v0.1** as enforced by
`check-okf.py`. OKF is platform-agnostic; this is the working reference, not the
upstream spec verbatim. When precision matters, confirm against the source.

## Contents

1. [Bundle layout](#bundle-layout)
2. [Concept documents](#concept-documents)
3. [Frontmatter fields](#frontmatter-fields)
4. [Reserved files](#reserved-files)
5. [Linking](#linking)
6. [Conformance rules](#conformance-rules)
7. [Permissive consumption](#permissive-consumption)
8. [Versioning](#versioning)

## Bundle layout

A **bundle** is a directory tree of markdown files with optional subdirectories. Two
filenames are **reserved** (`index.md`, `log.md`); every other `.md` is a **concept
document**.

```
my-bundle/
├── index.md            # (optional) directory listing; may carry okf_version at root
├── log.md              # (optional) chronological update history
├── concept-a.md        # concept document (frontmatter + body)
└── sub/
    └── concept-b.md
```

## Concept documents

Each concept document = **YAML frontmatter** delimited by `---`, then a **markdown
body**. Conventional (optional) body headings: `# Schema` (columns/fields), `# Examples`,
`# Citations`.

## Frontmatter fields

| Field | Required | Meaning |
|-------|----------|---------|
| `type` | **yes** | Short string identifying the kind of concept. Consumers route/filter/present on it. **The one hard requirement.** OKF does not define a taxonomy — you choose your `type` vocabulary. |
| `title` | recommended | Display name. |
| `description` | recommended | One-sentence summary. |
| `resource` | recommended | URI uniquely identifying the underlying asset. |
| `tags` | recommended | YAML list of short strings for cross-cutting categorization. |
| `timestamp` | recommended | ISO-8601 datetime of last change. |

Producers may add **arbitrary extra keys**; consumers **must preserve** unknown keys.
This is what lets a richer in-house schema (e.g. `level`, `children`) ride on top of an
OKF-conformant base — be a superset, never dumb down to OKF's minimum.

## Reserved files

- **`index.md`** — directory listing. Normally **no frontmatter**; uses markdown sections
  grouping links: `* [Title](url) - description`. The bundle-root `index.md` is the one
  allowed exception — it may carry `okf_version` in frontmatter.
- **`log.md`** — chronological history. ISO-8601 `YYYY-MM-DD` date headings grouping prose
  entries (conventional leads: `**Update**`, `**Creation**`).

## Linking

- Bundle-relative (absolute): `/path/to/concept.md`
- Relative: `./other.md`

Links assert a relationship; specific semantics come from surrounding prose. **Broken
links are tolerated** (see permissive consumption).

## Conformance rules

A bundle is **conformant** iff:

1. Every non-reserved `.md` file has **parseable YAML frontmatter**.
2. Every such frontmatter has a **non-empty `type`**.
3. Reserved files follow their structure **when present**.

`check-okf.py` enforces exactly these as hard failures (exit 10), plus light structural
sanity on reserved files. Everything else is INFO/warning.

## Permissive consumption

Consumers **MUST NOT** reject a bundle for any of:

- Missing optional frontmatter fields
- Unknown `type` values
- Unknown additional frontmatter keys
- Broken cross-links
- Missing `index.md`

This is intentional: OKF stays useful as bundles grow, get refactored, and are partially
agent-generated. `check-okf.py` honours this — these surface as INFO and never fail
conformance unless `--strict` is passed.

## Versioning

`<major>.<minor>`. Minor bumps add backward-compatibly; major bumps may break. A bundle
declares its target version with `okf_version: "0.1"` in the bundle-root `index.md`
frontmatter. Pin it and re-check on a major bump.
