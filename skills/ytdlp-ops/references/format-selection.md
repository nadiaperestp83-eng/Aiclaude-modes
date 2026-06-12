# Format Selection — `-S` sort vs `-f` filters

The single highest-leverage decision in any yt-dlp invocation. Get it right and the
file lands in the codec the destination needs; get it wrong and you pay a full
transcode (or a hard "Requested format is not available" failure) after the fact.

## The mental model

Platforms serve **separate video and audio streams** at high quality. "Downloading a
video" is really: pick a video stream, pick an audio stream, merge them (yt-dlp
shells out to ffmpeg for the merge). Two ways to steer the pick:

| Mechanism | Style | Failure mode |
|---|---|---|
| `-S` (`--format-sort`) | *Preferences* — "closest to these, in this priority order" | None — always degrades to nearest available |
| `-f` (`--format`) | *Filters* — "exactly this, or the next `/` alternative" | Hard error when nothing matches |

**Default to `-S`.** Reach for `-f` only when a hard requirement genuinely exists
(e.g. a pipeline that breaks on anything but `ext=m4a`), and even then end the chain
with `/b` so a catalog change degrades instead of failing.

## `-S` sort fields (the useful subset)

Comma-separated, priority order, first field dominates:

| Field | Meaning | Example |
|---|---|---|
| `res:1080` | Resolution closest to but not exceeding 1080p | `res:720` for 720p caps |
| `vcodec:h264` | Prefer this video codec family | `h264`, `h265`, `vp9`, `av01` |
| `acodec:m4a` | Prefer this audio codec/container family | `m4a` (AAC), `opus` |
| `ext` / `ext:mp4` | Prefer this container family | biases toward mp4/m4a |
| `fps` | Higher frame rate wins | `fps:30` to cap |
| `hdr:12` | Allow up to 12-bit HDR (default sort excludes some HDR) | archival masters |
| `+size`, `+br` | `+` prefix inverts: prefer SMALLER size/bitrate | bandwidth-constrained |
| `proto` | Prefer better download protocols (https over m3u8) | rarely needed manually |

Worked examples:

```bash
# Delivery-ready MP4, no transcode (h264 video + AAC audio merge natively):
yt-dlp -S "res:1080,vcodec:h264,acodec:m4a" --merge-output-format mp4 URL

# Absolute best quality (codec-agnostic master; expect VP9/AV1+Opus in MKV):
yt-dlp -S "res,fps,hdr:12,vcodec,acodec" --merge-output-format mkv URL

# Smallest file at >=480p-ish (floor the res, then ascend by size and bitrate):
yt-dlp -S "res:480,+size,+br" URL
```

## `-f` selector grammar (when you must)

| Token | Meaning |
|---|---|
| `bv`, `bv*` | best video-only / best video (may include audio) |
| `ba`, `ba*` | best audio-only / best audio |
| `b` / `best` | best single PRE-MERGED file — on YouTube caps ~720p |
| `wv`, `wa`, `w` | worst (testing) |
| `+` | merge: `bv+ba` |
| `/` | fallback chain, left wins: `bv*+ba/b` |
| `[...]` | filter: `[height<=1080]`, `[vcodec^=avc1]`, `[ext=m4a]`, `[filesize<500M]` |

Comparison operators: `=`, `!=`, `^=` (starts with), `$=` (ends with), `*=`
(contains), and numeric `<`, `<=`, `>`, `>=`. Combine inside one bracket with
implicit AND: `[height<=1080][fps<=30]`.

```bash
# Exact: H.264 video at <=1080p + AAC audio, fall back to best pre-merged, then anything:
yt-dlp -f "bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/b[height<=1080]/b" URL
```

Codec string gotcha: YouTube reports H.264 as `avc1.xxxx` — match with
`[vcodec^=avc1]`, not `[vcodec=h264]`. AV1 is `av01`, H.265 is `hev1`/`hvc1`.

## Avoiding the post-download transcode (the whole point)

| Destination needs | Ask for at download | Why it works |
|---|---|---|
| MP4 for web/editors | `-S "vcodec:h264,acodec:m4a" --merge-output-format mp4` | h264+aac are mp4-native; merge is a remux |
| Audio for STT | `-x --audio-format opus` | platform audio IS Opus; `-x` copies, no transcode |
| MKV archive | `-S "res,fps,hdr:12,vcodec,acodec" --merge-output-format mkv` | mkv holds anything; never forces re-encode |
| Anything else | download best-native, then ffmpeg-ops | yt-dlp's `--recode-video` is a blind transcode — no CRF/preset/pix_fmt control |

If the needed codec genuinely isn't offered (some platforms are VP9-only at high
res), that's a real transcode — do it deliberately with the ffmpeg-ops
web-compatible H.264 recipe, not `--recode-video`.

## Survey before arguing

```bash
yt-dlp -F URL                 # table of every offered format (ID, ext, res, codecs, size)
yt-dlp -J URL | jq '.formats[] | {format_id, ext, vcodec, acodec, height}'
```

When a selector misbehaves, `-F` output is ground truth — extractors change what
they offer (per-client, per-region, A/B tests), so yesterday's format ID list is
not evidence.

## Canonical presets

Machine-readable versions of these recipes (per-destination args, handoff notes):
[../assets/format-presets.json](../assets/format-presets.json).
