#!/bin/bash

# Transcode Monster - Universal Video Transcoding Script
# Supports both single titles (movies) and series with automatic detection
# Usage: transcode-monster.sh [options] <source> [output_dir]
#
# MIT License
#
# Copyright (c) 2025 Chris Wadge
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail

SCRIPT_VERSION="1.17.11"

# ════════════════════════════════════════════════════════════════════════════
# DEFAULT SETTINGS (Priority 1: Built-ins)
# ════════════════════════════════════════════════════════════════════════════

# Script assets
CONFIG_FILE="${HOME}/.config/transcode-monster.conf"
NNEDI_WEIGHTS_DIR="${HOME}/.local/share/transcode-monster"
NNEDI_WEIGHTS_FILE="${NNEDI_WEIGHTS_DIR}/nnedi3_weights.bin"
NNEDI_WEIGHTS_SHA256="27f382430435bb7613deb1c52f3c79c300c9869812cfe29079432a9c82251d42"

# Hardware acceleration
DEFAULT_VAAPI_DEVICE="/dev/dri/renderD128"
DEFAULT_VAAPI_COMPRESSION_LEVEL="4"  # 0-7: Trade encoding speed for better compression (0=fast, 7=slow/small)

# Video encoding settings
DEFAULT_VIDEO_CODEC="auto"  # Will choose hevc_vaapi or libx265 based on resolution
DEFAULT_QUALITY="20.6"  # CQP/CRF value - optimized for 10-bit encoding (use 18-20 for 8-bit)
DEFAULT_PRESET="medium"  # For libx265 (software encoding only) - balanced speed/quality
DEFAULT_X265_POOLS="+"  # Thread pools for libx265: "+" = auto-detect optimal, or specify count (e.g., "4")
DEFAULT_X265_TUNE=""  # x265 tuning: "" (none), "fastdecode", "grain", "psnr", "ssim", "zerolatency"
DEFAULT_GOP_SIZE="120"
DEFAULT_MIN_KEYINT="12"
DEFAULT_BFRAMES="0"  # B-frames: only effective for libx265 (software encoding); ignored by hevc_vaapi on all AMD GPUs (hardware limitation, VCN 1-5)
DEFAULT_REFS="4"

# Process priority
DEFAULT_USE_NICE="true"
DEFAULT_NICE_LEVEL="10"  # 0-19, higher = lower priority
DEFAULT_USE_IONICE="true"
DEFAULT_IONICE_CLASS="2"  # 2 = best-effort
DEFAULT_IONICE_LEVEL="4"  # 0-7, higher = lower priority

# Output options
DEFAULT_OVERWRITE="false"  # Overwrite existing output files
DEFAULT_UPGRADE_8BIT_TO_10BIT="true"  # Upgrade 8-bit sources to 10-bit for better quality/compression
DEFAULT_DOWNGRADE_12BIT_TO_10BIT="false"  # Downgrade 12-bit sources to 10-bit for compatibility/speed
DEFAULT_COLORSPACE="auto"  # Color space: auto, bt709, bt601, hdr, or none (disable conversion)
DEFAULT_BULK_MOVIES="false"  # Process multiple movies in a directory instead of selecting longest

# Audio encoding settings
DEFAULT_AUDIO_COPY_FIRST="true"  # Copy first audio track
DEFAULT_AUDIO_CODEC="libfdk_aac"
DEFAULT_AUDIO_PROFILE="aac_he"
DEFAULT_AUDIO_BITRATE_MONO="96k"     # HE-AAC transparent for mono
DEFAULT_AUDIO_BITRATE_STEREO="128k"  # HE-AAC transparent for stereo
DEFAULT_AUDIO_BITRATE_SURROUND="192k" # HE-AAC for 5.1
DEFAULT_AUDIO_BITRATE_SURROUND_PLUS="256k" # HE-AAC for 7.1+
DEFAULT_AUDIO_FILTER_LANGUAGES="true"  # Filter audio by language (skip foreign overdubs)
# Secondary audio tracks already in one of these efficient lossy formats are copied
# through untouched rather than re-encoded to HE-AAC. Re-encoding lossy->lossy only
# compounds generational loss while saving little or no space. Space-heavy lossy
# formats (ac3, eac3, dts) are deliberately left off so they still get downsized;
# add them here if you'd rather keep those bit-for-bit. Lossless sources (flac,
# truehd, dts-hd, pcm) are never on this list — they're meant to be re-encoded.
DEFAULT_AUDIO_PASSTHROUGH_CODECS="opus aac mp3 vorbis"  # Space-separated ffprobe codec_name values

# Language and subtitle settings
DEFAULT_LANGUAGE="eng"  # ISO 639-2 code(s), comma-separated for multilingual (e.g., "eng,spa,fra")
# First language in list has priority for subtitle selection
DEFAULT_PREFER_ORIGINAL="false"  # When true, prefer original audio + native subs over dubs
DEFAULT_ORIGINAL_LANGUAGE=""  # Set this for original language mode (e.g., "jpn" for anime)
# Forced/signs subtitle handling. When the default audio is already in the viewer's
# language we don't want full subtitles, but films like "Revolver" have intentional
# foreign-language scenes (Mandarin) that were meant to be translated. Auto-enabling a
# forced/signs track keeps those scenes and on-screen signage legible.
DEFAULT_FORCED_SUBS_ON_NATIVE_AUDIO="true"  # Auto-enable a forced/signs sub when audio is already native
DEFAULT_SUBTITLE_FORCED_DETECT_DENSITY="true"  # If the forced flag and title are inconclusive, judge forced-vs-full by cue density. Uses the container's cue-count metadata (instant) when present; see DEEP_SCAN for files that lack it
DEFAULT_SUBTITLE_FORCED_MAX_EVENTS_PER_MIN="3"  # Density threshold: fewer cues/min than this => forced/signs, more => full
DEFAULT_SUBTITLE_FORCED_DEEP_SCAN="false"  # When a long file has no cue-count metadata, demux the whole subtitle stream to count cues. Accurate but slow on large files over a network share, so off by default

# Processing options
DEFAULT_COPY_ONLY="false"  # Remux mode: copy the source video and audio streams instead of re-encoding, while still selecting the right tracks, setting dispositions, and naming the output. For sources that are already well-encoded but badly mastered/named.
DEFAULT_DETECT_INTERLACING="true"
DEFAULT_ADAPTIVE_DEINTERLACE="false"  # Force adaptive deinterlacing for mixed content
DEFAULT_FORCE_DEINTERLACE="false"  # Force deinterlacing even on progressive content
DEFAULT_DEINTERLACER="bwdif"  # bwdif (default - best for most content), nnedi (best for noisy/difficult sources), yadif
DEFAULT_DEINTERLACE_RATE="auto"  # Output rate for the deinterlace path (telecined film is IVTC'd separately, so this only governs true interlaced video). auto = field-rate for NTSC-family video (60i→60p) and frame-rate for PAL/unknown (to avoid double-bobbing 25PsF film); field = always double-rate; frame = always single-rate
DEFAULT_DETECT_CROP="true"
DEFAULT_DETECT_PULLDOWN="auto"  # auto = detect at any resolution (was SD-only), true = force on, false = force off
DEFAULT_IVTC_MODE="adaptive"  # How to drop the pulldown-duplicated frames after inverse telecine. adaptive = mpdecimate + VFR output: drops only true duplicates, so cleanly-telecined film becomes 23.976 while interlaced-video/effects sections (common in anime OVAs) keep their unique frames at ~29.97 with no judder. fixed = classic decimate + 23.976 CFR: exact 1-in-5 drop, best for uniformly-telecined film and players that require constant frame rate, but judders on mixed-cadence sources
DEFAULT_FIELDMATCH_MODE="pc_n"  # fieldmatch matching thoroughness. pc_n (default) tries the current+next field combinations plus a 5th-field check. pcn_ub additionally tries the previous-field (u/b) combinations — the most exhaustive matcher, which reconstructs more frames across cadence breaks (fewer orphans left for the deinterlacer) at a slightly higher risk of a bad match. Useful on mixed-cadence anime that fights pc_n
DEFAULT_SPLIT_CHAPTERS="auto"  # auto = series files >60min, true = force on, false = force off
DEFAULT_CHAPTERS_PER_EPISODE="auto"  # auto = detect optimal grouping, or specify number

# Blu-ray disc processing
DEFAULT_BD_MIN_DURATION="900"  # Minimum duration in seconds (15 minutes) for m2ts files

# Output settings
DEFAULT_OUTPUT_DIR="${HOME}/Videos"
DEFAULT_CONTAINER="matroska"  # mkv
DEFAULT_INPUT_VIDEO_EXTENSIONS="mkv mp4 m4v avi mpg mpeg ts m2ts mov webm flv wmv asf vob ogv"  # Supported input formats
DEFAULT_FFMPEG_LOGLEVEL="warning"  # FFmpeg verbosity: quiet, panic, fatal, error, warning, info, verbose, debug
DEFAULT_FFMPEG_ANALYZEDURATION="120000000"  # Microseconds (2 minutes) - analyze input to determine codec params
DEFAULT_FFMPEG_PROBESIZE="128000000"  # Bytes (128MB) - amount of data to probe for stream info

# ════════════════════════════════════════════════════════════════════════════
# ERROR HANDLING
# ════════════════════════════════════════════════════════════════════════════

# Track what we're currently processing for better error messages
CURRENT_OPERATION=""
CURRENT_FILE=""

# Error handler function
error_handler() {
	local exit_code=$?
	local line_number=$1
	local failed_command="${2:-}"

	echo ""
	echo -e "${RED}════════════════════════════════════════════${RESET}"
	echo -e "${RED}ERROR: Script failed with exit code $exit_code${RESET}"
	echo -e "${RED}════════════════════════════════════════════${RESET}"
	echo -e "${RED}Line number: $line_number${RESET}"

	# Show the command that actually tripped the trap; turns a bare line number
	# into something diagnosable for failures we didn't anticipate.
	if [[ -n "$failed_command" ]]; then
		echo -e "${RED}Failed command: $failed_command${RESET}"
	fi

	if [[ -n "$CURRENT_OPERATION" ]]; then
		echo -e "${RED}Operation: $CURRENT_OPERATION${RESET}"
	fi

	if [[ -n "$CURRENT_FILE" ]]; then
		echo -e "${RED}File: $CURRENT_FILE${RESET}"
	fi

	echo ""

	exit $exit_code
}

# Interrupt handler for Ctrl+C
interrupt_handler() {
	echo ""
	echo -e "${YELLOW}Transcoding interrupted by user${RESET}"
	exit 130
}

# Set up traps
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR
trap 'interrupt_handler' INT

# ════════════════════════════════════════════════════════════════════════════
# TERMINAL SETUP
# ════════════════════════════════════════════════════════════════════════════

# Check if stdout is a terminal
if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	YELLOW=$'\033[1;33m'
	GREEN=$'\033[0;32m'
	BLUE=$'\033[0;34m'
	CYAN=$'\033[0;36m'
	BOLD=$'\033[1m'
	BOLDBLUE=$'\033[1;34m'
	BOLDGREEN=$'\033[1;32m'
	RESET=$'\033[0m'
else
	RED=''
	YELLOW=''
	GREEN=''
	BLUE=''
	CYAN=''
	BOLD=''
	BOLDBLUE=''
	BOLDGREEN=''
	RESET=''
fi

# ════════════════════════════════════════════════════════════════════════════
# LOAD USER CONFIG (Priority 2: User .conf)
# ════════════════════════════════════════════════════════════════════════════

if [[ -f "$CONFIG_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
fi

# Apply config values (if set)
VAAPI_DEVICE="${VAAPI_DEVICE:-$DEFAULT_VAAPI_DEVICE}"
VAAPI_COMPRESSION_LEVEL="${VAAPI_COMPRESSION_LEVEL:-$DEFAULT_VAAPI_COMPRESSION_LEVEL}"
VIDEO_CODEC="${VIDEO_CODEC:-$DEFAULT_VIDEO_CODEC}"
QUALITY="${QUALITY:-$DEFAULT_QUALITY}"
PRESET="${PRESET:-$DEFAULT_PRESET}"
X265_POOLS="${X265_POOLS:-$DEFAULT_X265_POOLS}"
X265_TUNE="${X265_TUNE:-$DEFAULT_X265_TUNE}"
GOP_SIZE="${GOP_SIZE:-$DEFAULT_GOP_SIZE}"
MIN_KEYINT="${MIN_KEYINT:-$DEFAULT_MIN_KEYINT}"
BFRAMES="${BFRAMES:-$DEFAULT_BFRAMES}"
REFS="${REFS:-$DEFAULT_REFS}"

USE_NICE="${USE_NICE:-$DEFAULT_USE_NICE}"
NICE_LEVEL="${NICE_LEVEL:-$DEFAULT_NICE_LEVEL}"
USE_IONICE="${USE_IONICE:-$DEFAULT_USE_IONICE}"
IONICE_CLASS="${IONICE_CLASS:-$DEFAULT_IONICE_CLASS}"
IONICE_LEVEL="${IONICE_LEVEL:-$DEFAULT_IONICE_LEVEL}"

OVERWRITE="${OVERWRITE:-$DEFAULT_OVERWRITE}"

# Backward compatibility: Check for old FORCE_10BIT variable name
if [[ -n "${FORCE_10BIT:-}" ]]; then
	echo "Warning: FORCE_10BIT is deprecated. Please use UPGRADE_8BIT_TO_10BIT instead." >&2
	UPGRADE_8BIT_TO_10BIT="${FORCE_10BIT}"
fi
UPGRADE_8BIT_TO_10BIT="${UPGRADE_8BIT_TO_10BIT:-$DEFAULT_UPGRADE_8BIT_TO_10BIT}"
DOWNGRADE_12BIT_TO_10BIT="${DOWNGRADE_12BIT_TO_10BIT:-$DEFAULT_DOWNGRADE_12BIT_TO_10BIT}"
COLORSPACE="${COLORSPACE:-$DEFAULT_COLORSPACE}"
BULK_MOVIES="${BULK_MOVIES:-$DEFAULT_BULK_MOVIES}"

AUDIO_COPY_FIRST="${AUDIO_COPY_FIRST:-$DEFAULT_AUDIO_COPY_FIRST}"
AUDIO_CODEC="${AUDIO_CODEC:-$DEFAULT_AUDIO_CODEC}"
AUDIO_PROFILE="${AUDIO_PROFILE:-$DEFAULT_AUDIO_PROFILE}"
AUDIO_BITRATE_MONO="${AUDIO_BITRATE_MONO:-$DEFAULT_AUDIO_BITRATE_MONO}"
AUDIO_BITRATE_STEREO="${AUDIO_BITRATE_STEREO:-$DEFAULT_AUDIO_BITRATE_STEREO}"
AUDIO_BITRATE_SURROUND="${AUDIO_BITRATE_SURROUND:-$DEFAULT_AUDIO_BITRATE_SURROUND}"
AUDIO_BITRATE_SURROUND_PLUS="${AUDIO_BITRATE_SURROUND_PLUS:-$DEFAULT_AUDIO_BITRATE_SURROUND_PLUS}"
AUDIO_FILTER_LANGUAGES="${AUDIO_FILTER_LANGUAGES:-$DEFAULT_AUDIO_FILTER_LANGUAGES}"
AUDIO_PASSTHROUGH_CODECS="${AUDIO_PASSTHROUGH_CODECS:-$DEFAULT_AUDIO_PASSTHROUGH_CODECS}"

LANGUAGE="${LANGUAGE:-$DEFAULT_LANGUAGE}"
PREFER_ORIGINAL="${PREFER_ORIGINAL:-$DEFAULT_PREFER_ORIGINAL}"
ORIGINAL_LANGUAGE="${ORIGINAL_LANGUAGE:-$DEFAULT_ORIGINAL_LANGUAGE}"
FORCED_SUBS_ON_NATIVE_AUDIO="${FORCED_SUBS_ON_NATIVE_AUDIO:-$DEFAULT_FORCED_SUBS_ON_NATIVE_AUDIO}"
SUBTITLE_FORCED_DETECT_DENSITY="${SUBTITLE_FORCED_DETECT_DENSITY:-$DEFAULT_SUBTITLE_FORCED_DETECT_DENSITY}"
SUBTITLE_FORCED_MAX_EVENTS_PER_MIN="${SUBTITLE_FORCED_MAX_EVENTS_PER_MIN:-$DEFAULT_SUBTITLE_FORCED_MAX_EVENTS_PER_MIN}"
SUBTITLE_FORCED_DEEP_SCAN="${SUBTITLE_FORCED_DEEP_SCAN:-$DEFAULT_SUBTITLE_FORCED_DEEP_SCAN}"

COPY_ONLY="${COPY_ONLY:-$DEFAULT_COPY_ONLY}"
DETECT_INTERLACING="${DETECT_INTERLACING:-$DEFAULT_DETECT_INTERLACING}"
ADAPTIVE_DEINTERLACE="${ADAPTIVE_DEINTERLACE:-$DEFAULT_ADAPTIVE_DEINTERLACE}"
FORCE_DEINTERLACE="${FORCE_DEINTERLACE:-$DEFAULT_FORCE_DEINTERLACE}"
DEINTERLACER="${DEINTERLACER:-$DEFAULT_DEINTERLACER}"
DEINTERLACE_RATE="${DEINTERLACE_RATE:-$DEFAULT_DEINTERLACE_RATE}"
DETECT_CROP="${DETECT_CROP:-$DEFAULT_DETECT_CROP}"
DETECT_PULLDOWN="${DETECT_PULLDOWN:-$DEFAULT_DETECT_PULLDOWN}"
IVTC_MODE="${IVTC_MODE:-$DEFAULT_IVTC_MODE}"
FIELDMATCH_MODE="${FIELDMATCH_MODE:-$DEFAULT_FIELDMATCH_MODE}"
SPLIT_CHAPTERS="${SPLIT_CHAPTERS:-$DEFAULT_SPLIT_CHAPTERS}"
CHAPTERS_PER_EPISODE="${CHAPTERS_PER_EPISODE:-$DEFAULT_CHAPTERS_PER_EPISODE}"

BD_MIN_DURATION="${BD_MIN_DURATION:-$DEFAULT_BD_MIN_DURATION}"

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
CONTAINER="${CONTAINER:-$DEFAULT_CONTAINER}"

# Backward compatibility: Check for old VIDEO_EXTENSIONS variable name
if [[ -n "${VIDEO_EXTENSIONS:-}" ]]; then
	echo "Warning: VIDEO_EXTENSIONS is deprecated. Please use INPUT_VIDEO_EXTENSIONS instead." >&2
	INPUT_VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS}"
fi
INPUT_VIDEO_EXTENSIONS="${INPUT_VIDEO_EXTENSIONS:-$DEFAULT_INPUT_VIDEO_EXTENSIONS}"
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-$DEFAULT_FFMPEG_LOGLEVEL}"
FFMPEG_ANALYZEDURATION="${FFMPEG_ANALYZEDURATION:-$DEFAULT_FFMPEG_ANALYZEDURATION}"
FFMPEG_PROBESIZE="${FFMPEG_PROBESIZE:-$DEFAULT_FFMPEG_PROBESIZE}"

# ════════════════════════════════════════════════════════════════════════════
# FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════

