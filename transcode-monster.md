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
- **Hybrid encoding**: Intelligently chooses hardware (VAAPI) or software (x265) encoding
- **Smart deinterlacing**: Automatically detects and removes interlacing with multiple filter options
- **Color space handling**: Preserves HDR, converts legacy formats (BT.601 for SD, BT.709 for HD)
- **Multi-episode files**: Automatically splits by chapters for disc rips with multiple episodes
- **Audio/subtitle management**: Language filtering, format conversion, disposition handling
- **Configurable**: Config file + CLI arguments for full control

## Dependencies
- `bash` - The script is written in bash for simplicity, and we use its built-in error handling
- `bc` - For doing advanced things like automatically calculating whether or not a series is broken up by chapter or by file
- `ffmpeg` - The latest version available to you, e.g. with a rolling distro like `arch` or utilizing the [deb-multimedia](https://www.deb-multimedia.org/) repository for Debian.
- `VA-API`_(optional)_ -  Use your GPU to give you a massive encoding speedup (usually available through packages like `mesa-va-drivers` or `va-driver-all`)

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

Create `~/.config/transcode-monster.conf` for persistent settings:

```bash
# Video quality (CRF/CQP value - lower = better quality)
QUALITY="20.6"

# Deinterlacer preference (bwdif, nnedi, yadif)
DEINTERLACER="bwdif"

# Default language for audio/subtitles
LANGUAGE="eng"

# Upgrade 8-bit sources to 10-bit (recommended)
UPGRADE_8BIT_TO_10BIT="true"
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
- **Recommendation**: Keep original files for DV playback on compatible devices

If you have Dolby Vision-capable playback (Apple TV 4K, LG OLED, etc.), consider keeping the original file rather than transcoding.

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

### Noisy Broadcast Sources

Use nnedi deinterlacer for heavily compressed or noisy sources:

```bash
transcode-monster.sh --deinterlacer nnedi "/path/to/The Maxx/" "/output/"
```

### Film with Interlaced Elements

Use adaptive deinterlacing for mixed progressive/interlaced content:

```bash
transcode-monster.sh --adaptive-deinterlace "/path/to/movie.mkv" "/output/"
```

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

## Understanding Automatic Detection

### Interlacing Detection

The script samples frames at multiple points to detect interlacing:

- **Progressive**: 0-5% interlaced → No deinterlacing
- **Interlaced**: >5% interlaced → Applies deinterlacer
- **Threshold**: 5% ensures even partially interlaced content is handled

### Telecine Detection (3:2 Pulldown)

For SD content (≤576p), checks for telecine patterns:

- **Repeated fields**: >10% indicates pulldown
- **Interlacing percentage**: <50% confirms it's telecine (not just noisy interlaced)
- **Action**: Uses inverse telecine (fieldmatch+yadif+decimate)

Override if needed:
```bash
# Force telecine removal
transcode-monster.sh --force-ivtc "/path/to/source/"

# Disable telecine detection
transcode-monster.sh --no-pulldown "/path/to/source/"
```

### Crop Detection

Automatically detects and removes black bars:

- Samples at 25%, 50%, 75% through file
- Uses the least aggressive crop (preserves most content)
- Rounds to 16-pixel boundaries for encoder efficiency

Disable if needed:
```bash
transcode-monster.sh --no-crop "/path/to/source/"
```

## Deinterlacing Options

### When to Use Each Filter

**bwdif (default)**:
- Best for most content
- Fast, sharp results
- Good balance of quality and speed
- Preserves fine details well

**nnedi (neural network)**:
- Best for noisy broadcast sources
- Heavily compressed video with artifacts
- Sources where bwdif leaves residual combing
- Slower, but handles difficult content better

**yadif**:
- Fast, widely compatible
- Good for quick previews
- Slightly less quality than bwdif

### Examples

```bash
# Use default (bwdif)
transcode-monster.sh "/path/to/source/"

# Use nnedi for noisy source
transcode-monster.sh --deinterlacer nnedi "/path/to/source/"

# Force deinterlacing on misdetected progressive content
transcode-monster.sh --force-deinterlace "/path/to/source/"

# Adaptive mode (only deinterlace interlaced frames)
transcode-monster.sh --adaptive-deinterlace "/path/to/source/"
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

**Inside Each Disc Directory**:
```
S1D1/
├── title_t00.mkv  # Episode 1
├── title_t01.mkv  # Episode 2
├── title_t02.mkv  # Episode 3
└── title_t03.mkv  # Episode 4
```

The script automatically:
- Detects season/disc numbers from directory names
- Sorts episodes by filename
- Numbers episodes sequentially across all discs

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
# Auto-detect chapters (files >60min)
transcode-monster.sh "/path/to/source/"

# Force chapter splitting
transcode-monster.sh --split-chapters "/path/to/source/"

# Specify episodes per file (e.g., 2 episodes per file)
transcode-monster.sh --chapters-per-episode 2 "/path/to/source/"
```

## Encoder Selection

### Automatic (Default)

The script automatically chooses the best encoder:

- **Hardware (hevc_vaapi)**: HD content, simple characteristics
- **Software (libx265)**: SD content, needs color space conversion, complex processing

### Manual Override

```bash
# Force software encoding (highest quality)
transcode-monster.sh --codec libx265 "/path/to/source/"

# Force hardware encoding (fastest)
transcode-monster.sh --codec hevc_vaapi "/path/to/source/"
```

### Hardware Encoding Quality

Intel VAAPI compression level (0-7, default 4):

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
# Maximum compatibility (older AMD GPUs, Raspberry Pi)
transcode-monster.sh -b 0 "/path/to/source/"

# Best compression
transcode-monster.sh -b 4 "/path/to/source/"
```

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

## Troubleshooting

### Content Detected as Progressive but Has Combing

Force deinterlacing:
```bash
transcode-monster.sh --force-deinterlace "/path/to/source/"
```

### Deinterlacer Leaves Artifacts

Try nnedi for difficult sources:
```bash
transcode-monster.sh --deinterlacer nnedi "/path/to/source/"
```

### Telecine Detection Issues

Disable telecine detection for purely interlaced content:
```bash
transcode-monster.sh --no-pulldown "/path/to/source/"
```

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
DEINTERLACER="bwdif"           # bwdif, nnedi, yadif

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

# Language
LANGUAGE="eng"
PREFER_ORIGINAL="false"
ORIGINAL_LANGUAGE=""            # e.g., "jpn" for anime

# Processing
DETECT_INTERLACING="true"
ADAPTIVE_DEINTERLACE="false"
FORCE_DEINTERLACE="false"
DETECT_CROP="true"
DETECT_PULLDOWN="auto"         # auto, true, false
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
- **Optional**: nnedi filter in ffmpeg (compile with `--enable-libnnedi`)

## License

MIT License - See script header for full text

## Support

For issues or questions, check the script's `--help` output or review detection results with `--dry-run`.
