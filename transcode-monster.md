# Transcode Monster

A universal video transcoding script with intelligent automatic detection for series and movies. Designed for archiving DVD and Blu-ray collections with optimal quality and minimal manual intervention.

## Design Goals
- "Do the right thing" 90% of the time
    * The majority of use cases, the user should be able to simply point the script at a directory containing source media
- Simple workflow
    * Transcoding entire multi-disc series so you can stream them on your home media devices shouldn't involve hand tailoring your encoder for each of 100+ files
- High-quality results
    * The default product should be compressed but otherwise archival-grade, with transparent video, pass-through of primary audio for use with home theater / audio receivers, and transparent secondary & tertiary audio tracks

## Features

- **Automatic detection**: Series vs movies, interlacing, telecine (3:2 pulldown), crop borders
- **HDR support**: Detects and preserves HDR10, HLG, and BT.2020 content automatically
- **Bulk movie processing**: Process multiple movies in one directory without manual intervention
- **Hybrid encoding**: Stays on hardware (VAAPI) for speed and only falls back to software (x265) when the hardware genuinely can't handle the source
- **Smart deinterlacing**: Detects interlacing and telecine, then inverse-telecines film and deinterlaces true video, handling discs that mix the two in a single title
- **Verified telecine detection**: Confirms 3:2 pulldown at any resolution by trial-matching the cadence, and recognizes film whose cadence is too broken to decimate so it keeps its native rate instead of being resampled into judder
- **Measured field order**: Resolves top/bottom field order by deinterlacing both ways and keeping whichever leaves less combing, overriding container tags where they disagree; sources with no consistent field order are detected and held to frame-rate output
- **Automatic filter selection**: Profiles each source and picks the deinterlacer that suits it, falling back gracefully when a filter or its weights are unavailable
- **Color space handling**: Preserves HDR, converts legacy formats (BT.601 for SD, BT.709 for HD), and tags untagged sources with the correct standard so players don't guess
- **Multi-episode files**: Automatically splits by chapters for disc rips with multiple episodes
- **Audio/subtitle management**: Language filtering, format conversion, disposition handling
- **Copy-only (remux) mode**: Restructure track selection, dispositions, and naming without re-encoding, for sources that are already well-encoded but badly mastered or named
- **Configurable**: Config file + CLI arguments for full control