show_help() {
	cat << EOF
${BOLDBLUE}════════════════════════════════════════════════════════════════════════════${RESET}
${BOLD}  Transcode Monster v${SCRIPT_VERSION}${RESET}
  Universal video transcoding script with automatic series/movie detection
${BOLDBLUE}════════════════════════════════════════════════════════════════════════════${RESET}

${BOLDBLUE}USAGE${RESET}
  transcode-monster.sh [options] ${YELLOW}<source>${RESET} [${YELLOW}output_dir${RESET}]

${BOLDBLUE}ARGUMENTS${RESET}
  ${GREEN}source${RESET}                 Source directory or file(s) to transcode
  ${GREEN}output_dir${RESET}             Output directory (default: ${DEFAULT_OUTPUT_DIR})

${BOLDBLUE}GENERAL OPTIONS${RESET}
  ${GREEN}-h${RESET}, ${GREEN}--help${RESET}             Show this help message
  ${GREEN}-v${RESET}, ${GREEN}--version${RESET}          Show version information
  ${GREEN}-t${RESET}, ${GREEN}--type${RESET} ${YELLOW}TYPE${RESET}        Override auto-detection: ${CYAN}series${RESET} or ${CYAN}movie${RESET}
  ${GREEN}-n${RESET}, ${GREEN}--name${RESET} ${YELLOW}NAME${RESET}        Set content title (e.g., "Firefly" or "Dune")
  ${GREEN}-y${RESET}, ${GREEN}--year${RESET} ${YELLOW}YEAR${RESET}        Append year to title (e.g., 1984 for movies; 1959 for reboots)
  ${GREEN}-s${RESET}, ${GREEN}--season${RESET} ${YELLOW}NUM${RESET}       Process only a specific season (default: all seasons)
  ${GREEN}-e${RESET}, ${GREEN}--episode${RESET} ${YELLOW}NUM${RESET}      Process only a specific episode in series mode
  ${GREEN}-d${RESET}, ${GREEN}--dry-run${RESET}          Show what would be processed without encoding
      ${GREEN}--copy-only${RESET}, ${GREEN}--remux${RESET}
			 Remux instead of encode: copy the source video and audio
			 streams as-is, but still pick the right tracks, set
			 dispositions, and name the output. For sources that are
			 already well-encoded but badly mastered or named.
  ${GREEN}-o${RESET}, ${GREEN}--overwrite${RESET}        Overwrite existing output files

${BOLDBLUE}VIDEO ENCODING${RESET}
  ${GREEN}-q${RESET}, ${GREEN}--quality${RESET} ${YELLOW}NUM${RESET}      CQP/CRF quality value (default: ${DEFAULT_QUALITY})
			 Lower = better quality / higher = smaller files
			 Recommended: 18-20 (8-bit), 20-22 (10-bit), 22-24 (12-bit)
  ${GREEN}-c${RESET}, ${GREEN}--codec${RESET} ${YELLOW}CODEC${RESET}      Video codec (default: ${DEFAULT_VIDEO_CODEC})
			 ${CYAN}auto${RESET}       Choose hevc_vaapi or libx265 based on content
			 ${CYAN}hevc_vaapi${RESET} Hardware encoding — fastest
			 ${CYAN}libx265${RESET}    Software encoding — maximum quality/compatibility
  ${GREEN}--preset${RESET} ${YELLOW}PRESET${RESET}         libx265 software encoding preset (default: ${DEFAULT_PRESET})
			 ultrafast  superfast  veryfast  faster  fast
			 medium  slow  slower  veryslow  placebo
  ${GREEN}--tune${RESET} ${YELLOW}TUNE${RESET}             libx265 tuning preset (default: none)
			 ${CYAN}fastdecode${RESET}  Optimize for low-power playback (Pi, smart TVs, older
				      devices); automatically limits B-frames to 1
			 ${CYAN}grain${RESET}       Preserve film grain
			 ${CYAN}animation${RESET}   Optimize for sharp edges and flat colors
			 ${CYAN}psnr${RESET}  ${CYAN}ssim${RESET}  ${CYAN}zerolatency${RESET}
  ${GREEN}-b${RESET}, ${GREEN}--bframes${RESET} ${YELLOW}NUM${RESET}      B-frame count: 0-4+ (default: ${DEFAULT_BFRAMES})
			 0 = max compatibility / 1-2 = balanced / 3-4 = best compression
			 Higher values increase decode complexity on low-power devices
			 Automatically set to 1 when --tune fastdecode is active
			 ${YELLOW}NOTE:${RESET} Silently ignored by hevc_vaapi on all AMD GPUs (VCN 1-5);
			 only effective with libx265 or non-AMD VAAPI hardware

${BOLDBLUE}HARDWARE ACCELERATION${RESET}
  ${GREEN}--device${RESET} ${YELLOW}PATH${RESET}           VAAPI render device (default: ${DEFAULT_VAAPI_DEVICE})
  ${GREEN}--compression-level${RESET} ${YELLOW}N${RESET}  Hardware encoder compression level: 0-7 (default: ${DEFAULT_VAAPI_COMPRESSION_LEVEL})
			 0 = fastest / largest files
			 4 = balanced — ~5x faster than software, comparable file sizes
			 7 = slowest / smallest files (still faster than software)
			 Intel Arc/11th+ gen specific; safely ignored on AMD/older Intel

${BOLDBLUE}BIT DEPTH & COLOR SPACE${RESET}
  ${GREEN}--upgrade-8bit${RESET}         Upgrade 8-bit sources to 10-bit (default: enabled)
			 Benefits: reduced banding, ~10-15% smaller files, no visible loss
  ${GREEN}--no-upgrade-8bit${RESET}      Encode at source bit depth (disable 8→10-bit upgrade)
  ${GREEN}--downgrade-12bit${RESET}      Downgrade 12-bit to 10-bit for hardware compat/speed
			 Benefits: enables GPU encoding, ~20% smaller, minimal quality loss
  ${GREEN}--no-downgrade-12bit${RESET}   Preserve 12-bit sources at native depth (default)
  ${GREEN}--colorspace${RESET} ${YELLOW}SPACE${RESET}      Color space handling (default: auto)
			 ${CYAN}auto${RESET}   Detect from metadata; preserve HDR automatically
			 ${CYAN}bt709${RESET}  Force BT.709 (HD standard)
			 ${CYAN}bt601${RESET}  Force BT.601 (SD standard)
			 ${CYAN}hdr${RESET}    Preserve HDR metadata (HDR10, HLG, BT.2020)
			 ${CYAN}none${RESET}   Disable conversion (use source color space as-is)

${BOLDBLUE}VIDEO PROCESSING${RESET}
  ${GREEN}--no-crop${RESET}              Disable automatic black bar crop detection
  ${GREEN}--no-deinterlace${RESET}       Disable automatic interlacing detection
  ${GREEN}--force-deinterlace${RESET}    Force deinterlacing even on progressive content
  ${GREEN}--adaptive-deinterlace${RESET} Only deinterlace frames flagged as interlaced
			 Useful for mixed content: film transfers with interlaced title
			 cards, or compilations assembled from multiple sources
  ${GREEN}--deinterlacer${RESET} ${YELLOW}FILTER${RESET}  Deinterlacing filter (default: ${DEFAULT_DEINTERLACER})
			 ${CYAN}bwdif${RESET}  Bob weaver — best quality for most content
			 ${CYAN}nnedi${RESET}  Neural network — best for noisy or difficult sources
			 ${CYAN}yadif${RESET}  Yet another deinterlacer — fast and widely compatible
  ${GREEN}--deinterlace-rate${RESET} ${YELLOW}RATE${RESET}  Output rate when deinterlacing true interlaced video
			 ${CYAN}auto${RESET}   Field-rate for NTSC video (60i→60p), frame-rate for PAL/unknown
			 ${CYAN}field${RESET}  Always double-rate (one frame per field — smoothest motion)
			 ${CYAN}frame${RESET}  Always single-rate (one frame per frame — preserves source fps)
			 Telecined film is inverse-telecined regardless of this setting.
  ${GREEN}--no-pulldown${RESET}          Disable 3:2 pulldown / inverse telecine detection
  ${GREEN}--force-ivtc${RESET}           Force inverse telecine on this content
			 (auto mode now detects telecine at any resolution, including HD)
  ${GREEN}--ivtc-mode${RESET} ${YELLOW}MODE${RESET}       How to drop pulldown duplicates after inverse telecine
			 ${CYAN}adaptive${RESET} mpdecimate + VFR — keeps unique frames in mixed
				  film/video sources (anime OVAs); no judder (default)
			 ${CYAN}fixed${RESET}    decimate + 23.976 CFR — exact, best for uniform
				  film and players that require constant frame rate
  ${GREEN}--fieldmatch-mode${RESET} ${YELLOW}MODE${RESET} fieldmatch matching thoroughness during inverse telecine
			 ${CYAN}pc_n${RESET}    current+next field combos + 5th-field check (default)
			 ${CYAN}pcn_ub${RESET}  also tries previous-field combos — most exhaustive,
				  fewer orphans on mixed-cadence anime, slight mismatch risk
  ${GREEN}--split-chapters${RESET}       Force chapter splitting for multi-episode files
  ${GREEN}--no-split-chapters${RESET}    Process file as a single video (no chapter splitting)
  ${GREEN}--chapters-per-episode${RESET} ${YELLOW}N${RESET}
			 Group N chapters per episode (default: auto-detect optimal)

${BOLDBLUE}AUDIO & LANGUAGE${RESET}
  ${GREEN}--language${RESET} ${YELLOW}LANG${RESET}         Preferred language, ISO 639-2 code (default: ${DEFAULT_LANGUAGE})
			 Comma-separated for multilingual: ${CYAN}eng,spa,fra${RESET}
			 First code in the list takes priority for subtitle selection
  ${GREEN}--original-lang${RESET} ${YELLOW}LANG${RESET}    Original language mode — original audio + subtitles
			 in the default language (e.g., ${CYAN}--original-lang jpn${RESET} for anime)
  ${GREEN}--all-audio${RESET}            Keep all audio tracks (bypass language filtering)

  Language filtering (enabled by default) keeps: tracks matching LANGUAGE, commentary
  tracks, and 'und' (undetermined). Foreign overdubs are excluded automatically.

${BOLDBLUE}OUTPUT${RESET}
  ${GREEN}--bulk-movies${RESET}          Process all video files in a directory as separate movies
			 Default movie mode picks the longest file in a directory only

${BOLDBLUE}ENCODER NOTES${RESET}
  Hybrid encoding uses hardware (hevc_vaapi) when safe for maximum speed, and
  falls back to software (libx265) for content requiring higher accuracy.

  ${CYAN}Auto-detection considers:${RESET}
    Pixel format (yuv420p vs yuv422p/444p), color space metadata, source codec
    (H.264/HEVC vs MPEG2/DV), field order (progressive vs interlaced), and
    hardware 10-bit support.

  ${CYAN}Software encoding (libx265) provides:${RESET}
    Comprehensive color space handling, chroma subsampling correction, reduced
    system priority via nice/ionice, and automatic CPU thread pool maximization.
    Use --preset to trade encoding speed for quality.

  ${CYAN}Color space handling:${RESET}
    HDR content (HDR10, HLG, BT.2020) is detected and preserved automatically.
    Dolby Vision enhancement layers are stripped; only the HDR10 base layer is
    preserved — keep original files if you have DV-capable playback hardware.
    Legacy color spaces (BT.470BG, SMPTE170M) are converted to BT.709 (HD) or
    BT.601 (SD ≤576p). Conversion only occurs when source metadata is known;
    falls back to software for unknown or missing color metadata.

  ${CYAN}B-frames:${RESET}
    Improve compression by referencing both past and future frames. AMD hevc_vaapi
    silently ignores -bf across all VCN generations (1 through 5, RDNA 4 included).
    B-frames are only effective with libx265. Higher counts increase decode complexity
    and may not play smoothly on low-power devices (smart TVs, Raspberry Pi, etc.).

${BOLDBLUE}AUDIO ENCODING${RESET}
  The first audio track is copied as-is (e.g., for passthrough to an A/V receiver).
  Blu-ray PCM (pcm_bluray) is converted to FLAC, as PCM is unsupported in MKV.
  Secondary tracks already in an efficient lossy format (Opus, AAC, MP3, Vorbis)
  are copied untouched to avoid generational quality loss. All other secondary
  tracks are encoded to HE-AAC at channel-appropriate bitrates:

    Mono:     96 kbps    Stereo:  128 kbps
    5.1:     192 kbps    7.1+:    256 kbps

  Set AUDIO_PASSTHROUGH_CODECS in the config to change which formats are copied
  (e.g., add ac3/eac3/dts to keep them bit-for-bit instead of downsizing them).
  Language filtering keeps tracks matching LANGUAGE, commentary tracks, and 'und'.
  Use --all-audio to disable filtering and keep every track.

${BOLDBLUE}SUBTITLE HANDLING${RESET}
  Subtitles in LANGUAGE are kept and converted to MKV-compatible formats. Which
  track is enabled by default depends on the audio:

    ${CYAN}Foreign audio${RESET}  A full subtitle track is enabled by default so all dialogue
		   is translated (forced-only tracks are used only as a fallback).
    ${CYAN}Native audio${RESET}   A forced/signs track is enabled (disposition default+forced)
		   so intentional foreign-language scenes and on-screen signage
		   still get translated — e.g. the Mandarin scenes in "Revolver".
		   Full subtitles are not auto-enabled. Disable via
		   FORCED_SUBS_ON_NATIVE_AUDIO="false".

  Forced tracks are detected by the 'forced' disposition flag, then by title
  (forced/signs/songs), then, if still ambiguous, by cue density (few cues per
  minute = forced). Density reads the container's cue-count metadata when present
  (instant), so it adds no measurable cost to a normal run. Tune or disable via
  SUBTITLE_FORCED_DETECT_DENSITY and SUBTITLE_FORCED_MAX_EVENTS_PER_MIN. For the
  rare long file with no such metadata, set SUBTITLE_FORCED_DEEP_SCAN="true" to
  count cues by demuxing the stream (accurate but slow on large network sources).

${BOLDBLUE}INPUT FORMATS${RESET}
  ${CYAN}Recommended:${RESET}  MKV, MP4, M4V — best metadata support
  ${CYAN}Legacy:${RESET}       AVI, MPEG, MPG — limited metadata; may pull in extra tracks
  ${CYAN}Disc/stream:${RESET}  TS, M2TS — Blu-ray transport streams
  ${CYAN}Other:${RESET}        MOV (QuickTime), WebM, FLV, WMV, ASF, VOB (DVD), OGV

  Output is always MKV for maximum compatibility and metadata support.

${BOLDBLUE}CONTENT DETECTION${RESET}
  Series is detected from S#D# directories, _S#_D# naming, or "Season #" paths.
  Movie mode is used for single files or directories without series markers.

  ${CYAN}Series naming patterns:${RESET}
    /path/to/Show/S1D1/    /path/to/Show_S1_D1/    /path/to/Show/Season 1/

  ${CYAN}Season & episode detection:${RESET}
    Season and episode are read from the most specific source available: the
    file's own name first (S02E05, S02_E05, 2x05, "Season 2"), then its disc/
    season directory, then context. This means a flat folder whose season lives
    only in the filenames (Show_S01_E01 … Show_S02_E27) is split into the right
    seasons instead of being lumped together, and mixed layouts — some seasons
    pooled in one folder, others in S#D# disc dirs — are handled in one pass.
    Episodes are numbered by their parsed value when those are unambiguous, so a
    set with a missing episode keeps canonical numbering rather than renumbering;
    unparseable or duplicated sets fall back to sorted position.

  ${CYAN}Disc continuation:${RESET}
    SHOW_S1_D1, SHOW_S1_D2, SHOW_D3, SHOW_D4 — discs without a season number
    after a numbered season are automatically detected as continuations.

  ${CYAN}Output naming:${RESET}
    Series:  Show Name - S01E01.mkv
    Movie:   Movie Name (1984).mkv

${BOLDBLUE}CONFIG FILE${RESET}
  ${CYAN}${CONFIG_FILE}${RESET}

  All settings use bash variable syntax. Priority: defaults < config < CLI args.

  ${CYAN}Common settings:${RESET}
    QUALITY="20.6"                         # Default optimized for 10-bit
    VIDEO_CODEC="hevc_vaapi"
    PRESET="medium"
    X265_TUNE="fastdecode"                 # For low-power playback devices
    OUTPUT_DIR="/path/to/videos"
    AUDIO_BITRATE_STEREO="128k"
    AUDIO_BITRATE_SURROUND="192k"
    AUDIO_PASSTHROUGH_CODECS="opus aac mp3 vorbis"  # Copy these secondary tracks as-is
    FORCED_SUBS_ON_NATIVE_AUDIO="true"     # Auto-enable forced/signs subs on native-audio films
    ADAPTIVE_DEINTERLACE="true"
    INPUT_VIDEO_EXTENSIONS="mkv mp4 m4v avi"

  ${CYAN}FFmpeg verbosity (config file only):${RESET}
    FFMPEG_LOGLEVEL           Output level (default: warning)
			      quiet  panic  fatal  error  warning  info  verbose  debug
			      The progress indicator (-stats) is always enabled.
    FFMPEG_ANALYZEDURATION    Microseconds to analyze input (default: 120000000 = 2 min)
			      Increase if you see "Could not find codec parameters" on
			      subtitle streams. Large Blu-ray rips may need 200000000+.
    FFMPEG_PROBESIZE          Bytes to probe for stream info (default: 128000000 = 128 MB)
			      Raise alongside ANALYZEDURATION for persistent warnings.
			      Higher values add 3-8 sec to startup but eliminate them.

${BOLDBLUE}EXAMPLES${RESET}
  ${CYAN}# Auto-detect everything from a disc directory${RESET}
  transcode-monster.sh "/path/to/Firefly/S1D1"

  ${CYAN}# Transcode a specific file or glob${RESET}
  transcode-monster.sh "/path/to/rips/movie.mkv" "/path/to/movies"
  transcode-monster.sh "/path/to/rips/episode_*.mkv" "/path/to/tv"

  ${CYAN}# Explicit series name and output directory${RESET}
  transcode-monster.sh -n "Firefly" "/path/to/rips/S1D1" "/path/to/tv/Firefly"

  ${CYAN}# Movie with year${RESET}
  transcode-monster.sh -t movie -n "Dune" -y 1984 "/path/to/rips/dune"

  ${CYAN}# Series with year (reboots/disambiguation)${RESET}
  transcode-monster.sh -n "The Twilight Zone" -y 1959 "/path/to/rips/twilight/"

  ${CYAN}# Only transcode a specific season${RESET}
  transcode-monster.sh -s 2 "/path/to/rips/disc1" "/path/to/tv/House"

  ${CYAN}# Only transcode a specific episode${RESET}
  transcode-monster.sh -s 1 -e 3 "/path/to/tv/Show/"

  ${CYAN}# Custom quality, disable crop detection${RESET}
  transcode-monster.sh -q 21 --no-crop "/path/to/rips"

  ${CYAN}# Mixed progressive/interlaced content (film with interlaced title cards)${RESET}
  transcode-monster.sh --adaptive-deinterlace "/path/to/rips/ctd.mkv"

  ${CYAN}# Noisy broadcast source — neural network deinterlacer${RESET}
  transcode-monster.sh --deinterlacer nnedi "/path/to/The Maxx/"

  ${CYAN}# Anime: original audio with subtitles in the default language${RESET}
  transcode-monster.sh --original-lang jpn "/path/to/anime/Cowboy Bebop/"

  ${CYAN}# Default language override${RESET}
  transcode-monster.sh --language spa "/path/to/series/La Casa de Papel/"

  ${CYAN}# Bulk movie transcoding from a directory${RESET}
  transcode-monster.sh --bulk-movies "/path/to/movies/rips/" "/path/to/output/"

  ${CYAN}# UHD/HDR content (HDR detected and preserved automatically)${RESET}
  transcode-monster.sh "/path/to/uhd/Ghost in the Shell/" "/path/to/movies/"

EOF
}

show_version() {
	echo "Transcode Monster v${SCRIPT_VERSION}"
}

