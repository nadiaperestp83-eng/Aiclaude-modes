# Playlists, Channels, and Archive Files

Batch acquisition done right: resumable, deduplicated, polite, and cheap to re-run.

## The archive file (`--download-archive`)

```bash
yt-dlp --download-archive archive.txt -o "%(title).100B [%(id)s].%(ext)s" PLAYLIST_URL
```

The archive is a plain text file, one `extractor video_id` line per completed
download (e.g. `youtube dQw4w9WgXcQ`). On every run, anything already listed is
skipped *before* download. Properties worth knowing:

- **Append-only and trivially repairable** — delete a line to force a re-download;
  concatenate archives to merge collections.
- **It records IDs, not files** — moving/renaming downloaded files doesn't break it,
  but *deleting* a file doesn't trigger a re-download either. Keep `%(id)s` in the
  filename template so files and archive lines stay correlatable.
- **Scope it per collection** (one archive per channel/playlist/job), not one
  global file — global archives make "did job X get video Y?" unanswerable.

## Incremental channel sync (the cron pattern)

The naive cron job re-walks the whole channel every run — thousands of metadata
requests to discover nothing is new. The right shape:

```bash
yt-dlp --download-archive archive.txt --break-on-existing --lazy-playlist \
  -S "res:1080,vcodec:h264,acodec:m4a" \
  --sleep-requests 1 --sleep-interval 5 --max-sleep-interval 15 \
  -o "%(channel)s/%(upload_date)s - %(title).100B [%(id)s].%(ext)s" \
  CHANNEL_URL
```

- `--break-on-existing` — stop the entire run at the first already-archived video.
- `--lazy-playlist` — process entries as they stream in, instead of fetching the
  full playlist metadata first. The pair turns "walk 2,000 entries" into "check
  the 3 newest, stop".

**Caveat — only valid when new items appear at the front.** Channel upload feeds
are newest-first, so this is safe. A curated playlist that gets items inserted
anywhere (or sorted oldest-first) will *miss* additions behind the first archived
hit: drop `--break-on-existing` for those and eat the full walk.

`--break-on-reject` is the sibling for filter-based stops (e.g. with
`--dateafter`); same front-loaded-ordering caveat.

## Selecting subsets

```bash
yt-dlp -I 1:10 PLAYLIST_URL            # items 1-10
yt-dlp -I -3: PLAYLIST_URL             # last three
yt-dlp -I ::2 PLAYLIST_URL             # every second item
yt-dlp --dateafter 20260101 CHANNEL_URL   # uploaded on/after a date (YYYYMMDD)
yt-dlp --match-filters "duration<600 & !is_live" CHANNEL_URL
```

`-I`/`--playlist-items` takes Python-slice-like `start:stop:step` with negative
indexing. `--match-filters` runs against metadata fields — combine with
`--break-on-reject` carefully (ordering caveat above).

## Enumerate without downloading

```bash
# Fast listing (no per-video page fetches):
yt-dlp --flat-playlist --print "%(id)s %(title)s" PLAYLIST_URL

# Full playlist metadata as one JSON document:
yt-dlp --flat-playlist -J PLAYLIST_URL | jq '.entries | length'
```

`--flat-playlist` skips per-entry extraction — fields like exact duration,
formats, and descriptions may be missing or approximate; it's for inventory, not
for metadata-accurate pipelines.

## Playlist-aware output templates

```bash
-o "%(playlist)s/%(playlist_index)03d - %(title).100B [%(id)s].%(ext)s"
```

`%(playlist_index)s` is the position *in this playlist* (zero-pad it — `03d` —
so shells sort correctly). For channel scrapes prefer `%(upload_date)s` prefixes:
playlist indexes shift as videos are added/removed; upload dates don't.

## Robustness flags for long batch runs

```bash
--retries 10 --fragment-retries 10    # transient network errors
--ignore-errors                       # one private/deleted video doesn't kill the run
--no-overwrites                       # never clobber an existing file
--windows-filenames                   # force Windows-safe names even on Linux (NAS/SMB targets)
```

A failed run is rerunnable for free: the archive skips everything completed, and
partially-downloaded `.part` files resume automatically.
