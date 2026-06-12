# Output Templates (`-o`) and Paths (`-P`)

Filenames are an API: archive correlation, sort order, and cross-filesystem safety
are all decided by the template. Get the convention right once.

## The house convention

```bash
-o "%(uploader)s/%(upload_date)s - %(title).100B [%(id)s].%(ext)s"
```

- `[%(id)s]` **always** — titles change, get truncated, and collide; the ID is the
  only stable join key to archive files and metadata.
- `%(upload_date)s` prefix (YYYYMMDD) — lexicographic = chronological sort.
- `%(title).100B` — truncate at 100 **bytes**, UTF-8-safe. `%(title).100s`
  truncates *characters* and can blow filesystem byte limits on CJK/emoji titles.
- Never end a directory component with `%(title)s` alone — a title of `.` or
  emoji-only produces garbage paths.

## Field catalog (the useful subset)

| Field | Value |
|---|---|
| `%(id)s` | platform video ID |
| `%(title)s` | video title (sanitized for the local OS by default) |
| `%(ext)s` | final extension — **always end the template with this**; yt-dlp picks it post-merge |
| `%(uploader)s`, `%(channel)s` | display name / channel name |
| `%(channel_id)s` | stable channel ID (display names get renamed) |
| `%(upload_date)s` | YYYYMMDD |
| `%(duration)s` | seconds |
| `%(playlist)s`, `%(playlist_index)s` | playlist name / position (`%(playlist_index)03d` to zero-pad) |
| `%(resolution)s`, `%(fps)s`, `%(vcodec)s`, `%(acodec)s` | stream properties |
| `%(epoch)s` | download time (unix) — for run-stamping |

Numeric fields accept printf formatting (`%(playlist_index)03d`); all fields accept
the `.NB` byte-truncation suffix. Missing fields render as `NA` — provide defaults
with `%(uploader|unknown)s` pipe syntax.

## Sanitization

```bash
--restrict-filenames     # ASCII-only, no spaces (shell/CI-safe; ugly)
--windows-filenames      # Windows-illegal chars stripped even on Linux (NAS/SMB)
--trim-filenames 200     # hard cap on total filename length
```

Default sanitization already strips the local OS's illegal characters;
`--restrict-filenames` is for files that must survive *any* downstream system
(URLs, docker volumes, old CI). Pick per destination, not reflexively.

## Per-type routing

Different artifact types can take different templates in one run:

```bash
yt-dlp --write-subs --write-thumbnail \
  -o "%(title).100B [%(id)s].%(ext)s" \
  -o "subtitle:subs/%(id)s.%(ext)s" \
  -o "thumbnail:thumbs/%(id)s.%(ext)s" URL
```

Types: `subtitle`, `thumbnail`, `description`, `infojson`, `chapter`, `pl_thumbnail`,
`pl_description`, `pl_infojson`.

## Paths (`-P`): destination vs scratch

```bash
yt-dlp -P "D:/media" -P "temp:C:/tmp/ytdlp" URL
```

- `-P home:` (or bare `-P`) — final destination.
- `-P temp:` — fragments, `.part` files, and pre-merge intermediates. Putting temp
  on fast local disk while home is a NAS/slow volume avoids double-writing large
  files over the network. The final file is *moved* (not re-downloaded) on completion.
- Type-specific paths compose with type-specific templates: `-P "subtitle:subs"`.

## Sidecar metadata for pipelines

```bash
yt-dlp --write-info-json -o "%(id)s.%(ext)s" URL    # full metadata as <id>.info.json
yt-dlp --load-info-json X.info.json                  # re-download later without re-extracting
```

`--write-info-json` is the pipeline-friendly pattern: every downstream step
(transcription, indexing, dedup) reads structured metadata from the sidecar
instead of re-querying the platform.