# Parse episode number from filename
get_episode_num() {
	local filename="$1"
	local ep_num=""

	# 0. OVA/OAV prefix — normalize OAV→OVA, encode as N-1000 so negatives sort before episodes
	if echo "$filename" | grep -qiP '^O(VA|AV)[\s._\-]'; then
		ep_num=$(echo "$filename" | grep -oP '\d{1,3}' | head -1)
		[[ -n "$ep_num" ]] && { echo $((10#$ep_num - 1000)); return; }
	fi

	# 1. Standard SxxExx / sxx.exx / S1E1 — allow a separator between season and
	#    episode (S01_E06, S01.E06, S01 E06) and 1-or-2 digit season/episode.
	ep_num=$(echo "$filename" | grep -oP '[Ss]\d{1,2}[\s._-]*[Ee]\K\d{1,3}' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	# 2. NxNN / NNxNN (e.g. 2x07)
	ep_num=$(echo "$filename" | grep -oP '\d{1,2}[xX]\K\d{2,3}' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	# 3. Episode NNN or ep/ep./epNNN (case-insensitive)
	ep_num=$(echo "$filename" | sed -En 's/.*[Ee]pisode[[:space:]]*([0-9]{2,3}).*/\1/p' | head -1)
	[[ -z "$ep_num" ]] && ep_num=$(echo "$filename" | sed -En 's/.*[Ee][Pp][[:punct:][:space:]]*([0-9]{2,3}).*/\1/p' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	# 4. NN or NNN at start of filename before a separator (e.g. "01 - Title.mkv")
	ep_num=$(echo "$filename" | grep -oP '^\d{2,3}(?=[\s.\-])' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	# 5. _NN or _NNN before a dot (e.g. Name_01.extra.mkv)
	ep_num=$(echo "$filename" | grep -oP '(?<=_)\d{2,3}(?=\.)' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	# 6. _NN directly before .mkv (e.g. Show_07.mkv). Deliberately matches only
	#    an underscore before the digits, NOT the MakeMKV title pattern _tNN
	#    (BGC_t01.mkv, Name_t00.mkv) — there the number is the disc's title index,
	#    not an episode, so those fall through to UNKNOWN and get sequential
	#    numbering by sorted filename instead of inheriting gappy title numbers.
	ep_num=$(echo "$filename" | sed -E 's/.*_([0-9]{2,3})\.mkv$/\1/')
	if [[ -n "$ep_num" && "$ep_num" =~ ^[0-9]{2,3}$ ]]; then
		echo $((10#$ep_num)); return
	fi

	# 7. Bare NN/NNN surrounded by separators (space, hyphen, dot)
	ep_num=$(echo "$filename" | grep -oP '(?<=[\s.\-])\d{2,3}(?=[\s.\-])' | head -1)
	[[ -n "$ep_num" ]] && { echo $((10#$ep_num)); return; }

	echo "UNKNOWN"
}

# Extract a SEASON number from a filename. Echoes the number (no leading zeros)
# or "UNKNOWN". Deliberately conservative — only high-confidence patterns, with
# guards so resolutions (1920x1080), years, and codec tags don't masquerade as
# seasons. This lets a flat directory of "Show_S02_E01.mkv" files be grouped by
# their real season even when the directory layout gives no season hint.
get_season_num() {
	local filename="$1"
	# 1. SxxExx / sxx.exx / S1E1 — season and episode together (highest confidence)
	if [[ "$filename" =~ [Ss]([0-9]{1,2})[[:space:]._-]*[Ee][0-9]{1,3} ]]; then
		echo "$((10#${BASH_REMATCH[1]}))"; return
	fi
	# 2. "Season N" / "Series N" (British), any common separator
	if [[ "$filename" =~ [Ss](eason|eries)[[:space:]._-]*([0-9]{1,2}) ]]; then
		echo "$((10#${BASH_REMATCH[2]}))"; return
	fi
	# 3. NxNN (e.g. 2x07). Guarded: the season digits must not be preceded by a
	#    digit or x, and the episode digits must not be followed by a digit, so
	#    "1920x1080" and similar can't be misread as a season.
	if [[ "$filename" =~ (^|[^0-9xX])([0-9]{1,2})[xX]([0-9]{2,3})($|[^0-9]) ]]; then
		echo "$((10#${BASH_REMATCH[2]}))"; return
	fi
	echo "UNKNOWN"
}

# Assign sequential episode numbers (by alphabetical filename sort) to any
# episode_files[] entries that get_episode_num() could not parse. Fills gaps
# left by known episodes; if all are unknown, assigns 1..N in sorted order.
resolve_unknown_episodes() {
	local unknown_count=0
	local entry ep src

	for entry in "${episode_files[@]}"; do
		IFS='|' read -r _ _ ep src _ _ <<< "$entry"
		[[ "$ep" == "UNKNOWN" ]] && ((unknown_count++)) || true
	done
	[[ $unknown_count -eq 0 ]] && return

	# Collect UNKNOWN source paths: sort regular files alphabetically, OVA/OAV files last
	local -a regular_srcs=() ova_srcs=()
	for entry in "${episode_files[@]}"; do
		IFS='|' read -r _ _ ep src _ _ <<< "$entry"
		if [[ "$ep" == "UNKNOWN" ]]; then
			if basename "$src" | grep -qiP '^OV[AV]\b'; then
				ova_srcs+=("$src")
			else
				regular_srcs+=("$src")
			fi
		fi
	done
	IFS=$'\n' regular_srcs=($(printf '%s\n' "${regular_srcs[@]+${regular_srcs[@]}}" | sort)); unset IFS
	IFS=$'\n' ova_srcs=($(printf '%s\n' "${ova_srcs[@]+${ova_srcs[@]}}" | sort)); unset IFS
	local -a unknown_srcs=("${regular_srcs[@]+${regular_srcs[@]}}" "${ova_srcs[@]+${ova_srcs[@]}}")

	# Build a set of episode numbers already claimed by parsed entries
	local -A known_eps=()
	for entry in "${episode_files[@]}"; do
		IFS='|' read -r _ _ ep _ _ _ <<< "$entry"
		[[ "$ep" != "UNKNOWN" ]] && known_eps["$ep"]=1
	done

	# Assign the next free episode number to each unknown file in sorted order
	local -A assignment=()
	local next_ep=1
	for src in "${unknown_srcs[@]}"; do
		while [[ -n "${known_eps[$next_ep]:-}" ]]; do ((next_ep++)); done
		assignment["$src"]=$next_ep
		known_eps[$next_ep]=1
		((next_ep++))
	done

	# Rebuild episode_files[] with resolved numbers
	local -a new_episode_files=()
	for entry in "${episode_files[@]}"; do
		IFS='|' read -r disc_num disc_dir ep src start end <<< "$entry"
		if [[ "$ep" == "UNKNOWN" ]]; then
			ep="${assignment[$src]}"
		fi
		new_episode_files+=("$disc_num|$disc_dir|$ep|$src|$start|$end")
	done
	episode_files=("${new_episode_files[@]}")

	echo -e "${YELLOW}  Notice: Could not parse episode number(s) from $unknown_count file(s) — using alphabetical sort order as fallback${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# Source metadata priors — cheap ffprobe reads that steer the heavier
# frame-analysis passes below. Reading the nominal rate and field order up
# front lets us skip work (already-progressive film) or route it correctly
# (NTSC video vs PAL film) instead of inferring everything from idet alone.
# ─────────────────────────────────────────────────────────────────────────

# Format a duration in seconds as H:MM:SS (or M:SS under an hour). Display
# only — the seek-time math elsewhere in this file stays in raw seconds.
format_duration() {
	local total_seconds="${1%.*}"  # drop any fractional part
	[[ "$total_seconds" =~ ^[0-9]+$ ]] || { echo "unknown"; return; }

	local h=$((total_seconds / 3600))
	local m=$(((total_seconds % 3600) / 60))
	local s=$((total_seconds % 60))

	if [[ $h -gt 0 ]]; then
		printf '%d:%02d:%02d\n' "$h" "$m" "$s"
	else
		printf '%d:%02d\n' "$m" "$s"
	fi
}

# Nominal frame rate as a decimal (e.g. 23.976, 25.000, 29.970). Echoes "0"
# when it can't be determined.
get_frame_rate() {
	local input="$1"
	local rate
	rate=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$input" 2>/dev/null | head -1 | tr -d '[:space:],')

	if [[ "$rate" =~ ^([0-9]+)/([0-9]+)$ ]]; then
		local num="${BASH_REMATCH[1]}" den="${BASH_REMATCH[2]}"
		[[ "$den" -eq 0 ]] && { echo "0"; return; }
		echo "scale=3; $num/$den" | bc 2>/dev/null || echo "0"
	elif [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "$rate"
	else
		echo "0"
	fi
}

# Classify the rate family: ntsc (29.97/30/59.94/60), pal (25/50),
# film (23.976/24), or other. Drives both telecine candidacy and the
# auto deinterlace-rate decision.
classify_frame_rate() {
	local rate="$1"
	# bc echoes 1 when the comparison holds. Bands are deliberately loose to
	# absorb 1000/1001 pulldown (29.970, 23.976, 59.940) and minor rounding.
	if [[ "$(echo "$rate >= 23.5 && $rate <= 24.5" | bc 2>/dev/null)" == "1" ]]; then
		echo "film"
	elif [[ "$(echo "$rate >= 24.9 && $rate <= 25.1" | bc 2>/dev/null)" == "1" ]]; then
		echo "pal"
	elif [[ "$(echo "$rate >= 49.0 && $rate <= 50.1" | bc 2>/dev/null)" == "1" ]]; then
		echo "pal"
	elif [[ "$(echo "$rate >= 29.0 && $rate <= 30.1" | bc 2>/dev/null)" == "1" ]]; then
		echo "ntsc"
	elif [[ "$(echo "$rate >= 59.0 && $rate <= 60.1" | bc 2>/dev/null)" == "1" ]]; then
		echo "ntsc"
	else
		echo "other"
	fi
}

# Map the container's field-order metadata to a fieldmatch/deinterlace order.
# Echoes "tff", "bff", or "" (unknown — caller falls back to its own default).
get_field_order() {
	local input="$1"
	local fo
	fo=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$input" 2>/dev/null | head -1 | tr -d '[:space:],')
	case "$fo" in
		tt|tb) echo "tff" ;;   # top field first / top coded first
		bb|bt) echo "bff" ;;   # bottom field first / bottom coded first
		*)     echo "" ;;       # progressive or unknown
	esac
}

# Resolve the output rate for the deinterlace path: "field" (double-rate,
# motion-preserving) or "frame" (single-rate). Honors an explicit
# DEINTERLACE_RATE; in "auto" it uses the rate family — true NTSC interlaced
# content is video (60i→60p), while PAL/unknown defaults to single-rate to
# avoid double-bobbing 25PsF film that carries no 3:2 cadence for the IVTC
# path to catch.
resolve_deint_rate() {
	local input="$1"
	case "$DEINTERLACE_RATE" in
		field|double) echo "field"; return ;;
		frame|single) echo "frame"; return ;;
	esac
	# auto
	local family
	family=$(classify_frame_rate "$(get_frame_rate "$input")")
	if [[ "$family" == "ntsc" ]]; then
		echo "field"
	else
		echo "frame"
	fi
}

# Detect if content is telecined (3:2 pulldown)
detect_telecine() {
	local input="$1"

	# Rate prior: 3:2 pulldown only exists in the NTSC family. Content already
	# at film rate (23.976/24) is progressive film — nothing to inverse. PAL
	# (25/50) uses 2:2, which has no repeated-field signature and is handled by
	# the deinterlace path, not here. Skip the expensive scan when the rate
	# rules telecine out — unless the user forced IVTC (--force-ivtc), in which
	# case we still run the scan to catch sources whose rate tag lies. The
	# repeated-field cadence test below remains the real gate either way, so a
	# genuinely progressive forced source still returns "none".
	local family
	family=$(classify_frame_rate "$(get_frame_rate "$input")")
	if [[ "$DETECT_PULLDOWN" != "true" && "$family" != "ntsc" ]]; then
		echo -e "    ${BOLD}Telecine:${RESET}    skipped (frame-rate family '$family', not an NTSC candidate)" >&2
		echo "none"
		return
	fi

	local duration
	duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
	duration=${duration//,/}
	if ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		echo "none"
		return
	fi

	# Sample the body of the file, not the head — opening logos and title
	# cards are frequently progressive overlays or a different cadence than
	# the feature, and scanning from frame 0 (the old behavior) gave the
	# detector its least representative window.
	local sample_points=("0.20" "0.40" "0.60" "0.80")
	local total_rep=0 total_tff=0 total_bff=0 total_prog=0 samples_taken=0

	for pct in "${sample_points[@]}"; do
		local seek_time
		seek_time=$(echo "scale=2; $duration * $pct" | bc 2>/dev/null || echo "0")
		[[ "$seek_time" =~ ^[0-9]+\.?[0-9]*$ ]] || continue

		# 500 frames/point ≈ 100 full 3:2 cadences — plenty to see the pattern
		local idet_output
		idet_output=$(ffmpeg -ss "$seek_time" -i "$input" -vf idet -frames:v 500 -an -f null - 2>&1)

		local rep_top rep_bot tff bff prog
		rep_top=$(echo "$idet_output" | grep "Repeated Fields:" | tail -1 | grep -oP 'Top:\s*\K[0-9]+' || echo "0")
		rep_bot=$(echo "$idet_output" | grep "Repeated Fields:" | tail -1 | grep -oP 'Bottom:\s*\K[0-9]+' || echo "0")
		tff=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'TFF:\s*\K[0-9]+' || echo "0")
		bff=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'BFF:\s*\K[0-9]+' || echo "0")
		prog=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'Progressive:\s*\K[0-9]+' || echo "0")

		rep_top=$(echo "$rep_top" | tr -d '[:space:]'); rep_bot=$(echo "$rep_bot" | tr -d '[:space:]')
		tff=$(echo "$tff" | tr -d '[:space:]'); bff=$(echo "$bff" | tr -d '[:space:]'); prog=$(echo "$prog" | tr -d '[:space:]')

		[[ "$tff" =~ ^[0-9]+$ ]] && [[ "$bff" =~ ^[0-9]+$ ]] && [[ "$prog" =~ ^[0-9]+$ ]] || continue
		[[ "$rep_top" =~ ^[0-9]+$ ]] || rep_top=0
		[[ "$rep_bot" =~ ^[0-9]+$ ]] || rep_bot=0

		total_rep=$((total_rep + rep_top + rep_bot))
		total_tff=$((total_tff + tff))
		total_bff=$((total_bff + bff))
		total_prog=$((total_prog + prog))
		samples_taken=$((samples_taken + 1))
	done

	local total=$((total_tff + total_bff + total_prog))
	if [[ $samples_taken -eq 0 || $total -eq 0 ]]; then
		echo "none"
		return
	fi

	local repeated_pct=$((total_rep * 100 / total))
	local combed_pct=$(( (total_tff + total_bff) * 100 / total ))

	# ── Decision ────────────────────────────────────────────────────────────
	# Three tiers, because no single idet statistic separates all cases:
	#
	#   1. Strong repeat cadence (≥12%) → telecine outright. Clean live-action
	#      3:2 repeats ~20% of frames; nothing else produces a sustained repeat
	#      signature, so this is a safe fast-accept that skips the costly trial.
	#
	#   2. Weak repeats but real combing (combed ≥20%) → AMBIGUOUS. This is the
	#      band that fooled the old detector: animation held on 2s/3s already has
	#      many identical adjacent fields, which starves idet's repeat counter
	#      (Bubblegum Crash measured ~3–7% repeats despite being textbook NTSC
	#      telecine). The repeat ratio can't tell weak-cadence telecine from true
	#      interlaced video — but a trial fieldmatch can: on telecine it
	#      reconstructs the progressive frames and combing collapses to near
	#      zero; on true video the fields have no match and combing stays high.
	#      We verify rather than guess.
	#
	#   3. Otherwise → not telecine.
	local fm_order
	fm_order=$(get_field_order "$input"); fm_order="${fm_order:-tff}"

	if [[ $repeated_pct -ge 12 ]]; then
		echo -e "    ${BOLD}Telecine:${RESET}    detected (order=${fm_order}) — repeated ${repeated_pct}%, combed ${combed_pct}%" >&2
		echo "telecine"
		return
	fi

	if [[ $combed_pct -ge 20 ]]; then
		echo -e "    ${BOLD}Telecine:${RESET}    ambiguous (repeated ${repeated_pct}%, combed ${combed_pct}%) — verifying with trial fieldmatch (order=${fm_order})..." >&2

		local v_combed=0 v_total=0 v_samples=0
		for pct in "${sample_points[@]}"; do
			local seek_time
			seek_time=$(echo "scale=2; $duration * $pct" | bc 2>/dev/null || echo "0")
			[[ "$seek_time" =~ ^[0-9]+\.?[0-9]*$ ]] || continue

			# Mirror the production IVTC matcher so the measurement reflects
			# what the real chain would actually achieve, then idet the result.
			local v_out
			v_out=$(ffmpeg -ss "$seek_time" -i "$input" \
				-vf "fieldmatch=order=${fm_order}:mode=pc_n:combmatch=full,idet" \
				-frames:v 400 -an -f null - 2>&1)

			local v_tff v_bff v_prog
			v_tff=$(echo "$v_out" | grep "Multi frame detection:" | tail -1 | grep -oP 'TFF:\s*\K[0-9]+' || echo "0")
			v_bff=$(echo "$v_out" | grep "Multi frame detection:" | tail -1 | grep -oP 'BFF:\s*\K[0-9]+' || echo "0")
			v_prog=$(echo "$v_out" | grep "Multi frame detection:" | tail -1 | grep -oP 'Progressive:\s*\K[0-9]+' || echo "0")
			v_tff=$(echo "$v_tff" | tr -d '[:space:]'); v_bff=$(echo "$v_bff" | tr -d '[:space:]'); v_prog=$(echo "$v_prog" | tr -d '[:space:]')

			[[ "$v_tff" =~ ^[0-9]+$ ]] && [[ "$v_bff" =~ ^[0-9]+$ ]] && [[ "$v_prog" =~ ^[0-9]+$ ]] || continue
			v_combed=$((v_combed + v_tff + v_bff))
			v_total=$((v_total + v_tff + v_bff + v_prog))
			v_samples=$((v_samples + 1))
		done

		if [[ $v_samples -gt 0 && $v_total -gt 0 ]]; then
			local residual_pct=$((v_combed * 100 / v_total))
			# Telecine if the matcher reconstructed nearly everything: low
			# absolute residual AND a large relative collapse. True interlaced
			# video can't satisfy both — its fields have no progressive frame to
			# match back to, so combing barely moves.
			local drop_floor=$(( combed_pct * 40 / 100 ))  # require ≥60% collapse
			if [[ $residual_pct -le 8 && $residual_pct -le $drop_floor ]]; then
				echo "        Residual combing ${residual_pct}% (was ${combed_pct}%) — collapsed, telecine confirmed" >&2
				echo "telecine"
				return
			fi
			echo "        Residual combing ${residual_pct}% (was ${combed_pct}%) — persists, true interlaced video" >&2
		else
			echo "        Trial fieldmatch produced no usable samples — treating as not telecine" >&2
		fi
		echo "none"
		return
	fi

	echo -e "    ${BOLD}Telecine:${RESET}    none (repeated ${repeated_pct}%, combed ${combed_pct}%)" >&2
	echo "none"
}

# Detect interlacing
detect_interlacing() {
	local input="$1"

    # Get total duration
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    duration=${duration//,/}

    if ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
	    echo "progressive"
	    return
    fi

    # Sample at multiple points to catch localized noise/quality issues
    # Sample at 20%, 40%, 60%, and 80% to avoid title cards and capture quality variations
    local sample_points=("0.20" "0.40" "0.60" "0.80")
    local total_tff=0
    local total_bff=0
    local total_prog=0
    local total_undetermined=0
    local samples_taken=0

    for pct in "${sample_points[@]}"; do
	    local seek_time=$(echo "scale=2; $duration * $pct" | bc 2>/dev/null || echo "0")

	    if ! [[ "$seek_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		    continue
	    fi

	# Analyze 300 frames per sample point
	local idet_output=$(ffmpeg -ss "$seek_time" -i "$input" -vf idet -frames:v 300 -an -f null - 2>&1)

	# Parse the "Multi frame detection" line
	local tff_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'TFF:\s*\K[0-9]+' || echo "0")
	local bff_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'BFF:\s*\K[0-9]+' || echo "0")
	local prog_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'Progressive:\s*\K[0-9]+' || echo "0")
	local undet_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'Undetermined:\s*\K[0-9]+' || echo "0")

	# Clean values
	tff_count=$(echo "$tff_count" | tr -d '[:space:]')
	bff_count=$(echo "$bff_count" | tr -d '[:space:]')
	prog_count=$(echo "$prog_count" | tr -d '[:space:]')
	undet_count=$(echo "$undet_count" | tr -d '[:space:]')

	# Validate and accumulate
	if [[ "$tff_count" =~ ^[0-9]+$ ]] && [[ "$bff_count" =~ ^[0-9]+$ ]] && [[ "$prog_count" =~ ^[0-9]+$ ]] && [[ "$undet_count" =~ ^[0-9]+$ ]]; then
		total_tff=$((total_tff + tff_count))
		total_bff=$((total_bff + bff_count))
		total_prog=$((total_prog + prog_count))
		total_undetermined=$((total_undetermined + undet_count))
		samples_taken=$((samples_taken + 1))
	fi
done

    # If we couldn't get any valid samples, assume progressive
    if [[ $samples_taken -eq 0 ]]; then
	    echo "progressive"
	    return
    fi

    # Analyze aggregated results
    local total=$((total_tff + total_bff + total_prog + total_undetermined))
    local result="progressive"
    if [[ $total -gt 0 ]]; then
	    local interlaced_count=$((total_tff + total_bff))
	    local interlaced_pct=$((interlaced_count * 100 / total))
	    local progressive_pct=$((total_prog * 100 / total))
	    local undetermined_pct=$((total_undetermined * 100 / total))

	# If >5% of frames across all samples are interlaced, treat as interlaced
	# True progressive content shows 0-1% interlaced (detection noise)
	# Any significant interlacing (>5%) needs to be addressed
	if [[ $interlaced_pct -gt 5 ]]; then
		if [[ $total_tff -gt $total_bff ]]; then
			result="tff"
		else
			result="bff"
		fi
	fi

	echo -e "    ${BOLD}Interlacing:${RESET} ${result} (${interlaced_pct}% interlaced, ${progressive_pct}% progressive, ${undetermined_pct}% undetermined)" >&2
    fi

    echo "$result"
}

# Apply deinterlacer based on DEINTERLACER setting, field order, and rate
# Returns the filter string to add to vf chain
#   $1 field_order : "tff", "bff", or "auto"
#   $2 rate        : "field" (double-rate, one frame per field) or
#                    "frame" (single-rate, one frame per frame). Default frame.
apply_deinterlacer() {
	local field_order="$1"
	local rate="${2:-frame}"
	local filter=""

	# Field parity for bwdif/yadif (0=tff, 1=bff, -1=auto) and the matching
	# nnedi field token. nnedi distinguishes rate in the token itself:
	# t/b/a keep the frame count (single-rate); tf/bf/af emit one frame per
	# field (double-rate). bwdif/yadif carry rate in mode (0=frame, 1=field).
	local parity nnedi_field
	if [[ "$field_order" == "tff" ]]; then
		parity="0"; nnedi_field="t"
	elif [[ "$field_order" == "bff" ]]; then
		parity="1"; nnedi_field="b"
	else
		parity="-1"; nnedi_field="a"
	fi

	local mode
	if [[ "$rate" == "field" ]]; then
		mode="1"
		[[ "$nnedi_field" != "a" ]] && nnedi_field="${nnedi_field}f" || nnedi_field="af"
	else
		mode="0"
	fi

	case "$DEINTERLACER" in
		nnedi)
			# Use nnedi only (error if unavailable)
			if ! check_nnedi_available; then
				echo "    ERROR: nnedi filter not available in your ffmpeg build" >&2
				echo "    Install ffmpeg with nnedi support or use --deinterlacer bwdif" >&2
				return 1
			fi
			# Download weights file if needed
			if ! ensure_nnedi_weights; then
				echo "    ERROR: Failed to download nnedi3_weights.bin" >&2
				echo "    Download manually from: https://github.com/dubhater/vapoursynth-nnedi3/raw/master/src/nnedi3_weights.bin" >&2
				echo "    Place in: $NNEDI_WEIGHTS_FILE" >&2
				return 1
			fi
			filter="nnedi=weights='${NNEDI_WEIGHTS_FILE}':field=${nnedi_field}"
			echo "        Using nnedi deinterlacer (high quality, neural network, ${rate}-rate)" >&2
			;;
		bwdif)
			filter="bwdif=mode=${mode}:parity=$parity"
			echo "        Using bwdif deinterlacer (bob weaver, ${rate}-rate)" >&2
			;;
		yadif)
			filter="yadif=mode=${mode}:parity=$parity"
			echo "        Using yadif deinterlacer (${rate}-rate)" >&2
			;;
		auto|*)
			filter="bwdif=mode=${mode}:parity=$parity"
			echo "        Using bwdif deinterlacer (default, ${rate}-rate)" >&2
			;;
	esac

	echo "$filter"
}

# Detect crop
detect_crop() {
	local input="$1"

    # Get total duration
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    duration=${duration//,/}

    if ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
	    echo ""
	    return
    fi

    # Sample at 25%, 50%, and 75% to avoid title cards and get representative content
    local sample_points=("0.25" "0.50" "0.75")
    declare -A crop_results

    for pct in "${sample_points[@]}"; do
	    local seek_time=$(echo "scale=2; $duration * $pct" | bc 2>/dev/null || echo "0")

	    if ! [[ "$seek_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		    continue
	    fi

	# Don't use -v quiet here - we need the cropdetect output!
	local crop_line=$(ffmpeg -ss "$seek_time" -i "$input" -vf cropdetect=0.1:16:100 -frames:v 200 -f null - 2>&1 | grep 'crop=' | tail -20 | sort | uniq -c | sort -nr | head -1 | grep -o 'crop=[0-9:]*' | cut -d'=' -f2)

	if [[ -n "$crop_line" ]]; then
		local w=$(echo "$crop_line" | cut -d: -f1)
		local h=$(echo "$crop_line" | cut -d: -f2)
		local x=$(echo "$crop_line" | cut -d: -f3)
		local y=$(echo "$crop_line" | cut -d: -f4)

	    # Validate
	    if [[ -n "$w" && -n "$h" && -n "$x" && -n "$y" ]]; then
		    w=${w//,/}
		    h=${h//,/}
		    x=${x//,/}
		    y=${y//,/}

		    if [[ "$w" =~ ^[0-9]+$ ]] && [[ "$h" =~ ^[0-9]+$ ]] && [[ "$x" =~ ^[0-9]+$ ]] && [[ "$y" =~ ^[0-9]+$ ]]; then
			    # Store crop with its area (use as key to deduplicate)
			    local area=$((w * h))
			    crop_results[$area]="$w:$h:$x:$y"
		    fi
	    fi
	fi
done

    # Find the crop with the largest area (least aggressive crop)
    local max_area=0
    local best_crop=""

    for area in "${!crop_results[@]}"; do
	    if [[ $area -gt $max_area ]]; then
		    max_area=$area
		    best_crop="${crop_results[$area]}"
	    fi
    done

    if [[ -z "$best_crop" ]]; then
	    echo ""
	    return
    fi

    # Parse the best crop
    local w=$(echo "$best_crop" | cut -d: -f1)
    local h=$(echo "$best_crop" | cut -d: -f2)
    local x=$(echo "$best_crop" | cut -d: -f3)
    local y=$(echo "$best_crop" | cut -d: -f4)

    # Round dimensions down to a multiple of 16 (encoder/VAAPI alignment).
    w=$((w - (w % 16)))
    h=$((h - (h % 16)))

    # Force even offsets. Two reasons, both of which bite the downstream chain:
    #   • 4:2:0 chroma is subsampled 2×2, so an odd x/y shifts chroma against
    #     luma → colored fringing along the crop edges.
    #   • An odd vertical offset swaps which line is the "top" field, inverting
    #     parity for fieldmatch/yadif and leaving residual combing that
    #     survives the whole pipeline.
    # Rounding down is always in-bounds here because w/h were only shrunk, so
    # the right/bottom edge can never exceed the source.
    x=$((x - (x % 2)))
    y=$((y - (y % 2)))

    # Get original dimensions
    local orig_w=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input" | head -1)
    local orig_h=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input" | head -1)

    # Remove any commas from locale-formatted numbers
    orig_w=${orig_w//,/}
    orig_h=${orig_h//,/}

    # Validate they're numbers
    if ! [[ "$orig_w" =~ ^[0-9]+$ ]] || ! [[ "$orig_h" =~ ^[0-9]+$ ]]; then
	    echo ""
	    return
    fi

    # If crop matches original dimensions, no crop needed
    if [[ "$w" -eq "$orig_w" && "$h" -eq "$orig_h" ]]; then
	    echo -e "    ${BOLD}Crop:${RESET}        none needed (source ${orig_w}x${orig_h})" >&2
	    echo ""
	    return
    fi

    echo -e "    ${BOLD}Crop:${RESET}        ${w}:${h}:${x}:${y} (source ${orig_w}x${orig_h})" >&2
    echo "$w:$h:$x:$y"
}

# Check and download nnedi3 weights file if needed
ensure_nnedi_weights() {
	# Check if file exists and is valid
	if [[ -f "$NNEDI_WEIGHTS_FILE" ]]; then
		local current_sha256=$(sha256sum "$NNEDI_WEIGHTS_FILE" 2>/dev/null | cut -d' ' -f1)
		if [[ "$current_sha256" == "$NNEDI_WEIGHTS_SHA256" ]]; then
			return 0  # File exists and is valid
		fi
		echo "    Existing nnedi3_weights.bin failed verification, redownloading..." >&2
	fi

    # Create directory if needed
    mkdir -p "$NNEDI_WEIGHTS_DIR" 2>/dev/null || {
	    echo "    Cannot create directory $NNEDI_WEIGHTS_DIR" >&2
		return 1
	}

	echo "    Downloading nnedi3_weights.bin..." >&2

    # Try primary source (dubhater's repository)
    if curl -f -L -o "$NNEDI_WEIGHTS_FILE.tmp" \
	    "https://github.com/dubhater/vapoursynth-nnedi3/raw/master/src/nnedi3_weights.bin" 2>/dev/null; then

	# Verify download
	local downloaded_sha256=$(sha256sum "$NNEDI_WEIGHTS_FILE.tmp" 2>/dev/null | cut -d' ' -f1)
	if [[ "$downloaded_sha256" == "$NNEDI_WEIGHTS_SHA256" ]]; then
		mv "$NNEDI_WEIGHTS_FILE.tmp" "$NNEDI_WEIGHTS_FILE"
		echo "    Successfully downloaded and verified nnedi3_weights.bin" >&2
		return 0
	fi
	rm -f "$NNEDI_WEIGHTS_FILE.tmp"
	echo "    Downloaded file failed verification" >&2
    fi

    echo "    Failed to download nnedi3_weights.bin" >&2
    return 1
}

# Check if nnedi deinterlacer is available
check_nnedi_available() {
	# Only check if nnedi filter exists in ffmpeg
	# Don't check weights file here - we'll download it when needed
	# Capture output first to avoid pipeline issues with set -euo pipefail
	local ffmpeg_output=$(ffmpeg -hide_banner -filters 2>&1)
	if echo "$ffmpeg_output" | grep -q "nnedi"; then
		return 0  # Filter found
	fi
	return 1  # Filter not found
}

# Build video filter chain - works for both VAAPI and software encoding
build_vf() {
	local input="$1"
	local encoder_type="$2"  # "vaapi" or "software"
	local bit_depth="$3"
	local vf=""
	local vf_cpu=""  # CPU-side filters (before hwupload)

    # Get height for later use
    local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input" | head -1)
    height=${height//,/}

    # Which frame-dropper to append after inverse telecine. mpdecimate drops
    # only near-duplicate frames (adaptive, → VFR), decimate drops a fixed
    # 1-in-5 (→ 23.976 CFR). The caller turns VFR on by detecting "mpdecimate"
    # in the returned filter string. See IVTC_MODE for the tradeoff.
    local ivtc_decimator="mpdecimate"
    [[ "$IVTC_MODE" == "fixed" ]] && ivtc_decimator="decimate"

    # Display analysis phase message
    echo "  Analyzing source content (crop, interlacing, telecine)..." >&2

    # Crop detection (always done on CPU first)
    if [[ "$DETECT_CROP" == "true" ]]; then
	    local crop=$(detect_crop "$input")
	    if [[ -n "$crop" ]]; then
		    vf_cpu="crop=$crop"
	    fi
    fi

    # For VAAPI, HEVC wants the coded surface aligned to 16 pixels. We compute
    # the target here but DO NOT insert the alignment filter yet: it must land
    # AFTER any inverse-telecine/deinterlace step. Scaling or trimming a frame
    # that still has interlaced field structure combs it permanently. We also
    # switched from scale-down to pad-up (see the deferred block below) so we
    # never throw away picture rows — note 1080 is not a multiple of 16
    # (67.5×16), so the old code was silently scaling nearly every 1080p source
    # to 1072 and losing 8 rows.
    local vaapi_need_align=false
    local vaapi_aligned_width="" vaapi_aligned_height="" vaapi_src_width="" vaapi_src_height=""
    if [[ "$encoder_type" == "vaapi" ]]; then
	    local current_width current_height
	    if [[ -n "$vf_cpu" && "$vf_cpu" =~ crop=([0-9]+):([0-9]+) ]]; then
		    current_width="${BASH_REMATCH[1]}"
		    current_height="${BASH_REMATCH[2]}"
	    else
		    current_width=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input" | head -1)
		    current_height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input" | head -1)
		    current_width=${current_width//,/}
		    current_height=${current_height//,/}
	    fi

	    # Round UP to the next multiple of 16 — pad rather than crop.
	    vaapi_aligned_width=$(( ( (current_width + 15) / 16 ) * 16 ))
	    vaapi_aligned_height=$(( ( (current_height + 15) / 16 ) * 16 ))
	    vaapi_src_width="$current_width"
	    vaapi_src_height="$current_height"
	    if [[ "$vaapi_aligned_width" -ne "$current_width" || "$vaapi_aligned_height" -ne "$current_height" ]]; then
		    vaapi_need_align=true
	    fi
    fi

    if [[ "$encoder_type" == "vaapi" ]]; then
	    # ────────────────────────────────────────────────────────────
	    # VAAPI PATH: Deinterlace on CPU before hwupload
	    # deinterlace_vaapi is avoided: AMD's VAAPI implementation has
	    # poor/broken support for it, especially on 10-bit surfaces.
	    # CPU deinterlacing → progressive frames → hwupload is more
	    # reliable and respects the user's DEINTERLACER setting.
	    # ────────────────────────────────────────────────────────────

	# Determine if we should check for telecine. "auto" now scans at any
	# resolution — the most common telecine in an archiving workflow is 1080i
	# film off broadcast/Blu-ray, and the repeated-field cadence is just as
	# reliable at HD as at SD. detect_telecine's own rate prior keeps it from
	# firing on PAL or already-progressive film.
	local should_check_telecine=false
	if [[ "$DETECT_PULLDOWN" == "true" ]]; then
		should_check_telecine=true
	elif [[ "$DETECT_PULLDOWN" == "auto" ]]; then
		should_check_telecine=true
	fi

	# Field order for fieldmatch comes from the container when it's tagged,
	# falling back to TFF (the near-universal NTSC telecine order).
	local fm_order
	fm_order=$(get_field_order "$input"); fm_order="${fm_order:-tff}"

	# Check for telecine first
	local telecine="none"
	local skip_interlace=false
	if [[ "$should_check_telecine" == "true" ]]; then
		telecine=$(detect_telecine "$input")
		if [[ "$telecine" == "telecine" ]]; then
			# Telecine MUST be done on CPU (no GPU equivalent). IVTC:
			# fieldmatch reconstructs progressive frames, yadif with
			# deint=interlaced cleans the orphans it can't match, the decimator
			# drops the pulldown duplicates.
			[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
			vf_cpu="${vf_cpu}fieldmatch=order=${fm_order}:mode=${FIELDMATCH_MODE}:combmatch=full,yadif=mode=0:parity=-1:deint=1,${ivtc_decimator}"
			echo "        Inverse telecine via fieldmatch+yadif+${ivtc_decimator} (CPU, will be slower)" >&2
			skip_interlace=true
		fi
	fi

	# Deinterlace on CPU before hwupload. By the time we reach this branch,
	# cadenced film has already been routed to IVTC above, so whatever remains
	# flagged interlaced is treated as true video and gets the resolved rate.
	if [[ "$ADAPTIVE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
		vf_cpu="${vf_cpu}yadif=mode=0:parity=-1:deint=1"
		echo -e "    ${BOLD}Interlacing:${RESET} forced adaptive — yadif (interlaced frames only)" >&2
	elif [[ "$FORCE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
		local deint_rate=$(resolve_deint_rate "$input")
		local deint_filter=$(apply_deinterlacer "$fm_order" "$deint_rate")
		if [[ -n "$deint_filter" ]]; then
			vf_cpu="${vf_cpu}${deint_filter}"
		fi
	elif [[ "$DETECT_INTERLACING" == "true" && "$skip_interlace" == "false" ]]; then
		local interlacing=$(detect_interlacing "$input")
		if [[ "$interlacing" == "tff" || "$interlacing" == "bff" ]]; then
			[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
			local deint_rate=$(resolve_deint_rate "$input")
			local deint_filter=$(apply_deinterlacer "$interlacing" "$deint_rate")
			if [[ -n "$deint_filter" ]]; then
				vf_cpu="${vf_cpu}${deint_filter}"
			fi
		fi
	fi

	# Apply the deferred VAAPI alignment now — AFTER field processing — as a
	# pad so we never comb or discard rows. The pad sits at the bottom-right;
	# the encoder's conformance window would otherwise be the "right" answer,
	# but an explicit pad is predictable across ffmpeg/Mesa versions and the
	# few added pixels cost nothing.
	if [[ "$vaapi_need_align" == "true" ]]; then
		[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
		vf_cpu="${vf_cpu}pad=${vaapi_aligned_width}:${vaapi_aligned_height}:0:0"
		echo -e "    ${BOLD}Alignment:${RESET}   ${vaapi_src_width}x${vaapi_src_height} → ${vaapi_aligned_width}x${vaapi_aligned_height} (padded for VAAPI 16px)" >&2
	fi

	# Color space handling
	local colorspace_conversion=$(get_colorspace_conversion "$input" "$height")
	if [[ "$colorspace_conversion" == "hdr" ]]; then
		# HDR content detected - preserve metadata without conversion
		echo -e "    ${BOLD}Color space:${RESET} HDR — preserving metadata" >&2
	elif [[ "$colorspace_conversion" == "bt709" || "$colorspace_conversion" == "bt601" ]]; then
		# Source carries a legacy/mismatched tag — actually convert the pixels.
		local cs_filter=""
		if [[ "$colorspace_conversion" == "bt709" ]]; then
			cs_filter="colorspace=space=bt709:primaries=bt709:trc=bt709:range=tv"
			echo -e "    ${BOLD}Color space:${RESET} converting to BT.709 (HD standard)" >&2
		else
			cs_filter="colorspace=space=smpte170m:primaries=smpte170m:trc=smpte170m:range=tv"
			echo -e "    ${BOLD}Color space:${RESET} converting to BT.601 (SD standard)" >&2
		fi
		[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
		vf_cpu="${vf_cpu}${cs_filter}"
	elif [[ "$colorspace_conversion" == "tag601" ]]; then
		# Untagged SD — output tagged BT.601 in build_ffmpeg_command (no pixels touched)
		echo -e "    ${BOLD}Color space:${RESET} untagged — tagging output as BT.601 (SD convention)" >&2
	elif [[ "$colorspace_conversion" == "tag709" ]]; then
		echo -e "    ${BOLD}Color space:${RESET} untagged — tagging output as BT.709 (HD convention)" >&2
	fi

	# Build complete filter chain: CPU processing → format → hwupload
	[[ -n "$vf_cpu" ]] && vf="$vf_cpu,"
	if [[ "$bit_depth" == "12" ]]; then
		vf="${vf}format=p012le,hwupload"
	elif [[ "$bit_depth" == "10" ]]; then
		vf="${vf}format=p010le,hwupload"
	else
		vf="${vf}format=nv12,hwupload"
	fi

else
	# ────────────────────────────────────────────────────────────
	# SOFTWARE PATH: Use CPU filters with comprehensive color handling
	# ────────────────────────────────────────────────────────────

	vf="$vf_cpu"

	# Determine if we should check for telecine (auto = any resolution; see
	# the VAAPI branch for the rationale)
	local should_check_telecine=false
	if [[ "$DETECT_PULLDOWN" == "true" ]]; then
		should_check_telecine=true
	elif [[ "$DETECT_PULLDOWN" == "auto" ]]; then
		should_check_telecine=true
	fi

	local fm_order
	fm_order=$(get_field_order "$input"); fm_order="${fm_order:-tff}"

	# Check for telecine first
	local telecine="none"
	local skip_interlace=false
	if [[ "$should_check_telecine" == "true" ]]; then
		telecine=$(detect_telecine "$input")
		if [[ "$telecine" == "telecine" ]]; then
			[[ -n "$vf" ]] && vf="$vf,"
			vf="${vf}fieldmatch=order=${fm_order}:mode=${FIELDMATCH_MODE}:combmatch=full,yadif=mode=0:parity=-1:deint=1,${ivtc_decimator}"
			echo "        Inverse telecine via fieldmatch+yadif+${ivtc_decimator}" >&2
			skip_interlace=true
		fi
	fi

	# Check if adaptive deinterlacing is requested
	if [[ "$ADAPTIVE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		# Force adaptive deinterlacing regardless of detection
		[[ -n "$vf" ]] && vf="$vf,"
		vf="${vf}yadif=mode=0:parity=-1:deint=1"
		echo -e "    ${BOLD}Interlacing:${RESET} forced adaptive — yadif (deint=interlaced only)" >&2
	elif [[ "$FORCE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		# Force deinterlacing without detection
		[[ -n "$vf" ]] && vf="$vf,"
		local deint_rate=$(resolve_deint_rate "$input")
		local deint_filter=$(apply_deinterlacer "$fm_order" "$deint_rate")
		if [[ -n "$deint_filter" ]]; then
			vf="${vf}${deint_filter}"
		fi
	elif [[ "$DETECT_INTERLACING" == "true" && "$skip_interlace" == "false" ]]; then
		local interlacing=$(detect_interlacing "$input")

	    # Add deinterlacer if interlacing detected
	    if [[ "$interlacing" == "tff" || "$interlacing" == "bff" ]]; then
		    [[ -n "$vf" ]] && vf="$vf,"
		    local deint_rate=$(resolve_deint_rate "$input")
		    local deint_filter=$(apply_deinterlacer "$interlacing" "$deint_rate")
		    if [[ -n "$deint_filter" ]]; then
			    vf="${vf}${deint_filter}"
		    fi
	    fi
	fi

	# Comprehensive color space handling for software encoding
	local colorspace_conversion=$(get_colorspace_conversion "$input" "$height")

	if [[ "$colorspace_conversion" == "hdr" ]]; then
		# HDR content detected - preserve metadata without conversion
		echo -e "    ${BOLD}Color space:${RESET} HDR — preserving metadata" >&2
	elif [[ "$colorspace_conversion" == "bt709" || "$colorspace_conversion" == "bt601" ]]; then
		# Add colorspace filter
		local cs_filter=""
		if [[ "$colorspace_conversion" == "bt709" ]]; then
			cs_filter="colorspace=space=bt709:primaries=bt709:trc=bt709:range=tv"
			echo -e "    ${BOLD}Color space:${RESET} converting to BT.709 (HD standard)" >&2
		elif [[ "$colorspace_conversion" == "bt601" ]]; then
			cs_filter="colorspace=space=smpte170m:primaries=smpte170m:trc=smpte170m:range=tv"
			echo -e "    ${BOLD}Color space:${RESET} converting to BT.601 (SD standard)" >&2
		fi
		[[ -n "$vf" ]] && vf="$vf,"
		vf="${vf}${cs_filter}"
	elif [[ "$colorspace_conversion" == "tag601" ]]; then
		echo -e "    ${BOLD}Color space:${RESET} untagged — tagging output as BT.601 (SD convention)" >&2
	elif [[ "$colorspace_conversion" == "tag709" ]]; then
		echo -e "    ${BOLD}Color space:${RESET} untagged — tagging output as BT.709 (HD convention)" >&2
	elif [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
		# Tagged SD with a compatible space: keep the matrix intact across the encode
		[[ -n "$vf" ]] && vf="$vf,"
		vf="${vf}scale=in_color_matrix=bt601:out_color_matrix=bt601:flags=lanczos"
		echo -e "    ${BOLD}Color space:${RESET} bt601 matrix preserved" >&2
	fi
    fi

    echo "$vf"
}

# Build x265 parameters
build_x265_params() {
	local bit_depth="$1"
	local height="$2"
	local bframes_to_use="$BFRAMES"

    # Adjust B-frames for fastdecode tuning to avoid conflicts
    # fastdecode optimizes for decode speed, which means limiting B-frames
    if [[ "$X265_TUNE" == "fastdecode" ]] && [[ "$BFRAMES" -gt 1 ]]; then
	    echo "    NOTE: Adjusting B-frames from $BFRAMES to 1 for fastdecode compatibility" >&2
	    bframes_to_use="1"
    fi

    # Optimize for maximum CPU utilization
    local params="keyint=${GOP_SIZE}:min-keyint=${MIN_KEYINT}:bframes=${bframes_to_use}:ref=${REFS}"

    # Add thread pooling for better multi-core utilization
    # "+" means auto-detect optimal thread count and distribution
    params="${params}:pools=${X265_POOLS}"

    # Set appropriate profile and pixel format based on bit depth
    local profile pix_fmt
    if [[ "$bit_depth" == "12" ]]; then
	    profile="main12"
	    pix_fmt="yuv420p12le"
    elif [[ "$bit_depth" == "10" ]]; then
	    profile="main10"
	    pix_fmt="yuv420p10le"
    else
	    profile="main"
	    pix_fmt="yuv420p"
    fi

    # Add color metadata
    if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
	    params="${params}:colorprim=smpte170m:transfer=smpte170m:colormatrix=smpte170m:range=limited"
    else
	    params="${params}:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited"
    fi

    echo "${profile}|${pix_fmt}|${params}"
}

# Build priority prefix for software encoding
build_priority_prefix() {
	local prefix=""

	if [[ "$USE_NICE" == "true" ]]; then
		prefix="nice -n ${NICE_LEVEL}"
	fi

	if [[ "$USE_IONICE" == "true" ]]; then
		# Class 3 (idle) doesn't use priority levels
		if [[ "$IONICE_CLASS" == "3" ]]; then
			if [[ -n "$prefix" ]]; then
				prefix="${prefix} ionice -c ${IONICE_CLASS}"
			else
				prefix="ionice -c ${IONICE_CLASS}"
			fi
		else
			# Classes 1 (realtime) and 2 (best-effort) use levels 0-7
			if [[ -n "$prefix" ]]; then
				prefix="${prefix} ionice -c ${IONICE_CLASS} -n ${IONICE_LEVEL}"
			else
				prefix="ionice -c ${IONICE_CLASS} -n ${IONICE_LEVEL}"
			fi
		fi
	fi

	echo "$prefix"
}

# Detect bit depth from source
detect_bit_depth() {
	local input="$1"
	local pix_fmt=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1)

    # 12-bit formats
    if [[ "$pix_fmt" =~ (yuv420p12|yuv422p12|yuv444p12|p012|p016) ]]; then
	    echo "12"
	    return
    fi

    # 10-bit formats
    if [[ "$pix_fmt" =~ (yuv420p10|yuv422p10|yuv444p10|p010) ]]; then
	    echo "10"
	    return
    fi

    # Default to 8-bit
    echo "8"
}

# Get VAAPI profile based on bit depth
get_vaapi_profile() {
	local bit_depth="$1"

	if [[ "$bit_depth" == "12" ]]; then
		echo "main12"
	elif [[ "$bit_depth" == "10" ]]; then
		echo "main10"
	else
		echo "main"
	fi
}

# Check if a specific audio track requires conversion rather than copy.
# Covers container-specific PCM formats that cannot be safely muxed into standard
# containers: pcm_bluray (BD-specific) and pcm_dvd (DVD-specific).
needs_audio_remux() {
	local input="$1"
	local track_idx="$2"
	local audio_codec=$(ffprobe -v quiet -select_streams "a:${track_idx}" -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1 | tr -d '[:space:]')
	case "$audio_codec" in
		pcm_bluray|pcm_dvd)
			return 0 ;;
		*)
			return 1 ;;
	esac
}

# Return the source codec name for a given audio track (used for display)
get_audio_codec_name() {
	local input="$1"
	local track_idx="$2"
	ffprobe -v quiet -select_streams "a:${track_idx}" -show_entries stream=codec_name \
		-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1 | tr -d '[:space:]'
	}

# Check whether an audio track is already in an efficient lossy format that we
# should copy through rather than re-encode. Re-encoding an already-lossy codec
# to HE-AAC compounds generational loss while saving little or no space, so for
# the formats listed in AUDIO_PASSTHROUGH_CODECS we pass the track through
# untouched. Returns 0 (true) on a match, 1 otherwise.
audio_track_is_passthrough() {
	local input="$1"
	local track_idx="$2"
	local codec
	codec=$(get_audio_codec_name "$input" "$track_idx")
	local candidate
	for candidate in $AUDIO_PASSTHROUGH_CODECS; do
		if [[ "$codec" == "$candidate" ]]; then
			return 0
		fi
	done
	return 1
}

# Determine output codec for a subtitle track when muxing to MKV.
# Returns "copy" for MKV-compatible codecs, a transcode target (e.g. "srt") for
# formats that need conversion, or "drop" for codecs that cannot be meaningfully
# converted (embedded closed captions, binary data streams, etc.).
get_subtitle_output_codec() {
	local input="$1"
	local track_index="$2"
	local codec
	codec=$(ffprobe -v quiet -select_streams "s:${track_index}" \
		-show_entries stream=codec_name \
		-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1 | tr -d '[:space:]')
			case "$codec" in
				# MP4/ISOBMFF text subtitles — MKV does not support these; convert to SRT
				mov_text|ttml)
				echo "srt" ;;
				# WebVTT — convert to SRT for broad player compatibility
				webvtt)
				echo "srt" ;;
				# CEA-608/708 closed captions are embedded in the video stream and cannot
				# be independently muxed as a subtitle stream — drop them
				eia_608|eia_708|cea_608|cea_708)
				echo "drop" ;;
				# Binary data or unrecognized codec — not a real subtitle stream
				bin_data|"")
				echo "drop" ;;
				# All other codecs (ass, srt, hdmv_pgs_subtitle, dvd_subtitle,
				# dvb_subtitle, etc.) are MKV-compatible
				*)
				echo "copy" ;;
		esac
	}

# Get duration of a video file in seconds
get_video_duration() {
	local input="$1"
	local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

	# Handle empty or invalid durations
	if [[ -z "$duration" ]] || [[ "$duration" == "N/A" ]]; then
		echo "0"
		return
	fi

	# Convert to integer (round down)
	printf "%.0f" "$duration"
}

# Find m2ts files in Blu-ray disc structure, filtering by duration
# Recursively searches for BDMV/STREAM directories
find_bd_m2ts_files() {
	local search_path="$1"
	local min_duration="$2"

	# Find all STREAM directories in the BD structure
	while IFS= read -r -d '' stream_dir; do
		# Find all m2ts files in this STREAM directory
		while IFS= read -r -d '' m2ts_file; do
			local duration=$(get_video_duration "$m2ts_file")

			# Only include files meeting minimum duration
			if [[ "$duration" -ge "$min_duration" ]]; then
				echo "$m2ts_file"
			fi
		done < <(find "$stream_dir" -maxdepth 1 -type f -iname "*.m2ts" -print0 2>/dev/null | sort -z)
	done < <(find "$search_path" -type d -iname "STREAM" -path "*/BDMV/STREAM" -print0 2>/dev/null | sort -z)
}

# Determine color space conversion strategy for hardware encoding
# Returns: "none" | "bt601" | "bt709" | "tag601" | "tag709" | "hdr"
# - none:   No conversion needed, color space already compatible
# - bt601:  Convert pixels to BT.601 (tagged SD with a mismatched space)
# - bt709:  Convert pixels to BT.709 (tagged HD with a mismatched space)
# - tag601: Untagged SD — no conversion, tag output BT.601 by convention
# - tag709: Untagged HD — no conversion, tag output BT.709 by convention
# - hdr:    HDR/wide-gamut — preserve metadata, no conversion
get_colorspace_conversion() {
	local source_file="$1"
	local height="$2"
	local quiet="${3:-}"  # "quiet" suppresses the advisory warnings (for the
	# second, decision-only call in build_ffmpeg_command)

	# Check for manual override
	if [[ "$COLORSPACE" != "auto" ]]; then
		case "$COLORSPACE" in
			bt709|bt601)
				# User explicitly requested this color space conversion
				echo "$COLORSPACE"
				return
				;;
			hdr|none)
				# User explicitly disabled conversion or wants HDR preserved
				echo "none"
				return
				;;
			*)
				# Invalid value, fall through to auto detection
				[[ "$quiet" != "quiet" ]] && echo "    Warning: Invalid COLORSPACE value '$COLORSPACE', using auto detection" >&2
				;;
		esac
	fi

	# Get color metadata
	local color_space=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=color_space -of csv=p=0 "$source_file" 2>/dev/null | head -1 | tr -d ',' | xargs)
	local color_transfer=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$source_file" 2>/dev/null | head -1 | tr -d ',' | xargs)
	local color_primaries=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=color_primaries -of csv=p=0 "$source_file" 2>/dev/null | head -1 | tr -d ',' | xargs)

	# Check for Dolby Vision - cannot be preserved during transcoding
	local has_dolby_vision=$(ffprobe -v quiet -select_streams v:0 -show_entries stream_side_data=side_data_type -of csv=p=0 "$source_file" 2>/dev/null | grep -i "DOVI configuration record" || true)
	if [[ -n "$has_dolby_vision" && "$quiet" != "quiet" ]]; then
		echo -e "${YELLOW}    WARNING: Dolby Vision detected - will be stripped during transcoding${RESET}" >&2
		echo -e "${YELLOW}    Only HDR10 base layer will be preserved (colors may appear washed out)${RESET}" >&2
		echo -e "${YELLOW}    Consider keeping the original file for Dolby Vision playback${RESET}" >&2
	fi

	# Detect HDR content and preserve it
	# HDR10: smpte2084 (PQ), HDR10+: same as HDR10, HLG: arib-std-b67
	if [[ "$color_transfer" =~ ^(smpte2084|arib-std-b67)$ ]]; then
		echo "hdr"
		return
	fi

	# BT.2020 color space typically indicates HDR or wide color gamut content
	if [[ "$color_space" == "bt2020nc" || "$color_primaries" == "bt2020" ]]; then
		echo "hdr"
		return
	fi

	# Untagged or partly-tagged source: there's nothing reliable to convert
	# FROM, so we don't run a conversion — but the output should still declare a
	# color space by convention (SD is BT.601, HD is BT.709). This is lossless
	# VUI metadata and replaces the old "unsafe" path, which could only warn.
	# SD DVDs in particular are BT.601 but almost always ship untagged.
	if [[ "$color_space" =~ ^(unknown|)$ ]] || [[ "$color_transfer" =~ ^(unknown|)$ ]] || [[ "$color_primaries" =~ ^(unknown|)$ ]]; then
		if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
			echo "tag601"
		else
			echo "tag709"
		fi
		return
	fi

	# Determine target color space based on resolution
	local target_space
	if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
		target_space="bt601"
	else
		target_space="bt709"
	fi

	# Check if current color space is already compatible with VAAPI
	if [[ "$target_space" == "bt709" ]]; then
		# For HD content, bt709 is ideal
		if [[ "$color_space" == "bt709" ]]; then
			echo "none"
			return
		fi

		# Legacy spaces that need conversion to bt709
		if [[ "$color_space" =~ ^(bt470bg|smpte170m|bt601)$ ]]; then
			echo "bt709"
			return
		fi
	else
		# For SD content, bt601 is ideal
		if [[ "$color_space" == "bt601" ]]; then
			echo "none"
			return
		fi

		# SMPTE170M: Hardware encoding automatically falls back to software (see should_use_software_encoder)
		# No conversion needed - software handles SMPTE170M correctly as-is
		if [[ "$color_space" == "smpte170m" ]]; then
			echo "none"
			return
		fi

		# bt470bg is close to bt601, but convert for consistency
		if [[ "$color_space" == "bt470bg" ]]; then
			echo "bt601"
			return
		fi

		# HD content being downscaled or upscaled SD
		if [[ "$color_space" == "bt709" ]]; then
			echo "bt601"
			return
		fi
	fi

	# Other color spaces (bt2020, smpte240m, etc.) - convert to appropriate target
	echo "$target_space"
}

# Determine optimal encoder based on video characteristics
# Returns "libx265" for software or "hevc_vaapi" for hardware encoding
should_use_software_encoder() {
	local source_file="$1"

	# Get video properties
	local bit_depth=$(detect_bit_depth "$source_file")
	local pix_fmt=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$source_file" 2>/dev/null | head -1 | tr -d ',')
	local source_codec=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$source_file" 2>/dev/null | head -1 | tr -d ',')

	# ─── HARD BLOCKERS: Will definitely produce artifacts ───

	# 12-bit encoding when VAAPI doesn't support it
	# Very few GPUs support 12-bit HEVC encoding
	if [[ "$bit_depth" == "12" ]]; then
		if ! vainfo 2>/dev/null | grep -q "VAProfileHEVCMain12"; then
			echo "libx265"
			return
		fi
	fi

	# 10-bit encoding when VAAPI doesn't support it
	# This includes both: native 10-bit sources AND upgraded 8-bit sources
	# Check if hardware supports 10-bit HEVC (most modern Intel/AMD do)
	if [[ "$bit_depth" == "10" || "$UPGRADE_8BIT_TO_10BIT" == "true" ]]; then
		if ! vainfo 2>/dev/null | grep -q "VAProfileHEVCMain10"; then
			echo "libx265"
			return
		fi
	fi

	# Pixel formats that VAAPI doesn't support properly
	# VAAPI primarily works with yuv420p; other formats cause artifacts or fail
	if [[ "$pix_fmt" =~ ^(yuv422p|yuv411p|yuv440p|yuyv422|yuv444p)$ ]]; then
		echo "libx265"
		return
	fi

	# DV codec has known hardware encoding issues
	if [[ "$source_codec" == "dvvideo" ]]; then
		echo "libx265"
		return
	fi

	# ─── Everything below the hard blockers encodes in hardware ───
	#
	# Earlier versions also routed SD BT.601 (tagged smpte170m or untagged) and
	# interlaced content to software. Both rationales have since dissolved:
	#   • Color: the "VAAPI mangles BT.601" artifacts were really matrix
	#     mistagging — the bitstream signaling BT.709 on SD so players applied
	#     the wrong matrix. build_ffmpeg_command now tags the output BT.601
	#     explicitly, so the encoder isn't guessing and the colors are correct.
	#   • Interlacing: the VAAPI path deinterlaces/inverse-telecines on the CPU
	#     (bwdif/nnedi/fieldmatch) before hwupload, so it uses the exact same
	#     field processing software encoding would — there's no quality argument
	#     left for the detour.
	#
	# Hardware HEVC is several times faster at a fraction of the power (SD runs
	# into the thousands of fps), and libx265's marginally smaller file at equal
	# quality doesn't justify the time and wattage for most content. So once a
	# clip clears the genuine capability blockers above, it encodes in hardware.
	echo "hevc_vaapi"
}

# Get appropriate bitrate for audio track based on channel count
get_audio_bitrate() {
	local input="$1"
	local track_index="$2"

    # Get channel count for this audio track
    local channels=$(ffprobe -v quiet -select_streams a:$track_index -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

    # Default to stereo if detection fails
    if [[ -z "$channels" ]] || ! [[ "$channels" =~ ^[0-9]+$ ]]; then
	    echo "$AUDIO_BITRATE_STEREO"
	    return
    fi

    # Return appropriate bitrate based on channel count
    if [[ $channels -eq 1 ]]; then
	    echo "$AUDIO_BITRATE_MONO"
    elif [[ $channels -le 2 ]]; then
	    echo "$AUDIO_BITRATE_STEREO"
    elif [[ $channels -le 6 ]]; then
	    echo "$AUDIO_BITRATE_SURROUND"
    else
	    echo "$AUDIO_BITRATE_SURROUND_PLUS"
    fi
}

# Get audio track info and determine default audio track
get_audio_track_info() {
	local input="$1"
	local prefer_lang="$2"  # Language to prefer (empty = use first track)

    # Get all audio tracks with their language
    local audio_info=$(ffprobe -v quiet -select_streams a -show_entries stream_tags=language -of csv=p=0 "$input" 2>/dev/null)

    local default_index=0
    local track_index=0

    while IFS=',' read -r lang; do
	    # If we have a preferred language and this track matches, use it
	    if [[ -n "$prefer_lang" && "$lang" == "$prefer_lang" ]]; then
		    default_index=$track_index
		    echo "$default_index|$lang"
		    return
	    fi
	    track_index=$((track_index + 1))
    done <<< "$audio_info"

    # No match found, return first track with its language
    local first_lang=$(echo "$audio_info" | head -1)
    echo "0|${first_lang:-und}"
}

# Check if an audio track should be included based on language filtering
should_include_audio_track() {
	local input="$1"
	local track_index="$2"

    # If language filtering is disabled, include all tracks
    if [[ "$AUDIO_FILTER_LANGUAGES" != "true" ]]; then
	    echo "true"
	    return
    fi

    # Get track language and title
    local lang=$(ffprobe -v quiet -select_streams a:$track_index -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    local title=$(ffprobe -v quiet -select_streams a:$track_index -show_entries stream_tags=title -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

    # Always include if it's a commentary track (check title for "commentary" case-insensitive)
    if [[ -n "$title" ]] && [[ "$title" =~ [Cc]ommentary ]]; then
	    echo "true"
	    return
    fi

    # Build list of allowed languages
    # Start with user's default language
    local allowed_langs="$LANGUAGE"

    # Add original language if in original language mode
    if [[ "$PREFER_ORIGINAL" == "true" && -n "$ORIGINAL_LANGUAGE" ]]; then
	    allowed_langs="$allowed_langs,$ORIGINAL_LANGUAGE"
    fi

    # Always include 'und' (undetermined) tracks
    allowed_langs="$allowed_langs,und"

    # Check if track language is in the allowed list
    IFS=',' read -ra ALLOWED_LANGS <<< "$allowed_langs"
    for allowed in "${ALLOWED_LANGS[@]}"; do
	    # Trim whitespace
	    allowed=$(echo "$allowed" | xargs)
	    if [[ "$lang" == "$allowed" ]]; then
		    echo "true"
		    return
	    fi
    done

    # Track doesn't match criteria
    echo "false"
}

# Check if a subtitle track should be included based on language filtering
should_include_subtitle_track() {
	local input="$1"
	local track_index="$2"

    # Get track language
    local lang=$(ffprobe -v quiet -select_streams s:$track_index -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

    # Build list of allowed languages from LANGUAGE setting (can be comma-separated)
    local allowed_langs="$LANGUAGE"

    # Check if track language is in the allowed list
    IFS=',' read -ra ALLOWED_LANGS <<< "$allowed_langs"
    for allowed in "${ALLOWED_LANGS[@]}"; do
	    # Trim whitespace
	    allowed=$(echo "$allowed" | xargs)
	    if [[ "$lang" == "$allowed" ]]; then
		    echo "true"
		    return
	    fi
    done

    # Track doesn't match criteria
    echo "false"
}

# Read a subtitle track's cue count from container metadata, with no demux.
# mkvmerge/MakeMKV write a per-track NUMBER_OF_FRAMES statistics tag (the cue
# count for subtitle tracks); some files expose nb_frames instead. Echoes an
# integer, or nothing if no such metadata exists.
get_subtitle_cue_count() {
	local input="$1"
	local sub_idx="$2"
	local count
	# Statistics tag (may be plain or language-suffixed, e.g. NUMBER_OF_FRAMES-eng)
	count=$(ffprobe -v quiet -select_streams "s:${sub_idx}" -show_entries stream_tags \
		-of default=noprint_wrappers=1 "$input" 2>/dev/null \
		| grep -iE 'NUMBER_OF_FRAMES' | head -1 | sed 's/.*=//' | tr -dc '0-9')
		if [[ -n "$count" ]]; then echo "$count"; return; fi
		# Container-provided frame count, when present (often N/A for subtitles)
		count=$(ffprobe -v quiet -select_streams "s:${sub_idx}" -show_entries stream=nb_frames \
			-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | tr -dc '0-9')
					[[ -n "$count" ]] && echo "$count"
				}

# Estimate subtitle cue density (cues per minute) for a track. Strategy:
#   1. Read the cue count from container metadata (instant, no demux) — this
#      covers virtually all mkvmerge/MakeMKV output.
#   2. If there's no such metadata, an exact count requires demuxing the whole
#      subtitle stream, which is expensive on a large file over a network share.
#      We do that only for short files (cheap) or when SUBTITLE_FORCED_DEEP_SCAN
#      is enabled, printing a heads-up first. Otherwise we report nothing, and
#      the caller falls back to flag/title (treating the track as full).
# Echoes a float, or nothing when undeterminable.
subtitle_cues_per_min() {
	local input="$1"
	local sub_idx="$2"

	local duration
	duration=$(ffprobe -v quiet -show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | tr -d '[:space:]')
			[[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]] || return
			(( $(echo "$duration > 0" | bc -l 2>/dev/null || echo 0) )) || return

	# 1. Instant: cue count from metadata.
	local count
	count=$(get_subtitle_cue_count "$input" "$sub_idx")
	if [[ -n "$count" ]]; then
		echo "$(echo "scale=4; ($count * 60) / $duration" | bc -l 2>/dev/null)"
		return
	fi

	# 2. No metadata: full demux, gated on cost.
	local do_scan=false
	(( $(echo "$duration <= 900" | bc -l 2>/dev/null || echo 0) )) && do_scan=true
	[[ "$SUBTITLE_FORCED_DEEP_SCAN" == "true" ]] && do_scan=true
	if [[ "$do_scan" != "true" ]]; then
		return  # undeterminable cheaply; caller treats as full
	fi
	if (( $(echo "$duration > 900" | bc -l 2>/dev/null || echo 0) )); then
		echo -e "${YELLOW}    Scanning subtitle cues (no count metadata; may take a moment over network)...${RESET}" >&2
	fi
	local events
	events=$(ffprobe -v quiet -select_streams "s:${sub_idx}" -show_entries packet=pts \
		-of csv=p=0 "$input" 2>/dev/null | grep -c .)
			echo "$(echo "scale=4; ($events * 60) / $duration" | bc -l 2>/dev/null)"
		}

# Classify a subtitle track as "forced" (signs/songs/foreign-dialogue only) or
# "full" (complete dialogue). Strategy, cheapest-first:
#   1. The 'forced' disposition flag — authoritative when the muxer set it.
#   2. The title tag — "forced", "signs", or "songs" (case-insensitive).
#   3. Cue density — forced tracks light up only a handful of times per film,
#      full tracks run continuously. Only consulted when 1 and 2 are silent and
#      SUBTITLE_FORCED_DETECT_DENSITY is enabled.
# Echoes "forced" or "full".
classify_subtitle_track() {
	local input="$1"
	local sub_idx="$2"

	# 1. Disposition flag
	local forced_flag
	forced_flag=$(ffprobe -v quiet -select_streams "s:${sub_idx}" \
		-show_entries stream_disposition=forced \
		-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1 | tr -d '[:space:]')
			if [[ "$forced_flag" == "1" ]]; then
				echo "forced"
				return
			fi

	# 2. Title tag
	local title
	title=$(ffprobe -v quiet -select_streams "s:${sub_idx}" \
		-show_entries stream_tags=title \
		-of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1)
			if [[ "$title" =~ [Ff]orced|[Ss]igns|[Ss]ongs ]]; then
				echo "forced"
				return
			fi

	# 3. Cue-density fallback (opt-in; metadata flag and title were inconclusive).
	#    Cheap when the file carries cue-count metadata; see subtitle_cues_per_min.
	if [[ "$SUBTITLE_FORCED_DETECT_DENSITY" == "true" ]]; then
		local per_min
		per_min=$(subtitle_cues_per_min "$input" "$sub_idx")
		if [[ -n "$per_min" ]] && (( $(echo "$per_min < $SUBTITLE_FORCED_MAX_EVENTS_PER_MIN" | bc -l 2>/dev/null || echo 0) )); then
			echo "forced"
			return
		fi
	fi

	echo "full"
}

# Choose which subtitle track (if any) to enable by default, and whether it is a
# forced track. Two situations drive the decision:
#
#   * Default audio is NOT in the viewer's language (foreign film, or
#     original-language mode): we want a FULL track to translate all dialogue, so
#     pick the first full preferred-language track. If only a forced track
#     exists, fall back to it rather than leaving the viewer with nothing.
#
#   * Default audio IS already in the viewer's language (e.g. "Revolver", an
#     English film with untranslated Mandarin scenes): we don't want full subs,
#     but we DO want a forced/signs track so those scenes and on-screen signage
#     get translated automatically. Controlled by FORCED_SUBS_ON_NATIVE_AUDIO.
#
# Echoes "INPUT_SUB_INDEX|forced", "INPUT_SUB_INDEX|full", or "-1|none".
select_default_subtitle() {
	local input="$1"
	local audio_lang="$2"      # Language of the default audio track
	local native_langs="$3"    # Viewer's language(s), comma-separated (e.g. "eng" or "eng,spa")

	local sub_info
	sub_info=$(ffprobe -v quiet -select_streams s -show_entries stream_tags=language -of csv=p=0 "$input" 2>/dev/null)

	IFS=',' read -ra NATIVE_LANGS <<< "$native_langs"

	# Is the default audio already in one of the viewer's languages?
	local audio_is_native=false
	local native
	for native in "${NATIVE_LANGS[@]}"; do
		native=$(echo "$native" | xargs)
		if [[ "$audio_lang" == "$native" ]]; then
			audio_is_native=true
			break
		fi
	done

	# Walk preferred-language subtitle tracks, recording the first forced and the
	# first full track we encounter.
	local track_index=0
	local first_forced=-1
	local first_full=-1
	while IFS=',' read -r lang; do
		local match=false
		for native in "${NATIVE_LANGS[@]}"; do
			native=$(echo "$native" | xargs)
			if [[ "$lang" == "$native" ]]; then
				match=true
				break
			fi
		done
		if [[ "$match" == "true" ]]; then
			local kind
			kind=$(classify_subtitle_track "$input" "$track_index")
			if [[ "$kind" == "forced" && $first_forced -eq -1 ]]; then
				first_forced=$track_index
			elif [[ "$kind" == "full" && $first_full -eq -1 ]]; then
				first_full=$track_index
			fi
		fi
		track_index=$((track_index + 1))
	done <<< "$sub_info"

	if [[ "$audio_is_native" == "true" ]]; then
		# Native audio: only a forced/signs track is wanted, and only if enabled
		if [[ "$FORCED_SUBS_ON_NATIVE_AUDIO" == "true" && $first_forced -ne -1 ]]; then
			echo "${first_forced}|forced"
		else
			echo "-1|none"
		fi
	else
		# Foreign audio: prefer a full track, fall back to forced if that's all
		if [[ $first_full -ne -1 ]]; then
			echo "${first_full}|full"
		elif [[ $first_forced -ne -1 ]]; then
			echo "${first_forced}|forced"
		else
			echo "-1|none"
		fi
	fi
}

# Check if file should be split by chapters
should_split_by_chapters() {
	local input="$1"
	local content_type="$2"

	# Chapter count is the cheap pre-check
	local chapter_count=$(ffprobe -v quiet -show_chapters "$input" 2>/dev/null | grep -c "^\[CHAPTER\]" || true)
	[[ $chapter_count -gt 1 ]] || { echo "false"; return; }

	# A file is only split when its chapters actually mark episode boundaries.
	# Rather than guess from file length (a single drama episode can run 70+
	# minutes, while a multi-episode disc and a single episode can be the same
	# size), require evidence: an explicit per-episode count, or a confident
	# repeating episodic period from detect_chapters_per_episode (which returns
	# "0" when the chapters are intra-episode scene markers). This is what keeps
	# a long single episode with scene chapters from being shredded into scenes.
	local has_grouping="false"
	if [[ "$CHAPTERS_PER_EPISODE" != "auto" ]]; then
		has_grouping="true"            # user specified the grouping explicitly
	elif [[ "$(detect_chapters_per_episode "$input")" != "0" ]]; then
		has_grouping="true"            # a real episodic period was detected
	fi
	[[ "$has_grouping" == "true" ]] || { echo "false"; return; }

	if [[ "$SPLIT_CHAPTERS" == "true" ]]; then
		echo "true"; return
	elif [[ "$SPLIT_CHAPTERS" == "auto" ]]; then
		[[ "$content_type" == "series" ]] && { echo "true"; return; }
	fi

	echo "false"
}

# Get chapter times for splitting
get_chapter_times() {
	local input="$1"

    # Extract only chapter start times using a more reliable method
    ffprobe -v quiet -show_chapters "$input" 2>/dev/null | grep "start_time=" | cut -d'=' -f2
}

# Numeric check for the non-negative values bc produces here. Also accepts bc's
# leading-zero-less output for values in (0,1) — bc prints "0.24" as ".24",
# which a leading-digit-anchored regex wrongly rejects. Rejects negatives and
# garbage so bad chapter data bails out.
is_numeric() { [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]]; }

# Detect optimal chapters per episode grouping.
#
# Scores each candidate grouping by how uniform its full (g-chapter) episodes
# are: disc-authored episodes share a near-identical chapter layout (e.g. OP,
# two content parts, ED, next-episode preview), so the correct grouping has by
# far the lowest episode-to-episode duration variance. A leftover smaller than g
# becomes a short final episode (a finale with no next-ep preview, which is what
# makes a disc's chapter count indivisible) — it's allowed but excluded from the
# uniformity score so it can't penalize the right grouping. Lowest stddev wins,
# with a 15-35 min mean-episode gate to rule out the degenerate 1-chapter case.
detect_chapters_per_episode() {
	local input="$1"

	local chapter_times=($(get_chapter_times "$input"))
	local chapter_count=${#chapter_times[@]}
	[[ $chapter_count -eq 0 ]] && { echo "0"; return; }

	local total_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
	total_duration=${total_duration//,/}
	is_numeric "$total_duration" || { echo "0"; return; }

	# Per-chapter durations (last chapter runs to end of file)
	local durations=() i
	for ((i=0; i<chapter_count; i++)); do
		local start="${chapter_times[$i]}" end
		if (( i+1 < chapter_count )); then end="${chapter_times[$((i+1))]}"; else end="$total_duration"; fi
		is_numeric "$start" && is_numeric "$end" || { echo "0"; return; }
		local d=$(echo "$end - $start" | bc 2>/dev/null)
		is_numeric "$d" || { echo "0"; return; }
		durations+=("$d")
	done

	# Structural-period detection. Disc-authored episodes repeat a chapter layout
	# that includes at least one recurring marker (OP, recap, title card, next-
	# episode preview), so the true chapters-per-episode is the smallest grouping
	# g at which the duration sequence repeats: a low mean relative difference
	# between chapter i and chapter i+g. This keys on repeating structure rather
	# than absolute length, so it works identically for ~11-minute cartoons and
	# ~50-minute dramas — unlike a fixed episode-length window, which can't bound
	# both. One awk pass scores every candidate grouping.
	local thresh="0.18"    # mean relative diff at/below this == episode-aligned
	local min_ep_sec=120   # ignore groupings implying sub-2-minute episodes

	local scores
	scores=$(printf '%s\n' "${durations[@]}" | awk -v gmax=8 '
	{ d[NR]=$1+0; n=NR }
	END {
	for (g=1; g<=gmax; g++) {
		if (int(n/g) < 2) continue
			sum=0; cnt=0
			for (i=1; i+g<=n; i++) {
				a=d[i]; b=d[i+g]; mx=(a>b)?a:b
				if (mx<=0) continue
					diff=a-b; if (diff<0) diff=-diff
					sum+=diff/mx; cnt++
				}
				if (cnt>0) printf "%d %.4f\n", g, sum/cnt
				}
			}')

	# Smallest grouping at/below threshold wins (the base period, not a multiple).
	local g score
	while read -r g score; do
		[[ -z "$g" ]] && continue
		local ep_len_int
		ep_len_int=$(awk -v t="$total_duration" -v g="$g" -v c="$chapter_count" 'BEGIN{printf "%.0f", t*g/c}')
		(( ep_len_int < min_ep_sec )) && continue
		if awk -v s="$score" -v t="$thresh" 'BEGIN{exit !(s<=t)}'; then
			echo "$g"; return
		fi
	done <<< "$scores"

	# No grouping repeats cleanly: the chapters are intra-episode scene markers,
	# not episode boundaries (e.g. a single long drama episode with scene
	# chapters). Signal "no episodic period" so the caller keeps the file whole.
	echo "0"
}

# Infer content type from directory structure
infer_type() {
	local source="$1"

    # Check for season/disc patterns (case-insensitive)
    if [[ "$source" =~ [Ss][0-9]+[^0-9]*[Dd][0-9]+ ]] || [[ "$source" =~ [Ss]eason.*[0-9]+ ]]; then
	    echo "series"
	    return
    fi

    # Check if directory contains S#D# subdirectories (multi-season series, case-insensitive)
    shopt -s nullglob nocaseglob
    local season_dirs=("$source"/*[Ss][0-9]*[Dd][0-9]*)
    shopt -u nullglob nocaseglob
    if [[ ${#season_dirs[@]} -gt 0 ]]; then
	    echo "series"
	    return
    fi

    # Check if directory contains multiple video files
    local video_count=$(count_video_files "$source")
    if [[ $video_count -gt 1 ]]; then
	    echo "series"
	    return
    fi

    # Default to movie for single file
    echo "movie"
}

# Extract a SEASON number from a single path component (directory or file name).
# Echoes the number (no leading zeros) or "UNKNOWN". Used both for directory
# layouts (S02D1, "Season 2") and as the dirname half of season detection.
season_from_path() {
	local s="$1"
	# S#D# disc directory (e.g. S02D1, Show.S2.D1)
	if [[ "$s" =~ [Ss]([0-9]+)[^0-9]*[Dd][0-9]+ ]]; then echo "$((10#${BASH_REMATCH[1]}))"; return; fi
	# "Season N" / "Series N"
	if [[ "$s" =~ [Ss](eason|eries)[[:space:]._-]*([0-9]+) ]]; then echo "$((10#${BASH_REMATCH[2]}))"; return; fi
	# Bare zero-padded S## token
	if [[ "$s" =~ [Ss]([0-9]{2}) ]]; then echo "$((10#${BASH_REMATCH[1]}))"; return; fi
	echo "UNKNOWN"
}

# Get all seasons present under a source directory. Unions three signals so that
# disc-based layouts, "Season N" folders, and flat directories whose season
# lives only in the filenames are all detected:
#   1. S#D# disc subdirectories
#   2. "Season N" / "Series N" subdirectories
#   3. Season tags in the video filenames themselves (top level + one level deep)
# Echoes the unique season numbers, one per line, sorted ascending.
get_all_seasons() {
	local source="$1"
	local -A season_set=()

	shopt -s nullglob nocaseglob
	# 1 + 2: season-bearing subdirectories
	local dir b s
	for dir in "$source"/*[Ss][0-9]*[Dd][0-9]* "$source"/*[Ss]eason* "$source"/*[Ss]eries*; do
		[[ -d "$dir" ]] || continue
		s=$(season_from_path "$(basename "$dir")")
		[[ "$s" != "UNKNOWN" ]] && season_set["$s"]=1
	done
	shopt -u nullglob nocaseglob

	# 3: season tags in filenames (handles flat multi-season dirs and mixed layouts)
	local ext f
	for ext in $INPUT_VIDEO_EXTENSIONS; do
		while IFS= read -r -d '' f; do
			s=$(get_season_num "$(basename "$f")")
			[[ "$s" != "UNKNOWN" ]] && season_set["$s"]=1
		done < <(find "$source" -maxdepth 2 -type f -iname "*.$ext" -print0 2>/dev/null)
	done

	if [[ ${#season_set[@]} -gt 0 ]]; then
		printf '%s\n' "${!season_set[@]}" | sort -n
	fi
}

# Find video files in directory using configured extensions
# Usage: find_video_files "/path/to/dir" array_name
find_video_files() {
	local dir="$1"
	local -n result_array=$2

	result_array=()
	shopt -s nullglob
	for ext in $INPUT_VIDEO_EXTENSIONS; do
		result_array+=("$dir"/*."$ext")
	done
	shopt -u nullglob
}

# Count video files in directory
count_video_files() {
	local dir="$1"
	local count=0

	for ext in $INPUT_VIDEO_EXTENSIONS; do
		local ext_count=$(find "$dir" -maxdepth 1 -iname "*.$ext" 2>/dev/null | wc -l)
		count=$((count + ext_count))
	done

	echo "$count"
}

# Extract season number from a full path, defaulting to 1 when nothing matches.
# Scans path components from the most specific (the item itself) outward so a
# disc/season folder anywhere in the path is honored.
extract_season() {
	local source="$1"
	local component s
	# Walk path components leaf-first
	while [[ -n "$source" && "$source" != "." && "$source" != "/" ]]; do
		component=$(basename "$source")
		s=$(season_from_path "$component")
		[[ "$s" != "UNKNOWN" ]] && { echo "$s"; return; }
		source=$(dirname "$source")
	done
	echo "1"  # Default to season 1
}

# Decide which season a file belongs to, most specific signal first:
#   1. the file's own name (e.g. Show_S02_E01.mkv)
#   2. its containing directory (S02D1, "Season 2")
#   3. the season currently being processed (context fallback)
# This is what lets a flat directory of mixed-season files split correctly while
# leaving path-separated disc/season layouts working exactly as before.
get_effective_season() {
	local file="$1"
	local container="$2"
	local ctx_season="$3"
	local s
	s=$(get_season_num "$(basename "$file")")
	[[ "$s" != "UNKNOWN" ]] && { echo "$s"; return; }
	s=$(season_from_path "$(basename "$container")")
	[[ "$s" != "UNKNOWN" ]] && { echo "$s"; return; }
	echo "$ctx_season"
}

# Extract show/movie name from path
extract_name() {
	local source="$1"
	local type="$2"

    # For movie mode with a file, try metadata title first, then filename
    if [[ "$type" == "movie" && -f "$source" ]]; then
	    # Try to get title from metadata
	    local metadata_title=$(ffprobe -v quiet -show_entries format_tags=title -of default=noprint_wrappers=1:nokey=1 "$source" 2>/dev/null)
	    if [[ -n "$metadata_title" && "$metadata_title" != "N/A" ]]; then
		    echo "$metadata_title"
		    return
	    fi

	# Fall back to filename
	local filename=$(basename "$source")
	# Remove extension
	filename="${filename%.*}"
	# Remove technical suffixes like _t00, _t01, etc.
	filename=$(echo "$filename" | sed -E 's/_t[0-9]{2}$//')
	# Remove disc/title markers like -B1, -D1, etc.
	filename=$(echo "$filename" | sed -E 's/-[BDT][0-9]+$//')
	# If we got a meaningful name, use it
	if [[ -n "$filename" && "$filename" != "." ]]; then
		echo "$filename"
		return
	fi
    fi

    # If source is a file, get its directory
    if [[ -f "$source" ]]; then
	    source="$(dirname "$source")"
    fi

    # Try to get parent directory name
    local dirname=""

    # If source itself is a disc directory (S#D# pattern), go up one level (case-insensitive)
    if [[ "$(basename "$source")" =~ ^.*[Ss][0-9]+[^0-9]*[Dd][0-9]+$ ]]; then
	    dirname=$(basename "$(dirname "$source")")
    else
	    # Get the parent directory name
	    dirname=$(basename "$(dirname "$source")")

	# If source itself is the show directory
	if [[ -d "$source" ]]; then
		dirname=$(basename "$source")
	fi
    fi

    # Clean up season/disc markers (case-insensitive)
    dirname=$(echo "$dirname" | sed -E 's/[[:space:]]*[Ss][0-9]+[Dd]?[0-9]*//g')
    dirname=$(echo "$dirname" | sed -E 's/[[:space:]]*[Ss]eason[[:space:]]*[0-9]+//g')
    dirname=$(echo "$dirname" | sed -E 's/[[:space:]]*[Dd]isc[[:space:]]*[0-9]+//g')
    dirname=$(echo "$dirname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$dirname" || "$dirname" == "." ]]; then
	    dirname="Unknown"
    fi

    echo "$dirname"
}

# Normalize source input - handles both directories and files
# Sets SOURCE_DIR and populates SOURCE_FILES array if files were specified
normalize_source() {
	# Accept all arguments as separate files (handles glob expansion by shell)
	SOURCE_FILES=()
	SOURCE_DIR=""

    # Check if we have any arguments at all
    if [[ $# -eq 0 ]]; then
	    return 1
    fi

    # If we got multiple arguments, they're pre-expanded files from shell globbing
    if [[ $# -gt 1 ]]; then
	    SOURCE_FILES=("$@")
	    SOURCE_DIR="$(dirname "${SOURCE_FILES[0]}")"
	    return 0
    fi

    local source="${1}"

    # Check if source is a file
    if [[ -f "$source" ]]; then
	    # Single file
	    SOURCE_FILES=("$source")
	    SOURCE_DIR="$(dirname "$source")"
	    return 0
    fi

    # Check if source is a directory
    if [[ -d "$source" ]]; then
	    SOURCE_DIR="$source"

	    # Check if this is a BD dump by looking for BDMV/STREAM directories
	    local has_bd_structure=false
	    if find "$source" -type d -iname "STREAM" -path "*/BDMV/STREAM" -print -quit 2>/dev/null | grep -q .; then
		    has_bd_structure=true
	    fi

	    # If BD structure found, collect m2ts files with duration filtering
	    if [[ "$has_bd_structure" == "true" ]]; then
		    echo -e "${CYAN}Detected Blu-ray disc structure - scanning for m2ts files (minimum duration: ${BD_MIN_DURATION}s)${RESET}"
		    readarray -t SOURCE_FILES < <(find_bd_m2ts_files "$source" "$BD_MIN_DURATION")

		    if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
			    echo -e "${RED}Error: No m2ts files found matching minimum duration${RESET}"
			    return 1
		    fi

		    echo -e "${CYAN}Found ${#SOURCE_FILES[@]} m2ts file(s) meeting duration criteria${RESET}"
	    fi

	    return 0
    fi

    # Nothing found
    return 1
}

# Build ffmpeg command (refactored to eliminate duplication)
build_ffmpeg_command() {
	local source_file="$1"
	local output_file="$2"
	local input_opts="${3:-}"  # Optional, for chapter extraction (default to empty)
	# Optional: a precomputed "idx|kind" subtitle decision from select_default_subtitle.
	# The series path resolves this once for its display line and passes it back here
	# so we don't classify (and re-sample) the subtitle tracks a second time. Empty
	# means compute it ourselves (movie path, dry-run).
	local precomputed_sub_spec="${4:-}"

    # Video analysis (bit depth, encoder choice, filter chain) is only needed
    # when we're actually re-encoding. Copy-only mode keeps the source video
    # stream verbatim, so we skip all of this — including the crop/interlace
    # detection passes inside build_vf, which would otherwise spawn ffmpeg.
    local bit_depth="" height="" actual_codec="" encoder_type="" vf=""
    if [[ "$COPY_ONLY" != "true" ]]; then
	    # Detect bit depth and height
	    bit_depth=$(detect_bit_depth "$source_file")
	    height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$source_file" | head -1)
	    height=${height//,/}

	    # Adjust bit depth based on user preferences
	    if [[ "$DOWNGRADE_12BIT_TO_10BIT" == "true" && "$bit_depth" == "12" ]]; then
		    bit_depth="10"
	    fi
	    if [[ "$UPGRADE_8BIT_TO_10BIT" == "true" && "$bit_depth" == "8" ]]; then
		    bit_depth="10"
	    fi

	    # Determine encoder
	    if [[ "$VIDEO_CODEC" == "auto" ]]; then
		    actual_codec=$(should_use_software_encoder "$source_file")
		    if [[ "$actual_codec" == "libx265" ]]; then
			    encoder_type="software"
		    else
			    encoder_type="vaapi"
		    fi
	    else
		    actual_codec="$VIDEO_CODEC"
		    if [[ "$actual_codec" == "hevc_vaapi" ]]; then
			    encoder_type="vaapi"
		    else
			    encoder_type="software"
		    fi
	    fi

	    # Build filter chain
	    vf=$(build_vf "$source_file" "$encoder_type" "$bit_depth")
    fi

    # Count audio tracks
    local num_audio=$(ffprobe -v quiet -select_streams a -show_entries stream=index -of csv=p=0 "$source_file" 2>/dev/null | wc -l)

    # Determine preferred audio track
    local preferred_audio_lang=""
    if [[ "$PREFER_ORIGINAL" == "true" && -n "$ORIGINAL_LANGUAGE" ]]; then
	    preferred_audio_lang="$ORIGINAL_LANGUAGE"
    fi

    local default_audio_idx default_audio_lang
    IFS='|' read -r default_audio_idx default_audio_lang <<< "$(get_audio_track_info "$source_file" "$preferred_audio_lang")"

    # Build audio options
    local audio_opts=""

    # Check whether the default audio track uses a container-specific PCM format
    # (pcm_bluray, pcm_dvd) that cannot be safely copied to a standard muxer.
    local has_pcm_bluray=false
    if [[ $num_audio -gt 0 ]] && needs_audio_remux "$source_file" "$default_audio_idx"; then
	    has_pcm_bluray=true
    fi

    # Map the preferred audio track first. A file may legitimately have no audio
    # (silent films, or audio stripped in a prior edit); in that case we map no
    # audio at all rather than emitting a -map for a stream that doesn't exist,
    # which would make ffmpeg abort.
    if [[ $num_audio -eq 0 ]]; then
	    echo -e "${YELLOW}    No audio tracks found; output will have no audio${RESET}" >&2
    elif [[ "$has_pcm_bluray" == "true" ]]; then
	    # pcm_bluray must be converted - use FLAC for lossless preservation
	    audio_opts="-map 0:a:$default_audio_idx -c:a:0 flac"
    elif [[ "$COPY_ONLY" == "true" || "$AUDIO_COPY_FIRST" == "true" ]]; then
	    audio_opts="-map 0:a:$default_audio_idx -c:a:0 copy"
    else
	    local bitrate=$(get_audio_bitrate "$source_file" $default_audio_idx)
	    audio_opts="-map 0:a:$default_audio_idx -c:a:0 $AUDIO_CODEC -profile:a:0 $AUDIO_PROFILE -b:a:0 $bitrate"
    fi

    # Map remaining audio tracks. track_idx doubles as the running count of
    # output audio tracks; it starts at 1 because the preferred track above is
    # output audio 0.
    local track_idx=1
    if [[ $num_audio -gt 1 ]]; then
	    for ((i=0; i<num_audio; i=i+1)); do
		    if [[ $i -eq $default_audio_idx ]]; then
			    continue
		    fi

	    # Check if we should include this track
	    if [[ "$(should_include_audio_track "$source_file" $i)" != "true" ]]; then
		    continue
	    fi

	    # Tracks already in an efficient lossy format (Opus, AAC, ...) are
	    # copied as-is: re-encoding them to HE-AAC only compounds generational
	    # loss for negligible space savings. Everything else is encoded to
	    # HE-AAC at a channel-appropriate bitrate. In copy-only mode every track
	    # is copied (FLAC only where a stream can't be muxed verbatim).
	    if [[ "$COPY_ONLY" == "true" ]]; then
		    if needs_audio_remux "$source_file" "$i"; then
			    audio_opts="$audio_opts -map 0:a:$i -c:a:$track_idx flac"
		    else
			    audio_opts="$audio_opts -map 0:a:$i -c:a:$track_idx copy"
		    fi
	    elif audio_track_is_passthrough "$source_file" $i; then
		    audio_opts="$audio_opts -map 0:a:$i -c:a:$track_idx copy"
	    else
		    local bitrate=$(get_audio_bitrate "$source_file" $i)
		    audio_opts="$audio_opts -map 0:a:$i -c:a:$track_idx $AUDIO_CODEC -profile:a:$track_idx $AUDIO_PROFILE -b:a:$track_idx $bitrate"
	    fi
	    track_idx=$((track_idx + 1))
    done
    fi
    # Exactly one audio track may carry the default/enabled flag. Make the
    # preferred track (output a:0) default and strip the flag from every other
    # output audio track, so a source that shipped more than one "default" audio
    # track (e.g. an English dub flagged alongside the Japanese original) doesn't
    # leave the container with two enabled tracks and ambiguous player behavior.
    # Relative +/-default is used so other flags (commentary, original, ...) survive.
    if [[ $num_audio -gt 0 ]]; then
	    audio_opts="$audio_opts -disposition:a:0 +default"
	    local extra_a
	    for ((extra_a=1; extra_a<track_idx; extra_a=extra_a+1)); do
		    audio_opts="$audio_opts -disposition:a:$extra_a -default"
	    done
    fi

    # Smart subtitle handling with language filtering
    local num_subs=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$source_file" 2>/dev/null | wc -l)

    # Build subtitle mapping - only include subtitles in our language(s)
    local sub_opts=""
    local sub_track_idx=0
    declare -A input_to_output_sub_map
    declare -a sub_out_codecs  # output codec per output track index

    for ((i=0; i<num_subs; i=i+1)); do
	    # Check if we should include this subtitle track
	    if [[ "$(should_include_subtitle_track "$source_file" $i)" == "true" ]]; then
		    local sub_codec
		    sub_codec=$(get_subtitle_output_codec "$source_file" $i)
		    if [[ "$sub_codec" == "drop" ]]; then
			    echo -e "${YELLOW}    Skipping subtitle track $i: codec incompatible with MKV output${RESET}" >&2
			    continue
		    fi
		    sub_opts="$sub_opts -map 0:s:$i"
		    sub_out_codecs[$sub_track_idx]="$sub_codec"
		    input_to_output_sub_map[$i]=$sub_track_idx
		    sub_track_idx=$((sub_track_idx + 1))
	    fi
    done

    # Add per-track codec options (converts incompatible formats, e.g. mov_text → srt)
    if [[ $sub_track_idx -gt 0 ]]; then
	    for ((i=0; i<sub_track_idx; i=i+1)); do
		    sub_opts="$sub_opts -c:s:$i ${sub_out_codecs[$i]}"
	    done

	# Determine which subtitle should be enabled by default, and whether it is
	# a forced/signs track (forced tracks get both 'default' and 'forced' so
	# compliant players show them even with subtitles otherwise turned off).
	local sub_default_input_idx sub_default_kind
	if [[ -n "$precomputed_sub_spec" ]]; then
		IFS='|' read -r sub_default_input_idx sub_default_kind <<< "$precomputed_sub_spec"
	else
		IFS='|' read -r sub_default_input_idx sub_default_kind \
			<<< "$(select_default_subtitle "$source_file" "$default_audio_lang" "$LANGUAGE")"
	fi

	# Check if the chosen subtitle exists in our filtered set
	if [[ "$sub_default_input_idx" != "-1" ]] && [[ -v input_to_output_sub_map[$sub_default_input_idx] ]]; then
		# Map input index to output index
		local sub_default_output_idx="${input_to_output_sub_map[$sub_default_input_idx]}"
		# Forced tracks: default+forced. Full tracks: default. Everything else: cleared.
		local default_disposition="default"
		[[ "$sub_default_kind" == "forced" ]] && default_disposition="default+forced"
		for ((i=0; i<sub_track_idx; i=i+1)); do
			if [[ $i -eq $sub_default_output_idx ]]; then
				sub_opts="$sub_opts -disposition:s:$i $default_disposition"
			else
				sub_opts="$sub_opts -disposition:s:$i 0"
			fi
		done
	else
		# No default subtitle, set all to 0
		for ((i=0; i<sub_track_idx; i=i+1)); do
			sub_opts="$sub_opts -disposition:s:$i 0"
		done
	fi
    fi

    # Assemble the ffmpeg invocation as an argument array and execute it
    # directly (see the call sites) instead of building a string for eval. eval
    # re-parses its argument as shell source, so a backtick, $, or quote in a
    # filename becomes live syntax (a stray backtick in an episode title is what
    # exposed this). An array passes every argument through literally. The option
    # groups spliced in with read -ra (priority prefix, input options, audio and
    # subtitle maps) are script-generated tokens with no embedded spaces, so
    # word-splitting them is safe; only the file paths carry arbitrary
    # characters, and those are added as single elements.
    local priority_prefix=$(build_priority_prefix)
    local -a prefix_arr=() input_arr=() audio_arr=() subs_arr=()
    [[ -n "$priority_prefix" ]] && read -ra prefix_arr <<< "$priority_prefix"
    [[ -n "$input_opts" ]] && read -ra input_arr <<< "$input_opts"
    [[ -n "$audio_opts" ]] && read -ra audio_arr <<< "$audio_opts"
    [[ -n "$sub_opts" ]] && read -ra subs_arr <<< "$sub_opts"

    # fieldmatch logs a per-frame "still interlaced" warning for every frame it
    # can't match. Those are harmless here — the yadif cleanup handles them
    # downstream — but on mixed-cadence anime they flood thousands of lines and
    # bury the script's own output (and the matroska muxer adds VFR "new
    # cluster" chatter on top). Drop the encode to error level to mute the
    # benign noise; -stats still draws the live progress bar and genuine errors
    # still surface. An explicitly verbose FFMPEG_LOGLEVEL is respected so
    # debugging sessions keep the full firehose.
    local encode_loglevel="$FFMPEG_LOGLEVEL"
    if [[ "$vf" == *fieldmatch* ]]; then
	    case "$FFMPEG_LOGLEVEL" in
		    verbose|debug|trace) : ;;
		    *) encode_loglevel="error" ;;
	    esac
    fi

    FFMPEG_CMD=("${prefix_arr[@]}" ffmpeg -hide_banner -loglevel "$encode_loglevel" -stats)
    FFMPEG_CMD+=(-analyzeduration "$FFMPEG_ANALYZEDURATION" -probesize "$FFMPEG_PROBESIZE")
    FFMPEG_CMD+=("${input_arr[@]}" -i "$source_file" -map 0:v:0)
    FFMPEG_CMD+=("${audio_arr[@]}" "${subs_arr[@]}")

    if [[ "$COPY_ONLY" == "true" ]]; then
	    # Remux: keep the video stream verbatim. Track mapping, audio/subtitle
	    # codecs, dispositions, and chapters are already resolved above exactly
	    # as they would be for an encode; only the video codec changes to copy.
	    FFMPEG_CMD+=(-c:v copy)
    elif [[ "$encoder_type" == "vaapi" ]]; then
	    local vaapi_profile=$(get_vaapi_profile "$bit_depth")
	    FFMPEG_CMD+=(-c:v "$actual_codec" -vaapi_device "$VAAPI_DEVICE" -rc_mode CQP -qp "$QUALITY")
	    [[ -n "$VAAPI_COMPRESSION_LEVEL" ]] && FFMPEG_CMD+=(-compression_level "$VAAPI_COMPRESSION_LEVEL")
	    # -bf is ignored by hevc_vaapi on AMD (all VCN); effective on libx265/h264_vaapi only
	    FFMPEG_CMD+=(-g "$GOP_SIZE" -keyint_min "$MIN_KEYINT" -bf "$BFRAMES" -low_power false)
	    FFMPEG_CMD+=(-refs "$REFS" -profile:v "$vaapi_profile")
	    [[ -n "$vf" ]] && FFMPEG_CMD+=(-vf "$vf")
    else
	    local x265_profile pix_fmt x265_params
	    IFS='|' read -r x265_profile pix_fmt x265_params <<< "$(build_x265_params "$bit_depth" "$height")"
	    FFMPEG_CMD+=(-c:v "$actual_codec" -preset "$PRESET")
	    [[ -n "$X265_TUNE" ]] && FFMPEG_CMD+=(-tune "$X265_TUNE")
	    FFMPEG_CMD+=(-crf "$QUALITY" -pix_fmt "$pix_fmt")
	    [[ -n "$vf" ]] && FFMPEG_CMD+=(-vf "$vf")
	    FFMPEG_CMD+=(-x265-params "$x265_params")
    fi

    # mpdecimate (adaptive IVTC) yields variable frame durations: pulldown
    # duplicates are dropped in film sections while unique frames survive in
    # interlaced-video/effects sections. Emit VFR so survivors keep their own
    # timestamps; forcing CFR here would re-pad to a constant rate and put back
    # exactly the judder mpdecimate removed. Keyed off the filter string so we
    # don't depend on a flag leaking out of build_vf's command substitution.
    if [[ "$COPY_ONLY" != "true" && "$vf" == *mpdecimate* ]]; then
	    FFMPEG_CMD+=(-fps_mode vfr)
    fi

    # Tag output color for sources we resolved by convention (untagged SD→BT.601,
    # untagged HD→BT.709). Pure VUI metadata, no pixel conversion — SD DVDs are
    # BT.601 but ship untagged, so this declares it instead of warning. Sources
    # that were genuinely converted (bt601/bt709) already got tagged by the
    # colorspace filter, so they don't match here. Decision-only call, hence quiet.
    if [[ "$COPY_ONLY" != "true" ]]; then
	    local cs_decision=$(get_colorspace_conversion "$source_file" "$height" quiet)
	    if [[ "$cs_decision" == "tag601" ]]; then
		    if [[ "$height" =~ ^[0-9]+$ && $height -gt 480 ]]; then
			    FFMPEG_CMD+=(-colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m)
		    else
			    FFMPEG_CMD+=(-colorspace smpte170m -color_primaries smpte170m -color_trc smpte170m)
		    fi
	    elif [[ "$cs_decision" == "tag709" ]]; then
		    FFMPEG_CMD+=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
	    fi
    fi

    FFMPEG_CMD+=(-map_chapters 0 -f "$CONTAINER" "$output_file" -y)
}

# ════════════════════════════════════════════════════════════════════════════
# PARSE COMMAND LINE ARGUMENTS (Priority 3: CLI)
# ════════════════════════════════════════════════════════════════════════════

CONTENT_TYPE=""
CONTENT_NAME=""
SEASON_NUM=""
EPISODE_NUM=""
YEAR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
	case $1 in
		-h|--help)
			show_help
			exit 0
			;;
		-v|--version)
			show_version
			exit 0
			;;
		-t|--type)
			CONTENT_TYPE="$2"
			shift 2
			;;
		-n|--name)
			CONTENT_NAME="$2"
			shift 2
			;;
		-s|--season)
			SEASON_NUM="$2"
			shift 2
			;;
		-e|--episode)
			EPISODE_NUM="$2"
			shift 2
			;;
		-y|--year)
			YEAR="$2"
			shift 2
			;;
		-q|--quality)
			QUALITY="$2"
			shift 2
			;;
		-c|--codec)
			VIDEO_CODEC="$2"
			shift 2
			;;
		--preset)
			PRESET="$2"
			shift 2
			;;
		--tune)
			X265_TUNE="$2"
			shift 2
			;;
		-b|--bframes)
			BFRAMES="$2"
			shift 2
			;;
		--no-crop)
			DETECT_CROP="false"
			shift
			;;
		--no-deinterlace)
			DETECT_INTERLACING="false"
			shift
			;;
		--adaptive-deinterlace)
			ADAPTIVE_DEINTERLACE="true"
			shift
			;;
		--force-deinterlace)
			FORCE_DEINTERLACE="true"
			shift
			;;
		--deinterlacer)
			DEINTERLACER="$2"
			shift 2
			;;
		--deinterlace-rate)
			DEINTERLACE_RATE="$2"
			shift 2
			;;
		--no-pulldown)
			DETECT_PULLDOWN="false"
			shift
			;;
		--force-ivtc)
			DETECT_PULLDOWN="true"
			shift
			;;
		--ivtc-mode)
			IVTC_MODE="$2"
			shift 2
			;;
		--fieldmatch-mode)
			FIELDMATCH_MODE="$2"
			shift 2
			;;
		--split-chapters)
			SPLIT_CHAPTERS="true"
			shift
			;;
		--no-split-chapters)
			SPLIT_CHAPTERS="false"
			shift
			;;
		--chapters-per-episode)
			CHAPTERS_PER_EPISODE="$2"
			shift 2
			;;
		--language)
			LANGUAGE="$2"
			shift 2
			;;
		--original-lang)
			ORIGINAL_LANGUAGE="$2"
			PREFER_ORIGINAL="true"
			shift 2
			;;
		--all-audio)
			AUDIO_FILTER_LANGUAGES="false"
			shift
			;;
		--device)
			VAAPI_DEVICE="$2"
			shift 2
			;;
		--compression-level)
			VAAPI_COMPRESSION_LEVEL="$2"
			shift 2
			;;
		-o|--overwrite)
			OVERWRITE="true"
			shift
			;;
		--upgrade-8bit)
			UPGRADE_8BIT_TO_10BIT="true"
			shift
			;;
		--no-upgrade-8bit)
			UPGRADE_8BIT_TO_10BIT="false"
			shift
			;;
		--downgrade-12bit)
			DOWNGRADE_12BIT_TO_10BIT="true"
			shift
			;;
		--no-downgrade-12bit)
			DOWNGRADE_12BIT_TO_10BIT="false"
			shift
			;;
		--colorspace)
			COLORSPACE="$2"
			shift 2
			;;
		--bulk-movies)
			BULK_MOVIES="true"
			shift
			;;
		-d|--dry-run)
			DRY_RUN=true
			shift
			;;
		--copy-only|--remux)
			COPY_ONLY=true
			shift
			;;
		-*)
			echo "Error: Unknown option $1"
			echo "Use -h or --help for usage information"
			exit 1
			;;
		*)
			break
			;;
	esac
