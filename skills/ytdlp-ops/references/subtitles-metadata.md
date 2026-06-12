# Subtitles, Transcripts, and Metadata Embedding

Subtitle download is also the cheapest transcription source that exists — auto-subs
for a 1-hour video cost one HTTP request vs minutes of Whisper compute.

## Downloading subtitles

```bash
# Survey what exists (manual and auto-generated, per language):
yt-dlp --list-subs URL

# Manual subs, all English variants, skip the live-chat pseudo-track, as SRT:
yt-dlp --write-subs --sub-langs "en.*,-live_chat" --convert-subs srt --skip-download URL

# Auto-generated (ASR) captions — present on most videos even without manual subs:
yt-dlp --write-auto-subs --sub-langs en --convert-subs srt --skip-download URL

# Both, preferring manual when it exists:
yt-dlp --write-subs --write-auto-subs --sub-langs "en.*,-live_chat" --convert-subs srt URL
```

- `--sub-langs` takes comma-separated language regexes with `-` exclusions.
  `"en.*"` catches `en`, `en-US`, `en-GB`, `en-orig`. `"all,-live_chat"` = everything
  except the live-chat JSON track (which otherwise downloads as a huge `.json`).
- `--convert-subs srt|vtt|ass|lrc` — platforms serve VTT/JSON3; most downstream
  tooling wants SRT. Conversion is lossless for timing/text (styling is dropped).
- `--skip-download` makes it a subs-only run.

## Subs as cheap transcripts (STT shortcut)

Before reaching for Whisper, check whether auto-subs are good enough:

```bash
yt-dlp --write-auto-subs --sub-langs en --convert-subs srt --skip-download -o "%(id)s" URL
```

Auto-subs quality is "ASR with platform-scale models" — usually fine for search,
summarisation, and topic extraction; weak on names, jargon, and punctuation.
When word-level timing precision or quality matters, do real STT: acquire audio
with `-x --audio-format opus`, then the ffmpeg-ops
[stt-whisper](../../ffmpeg-ops/references/stt-whisper.md) pipeline.

Note: auto-sub SRT contains rolling-caption duplication (each line appears twice
as the window scrolls). Dedupe before feeding to an LLM — naive concatenation
roughly doubles token cost.

## Embedding (subs travel with the file)

```bash
yt-dlp --embed-subs --sub-langs en URL
```

Embeds as *soft* subtitles (toggleable track — `mov_text` in MP4, SRT/ASS in MKV).
Burn-in (hard subs) is a re-encode and belongs to ffmpeg-ops
[subtitles.md](../../ffmpeg-ops/references/subtitles.md).

## Metadata, thumbnails, chapters

```bash
# The self-describing-file trio:
yt-dlp --embed-metadata --embed-thumbnail --embed-chapters URL
```

- `--embed-metadata` — title/uploader/date/description into container tags.
- `--embed-thumbnail` — cover art (mp4/m4a/mkv/mp3/opus targets; needs the
  thumbnail to be convertible — yt-dlp handles webp→jpg via ffmpeg automatically).
- `--embed-chapters` — platform chapter markers as container chapters; players
  and editors (and ffmpeg-ops EDL tooling) can navigate them.
  SponsorBlock chapter marking composes with this — see
  [sponsorblock.md](sponsorblock.md).

Sidecar alternative when files must stay pristine:

```bash
yt-dlp --write-thumbnail --write-description --write-info-json URL
```

`--write-info-json` is the machine-readable everything (formats, chapters, tags,
counts) — the right input for indexing pipelines; see
[output-templates.md](output-templates.md) for routing sidecars into subdirs.
