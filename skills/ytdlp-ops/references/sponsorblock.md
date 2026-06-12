# SponsorBlock Integration

yt-dlp has native SponsorBlock support: crowd-sourced segment data (sponsor reads,
intros, outros, self-promo) fetched at download time and either **marked** as
chapters or **removed** from the media.

## Mark vs remove (the decision)

| | `--sponsorblock-mark` | `--sponsorblock-remove` |
|---|---|---|
| Media bytes | Untouched — adds chapter markers only | Cut out — file is modified |
| Lossless | Yes | No — re-encodes around cut boundaries |
| Reversible | Yes (chapters are metadata) | No |
| Player behaviour | Players with auto-skip honor the chapters; others just show them | Segments simply don't exist |
| Composability | Works with everything | **Incompatible with `--download-sections`**; complicates archives (file ≠ platform timeline) |

**Default to `--sponsorblock-mark`.** It preserves the original media, keeps
timestamps aligned with the platform (comments, transcripts, and chapter URLs
still match), and the decision to skip stays with the player. Remove only for
final-consumption files where the segments must be gone (e.g. media-server
libraries watched on dumb clients).

## Usage

```bash
# Mark everything SponsorBlock knows about as chapters (lossless):
yt-dlp --sponsorblock-mark all URL

# Mark only the high-confidence ad categories:
yt-dlp --sponsorblock-mark sponsor,selfpromo URL

# Remove sponsor reads and self-promo from the file (re-encodes at boundaries):
yt-dlp --sponsorblock-remove sponsor,selfpromo URL

# Custom chapter title for marked segments:
yt-dlp --sponsorblock-mark all --sponsorblock-chapter-title "[SB]: %(category_names)l" URL
```

## Categories

| Category | Content |
|---|---|
| `sponsor` | Paid sponsor reads |
| `selfpromo` | Unpaid self-promotion (merch, Patreon, other videos) |
| `interaction` | "Like and subscribe" reminders |
| `intro` / `outro` | Intro animations / endcards and credits |
| `preview` | Recap/preview of the video itself |
| `filler` | Tangents and filler (aggressive — community-tagged loosely) |
| `music_offtopic` | Non-music sections in music videos |
| `poi_highlight` | Point-of-interest marker (mark-only) |
| `chapter` | Community-submitted chapters (mark-only) |
| `all` / `default` | Everything / the default mark set |

`-remove` accepts the cuttable subset (not `poi_highlight`/`chapter`). Start
conservative: `sponsor,selfpromo` has high community accuracy; `filler` is noisy.

## Operational notes

- **Data is crowd-sourced** — new uploads may have no segments yet (the flags then
  do nothing, silently). Niche channels may never be tagged.
- The SponsorBlock API is an extra network dependency: `--sponsorblock-api URL`
  points at a mirror if the default is unreachable; downloads proceed without
  segment data on API failure.
- Remove + `--download-archive` interact philosophically: the archive says
  "have video X", but the file is a *modified* X. If fidelity matters to the
  collection, mark instead.
- Chapter-mark output composes with `--embed-chapters` (platform chapters and
  SponsorBlock chapters merge into one track).