done

# ════════════════════════════════════════════════════════════════════════════
# VALIDATE ARGUMENTS
# ════════════════════════════════════════════════════════════════════════════

if [[ $# -lt 1 ]]; then
	echo -e "${RED}Error: Source required (directory or file)${RESET}"
	echo "Use -h or --help for usage information"
	exit 1
fi

# Separate source files/directory from output directory
# If last arg is a directory AND we have more than one positional arg, it's output_dir
# OR if last arg looks like a path (contains /) and we have >1 arg, treat as output_dir
# Otherwise, the single arg is the source
OUTPUT_DIR_ARG=""
SOURCE_ARGS=()

if [[ $# -gt 1 ]]; then
	# Multiple arguments - last one might be output directory
	last_arg="${!#}"

    # Check if last arg is an existing directory OR looks like a path (contains /)
    if [[ -d "$last_arg" ]] || [[ "$last_arg" == */* ]]; then
	    # Last arg is output directory (or intended to be)
	    OUTPUT_DIR_ARG="$last_arg"
	    # All arguments except the last are source files/directory
	    for ((i=1; i<$#; i=i+1)); do
		    SOURCE_ARGS+=("${!i}")
	    done
    else
	    # Last arg is not a path - all arguments are source
	    SOURCE_ARGS=("$@")
    fi
else
	# Single arg - must be source
	SOURCE_ARGS=("$@")
fi

# Override with -o if specified
if [[ -n "$OUTPUT_DIR_ARG" ]]; then
	OUTPUT_DIR="$OUTPUT_DIR_ARG"
fi

# Initialize SOURCE_FILES array and SOURCE_DIR before normalize_source sets them
SOURCE_FILES=()
SOURCE_DIR=""

# Normalize source - handles files, directories, and globs (pre-expanded by shell)
if [[ ${#SOURCE_ARGS[@]} -eq 0 ]]; then
	echo -e "${RED}Error: No source files or directories specified${RESET}"
	exit 1
fi
# Call in a condition so a "not found" return is handled here with a clear
# message, rather than tripping set -e and reporting a bare line number.
if ! normalize_source "${SOURCE_ARGS[@]}"; then
	echo -e "${RED}Error: Could not find a usable source: ${SOURCE_ARGS[*]}${RESET}"
	echo -e "${YELLOW}Relative paths are resolved from the current directory ($(pwd)).${RESET}"
	exit 1
fi

if [[ -z "$SOURCE_DIR" ]]; then
	echo -e "${RED}Error: Source not found${RESET}"
	exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
	echo -e "${RED}Error: Invalid source directory: $SOURCE_DIR${RESET}"
	exit 1
fi

# Determine if we're in file mode or directory mode
FILE_MODE=false
if [[ ${#SOURCE_FILES[@]} -gt 0 ]]; then
	FILE_MODE=true
	echo -e "${CYAN}File mode: Processing ${#SOURCE_FILES[@]} specific file(s)${RESET}"
fi

# ════════════════════════════════════════════════════════════════════════════
# CONTENT DETECTION
# ════════════════════════════════════════════════════════════════════════════

# Auto-detect if not specified
if [[ -z "$CONTENT_TYPE" ]]; then
	if [[ "$BULK_MOVIES" == "true" ]]; then
		# Bulk movies mode always processes as movies
		CONTENT_TYPE="movie"
	elif [[ "$FILE_MODE" == true ]]; then
		# File mode: detect based on number of files
		if [[ ${#SOURCE_FILES[@]} -eq 1 ]]; then
			CONTENT_TYPE="movie"
		else
			CONTENT_TYPE="series"
		fi
	else
		# Directory mode: use existing logic
		CONTENT_TYPE=$(infer_type "$SOURCE_DIR")
	fi
	echo -e "${CYAN}Auto-detected content type: $CONTENT_TYPE${RESET}"
fi

if [[ "$BULK_MOVIES" == "true" && "$CONTENT_TYPE" == "series" ]]; then
	echo -e "${RED}Error: --bulk-movies flag conflicts with series type. Did you mean to use -t movie?${RESET}"
	exit 1
fi

if [[ "$CONTENT_TYPE" == "movie" && ${#SOURCE_FILES[@]} -gt 1 && "$BULK_MOVIES" != "true" ]]; then
	echo -e "${RED}Error: Multiple files specified for movie mode. Use --bulk-movies flag or specify a single file/directory.${RESET}"
	exit 1
fi

if [[ -z "$CONTENT_NAME" ]]; then
	if [[ "$FILE_MODE" == true ]]; then
		# Extract name from first file's directory
		CONTENT_NAME=$(extract_name "${SOURCE_FILES[0]}" "$CONTENT_TYPE")
	else
		CONTENT_NAME=$(extract_name "$SOURCE_DIR" "$CONTENT_TYPE")
	fi
	echo -e "${CYAN}Auto-detected name: $CONTENT_NAME${RESET}"
fi

# For series, detect all seasons or use specified season
SEASONS_TO_PROCESS=()
if [[ "$CONTENT_TYPE" == "series" ]]; then
	if [[ -n "$SEASON_NUM" ]]; then
		# User specified a season
		SEASONS_TO_PROCESS=("$SEASON_NUM")
	else
		# Auto-detect all seasons
		readarray -t SEASONS_TO_PROCESS < <(get_all_seasons "$SOURCE_DIR")

		if [[ ${#SEASONS_TO_PROCESS[@]} -eq 0 ]]; then
			# No S#D# subdirectories found, try extracting from current path
			SEASON_NUM=$(extract_season "$SOURCE_DIR")
			SEASONS_TO_PROCESS=("$SEASON_NUM")
			echo -e "${CYAN}Auto-detected season: $SEASON_NUM${RESET}"
		else
			echo -e "${CYAN}Auto-detected ${#SEASONS_TO_PROCESS[@]} season(s): ${SEASONS_TO_PROCESS[*]}${RESET}"
		fi
	fi
fi

# Add year to content name if specified (works for both movies and series)
if [[ -n "$YEAR" ]]; then
	CONTENT_NAME="$CONTENT_NAME ($YEAR)"
fi

# Create output directory
if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
	echo -e "${RED}Error: Cannot create output directory: $OUTPUT_DIR${RESET}"
	echo "Check permissions and path validity"
	exit 1
fi

# Verify output directory is writable
if [[ ! -w "$OUTPUT_DIR" ]]; then
	echo -e "${RED}Error: Output directory is not writable: $OUTPUT_DIR${RESET}"
	exit 1
fi

echo -e "${BLUE}════════════════════════════════════════════${RESET}"
echo -e "${BOLDBLUE}Transcode Monster v${SCRIPT_VERSION}${RESET}"
echo -e "${BLUE}════════════════════════════════════════════${RESET}"
echo -e "${BOLD}Source:${RESET}       $SOURCE_DIR"
echo -e "${BOLD}Output:${RESET}       $OUTPUT_DIR"
echo -e "${BOLD}Type:${RESET}         $CONTENT_TYPE"
echo -e "${BOLD}Name:${RESET}         $CONTENT_NAME"
[[ "$CONTENT_TYPE" == "series" ]] && echo -e "${BOLD}Seasons:${RESET}      ${SEASONS_TO_PROCESS[*]}"
[[ "$CONTENT_TYPE" == "series" && -n "$EPISODE_NUM" ]] && echo -e "${BOLD}Episode:${RESET}      $EPISODE_NUM"
[[ "$CONTENT_TYPE" == "movie" && "$BULK_MOVIES" == "true" ]] && echo -e "${BOLD}Bulk Mode:${RESET}    enabled"
if [[ "$COPY_ONLY" == "true" ]]; then
	echo -e "${BOLD}Mode:${RESET}         ${BOLDGREEN}COPY-ONLY (remux, no re-encode)${RESET}"
else
	echo -e "${BOLD}Quality:${RESET}      $QUALITY (CQP)"
	echo -e "${BOLD}Codec:${RESET}        $VIDEO_CODEC"
	echo -e "${BOLD}Crop:${RESET}         $DETECT_CROP"
	echo -e "${BOLD}Deinterlace:${RESET}  $DETECT_INTERLACING"
	[[ "$ADAPTIVE_DEINTERLACE" == "true" ]] && echo -e "${BOLD}Adaptive:${RESET}     $ADAPTIVE_DEINTERLACE"
	echo -e "${BOLD}Deint rate:${RESET}   $DEINTERLACE_RATE"
	echo -e "${BOLD}Pulldown:${RESET}     $DETECT_PULLDOWN"
	echo -e "${BOLD}IVTC mode:${RESET}    $IVTC_MODE"
	[[ "$FIELDMATCH_MODE" != "pc_n" ]] && echo -e "${BOLD}Fieldmatch:${RESET}   $FIELDMATCH_MODE"
fi
echo -e "${BOLD}Split Chapters:${RESET} $SPLIT_CHAPTERS"
[[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}Mode:         DRY RUN${RESET}"
echo -e "${BLUE}════════════════════════════════════════════${RESET}"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# PROCESS FILES
# ════════════════════════════════════════════════════════════════════════════

if [[ "$CONTENT_TYPE" == "movie" ]]; then
	# ────────────────────────────────────────
	# MOVIE MODE
	# ────────────────────────────────────────

	CURRENT_OPERATION="Finding movie file(s)"

	# Determine which files to process
	movies_to_process=()
	if [[ "$FILE_MODE" == true ]]; then
		# Use the specified file
		movies_to_process+=("${SOURCE_FILES[0]}")
	elif [[ "$BULK_MOVIES" == "true" ]]; then
		# Bulk mode: process all video files in directory
		find_video_files "$SOURCE_DIR" movies_to_process

		if [[ ${#movies_to_process[@]} -eq 0 ]]; then
			echo -e "${RED}Error: No video files found in directory${RESET}"
			echo -e "${RED}Supported formats: $INPUT_VIDEO_EXTENSIONS${RESET}"
			exit 1
		fi

		echo -e "${CYAN}Found ${#movies_to_process[@]} movie(s) to process${RESET}"
	else
		# Standard mode: find the video file with the longest duration
		video_files=()
		find_video_files "$SOURCE_DIR" video_files

		if [[ ${#video_files[@]} -eq 0 ]]; then
			echo -e "${RED}Error: No video files found in directory${RESET}"
			echo -e "${RED}Supported formats: $INPUT_VIDEO_EXTENSIONS${RESET}"
			exit 1
		fi

		max_duration=0
		max_file=""
		for file in "${video_files[@]}"; do
			duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
			duration=${duration//,/}
			if [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$duration > $max_duration" | bc -l) )); then
				max_duration="$duration"
				max_file="$file"
			fi
		done

		if [[ -z "$max_file" ]]; then
			echo -e "${RED}Error: Could not determine longest video file${RESET}"
			exit 1
		fi

		movies_to_process+=("$max_file")
		echo -e "${CYAN}Selected longest file: $(basename "$max_file") (duration: $max_duration seconds)${RESET}"
	fi

	if [[ ${#movies_to_process[@]} -eq 0 ]]; then
		echo -e "${RED}Error: No video files found${RESET}"
		exit 1
	fi

	# Process each movie
	for video_file in "${movies_to_process[@]}"; do
		CURRENT_FILE="$video_file"
		CURRENT_OPERATION="Preparing output"

		# Extract movie name from file if in bulk mode
		movie_name="$CONTENT_NAME"
		if [[ "$BULK_MOVIES" == "true" ]]; then
			movie_name=$(extract_name "$video_file" "movie")
		fi

		output_file="${OUTPUT_DIR%/}/${movie_name}.mkv"

		if [[ -f "$output_file" && "$OVERWRITE" != "true" ]]; then
			echo -e "${YELLOW}Output file already exists: $output_file${RESET}"
			echo "Skipping: $(basename "$video_file")"
			echo ""
			continue
		fi

		echo -e "${BOLD}Processing:${RESET} $video_file"
		echo -e "${BOLD}Output:${RESET} $output_file"

		src_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null)
		echo -e "${BOLD}Duration:${RESET}    $(format_duration "$src_duration")"

		# Build the ffmpeg command (populates the FFMPEG_CMD array)
		build_ffmpeg_command "$video_file" "$output_file"

		if [[ "$DRY_RUN" == true ]]; then
			echo -e "${YELLOW}[DRY RUN] Would transcode to: $output_file${RESET}"
			echo ""
			echo -e "${CYAN}Command that would be executed:${RESET}"
			echo ""
			printf '%q ' "${FFMPEG_CMD[@]}"; echo
			echo ""
			continue
		fi

		if [[ "$COPY_ONLY" == "true" ]]; then
			echo -e "${CYAN}Remuxing (stream copy, no re-encode)${RESET}"
			CURRENT_OPERATION="Remuxing"
		else
			CURRENT_OPERATION="Detecting video properties"

			# Detect bit depth and height for informational output
			bit_depth=$(detect_bit_depth "$video_file")
			height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$video_file")
			height=${height//,/}

			# Adjust bit depth based on user preferences
			if [[ "$DOWNGRADE_12BIT_TO_10BIT" == "true" && "$bit_depth" == "12" ]]; then
				bit_depth="10"
			fi
			if [[ "$UPGRADE_8BIT_TO_10BIT" == "true" && "$bit_depth" == "8" ]]; then
				bit_depth="10"
			fi

			# Determine encoder for informational output
			actual_codec=""
			if [[ "$VIDEO_CODEC" == "auto" ]]; then
				actual_codec=$(should_use_software_encoder "$video_file")
				if [[ "$actual_codec" == "libx265" ]]; then
					echo "Using libx265 (software) - content characteristics require software encoding"
				else
					echo "Using hevc_vaapi (hardware) - fast encoding with good quality"
				fi
			else
				actual_codec="$VIDEO_CODEC"
				echo "Using $actual_codec (manual override)"
			fi

			# Determine profile based on bit depth
			if [[ "$bit_depth" == "12" ]]; then
				detected_profile="main12"
			elif [[ "$bit_depth" == "10" ]]; then
				detected_profile="main10"
			else
				detected_profile="main"
			fi

			echo -e "${CYAN}Bit depth: ${bit_depth}-bit, Height: ${height}p, Profile: $detected_profile${RESET}"

			CURRENT_OPERATION="Encoding"
		fi

		# Execute the ffmpeg command (array form, no eval — paths pass through literally)
		"${FFMPEG_CMD[@]}"

		CURRENT_OPERATION=""
		CURRENT_FILE=""

		echo -e "${BOLDGREEN}Complete: $output_file${RESET}"
		echo ""
	done

	[[ "$DRY_RUN" == true ]] && exit 0

else
	# ────────────────────────────────────────
	# SERIES MODE
	# ────────────────────────────────────────

    # Process each season
    for SEASON_NUM in "${SEASONS_TO_PROCESS[@]}"; do
	    # Normalize to a bare integer: avoids octal printf errors on "08"/"09"
	    # and keeps season comparisons consistent regardless of zero-padding.
	    [[ "$SEASON_NUM" =~ ^[0-9]+$ ]] && SEASON_NUM=$((10#$SEASON_NUM))
	    echo -e "${BLUE}────────────────────────────────────────${RESET}"
	    echo -e "${BOLDBLUE}PROCESSING SEASON $SEASON_NUM${RESET}"
	    echo -e "${BLUE}────────────────────────────────────────${RESET}"
	    echo ""

	    episode_files=()

	    if [[ "$FILE_MODE" == true ]]; then
		    # File mode: use specified files directly
		    echo -e "${CYAN}Processing ${#SOURCE_FILES[@]} specified file(s)${RESET}"

		    for source_file in "${SOURCE_FILES[@]}"; do
			    # Skip files that belong to a different season (explicit file
			    # lists can span seasons; honor each file's own season tag)
			    if [[ "$(get_effective_season "$source_file" "$(dirname "$source_file")" "$SEASON_NUM")" != "$SEASON_NUM" ]]; then
				    continue
			    fi
			    echo "Processing: $(basename "$source_file")"

		# Check if this file should be split by chapters
		should_split=$(should_split_by_chapters "$source_file" "$CONTENT_TYPE")

		if [[ "$should_split" == "true" ]]; then
			# Determine chapters per episode
			chapters_per_ep=""
			if [[ "$CHAPTERS_PER_EPISODE" == "auto" ]]; then
				chapters_per_ep=$(detect_chapters_per_episode "$source_file")
				echo "  Auto-detected $chapters_per_ep chapter(s) per episode"
			else
				chapters_per_ep="$CHAPTERS_PER_EPISODE"
				echo "  Using $chapters_per_ep chapter(s) per episode (manual override)"
			fi

		    # Get chapter count
		    chapter_count=$(ffprobe -v quiet -show_chapters "$source_file" 2>/dev/null | grep -c "^\[CHAPTER\]" || true)
		    # Ceiling division so a short final episode (indivisible remainder,
		    # e.g. a finale with fewer chapters) gets its own episode instead of
		    # being silently dropped by integer truncation.
		    episode_count=$(( (chapter_count + chapters_per_ep - 1) / chapters_per_ep ))
		    echo "  File has $chapter_count chapters - will split into $episode_count episodes"
		    src_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$source_file" 2>/dev/null)
		    echo "  Source duration: $(format_duration "$src_duration")"

		    # Extract disc number from directory name
		    file_dir=$(dirname "$source_file")
		    file_dir_base=$(basename "$file_dir")
		    file_disc_num=0
		    if [[ "$file_dir_base" =~ [Dd]([0-9]+) ]]; then
			    file_disc_num=$((10#${BASH_REMATCH[1]}))
		    fi

		    # Add each episode (group of chapters)
		    for ((ep=0; ep<episode_count; ep=ep+1)); do
			    start_chapter=$((ep * chapters_per_ep))
			    end_chapter=$((start_chapter + chapters_per_ep - 1))
			    # Final episode absorbs any leftover chapters (short last episode)
			    (( end_chapter > chapter_count - 1 )) && end_chapter=$((chapter_count - 1))
			    ep_num=$((ep + 1))
			    # Store: disc_num|disc_dir|episode_num|source_file|start_chapter|end_chapter
			    episode_files+=("$file_disc_num|$file_dir|$ep_num|$source_file|$start_chapter|$end_chapter")
		    done
	    else
		    # Regular file - parse episode number from filename
		    ep_num=$(get_episode_num "$(basename "$source_file")")

		    # Extract disc number from directory name
		    file_dir=$(dirname "$source_file")
		    file_dir_base=$(basename "$file_dir")
		    file_disc_num=0
		    if [[ "$file_dir_base" =~ [Dd]([0-9]+) ]]; then
			    file_disc_num=$((10#${BASH_REMATCH[1]}))
		    fi

		    if [[ "$ep_num" != "UNKNOWN" ]]; then
			    # Store with chapter markers as -1 to indicate whole file
			    episode_files+=("$file_disc_num|$file_dir|$ep_num|$source_file|-1|-1")
		    else
			    # Store with UNKNOWN marker; resolved by resolve_unknown_episodes() after collection
			    episode_files+=("$file_disc_num|$file_dir|UNKNOWN|$source_file|-1|-1")
		    fi
		fi
	done
else
	# Directory mode: gather this season's disc/segment subdirectories. Match by
	# parsed season (robust to zero-padding — S01D1, S1D1, "Season 1" all work)
	# instead of a literal glob, and read each disc number from its name.
	disc_dirs=()
	max_explicit_disc=0
	shopt -s nullglob nocaseglob
	for dir in "$SOURCE_DIR"/*/; do
		dir="${dir%/}"
		[[ -d "$dir" ]] || continue
		dir_basename=$(basename "$dir")
		if [[ "$(season_from_path "$dir_basename")" == "$SEASON_NUM" ]]; then
			disc_dirs+=("$dir")
			if [[ "$dir_basename" =~ [Dd]([0-9]+) ]]; then
				disc_num=$((10#${BASH_REMATCH[1]}))
				[[ $disc_num -gt $max_explicit_disc ]] && max_explicit_disc=$disc_num
			fi
		fi
	done
	shopt -u nullglob nocaseglob

	# If we found explicit discs, look for implicit continuation (_D# without S# prefix)
	if [[ $max_explicit_disc -gt 0 ]]; then
		shopt -s nullglob nocaseglob
		all_dirs=("$SOURCE_DIR"/*[Dd][0-9]*)
		shopt -u nullglob nocaseglob

		for dir in "${all_dirs[@]}"; do
			dir_basename=$(basename "$dir")
			# Match _D# pattern but NOT S#D# pattern
			if [[ "$dir_basename" =~ _[Dd]([0-9]+)$ ]]; then
				# Capture the disc number before the next regex check overwrites BASH_REMATCH
				captured_disc_num="${BASH_REMATCH[1]}"
				# Check that it's NOT an explicit S#D# directory
				if [[ ! "$dir_basename" =~ [Ss][0-9]+[^0-9]*[Dd][0-9]+ ]]; then
					disc_num=$((10#$captured_disc_num))
					# Include if disc number continues from explicit discs
					if [[ $disc_num -gt $max_explicit_disc ]]; then
						disc_dirs+=("$dir")
						echo -e "${CYAN}  Detected continuation disc: $(basename "$dir") (part of season $SEASON_NUM)${RESET}"
					fi
				fi
			fi
		done
	fi

	if [[ ${#disc_dirs[@]} -eq 0 ]]; then
		# No S#D# subdirectories found - check if files are directly in the source directory
		direct_video_files=()
		find_video_files "$SOURCE_DIR" direct_video_files

		if [[ ${#direct_video_files[@]} -gt 0 ]]; then
			# Files are directly in the source directory (single-disc series)
			echo -e "${CYAN}Processing ${#direct_video_files[@]} file(s) directly from source directory${RESET}"
			disc_dirs=("$SOURCE_DIR")
		else
			echo -e "${YELLOW}Warning: No disc directories found for season $SEASON_NUM (e.g., *S${SEASON_NUM}*D* or S${SEASON_NUM}D*) and no video files in source directory${RESET}"
			echo -e "${YELLOW}Supported formats: $INPUT_VIDEO_EXTENSIONS${RESET}"
			echo ""
			continue
		fi
	else
		echo -e "${CYAN}Processing ${#disc_dirs[@]} disc(s)/directory(ies) for season $SEASON_NUM${RESET}"
	fi

	    # Collect episodes
	    for disc_dir in "${disc_dirs[@]}"; do
		    echo "Scanning: $disc_dir"

		    # Extract disc number from directory name
		    disc_dir_base=$(basename "$disc_dir")
		    disc_number=0
		    if [[ "$disc_dir_base" =~ [Dd]([0-9]+) ]]; then
			    disc_number=$((10#${BASH_REMATCH[1]}))
		    fi

		    video_files=()
		    find_video_files "$disc_dir" video_files

		    if [[ ${#video_files[@]} -eq 0 ]]; then
			    echo -e "${YELLOW}  Warning: No video files found${RESET}"
			    continue
		    fi

		    echo "  Found ${#video_files[@]} file(s)"

		    for source_file in "${video_files[@]}"; do
			    # Skip files whose own season tag puts them in a different
			    # season than the one we're processing (lets a flat or mixed
			    # directory hold multiple seasons without cross-contamination).
			    if [[ "$(get_effective_season "$source_file" "$disc_dir" "$SEASON_NUM")" != "$SEASON_NUM" ]]; then
				    continue
			    fi
			    # Check if this file should be split by chapters
			    should_split=$(should_split_by_chapters "$source_file" "$CONTENT_TYPE")

			    if [[ "$should_split" == "true" ]]; then
				    # Determine chapters per episode
				    chapters_per_ep=""
				    if [[ "$CHAPTERS_PER_EPISODE" == "auto" ]]; then
					    chapters_per_ep=$(detect_chapters_per_episode "$source_file")
					    echo "  Auto-detected $chapters_per_ep chapter(s) per episode"
				    else
					    chapters_per_ep="$CHAPTERS_PER_EPISODE"
					    echo "  Using $chapters_per_ep chapter(s) per episode (manual override)"
				    fi

			# Get chapter count
			chapter_count=$(ffprobe -v quiet -show_chapters "$source_file" 2>/dev/null | grep -c "^\[CHAPTER\]" || true)
			# Ceiling division so a short final episode (indivisible remainder)
			# gets its own episode instead of being dropped by truncation.
			episode_count=$(( (chapter_count + chapters_per_ep - 1) / chapters_per_ep ))
			echo "  File has $chapter_count chapters - will split into $episode_count episodes"
			src_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$source_file" 2>/dev/null)
			echo "  Source duration: $(format_duration "$src_duration")"

			# Add each episode (group of chapters)
			for ((ep=0; ep<episode_count; ep=ep+1)); do
				start_chapter=$((ep * chapters_per_ep))
				end_chapter=$((start_chapter + chapters_per_ep - 1))
				# Final episode absorbs any leftover chapters (short last episode)
				(( end_chapter > chapter_count - 1 )) && end_chapter=$((chapter_count - 1))
				ep_num=$((ep + 1))
				# Store: disc_num|disc_dir|episode_num|source_file|start_chapter|end_chapter
				episode_files+=("$disc_number|$disc_dir|$ep_num|$source_file|$start_chapter|$end_chapter")
			done
		else
			# Regular file - parse episode number from filename
			ep_num=$(get_episode_num "$(basename "$source_file")")
			if [[ "$ep_num" != "UNKNOWN" ]]; then
				# Store: disc_num|disc_dir|episode_num|source_file|start_chapter|end_chapter
				episode_files+=("$disc_number|$disc_dir|$ep_num|$source_file|-1|-1")
			else
				# Store with UNKNOWN marker; resolved by resolve_unknown_episodes() after collection
				episode_files+=("$disc_number|$disc_dir|UNKNOWN|$source_file|-1|-1")
			fi
			    fi
		    done
	    done
	    fi

	    # Resolve any UNKNOWN episode numbers using alphabetical fallback
	    resolve_unknown_episodes

	    if [[ ${#episode_files[@]} -eq 0 ]]; then
		    echo -e "${YELLOW}Warning: No valid episode files found for season $SEASON_NUM${RESET}"
		    echo ""
		    continue
	    fi

	# Sort episodes: first by disc number, then by episode number within disc
	readarray -t sorted_files < <(
	for line in "${episode_files[@]}"; do
		echo "$line"
	done | sort -t'|' -k1,1n -k3,3n
)

	# Decide how to label episodes. When every regular episode carries a
	# distinct, positive parsed number we honor those numbers directly, so a
	# season with gaps (a missing episode, a set that starts at E03) keeps its
	# canonical numbering. When numbers are missing, duplicated, or synthetic
	# (e.g. several chapter-split discs each starting at 1), we fall back to
	# sequential position, which is collision-free.
	season_label_by_parsed=true
	declare -A _seen_epnum=()
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r _ _ _pen _ _ _ <<< "$sorted_line"
		[[ "$_pen" -lt 0 ]] && continue  # OVAs are labeled separately
		if [[ "$_pen" -lt 1 || -n "${_seen_epnum[$_pen]:-}" ]]; then
			season_label_by_parsed=false
			break
		fi
		_seen_epnum[$_pen]=1
	done
	unset _seen_epnum

	# Now display the episode mapping
	echo ""
	echo -e "${CYAN}Episode mapping:${RESET}"
	ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
		if [[ "$parsed_ep_num" -lt 0 ]]; then
			ova_num=$((parsed_ep_num + 1000))
			episode_label="OVA $(printf "%02d" $ova_num)"
		else
			if [[ "$season_label_by_parsed" == "true" ]]; then epn=$parsed_ep_num; else epn=$ep_index; fi
			episode_label="Episode $epn"
		fi
		if [[ "$start_ch" == "-1" ]]; then
			echo "    $(basename "$source_file") -> $episode_label"
		else
			if [[ "$start_ch" == "$end_ch" ]]; then
				echo "    $(basename "$source_file") [Chapter $((start_ch + 1))] -> $episode_label"
			else
				echo "    $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))] -> $episode_label"
			fi
		fi
		[[ "$parsed_ep_num" -ge 0 ]] && ep_index=$((ep_index + 1))
	done

	echo ""
	echo -e "${CYAN}Processing ${#sorted_files[@]} episode(s) for season $SEASON_NUM${RESET}"
	echo ""

	if [[ "$DRY_RUN" == true ]]; then
		ep_index=1
		for sorted_line in "${sorted_files[@]}"; do
			IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
			if [[ "$parsed_ep_num" -lt 0 ]]; then
				ova_num=$((parsed_ep_num + 1000))
				episode_num="OVA $(printf "%02d" $ova_num)"
			else
				if [[ "$season_label_by_parsed" == "true" ]]; then epn=$parsed_ep_num; else epn=$ep_index; fi
				episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $epn)"
			fi
			output_file="${OUTPUT_DIR%/}/${CONTENT_NAME} - ${episode_num}.mkv"
			if [[ "$start_ch" == "-1" ]]; then
				echo -e "${YELLOW}[DRY RUN] Would transcode: $(basename "$source_file") -> $(basename "$output_file")${RESET}"
			else
				if [[ "$start_ch" == "$end_ch" ]]; then
					echo -e "${YELLOW}[DRY RUN] Would transcode: $(basename "$source_file") [Chapter $((start_ch + 1))] -> $(basename "$output_file")${RESET}"
				else
					echo -e "${YELLOW}[DRY RUN] Would transcode: $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))] -> $(basename "$output_file")${RESET}"
				fi
			fi
			[[ "$parsed_ep_num" -ge 0 ]] && ep_index=$((ep_index + 1))
		done
		echo ""

	    # Show command for first episode as an example
	    echo -e "${CYAN}Example command for first episode:${RESET}"
	    IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "${sorted_files[0]}"
	    if [[ "$parsed_ep_num" -lt 0 ]]; then
		    ova_num=$((parsed_ep_num + 1000))
		    episode_num="OVA $(printf "%02d" $ova_num)"
	    else
		    if [[ "$season_label_by_parsed" == "true" ]]; then epn=$parsed_ep_num; else epn=1; fi
		    episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $epn)"
	    fi
	    output_file="${OUTPUT_DIR%/}/${CONTENT_NAME} - ${episode_num}.mkv"

	    # Build input options for chapter extraction if needed
	    input_opts=""
	    if [[ "$start_ch" != "-1" ]]; then
		    readarray -t chapter_times < <(get_chapter_times "$source_file")
		    start_time="${chapter_times[$start_ch]}"
		    start_time=$(echo "$start_time" | tr -d '[:space:]')

		    if [[ "$start_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
			    end_time=""
			    if [[ $((end_ch + 1)) -lt ${#chapter_times[@]} ]]; then
				    end_time="${chapter_times[$((end_ch + 1))]}"
				    end_time=$(echo "$end_time" | tr -d '[:space:]')
			    fi

			    input_opts="-ss $start_time"
			    if [[ -n "$end_time" ]] && [[ "$end_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
				    duration=$(echo "$end_time - $start_time" | bc)
				    input_opts="$input_opts -t $duration"
			    fi
		    fi
	    fi

	    build_ffmpeg_command "$source_file" "$output_file" "$input_opts"
	    echo ""
	    printf '%q ' "${FFMPEG_CMD[@]}"; echo
	    echo ""

	    continue
	fi

	# Process episodes
	ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"

		if [[ "$parsed_ep_num" -lt 0 ]]; then
			# OVA episode — always process, label as OVA NN, does not consume ep_index
			ova_num=$((parsed_ep_num + 1000))
			episode_num="OVA $(printf "%02d" $ova_num)"
		else
			# Determine this episode's label number (parsed when reliable, else positional)
			if [[ "$season_label_by_parsed" == "true" ]]; then epn=$parsed_ep_num; else epn=$ep_index; fi
			# Skip if user specified a specific episode and this label isn't it
			if [[ -n "$EPISODE_NUM" ]] && [[ "$epn" -ne "$EPISODE_NUM" ]]; then
				ep_index=$((ep_index + 1))
				continue
			fi
			episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $epn)"
		fi
		output_file="${OUTPUT_DIR%/}/${CONTENT_NAME} - ${episode_num}.mkv"

		if [[ -f "$output_file" && "$OVERWRITE" != "true" ]]; then
			echo -e "${YELLOW}[$ep_index/${#sorted_files[@]}] Skipping: $(basename "$output_file") (already exists)${RESET}"
			[[ "$parsed_ep_num" -ge 0 ]] && ep_index=$((ep_index + 1))
			continue
		fi

		if [[ "$start_ch" == "-1" ]]; then
			echo -e "${BOLD}[$ep_index/${#sorted_files[@]}] Processing: $(basename "$source_file")${RESET}"
		else
			if [[ "$start_ch" == "$end_ch" ]]; then
				echo -e "${BOLD}[$ep_index/${#sorted_files[@]}] Processing: $(basename "$source_file") [Chapter $((start_ch + 1))]${RESET}"
			else
				echo -e "${BOLD}[$ep_index/${#sorted_files[@]}] Processing: $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))]${RESET}"
			fi
		fi
		echo "    Output: $(basename "$output_file")"

		CURRENT_FILE="$source_file"
		CURRENT_OPERATION="Building chapter extraction parameters"

	    # Build input options for chapter extraction
	    input_opts=""
	    if [[ "$start_ch" != "-1" ]]; then
		    # Get all chapter times as an array
		    readarray -t chapter_times < <(get_chapter_times "$source_file")
		    start_time="${chapter_times[$start_ch]}"
		    end_time=""

		# Clean the start time (remove any whitespace)
		start_time=$(echo "$start_time" | tr -d '[:space:]')

		# Validate start_time is a number
		if ! [[ "$start_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
			echo "    ERROR: Invalid chapter start time: $start_time"
			[[ "$parsed_ep_num" -ge 0 ]] && ep_index=$((ep_index + 1))
			continue
		fi

		# End time is the start of the chapter after our range
		if [[ $((end_ch + 1)) -lt ${#chapter_times[@]} ]]; then
			end_time="${chapter_times[$((end_ch + 1))]}"
			end_time=$(echo "$end_time" | tr -d '[:space:]')
		fi

		input_opts="-ss $start_time"
		if [[ -n "$end_time" ]] && [[ "$end_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
			duration=$(echo "$end_time - $start_time" | bc)
			input_opts="$input_opts -t $duration"
			echo "    Extracting chapters: start=${start_time}s, duration=${duration}s"
		else
			echo "    Extracting chapters: start=${start_time}s, duration=remainder"
		fi
	    fi

	    if [[ "$COPY_ONLY" == "true" ]]; then
		    CURRENT_OPERATION="Remuxing"
		    echo "    Remuxing (stream copy, no re-encode)"
	    else
		    CURRENT_OPERATION="Detecting video properties"

		    # Detect bit depth and height
		    bit_depth=$(detect_bit_depth "$source_file")
		    height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$source_file")
		    height=${height//,/}

		    # Adjust bit depth based on user preferences
		    if [[ "$DOWNGRADE_12BIT_TO_10BIT" == "true" && "$bit_depth" == "12" ]]; then
			    bit_depth="10"
		    fi
		    if [[ "$UPGRADE_8BIT_TO_10BIT" == "true" && "$bit_depth" == "8" ]]; then
			    bit_depth="10"
		    fi

		    # Choose encoder based on video characteristics
		    actual_codec=""
		    if [[ "$VIDEO_CODEC" == "auto" ]]; then
			    actual_codec=$(should_use_software_encoder "$source_file")
		    else
			    actual_codec="$VIDEO_CODEC"
		    fi

		    # Determine profile based on bit depth
		    if [[ "$bit_depth" == "12" ]]; then
			    detected_profile="main12"
		    elif [[ "$bit_depth" == "10" ]]; then
			    detected_profile="main10"
		    else
			    detected_profile="main"
		    fi

		    echo "    Bit depth: ${bit_depth}-bit, Encoder: $actual_codec, Profile: $detected_profile"
	    fi

	    CURRENT_OPERATION="Analyzing audio and subtitles"

	    # Get audio track info for display
	    preferred_audio_lang=""
	    if [[ "$PREFER_ORIGINAL" == "true" && -n "$ORIGINAL_LANGUAGE" ]]; then
		    preferred_audio_lang="$ORIGINAL_LANGUAGE"
	    fi

	    IFS='|' read -r default_audio_idx default_audio_lang <<< "$(get_audio_track_info "$source_file" "$preferred_audio_lang")"

	    # Check if default audio needs container-specific PCM conversion
	    disp_num_audio=$(ffprobe -v quiet -select_streams a -show_entries stream=index -of csv=p=0 "$source_file" 2>/dev/null | wc -l || true)
	    if [[ $disp_num_audio -eq 0 ]]; then
		    echo -e "${YELLOW}    Audio: none${RESET}"
	    elif needs_audio_remux "$source_file" "$default_audio_idx"; then
		    disp_src_acodec=$(get_audio_codec_name "$source_file" "$default_audio_idx")
		    echo -e "${CYAN}    Audio: Track $default_audio_idx ($default_audio_lang) default [${disp_src_acodec} → FLAC]${RESET}"
	    else
		    echo -e "${CYAN}    Audio: Track $default_audio_idx ($default_audio_lang) default${RESET}"
	    fi

	    # Resolve the default subtitle once here, for both the line below and the
	    # build call (so the tracks aren't classified/sampled twice per episode).
	    sub_default_spec=$(select_default_subtitle "$source_file" "$default_audio_lang" "$LANGUAGE")
	    IFS='|' read -r sub_default_idx sub_default_kind <<< "$sub_default_spec"
	    if [[ "$sub_default_idx" != "-1" ]]; then
		    if [[ "$sub_default_kind" == "forced" ]]; then
			    echo -e "${CYAN}    Subs: Track $sub_default_idx ($LANGUAGE) forced${RESET}"
		    else
			    echo -e "${CYAN}    Subs: Track $sub_default_idx ($LANGUAGE) default${RESET}"
		    fi
	    fi

	    if [[ "$COPY_ONLY" == "true" ]]; then
		    CURRENT_OPERATION="Remuxing episode $ep_index"
	    else
		    CURRENT_OPERATION="Encoding episode $ep_index"
	    fi

	    # Build and execute the ffmpeg command (array form, no eval). Pass the
	    # subtitle decision we already resolved so build doesn't redo it.
	    build_ffmpeg_command "$source_file" "$output_file" "$input_opts" "$sub_default_spec"
	    "${FFMPEG_CMD[@]}"

	    echo "    Complete!"
	    echo ""
	    [[ "$parsed_ep_num" -ge 0 ]] && ep_index=$((ep_index + 1))
    done

    echo -e "${GREEN}Season $SEASON_NUM complete!${RESET}"
    echo ""
done

echo -e "${GREEN}All seasons complete!${RESET}"
fi

CURRENT_OPERATION=""
CURRENT_FILE=""

echo ""
echo -e "${BOLDGREEN}Transcoding finished!${RESET}"