## Dependencies
- `bash` - The script is written in bash for simplicity, and we use its built-in error handling
- `bc` - For doing advanced things like automatically calculating whether or not a series is broken up by chapter or by file
- `ffmpeg` - The latest version available to you, e.g. with a rolling distro like `arch` or utilizing the [deb-multimedia](https://www.deb-multimedia.org/) repository for Debian.
- `VA-API`_(optional)_ -  Use your GPU to give you a massive encoding speedup (usually available through packages like `mesa-va-drivers` or `va-driver-all`)
- Adequate permissions - The user you're leveraging for transcoding needs the correct privileges. Typically this means membership in the `video` or `render` group.

## Quick Start

### Basic Usage

Transcode a TV series:
```bash
transcode-monster.sh "/path/to/rips/Firefly/" "/path/to/output/Firefly/"
```

Transcode a movie:
```bash
transcode-monster.sh -t movie -n "Dune" -y 1984 "/path/to/rips/dune/" "/path/to/output/"
```

Process multiple movies:
```bash
transcode-monster.sh --bulk-movies "/path/to/movies/rips/" "/path/to/output/"
```

Overwrite existing files:
```bash
transcode-monster.sh -o "/path/to/source/" "/path/to/output/"
```

### Installation

```bash
# Copy to your PATH
sudo cp transcode-monster.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/transcode-monster.sh

# Verify installation
transcode-monster.sh --version
```

### Configuration

Create `~/.config/transcode-monster.conf` for persistent settings. Here is my own config for reference:

```bash
# Max bframes for compression. Playback even works great on Raspberry Pi4
# NOTE: Has no effect when VIDEO_CODEC="hevc_vaapi" on AMD GPUs, since B-frames
# are unsupported in AMD HEVC hardware encoding across all VCN generations.
# Only takes effect with libx265 (software encoding).
BFRAMES="4"
# Prefer the source media's native language over dubs in our default language.
PREFER_ORIGINAL="true"
# Default to hardware encoding, even if the source media has weird or missing color metadata. Fallback manually with the `-c libx265` flag.
VIDEO_CODEC="hevc_vaapi"
```

## Common Use Cases

### UHD / HDR Content

HDR content is automatically detected and preserved:

```bash
# HDR10, HLG, and BT.2020 are automatically detected
transcode-monster.sh "/path/to/UHD/Ghost in the Shell/" "/output/"

# Force HDR preservation if needed
transcode-monster.sh --colorspace hdr "/path/to/source/" "/output/"
```

**Important: Dolby Vision Limitation**

Dolby Vision **cannot be preserved** during transcoding. When re-encoding DV content:
- The script will warn you that DV will be stripped
- Only the HDR10 base layer is preserved
- Colors may appear washed out compared to the original

If you have Dolby Vision-capable playback (Apple TV 4K, LG OLED, etc.), keep the
original video stream. [`--copy-only`](#copy-only-remux-mode) restructures the
container — track selection, language filtering, subtitle dispositions, chapters
and naming — without re-encoding, so the Dolby Vision layer survives intact:

```bash
transcode-monster.sh -t movie -n "Blade Runner 2049" --copy-only "/rips/br2049.mkv" "/output/"
```

### Bulk Movie Processing

Process multiple movies in one directory:

```bash
# Process all movies in a directory
transcode-monster.sh --bulk-movies "/path/to/movies/rips/" "/output/"

# Example: Star Wars collection
transcode-monster.sh --bulk-movies "/path/to/Star Wars/Laserdisc/" "/output/Movies/"
# Outputs: Star Wars Episode 1 - The Phantom Menace.mkv, etc.
```

### Anime / Foreign Content

Prefer original audio with English subtitles:

```bash
transcode-monster.sh --original-lang jpn "/path/to/Cowboy Bebop/" "/output/"
```

Telecined anime (especially OVAs that mix telecined film with true interlaced
video/effects) is inverse-telecined automatically; the default `adaptive`
`--ivtc-mode` keeps those video sections smooth. If a disc shows stray combing or
fights detection, see [Telecine Detection Issues](#telecine-detection-issues).

### Difficult Interlaced Sources

Filter selection is automatic, but two cases are worth overriding by hand.

Grainy, heavily compressed or artifact-ridden sources do better on bwdif, which
softens noise rather than sharpening it into detail:

```bash
transcode-monster.sh --deinterlacer bwdif "/path/to/broadcast-tape/" "/output/"
```

Clean animation with frequent pans or vertical scrolls does better on nnedi,
which reconstructs near-horizontal edges without the stair-stepping that reads as
crawl during a scroll:

```bash
transcode-monster.sh --deinterlacer nnedi "/path/to/The Maxx/" "/output/"
```

### Mostly Progressive Sources

Some transfers are progressive apart from a title sequence, an optical effect or
a video-sourced insert — the script reports a low interlaced percentage and warns
that the source is mostly progressive. Deinterlacing every frame of such a file
softens the majority that never needed it, so restrict the filter to the frames
that do:

```bash
transcode-monster.sh --adaptive-deinterlace "/path/to/movie.mkv" "/output/"
```

Check the result before committing a batch — see
[Deinterlacing Scope](#deinterlacing-scope---adaptive-deinterlace).

### Custom Quality

Adjust quality for different use cases:

```bash
# High quality archival (larger files)
transcode-monster.sh -q 18 "/path/to/source/" "/output/"

# Space-conscious (smaller files)
transcode-monster.sh -q 24 "/path/to/source/" "/output/"
```

### Dry Run

Preview what will be processed without encoding:

```bash
transcode-monster.sh -d "/path/to/source/" "/output/"
```

### Copy-Only (Remux) Mode

When the source is already encoded the way you want it but is badly mastered or
named, `--copy-only` (also available as `--remux`) keeps the video and audio
streams byte-for-byte and only restructures the container: it selects the right
audio and subtitle tracks, filters by language, sets the default/forced subtitle
dispositions, maps chapters, and names the output exactly as a normal run would.

```bash
# Remux a badly-named series into clean Show - S01E01.mkv files, no re-encode
transcode-monster.sh -t series -n "Darkwing Duck" --copy-only "/rips/darkwing/" "/output/"

# Fix track selection/dispositions on a single film without touching quality
transcode-monster.sh -t movie -n "Revolver" --copy-only "/rips/revolver.mkv" "/output/"
```

Because nothing is re-encoded, this runs at copy speed and is lossless. All the
video-analysis steps (crop, interlacing, telecine, bit-depth, encoder choice)
are skipped. Audio is copied as-is; a track is only converted when it genuinely
cannot be muxed verbatim (for example `pcm_bluray`, which is remapped losslessly
to FLAC). Subtitle text formats that the target container can't carry directly
are converted losslessly, the same as in encode mode. Note that chapter-based
episode splitting in copy mode cuts on the nearest keyframe rather than the exact
frame, since the video isn't being re-encoded.

## Understanding Automatic Detection

### Interlacing Detection

The script samples frames at multiple points and applies a deinterlacer when more
than 5% of sampled frames show interlacing. The threshold is low so that partly
interlaced sources — progressive film with interlaced titles or optical effects,
for instance — are still handled.

**Field order** is resolved by measurement rather than by metadata. Sample points
are deinterlaced at both field orders and scored on how much combing each leaves;
the order leaving less is the correct one. Container tags and `idet`'s TFF/BFF
vote are both unreliable here — a mislabelled tag is common on DVD, and some
masters carry a single tag while their actual field order varies by segment.

Three outcomes:

- **Consistent** — one order wins across sample points. It is used for both
  deinterlacing and field matching, overriding the container tag if they differ.
- **Inconsistent** — the winner changes between sample points, so the source has
  no single field order. The majority order is used and output is forced to
  frame rate.
- **Unverifiable** — too few sample points separate the two orders meaningfully.
  The container tag is used and output is forced to frame rate.

Frame rate is forced in the latter two cases. An unverified field order costs
only some vertical softness at frame rate, but at field rate it emits each frame's
two fields in reversed temporal order, and motion repeatedly advances and snaps
back.

### Telecine Detection (3:2 Pulldown)

Telecine is checked at **every resolution**, since HD broadcast and disc masters
carry 3:2 pulldown as often as SD ones do. Detection samples the cadence at four
points (20%, 40%, 60%, 80% through the file), because cadence frequently varies
across a disc and any single sample can land on a static scene that shows no
cadence at all. Detection favors the 29.97/23.976 rate family that 3:2 pulldown
comes from, so PAL and native-progressive film aren't dragged through an inverse
telecine they don't need (`--scan-ivtc` overrides the rate prior).

Sources are sorted into three classes:

- **Telecine** — either a strong repeated-field cadence, which is the direct
  signature of 3:2 pulldown, or a trial fieldmatch that collapses the combing
  almost entirely. These are inverse-telecined: the original progressive frames
  are reconstructed and the pulldown duplicates dropped.
- **Film-interlaced** — a trial fieldmatch collapses most of the combing but
  leaves a modest residual. The fields still pair up into whole frames, so the
  source is film, but its 3:2 cadence is too broken to decimate safely. This is
  typical of anime OVA reissues that mix film blocks, true video blocks and
  soft-telecine pockets in a single master. These keep their original frame rate
  and are only deinterlaced, since resampling them to any one rate judders
  whichever part of the file doesn't match it.
- **Not telecine** — the combing survives the trial fieldmatch, meaning the two
  fields of a frame are genuinely different instants. Handled as true interlaced
  video.

The trial fieldmatch is what separates telecined film from interlaced video.
Film inverts cleanly because its fields were split from whole frames and can be
paired back up; interlaced video has no clean pairing to recover, so its combing
survives the attempt.

When telecine is confirmed, the script inverse-telecines on the CPU
(`fieldmatch` → `yadif` cleanup of the frames fieldmatch can't match → frame
decimation), then hands the progressive result to the encoder.

**Dropping the duplicates — `--ivtc-mode`:** after field matching, the pulldown
duplicate frames have to go. Two strategies:

- `adaptive` (default): `mpdecimate` + variable frame rate. Drops only true
  duplicates, so cleanly-telecined film lands at 23.976 while interlaced
  video/effects stretches (common in anime OVAs) keep their unique frames at
  ~29.97 — no judder on mixed-cadence sources.
- `fixed`: classic `decimate` + 23.976 CFR. An exact 1-in-5 drop, best for
  uniformly-telecined film and for players that require a constant frame rate,
  but it judders on mixed-cadence material. It also makes residual combing in the
  video sections less visible, since every frame is shown for the same duration
  instead of lingering under VFR — useful on a mixed disc that shows stray
  combing.

**Match thoroughness — `--fieldmatch-mode`:** `pc_n` (default) is the standard
matcher. `pcn_ub` additionally tries the previous-field combinations — the most
exhaustive search, which can reconstruct more frames across cadence breaks on
difficult anime, at a slightly higher risk of a bad match. Leave it on `pc_n`
unless a specific source fights the default.

Override if needed:
```bash
# Scan for telecine even when the rate prior would skip it
transcode-monster.sh --scan-ivtc "/path/to/source/"

# Inverse telecine unconditionally, skipping detection entirely
transcode-monster.sh --force-ivtc "/path/to/source/"

# Disable telecine detection entirely (treat as plain interlaced/progressive)
transcode-monster.sh --no-pulldown "/path/to/source/"

# Constant-frame-rate IVTC for uniformly telecined film
transcode-monster.sh --ivtc-mode fixed "/path/to/source/"

# Exhaustive matching for stubborn mixed-cadence anime
transcode-monster.sh --fieldmatch-mode pcn_ub "/path/to/source/"
```

`--pulldown MODE` is the explicit form of the first three: `auto` detects and
decides (default), `scan` detects even on non-NTSC rates, `always` skips
detection and always inverse-telecines, `never` skips detection and never does.
`--scan-ivtc`, `--force-ivtc` and `--no-pulldown` are shorthand for `scan`,
`always` and `never` respectively.

### Crop Detection

Automatically detects and removes black bars:

- Samples at 25%, 50%, 75% through file
- Uses the least aggressive crop (preserves most content)
- Rounds dimensions to 16-pixel boundaries for encoder efficiency
- Forces crop **offsets** to even values, so chroma siting and field parity stay
  correct on 4:2:0 sources (an odd offset would shift color planes or swap fields)

Disable if needed:
```bash
transcode-monster.sh --no-crop "/path/to/source/"
```

## Deinterlacing Options

Two different problems get two different treatments, chosen automatically:

- **Telecined film** (3:2 pulldown) is *inverse-telecined* — the original
  progressive frames are reconstructed and the duplicates dropped (see
  [Telecine Detection](#telecine-detection-32-pulldown)). This is the right path
  for film and most animation.
- **True interlaced video** (camera-original 50i/60i) is *deinterlaced* with one
  of the filters below, since there are no progressive frames to recover.

The filter choice (`--deinterlacer`) and output rate (`--deinterlace-rate`) below
govern the **deinterlace** path; telecined film is handled by `--ivtc-mode`.

### Filter Selection (`--deinterlacer`)

`auto` (default) profiles the source with a single `idet` pass and chooses from
the fraction of frames showing combing, which serves as a motion proxy:

- **At or above `AUTO_DEINT_MOTION_PCT` (85%)** — nnedi. Near-total combing means
  the whole frame is in motion: a pan, a scroll, or a camera move. A
  motion-adaptive filter decides between a temporal and a spatial estimate by
  comparing co-located pixels across fields, and under global motion those pixels
  always differ, so the temporal estimate is rejected on every pixel and the
  filter degrades into a plain spatial interpolator. nnedi is a considerably
  better spatial interpolator, so it wins outright in this regime.
- **Below the threshold** — bwdif. Where the image is static or slow-moving, the
  opposite field holds the true missing scanlines, and bwdif's temporal path
  reconstructs them exactly rather than guessing. nnedi never uses temporal data,
  so it can only approximate what bwdif recovers verbatim.

Both filters produce a valid result, so override the choice with `--deinterlacer`
whenever you disagree with it. If nnedi is unavailable or its weights can't be
fetched, selection falls back to bwdif and then yadif; a missing filter never
aborts a run.

The combing percentage serves as the motion proxy, which holds only while the
combing is strong enough to detect. A transfer with faint combing reads as low
motion however much movement it contains. The script measures at both standard
and high sensitivity and reports the gap when the two diverge:

```
Faint combing (3% at standard detection, 51% at high sensitivity)
Motion estimate unreliable — if edges look blocky, try --deinterlacer nnedi
```

bwdif is selected in that case. Check the result: blockiness or stair-stepping
along near-horizontal edges means bwdif is the wrong fit for the source, and nnedi
renders those edges cleanly.

### Choosing a Filter Manually

**bwdif** — motion-adaptive, blending a temporal and a spatial estimate per
pixel. The right choice for grainy, noisy or heavily compressed sources, and for
material with long static or slow-moving takes. Its failure mode is softness.

**nnedi** — a neural-network spatial interpolator that never consults
neighbouring fields. Best on clean, motion-dominated material such as animation
with pans and vertical scrolls, where no usable temporal reference exists anyway.
It reconstructs near-horizontal edges far better than a short-kernel filter,
which is what removes the stair-stepping that crawls frame to frame during a
scroll. Being a learned edge predictor, it will also extend compression blocking
and grain as though they were real detail, making it a poor fit for dirty
sources. Slower than bwdif, though at SD resolution rarely the bottleneck.

**yadif** — older and faster, slightly softer than bwdif. Useful for quick
previews and as a fallback where bwdif is unavailable.

### Deinterlacing Scope (`--adaptive-deinterlace`)

By default every frame of an interlaced source is deinterlaced. Deinterlacing is
lossy by nature — it keeps one field and reconstructs the other — so on a source
that is only occasionally interlaced, the progressive majority is softened for no
benefit. `--adaptive-deinterlace` restricts the filter to the frames that are
actually interlaced, leaving the rest untouched.

Which frames count as interlaced is decided from the picture. The adaptive chain
runs `idet` ahead of the deinterlacer to detect combing directly, because the
flags an encoder writes into the bitstream are unreliable: MPEG-2 encoders
routinely mark a picture progressive while its content is two interleaved fields,
and budget transfers sometimes mark every picture progressive.

How faint a combing pattern `idet` will notice is set by
`--adaptive-intl-thres` (default 1.04, ffmpeg's own). Lower values catch subtler
combing at the cost of processing more frames. Transfers whose combing is weak —
common on budget DVD releases and on video that has been through a resize — can
need 1.01 or below before detection registers anything at all. If a source looks
combed in motion but the script reports a low interlaced percentage, sweep the
value downward:

```bash
ADAPTIVE_INTL_THRES=1.005 transcode-monster.sh --adaptive-deinterlace "/path/to/source/"
# or
transcode-monster.sh --adaptive-deinterlace --adaptive-intl-thres 1.005 "/path/to/source/"
```

How much a source gains from this varies within a title as well as between discs,
so decide it per disc from a test encode.

When a source clears the interlacing threshold but is mostly progressive, the
script points it out:

```
Interlacing: tff (7% interlaced, 91% progressive, 0% undetermined)
    Note: mostly progressive — if output looks soft, retry with --adaptive-deinterlace
```

Encode one episode, look at it, and decide. Soft throughout means add the option;
combing after adding it means detection is missing frames, so lower
`--adaptive-intl-thres` before giving up on it.

### Output Rate (`--deinterlace-rate`)

Interlaced video carries two distinct fields per frame, so it can be
deinterlaced to either single or double frame rate:

- `auto` (default): field rate for NTSC-family video (60i → 60p, preserving the
  motion in true interlaced video) and frame rate for PAL/unknown sources (to
  avoid double-bobbing 25PsF film that was flagged interlaced). Field rate is
  withheld regardless of source rate when the field order could not be verified
  as consistent, or when the source was classified film-interlaced — bobbing film
  reconstructs each drawing twice from alternating single fields, which shimmers,
  and bobbing at an uncertain field order judders.
- `field`: always double-rate (e.g. 60p) — smoothest motion for real video.
- `frame`: always single-rate (e.g. 30p) — half the frames, for compatibility or
  size.

This only affects the deinterlace path; telecined film is set to its film rate by
`--ivtc-mode`, independent of this setting.

### Examples

```bash
# Automatic filter selection (default)
transcode-monster.sh "/path/to/source/"

# Force nnedi (clean, motion-heavy source such as animation with scrolls)
transcode-monster.sh --deinterlacer nnedi "/path/to/source/"

# Force bwdif (grainy, noisy or heavily compressed source)
transcode-monster.sh --deinterlacer bwdif "/path/to/source/"

# Force deinterlacing on misdetected progressive content
transcode-monster.sh --force-deinterlace "/path/to/source/"

# Deinterlace only frames flagged interlaced (for mostly-progressive sources)
transcode-monster.sh --adaptive-deinterlace "/path/to/source/"

# Force single-rate output when deinterlacing true video
transcode-monster.sh --deinterlace-rate frame "/path/to/source/"
```

## Series Organization

### Directory Naming Conventions

For optimal automatic detection, organize ripped discs using this structure:

**Format**: `S{season}D{disc}` where season and disc are numbers

**Single Season Series**:
```
/path/to/Firefly/
├── S1D1/          # Season 1, Disc 1
├── S1D2/          # Season 1, Disc 2
└── S1D3/          # Season 1, Disc 3
```

**Multi-Season Series**:
```
/path/to/The Venture Bros./
├── S1D1/          # Season 1, Disc 1
├── S1D2/          # Season 1, Disc 2
├── S1D3/          # Season 1, Disc 3
├── S2D1/          # Season 2, Disc 1
├── S2D2/          # Season 2, Disc 2
├── S2D3/          # Season 2, Disc 3
├── S3D1/          # Season 3, Disc 1
└── S3D2/          # Season 3, Disc 2
```

**Alternative Formats** (also supported):
```
/path/to/Breaking Bad/
├── Season 1/Disc 1/
├── Season 1/Disc 2/
├── Season 2/Disc 1/
└── Season 2/Disc 2/
```

**Flat directories (season in the filename)**:

A folder with no disc/season subdirectories is fine too; the season and episode
are read from the filenames, so a single pool of mixed-season files is split
correctly:
```
/path/to/Darkwing Duck/
├── Darkwing_Duck_S01_E01.mkv   # → S01E01
├── ...
├── Darkwing_Duck_S01_E28.mkv   # → S01E28
├── Darkwing_Duck_S02_E01.mkv   # → S02E01   (not lumped into season 1)
└── Darkwing_Duck_S02_E27.mkv   # → S02E27
```
Recognized filename tags include `S02E05`, `S02_E05`, `S02.E05`, `2x05`, and
`Season 2` / `Series 2`. The season and episode may be written together
(`S02E05`) or split by a space, underscore, dot, or hyphen (`S02_E05`); both
parse identically, and single-digit forms like `S2E5` work too. Guards prevent
resolutions like `1920x1080` from being misread as a season.

**Mixed layouts** are handled in a single pass: some seasons can live as a flat
pool of files while others are split across `S#D#` disc directories. Each file is
assigned to a season by its own name first, then its containing directory, then
the season being processed.

**Inside Each Disc Directory**:
```
S1D1/
├── title_t00.mkv  # Episode 1
├── title_t01.mkv  # Episode 2
├── title_t02.mkv  # Episode 3
└── title_t03.mkv  # Episode 4
```

The script automatically:
- Detects season numbers from filenames, then disc/season directory names
- Sorts episodes by disc, then by episode number
- Numbers episodes by their parsed value when those are unambiguous (so a season
  with a missing episode keeps its canonical numbering), falling back to
  sequential position when numbers are absent, duplicated, or synthetic (e.g.
  several chapter-split discs that each restart at 1)

### Output Naming

```
The Venture Bros. - S01E01.mkv
The Venture Bros. - S01E02.mkv
The Venture Bros. - S01E03.mkv
...
The Venture Bros. - S02E01.mkv
The Venture Bros. - S02E02.mkv
...
```

### Multi-Episode Files

For files with multiple episodes marked by chapters:

```bash
# Auto-detect (splits when the chapters form a repeating episodic structure)
transcode-monster.sh "/path/to/source/"

# Force chapter splitting
transcode-monster.sh --split-chapters "/path/to/source/"

# Specify episodes per file (e.g., 2 episodes per file)
transcode-monster.sh --chapters-per-episode 2 "/path/to/source/"
```

## Encoder Selection

### Automatic (Default)

The script stays on **hardware (hevc_vaapi)** wherever it can — VAAPI is far
faster and, on modern AMD, very efficient — and only falls back to **software
(libx265)** when the hardware genuinely can't encode the source. The fallback
triggers are capability blockers, not quality preferences:

- **Bit depth the GPU can't encode** (e.g. 12-bit, or 10-bit on a backend
  `vainfo` reports no support for)
- **Non-4:2:0 chroma** (4:2:2 / 4:4:4), which AMD/Intel HEVC encoders don't take
- **`dvvideo`** and similar formats that have no usable hardware path

Resolution and color metadata don't affect encoder choice: SD encodes on
hardware as readily as HD, and color is handled by tagging the output (see
[Color Space](#color-space)) rather than by switching encoders. Interlaced and
telecined sources also stay on hardware — the deinterlace/IVTC filtering runs on
the CPU *before* the frames are uploaded to the GPU, so the encode itself is
still hardware.

### Manual Override

```bash
# Force software encoding (highest quality)
transcode-monster.sh --codec libx265 "/path/to/source/"

# Force hardware encoding (fastest)
transcode-monster.sh --codec hevc_vaapi "/path/to/source/"
```

### Hardware Encoding Quality

VAAPI compression level (0-7, default 4):

This parameter controls encoder effort. On **Intel VAAPI**, it has a meaningful
impact on compression efficiency. On **AMD VAAPI** (RDNA 3/4, Mesa 25.2+), it
produces a marginal but measurable improvement (~1%); on older Mesa it is
effectively a no-op. On other VAAPI backends, behavior is driver-dependent.

```bash
# Faster, larger files
transcode-monster.sh --compression-level 0 "/path/to/source/"

# Slower, smaller files
transcode-monster.sh --compression-level 7 "/path/to/source/"
```

## Quality Settings

### Recommended CRF/CQP Values

**8-bit encoding**:
- Archival quality: 18-19
- High quality: 20-21
- Standard quality: 22-23

**10-bit encoding** (recommended, default):
- Archival quality: 20-21
- High quality: 22-23
- Standard quality: 24-25

**12-bit encoding**:
- Archival quality: 22-23
- High quality: 24-25
- Standard quality: 26-27

### Why 10-bit?

Enabled by default (`UPGRADE_8BIT_TO_10BIT="true"`):
- Better quality with less banding
- 10-15% smaller files at same quality
- No visible quality loss
- Wide device compatibility

## Audio Options

### Language Filtering

Keep only specific languages:

```bash
# English only (default)
transcode-monster.sh --language eng "/path/to/source/"

# Multiple languages
transcode-monster.sh --language "eng,spa,fra" "/path/to/source/"

# Keep all audio tracks
transcode-monster.sh --all-audio "/path/to/source/"
```

### Original Language Mode

For anime or foreign content:

```bash
# Prefer Japanese audio + English subs
transcode-monster.sh --original-lang jpn "/path/to/anime/"
```

This selects:
- Original language audio (jpn) as default
- Default language (eng) subtitles
- Skips foreign dubs

### Secondary Track Passthrough

The primary audio track is always copied as-is. For secondary tracks, anything
already in an efficient lossy format is copied untouched rather than re-encoded
to HE-AAC; re-encoding lossy audio into another lossy codec compounds
generational quality loss while saving little or no space. By default this
covers Opus, AAC, MP3, and Vorbis:

```bash
AUDIO_PASSTHROUGH_CODECS="opus aac mp3 vorbis"
```

Values are ffprobe `codec_name` strings, space-separated. Space-heavy lossy
formats (`ac3`, `eac3`, `dts`) are deliberately omitted so they still get
downsized to HE-AAC; add them to the list if you'd rather keep them bit-for-bit.
Lossless secondary tracks (FLAC, TrueHD, DTS-HD, PCM) are intentionally absent:
they're meant to be re-encoded.

### Subtitle Selection

Subtitles in `LANGUAGE` are kept and converted to MKV-compatible formats. Which
track gets enabled by default depends on the audio language of the file:

- **Foreign audio** (e.g. a Japanese film, or `--original-lang` mode): a *full*
  subtitle track is enabled by default so all dialogue is translated. A
  forced-only track is used only as a fallback if no full track exists.
- **Native audio** (audio already in `LANGUAGE`): full subtitles are *not*
  auto-enabled, but a *forced/signs* track is (with disposition `default+forced`)
  so compliant players show it even when subtitles are otherwise off. This keeps
  intentional foreign-language scenes and on-screen signage legible. A good
  example is the film *Revolver*, which has whole scenes in Mandarin that were
  meant to be translated; without the forced track those scenes play untranslated.
  Disable with `FORCED_SUBS_ON_NATIVE_AUDIO="false"`.

A track is classified as forced, cheapest check first:

1. The `forced` disposition flag (authoritative when the muxer set it).
2. The title tag matching `forced`, `signs`, or `songs` (case-insensitive).
3. Cue density: forced tracks light up only a handful of times per film, full
   tracks run continuously. This fallback only runs when steps 1-2 are silent and
   `SUBTITLE_FORCED_DETECT_DENSITY="true"`. It reads the container's cue-count
   metadata (the `NUMBER_OF_FRAMES` statistics tag that mkvmerge and MakeMKV
   write), so it is instant and adds no measurable cost to a normal run. Tune the
   boundary with `SUBTITLE_FORCED_MAX_EVENTS_PER_MIN` (default `3`). For the rare
   long file that lacks cue-count metadata, density is skipped by default rather
   than demuxing a multi-gigabyte stream; set `SUBTITLE_FORCED_DEEP_SCAN="true"`
   to count cues by demuxing instead (accurate, but slow on large network sources,
   and it prints a heads-up while it works).

Note: the forced track must be tagged in `LANGUAGE` (or matched by the language
filter) to be picked up. Properly authored discs tag forced tracks with the
correct language; a forced track tagged `und` with no flag/title won't be
detected.

**Untagged tracks**: sources with no language metadata at all (common on DVD/VOB,
MPEG-PS/TS, and AVI rips) report an empty language rather than `und`. Both the
audio and subtitle language filters treat an empty tag as `und` and keep the
track, so untagged secondary audio and subtitle streams aren't silently dropped.

## Advanced Options

### Process Specific Episodes

```bash
# Process only season 2
transcode-monster.sh -s 2 "/path/to/source/" "/output/"

# Process only season 1, episode 3
transcode-monster.sh -s 1 -e 3 "/path/to/source/" "/output/"
```

### B-frames

Control B-frame count (0-4+):

```bash
# Maximum compatibility
transcode-monster.sh -b 0 "/path/to/source/"

# Best compression (libx265 only)
transcode-monster.sh -b 4 "/path/to/source/"
```

> **AMD HEVC hardware encoding note:** `-b`/`BFRAMES` is **silently ignored**
> by `hevc_vaapi` on all AMD GPUs. This is a hardware-level limitation present
> across all VCN generations (VCN 1 through 5, covering every GPU up to and
> including RDNA 4). B-frames only take effect with `libx265` (software
> encoding).

### x265 Tuning (Software Encoding)

```bash
# Optimize for low-power playback devices
transcode-monster.sh --tune fastdecode "/path/to/source/"

# Preserve film grain
transcode-monster.sh --tune grain "/path/to/source/"

# Optimize for animation
transcode-monster.sh --tune animation "/path/to/source/"
```

### Color Space

Override automatic color space detection:

```bash
# Preserve HDR metadata (HDR10, HLG, BT.2020)
transcode-monster.sh --colorspace hdr "/path/to/uhd/"

# Force BT.709 (HD)
transcode-monster.sh --colorspace bt709 "/path/to/source/"

# Force BT.601 (SD)
transcode-monster.sh --colorspace bt601 "/path/to/source/"

# Disable conversion (use source as-is)
transcode-monster.sh --colorspace none "/path/to/source/"
```

**Note**: HDR content is automatically detected and preserved - manual override is rarely needed.

**Untagged sources**: when a source carries no color metadata at all (common on
DVD and older rips), the script tags the **output** with the correct standard by
convention — BT.601 for SD (`smpte170m` for ≤480-line, `bt470bg` for 576-line)
and BT.709 for HD — so players render colors correctly instead of guessing. This
is a metadata tag on the output, not a conversion of the pixels, so it costs
nothing to apply and has no bearing on which encoder is used.

## Troubleshooting

### Content Detected as Progressive but Has Combing

Force deinterlacing:
```bash
transcode-monster.sh --force-deinterlace "/path/to/source/"
```

### Deinterlacer Leaves Artifacts

Which filter to reach for depends on the artifact. Stair-stepping or a crawling
pattern along near-horizontal edges, most visible during pans and vertical
scrolls, is spatial interpolation failing — use nnedi:
```bash
transcode-monster.sh --deinterlacer nnedi "/path/to/source/"
```

Ringing or halos around high-contrast edges, or noise and compression blocking
being sharpened into detail, is nnedi over-predicting on a dirty source — use
bwdif:
```bash
transcode-monster.sh --deinterlacer bwdif "/path/to/source/"
```

Uniform softness on a source that is mostly progressive means the deinterlacer is
processing frames that didn't need it. Limit it to the frames that do:
```bash
transcode-monster.sh --adaptive-deinterlace "/path/to/source/"
```

If that leaves combing behind instead, the source's per-frame flags are wrong and
every frame has to be processed — drop the option again.

### Telecine Detection Issues

Disable telecine detection for purely interlaced content:
```bash
transcode-monster.sh --no-pulldown "/path/to/source/"
```

Scan for telecine when the rate prior skips a source you know is telecined
(e.g. a PAL or oddly-flagged film master):
```bash
transcode-monster.sh --scan-ivtc "/path/to/source/"
```

Force inverse telecine unconditionally when detection reports "true interlaced
video" on a source you know is film. The giveaway is a source that is combed on
nearly every frame yet plays smoothly, and a trial fieldmatch line showing a big
drop in residual combing that still doesn't reach zero:
```bash
transcode-monster.sh --force-ivtc "/path/to/source/"
# equivalently
transcode-monster.sh --pulldown always "/path/to/source/"
```

Stray combing on a mixed film/video disc (anime OVAs especially): the inverse
telecine reconstructs the film cleanly, but genuinely interlaced video/effects
shots can leave a few combed frames the field matcher can't invert. Two things to
try — switch to constant-rate decimation so those frames don't linger, and/or use
the exhaustive matcher:
```bash
transcode-monster.sh --ivtc-mode fixed "/path/to/source/"
transcode-monster.sh --fieldmatch-mode pcn_ub "/path/to/source/"
```
If a particular disc is mostly true interlaced video rather than film, it may be
better handled by disabling pulldown and deinterlacing it outright
(`--no-pulldown`).

### Crop Detection Too Aggressive

Disable automatic crop:
```bash
transcode-monster.sh --no-crop "/path/to/source/"
```

### Hardware Encoding Has Artifacts

Force software encoding:
```bash
transcode-monster.sh --codec libx265 "/path/to/source/"
```

### I Want To Do a Custom, Weird, One-Off

If the script doesn't handle some 0.001% edge-case, you can still use it to do the hard work and build the bulk of your `ffmpeg` command for you with the `--dry-run` option:
```
transcode-monster.sh --dry-run "/path/to/special-one-off/"
```
Then just copy the resulting `ffmpeg` command and adjust as needed.

### Washed Out Colors on UHD/HDR Content

This typically indicates Dolby Vision content being transcoded:

**Problem**: Dolby Vision uses enhancement layers and metadata that cannot be preserved during re-encoding. Only the HDR10 base layer remains, which may look washed out.

**Detection**: The script will warn "Dolby Vision detected - will be stripped during transcoding"

**Solutions**:
1. **Keep the original** - Best option if you have DV-capable playback
2. **Accept the HDR10 output** - Still HDR, but not as vibrant as DV
3. **Use specialized tools** - Advanced users can use `dovi_tool` to extract/inject RPU metadata (complex)

**Note**: Neither VAAPI nor x265 can preserve Dolby Vision during transcoding. This is a limitation of the encoding process, not the script.

### Episode Numbering Issues

For complex cases, manually specify:
```bash
# Set content name
transcode-monster.sh -n "Show Name" "/path/to/source/"

# Set specific season
transcode-monster.sh -s 1 "/path/to/source/"
```

## Configuration Reference

Full list of config file options (`~/.config/transcode-monster.conf`):

```bash
# Video encoding
VIDEO_CODEC="auto"              # auto, hevc_vaapi, libx265
QUALITY="20.6"                  # CRF/CQP value
PRESET="medium"                 # x265 preset
X265_TUNE=""                    # fastdecode, grain, animation, etc.
BFRAMES="4"                     # Number of B-frames
DEINTERLACER="auto"            # auto (profile the source and pick), bwdif, nnedi, yadif
AUTO_DEINT_MOTION_PCT=85       # combed% at or above which auto selects nnedi
DEINTERLACE_RATE="auto"        # auto, field, frame (deinterlace path only)

# Hardware encoding
VAAPI_DEVICE="/dev/dri/renderD128"
VAAPI_COMPRESSION_LEVEL="4"    # 0-7 for Intel VAAPI

# Bit depth
UPGRADE_8BIT_TO_10BIT="true"
DOWNGRADE_12BIT_TO_10BIT="false"

# Audio
AUDIO_CODEC="libfdk_aac"
AUDIO_PROFILE="aac_he"
AUDIO_FILTER_LANGUAGES="true"
AUDIO_PASSTHROUGH_CODECS="opus aac mp3 vorbis"  # Secondary tracks in these formats are copied, not re-encoded

# Language
LANGUAGE="eng"
PREFER_ORIGINAL="false"
ORIGINAL_LANGUAGE=""            # e.g., "jpn" for anime

# Subtitles
FORCED_SUBS_ON_NATIVE_AUDIO="true"      # Auto-enable forced/signs subs when audio is already native
SUBTITLE_FORCED_DETECT_DENSITY="true"   # Use cue-density fallback when the forced flag/title are absent
SUBTITLE_FORCED_MAX_EVENTS_PER_MIN="3"  # Below this cues/min => treated as forced/signs
SUBTITLE_FORCED_DEEP_SCAN="false"       # Demux long files lacking cue-count metadata to count cues (slow; off by default)

# Processing
DETECT_INTERLACING="true"
ADAPTIVE_DEINTERLACE="false"
ADAPTIVE_INTL_THRES="1.04"     # idet sensitivity for --adaptive-deinterlace; lower catches fainter combing
FORCE_DEINTERLACE="false"
DETECT_CROP="true"
DETECT_PULLDOWN="auto"         # auto (detect at any resolution), true (scan even
                               # when the rate prior would skip), always (skip
                               # detection, always inverse telecine), false
IVTC_MODE="adaptive"           # adaptive (mpdecimate + VFR), fixed (decimate + 23.976 CFR)
FIELDMATCH_MODE="pc_n"         # pc_n (standard), pcn_ub (exhaustive match)
SPLIT_CHAPTERS="auto"          # auto, true, false

# Output
OUTPUT_DIR="${HOME}/Videos"
OVERWRITE="false"
COLORSPACE="auto"              # auto, bt709, bt601, hdr, none
BULK_MOVIES="false"            # Process all movies in directory

# Process priority
USE_NICE="true"
NICE_LEVEL="10"
USE_IONICE="true"
IONICE_CLASS="2"
IONICE_LEVEL="4"
```

## Examples

### Standard TV Series

```bash
transcode-monster.sh "/mnt/rips/Firefly/" "/mnt/media/TV/Firefly/"
```

### UHD / HDR Movie

```bash
transcode-monster.sh -t movie "/mnt/rips/Ghost in the Shell/" "/mnt/media/Movies/"
# HDR10/HLG automatically detected and preserved
```

### Bulk Movie Processing

```bash
transcode-monster.sh --bulk-movies "/mnt/rips/Star Wars/Laserdisc/" "/mnt/media/Movies/"
# Processes all 6 Star Wars movies automatically
```

### Series with Year (for Reboots/Disambiguation)

```bash
transcode-monster.sh -n "The Twilight Zone" -y 1959 "/mnt/rips/TZ/" "/mnt/media/TV/"
# Output: The Twilight Zone (1959) - S01E01.mkv
```

### Anime Series (Japanese Audio, English Subs)

```bash
transcode-monster.sh --original-lang jpn "/mnt/rips/Cowboy Bebop/" "/mnt/media/Anime/"
```

### Noisy Broadcast Tape Source

```bash
transcode-monster.sh --deinterlacer nnedi "/mnt/rips/The Maxx/" "/mnt/media/TV/"
```

### Movie with Custom Quality

```bash
transcode-monster.sh -t movie -n "Blade Runner" -y 1982 -q 18 "/mnt/rips/blade_runner/" "/mnt/media/Movies/"
```

### Process Specific Season

```bash
transcode-monster.sh -s 2 "/mnt/rips/Breaking Bad/" "/mnt/media/TV/Breaking Bad/"
```

### High Quality Archival

```bash
transcode-monster.sh -q 18 --codec libx265 --tune grain "/mnt/rips/Lawrence of Arabia/" "/mnt/archive/"
```

### Quick Preview (Dry Run)

```bash
transcode-monster.sh -e 1 -d "/mnt/rips/New Show/" "/tmp/preview/"
```

## Tips & Best Practices

1. **Use dry run first** (`-d`) to verify detection
2. **Start with defaults** - they work well for most content
3. **Use nnedi sparingly** - only for noisy/difficult sources
4. **Test one episode** (`-e 1`) before processing entire series
5. **Keep 10-bit enabled** - better quality, smaller files
6. **Let auto-detection work** - manual overrides rarely needed
7. **Use config file** for persistent preferences
8. **Check output quality** on first few episodes before batch processing

## Detailed Requirements

- **bash** for advanced error handling
- **ffmpeg** with libx265, libfdk_aac
- **ffprobe** (included with ffmpeg)
- **bc** (for calculations)
- **Optional**: VAAPI drivers for hardware encoding
- **Optional**: the `nnedi` filter, for `--deinterlacer nnedi`. It's built into
  FFmpeg (no special filter flag); distro builds configured with `--enable-gpl`
  include it. The script downloads the required `nnedi3_weights.bin` on first use.

## License

MIT License - See script header for full text

## Support

For issues or questions, check the script's `--help` output or review detection results with `--dry-run`.
