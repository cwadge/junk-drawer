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

SCRIPT_VERSION="1.5.3"
CONFIG_FILE="${HOME}/.config/transcode-monster.conf"

# ============================================================================
# DEFAULT SETTINGS (Priority 1: Built-ins)
# ============================================================================

# Hardware acceleration
DEFAULT_VAAPI_DEVICE="/dev/dri/renderD128"

# Video encoding settings
DEFAULT_VIDEO_CODEC="auto"  # Will choose hevc_vaapi or libx265 based on resolution
DEFAULT_QUALITY="20"  # CQP/CRF value
DEFAULT_PRESET="medium"  # For libx265 (software encoding only) - balanced speed/quality
DEFAULT_X265_POOLS="+"  # Thread pools for libx265 (software encoding only) - auto-detect optimal
DEFAULT_GOP_SIZE="120"
DEFAULT_MIN_KEYINT="12"
DEFAULT_BFRAMES="0"  # B-frames: 0=max compatibility (older AMD), 1-2=balanced, 3-4=best compression
DEFAULT_REFS="4"

# Process priority
DEFAULT_USE_NICE="true"
DEFAULT_NICE_LEVEL="10"  # 0-19, higher = lower priority
DEFAULT_USE_IONICE="true"
DEFAULT_IONICE_CLASS="2"  # 2 = best-effort
DEFAULT_IONICE_LEVEL="4"  # 0-7, higher = lower priority

# Output options
DEFAULT_OVERWRITE="false"  # Overwrite existing output files

# Audio encoding settings
DEFAULT_AUDIO_COPY_FIRST="true"  # Copy first audio track
DEFAULT_AUDIO_CODEC="libfdk_aac"
DEFAULT_AUDIO_PROFILE="aac_he"
DEFAULT_AUDIO_BITRATE_MONO="96k"     # HE-AAC transparent for mono
DEFAULT_AUDIO_BITRATE_STEREO="128k"  # HE-AAC transparent for stereo
DEFAULT_AUDIO_BITRATE_SURROUND="192k" # HE-AAC for 5.1
DEFAULT_AUDIO_BITRATE_SURROUND_PLUS="256k" # HE-AAC for 7.1+
DEFAULT_AUDIO_FILTER_LANGUAGES="true"  # Filter audio by language (skip foreign overdubs)

# Language and subtitle settings
DEFAULT_LANGUAGE="eng"  # ISO 639-2 code(s), comma-separated for multilingual (e.g., "eng,spa,fra")
# First language in list has priority for subtitle selection
DEFAULT_PREFER_ORIGINAL="false"  # When true, prefer original audio + native subs over dubs
DEFAULT_ORIGINAL_LANGUAGE=""  # Set this for original language mode (e.g., "jpn" for anime)

# Processing options
DEFAULT_DETECT_INTERLACING="true"
DEFAULT_ADAPTIVE_DEINTERLACE="false"  # Force adaptive deinterlacing for mixed content
DEFAULT_DETECT_CROP="true"
DEFAULT_DETECT_PULLDOWN="auto"  # auto = SD only, true = force on, false = force off
DEFAULT_SPLIT_CHAPTERS="auto"  # auto = series files >60min, true = force on, false = force off
DEFAULT_CHAPTERS_PER_EPISODE="auto"  # auto = detect optimal grouping, or specify number

# Output settings
DEFAULT_OUTPUT_DIR="${HOME}/Videos"
DEFAULT_CONTAINER="matroska"  # mkv

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Track what we're currently processing for better error messages
CURRENT_OPERATION=""
CURRENT_FILE=""

# Error handler function
error_handler() {
	local exit_code=$?
	local line_number=$1

	echo ""
	echo -e "${RED}============================================${RESET}"
	echo -e "${RED}ERROR: Script failed with exit code $exit_code${RESET}"
	echo -e "${RED}============================================${RESET}"
	echo -e "${RED}Line number: $line_number${RESET}"

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
trap 'error_handler ${LINENO}' ERR
trap 'interrupt_handler' INT

# ============================================================================
# TERMINAL SETUP
# ============================================================================

# Check if stdout is a terminal
if [[ -t 1 ]]; then
	RED='\033[0;31m'
	YELLOW='\033[1;33m'
	GREEN='\033[0;32m'
	BLUE='\033[0;34m'
	CYAN='\033[0;36m'
	BOLD='\033[1m'
	BOLDBLUE='\033[1;34m'
	BOLDGREEN='\033[1;32m'
	RESET='\033[0m'
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

# ============================================================================
# LOAD USER CONFIG (Priority 2: User .conf)
# ============================================================================

if [[ -f "$CONFIG_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
fi

# Apply config values (if set)
VAAPI_DEVICE="${VAAPI_DEVICE:-$DEFAULT_VAAPI_DEVICE}"
VIDEO_CODEC="${VIDEO_CODEC:-$DEFAULT_VIDEO_CODEC}"
QUALITY="${QUALITY:-$DEFAULT_QUALITY}"
PRESET="${PRESET:-$DEFAULT_PRESET}"
X265_POOLS="${X265_POOLS:-$DEFAULT_X265_POOLS}"
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

AUDIO_COPY_FIRST="${AUDIO_COPY_FIRST:-$DEFAULT_AUDIO_COPY_FIRST}"
AUDIO_CODEC="${AUDIO_CODEC:-$DEFAULT_AUDIO_CODEC}"
AUDIO_PROFILE="${AUDIO_PROFILE:-$DEFAULT_AUDIO_PROFILE}"
AUDIO_BITRATE_MONO="${AUDIO_BITRATE_MONO:-$DEFAULT_AUDIO_BITRATE_MONO}"
AUDIO_BITRATE_STEREO="${AUDIO_BITRATE_STEREO:-$DEFAULT_AUDIO_BITRATE_STEREO}"
AUDIO_BITRATE_SURROUND="${AUDIO_BITRATE_SURROUND:-$DEFAULT_AUDIO_BITRATE_SURROUND}"
AUDIO_BITRATE_SURROUND_PLUS="${AUDIO_BITRATE_SURROUND_PLUS:-$DEFAULT_AUDIO_BITRATE_SURROUND_PLUS}"
AUDIO_FILTER_LANGUAGES="${AUDIO_FILTER_LANGUAGES:-$DEFAULT_AUDIO_FILTER_LANGUAGES}"

LANGUAGE="${LANGUAGE:-$DEFAULT_LANGUAGE}"
PREFER_ORIGINAL="${PREFER_ORIGINAL:-$DEFAULT_PREFER_ORIGINAL}"
ORIGINAL_LANGUAGE="${ORIGINAL_LANGUAGE:-$DEFAULT_ORIGINAL_LANGUAGE}"

DETECT_INTERLACING="${DETECT_INTERLACING:-$DEFAULT_DETECT_INTERLACING}"
ADAPTIVE_DEINTERLACE="${ADAPTIVE_DEINTERLACE:-$DEFAULT_ADAPTIVE_DEINTERLACE}"
DETECT_CROP="${DETECT_CROP:-$DEFAULT_DETECT_CROP}"
DETECT_PULLDOWN="${DETECT_PULLDOWN:-$DEFAULT_DETECT_PULLDOWN}"
SPLIT_CHAPTERS="${SPLIT_CHAPTERS:-$DEFAULT_SPLIT_CHAPTERS}"
CHAPTERS_PER_EPISODE="${CHAPTERS_PER_EPISODE:-$DEFAULT_CHAPTERS_PER_EPISODE}"

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
CONTAINER="${CONTAINER:-$DEFAULT_CONTAINER}"

# ============================================================================
# FUNCTIONS
# ============================================================================

show_help() {
	cat << EOF
Transcode Monster v${SCRIPT_VERSION}
Universal video transcoding script with automatic series/movie detection

USAGE:
  transcode-monster.sh [options] <source> [output_dir]

ARGUMENTS:
  source                 Source directory or file(s) to transcode
  output_dir             Output directory (default: ${DEFAULT_OUTPUT_DIR})

OPTIONS:
  -h, --help             Show this help message
  -v, --version          Show version information

  -t, --type TYPE        Override auto-detection: 'series' or 'movie'
  -n, --name NAME        Set title name (e.g., "Firefly" or "Dune")
  -s, --season NUM       Process only specific season (default: all seasons)
  -e, --episode NUM      Process only specific episode in series mode
  -y, --year YEAR        Add year to movie title (e.g., 1984)

  -q, --quality NUM      Video quality CQP/CRF value (default: ${DEFAULT_QUALITY})
  -c, --codec CODEC      Video codec: 'auto', 'hevc_vaapi', 'libx265' (default: ${DEFAULT_VIDEO_CODEC})
  --preset PRESET        x265 encoding preset for software encoding (default: ${DEFAULT_PRESET})
			 Options: ultrafast, superfast, veryfast, faster, fast,
				  medium, slow, slower, veryslow, placebo
  -b, --bframes NUM      Number of B-frames: 0-4+ (default: ${DEFAULT_BFRAMES})
			 0 = max compatibility, 1-2 = balanced, 3-4 = best compression

  --no-crop              Disable automatic crop detection
  --no-deinterlace       Disable automatic deinterlacing
  --adaptive-deinterlace Force adaptive deinterlacing for mixed progressive/interlaced content
			 Only processes frames detected as interlaced, leaving progressive
			 frames untouched. Useful for content like film transfers with
			 interlaced title cards or mixed-source compilations
  --no-pulldown          Disable 3:2 pulldown detection (inverse telecine)
  --force-ivtc           Force inverse telecine detection even on HD content
			 (by default, only runs on SD content ≤576p)
  --split-chapters       Force chapter splitting for multi-episode files
  --no-split-chapters    Disable chapter splitting (process file as single video)
  --chapters-per-episode N
			 Group N chapters into each episode (default: auto-detect)
			 Auto-detection finds most uniform episode grouping

  --language LANG        Default language (ISO 639-2 code, default: eng)
  --original-lang LANG   Prefer original language mode (e.g., jpn for anime)
			 Selects original language audio + default language subs
  --all-audio            Keep all audio tracks (disables language filtering)

  --device PATH          VAAPI device path (default: ${DEFAULT_VAAPI_DEVICE})
  --overwrite            Overwrite existing output files

  -d, --dry-run          Show what would be processed without encoding

ENCODER:
  The script uses hybrid encoding for optimal speed and quality:
  - SD content (≤576p): libx265 software encoding with robust image processing
  - HD content (>576p): hevc_vaapi hardware encoding for a massive speedup

  For software encoding (SD content):
  - Performs color correction to avoid chroma subsampling errors, etc.
  - Runs with reduced priority (nice/ionice) to lessen system impact
  - Maximizes CPU utilization with automatic thread pooling
  - You can adjust preset with --preset for speed/quality tradeoff

  B-frames (Bidirectional frames):
  - Improve compression by referencing both past and future frames
  - Default: 0 (disabled) for maximum hardware compatibility
	   1-2 = balanced efficiency with minimal overhead
	   3-4 = best compression for archiving (higher decode complexity)
  - Hardware support varies: Intel QSV and newer AMD (RX 6000+) support 2-4
  - Note: Higher B-frame values increase decode complexity; may not play
	  smoothly on older/low-power devices (smart TVs, older phones, etc.)
  - Configure via BFRAMES in config file or --bframes option

AUDIO ENCODING:
  The script copies the first audio track and encodes others to HE-AAC:
  - First track: Copied as-is (e.g. for passthrough to an A/V receiver)
  - Other tracks: HE-AAC with channel-appropriate, transparent bitrates
    - Mono: 96 kbps
    - Stereo: 128 kbps
    - 5.1 surround: 192 kbps
    - 7.1+ surround: 256 kbps

  Language filtering (enabled by default):
  - Keeps audio tracks matching your default language (LANGUAGE setting)
  - When using --original-lang, also keeps that language (e.g., jpn for anime)
  - Always keeps commentary tracks (regardless of language)
  - Always keeps 'und' (undetermined language) tracks
  - Skips foreign overdubs (e.g., French/German/Spanish dubs on English content)
  - Disable filtering with --all-audio to keep all tracks

CONTENT DETECTION:
  - Series: Multiple files in S#D# directories or sequential files
  - Movie: Single file or directory without series markers

  Series naming patterns detected:
    /path/to/Show/S1D1/, /path/to/Show Season 1/, /path/Show S01/

  Output examples:
    Series: "Firefly - S01E01.mkv"
    Movie:  "Dune (1984).mkv"

CONFIG FILE:
  ${CONFIG_FILE}

  All settings can be configured in this file using bash variable syntax:
    QUALITY="20"
    VIDEO_CODEC="hevc_vaapi"
    PRESET="medium"
    OUTPUT_DIR="/path/to/videos"
    AUDIO_BITRATE_STEREO="128k"
    AUDIO_BITRATE_SURROUND="192k"
    ADAPTIVE_DEINTERLACE="true"

  Priority: Built-in defaults < Config file < Command line arguments

EXAMPLES:
  # Auto-detect everything from directory
  transcode-monster.sh "/path/to/Firefly/S1D1"

  # Transcode specific file(s)
  transcode-monster.sh "/path/to/rips/movie.mkv" "/path/to/movies"
  transcode-monster.sh "/path/to/rips/episode_*.mkv" "/path/to/tv"

  # Specify series name and output
  transcode-monster.sh -n "Firefly" "/path/to/rips/S1D1" "/path/to/tv/Firefly"

  # Transcode a movie with year
  transcode-monster.sh -t movie -n "Dune" -y 1984 "/path/to/rips/dune"

  # Override season detection to only process a particular season
  transcode-monster.sh -s 2 "/path/to/rips/disc1" "/path/to/tv/House"

  # Process only episode 3 of season 1
  transcode-monster.sh -s 1 -e 3 "/path/to/tv/Show/"

  # Custom quality and disable crop detection
  transcode-monster.sh -q 21 --no-crop "/path/to/rips"

  # Mixed progressive/interlaced content (film with interlaced titles)
  transcode-monster.sh --adaptive-deinterlace "/path/to/rips/ctd.mkv"

  # "Anime mode": prefer foreign audio with subs in our default language
  transcode-monster.sh --original-lang jpn "/path/to/anime/Cowboy Bebop/"

  # Default language override: Spanish audio for native speakers
  transcode-monster.sh --language spa "/path/to/series/La Casa de Papel/"

EOF
}

show_version() {
	echo "Transcode Monster v${SCRIPT_VERSION}"
}

# Parse episode number from filename
get_episode_num() {
	local filename="$1"
	local ep_num=$(echo "$filename" | sed -E 's/.*[t_]([0-9]{2,3})\.mkv$/\1/')
	if [[ -z "$ep_num" || ! "$ep_num" =~ ^[0-9]{2,3}$ ]]; then
		echo "UNKNOWN"
	else
		# Strip leading zeros for sorting (will be reformatted later)
		ep_num=$((10#$ep_num))
		echo "$ep_num"
	fi
}

# Detect if content is telecined (3:2 pulldown)
detect_telecine() {
	local input="$1"

    # Analyze field statistics - need more frames for accurate detection
    local idet_output=$(ffmpeg -i "$input" -vf idet -frames:v 500 -an -f null - 2>&1)

    # Get repeated field counts (key indicator of telecine)
    local rep_top=$(echo "$idet_output" | grep "Repeated Fields:" | tail -1 | grep -oP 'Top:\s*\K[0-9]+' || echo "0")
    local rep_bot=$(echo "$idet_output" | grep "Repeated Fields:" | tail -1 | grep -oP 'Bottom:\s*\K[0-9]+' || echo "0")

    # Get interlacing stats
    local tff=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'TFF:\s*\K[0-9]+' || echo "0")
    local bff=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'BFF:\s*\K[0-9]+' || echo "0")
    local prog=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'Progressive:\s*\K[0-9]+' || echo "0")

    # Clean values
    rep_top=$(echo "$rep_top" | tr -d '[:space:]')
    rep_bot=$(echo "$rep_bot" | tr -d '[:space:]')
    tff=$(echo "$tff" | tr -d '[:space:]')
    bff=$(echo "$bff" | tr -d '[:space:]')
    prog=$(echo "$prog" | tr -d '[:space:]')

    # Validate
    if ! [[ "$tff" =~ ^[0-9]+$ ]] || ! [[ "$bff" =~ ^[0-9]+$ ]] || ! [[ "$prog" =~ ^[0-9]+$ ]]; then
	    echo "none"
	    return
    fi

    if ! [[ "$rep_top" =~ ^[0-9]+$ ]] || ! [[ "$rep_bot" =~ ^[0-9]+$ ]]; then
	    rep_top=0
	    rep_bot=0
    fi

    local total=$((tff + bff + prog))
    if [[ $total -eq 0 ]]; then
	    echo "none"
	    return
    fi

    # In 3:2 pulldown, every 5 frames has 2 repeated fields (40% of frames)
    local total_repeated=$((rep_top + rep_bot))
    if [[ $total_repeated -gt 0 ]]; then
	    local repeated_pct=$((total_repeated * 100 / total))
	    # If we see significant repeated fields (>10%), it's likely telecine
	    if [[ $repeated_pct -gt 10 ]]; then
		    echo "telecine"
		    return
	    fi
    fi

    echo "none"
}

# Detect interlacing
detect_interlacing() {
	local input="$1"

    # Get total duration and seek to ~10% in to avoid title cards/production logos
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    duration=${duration//,/}

    local seek_time="0"
    if [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
	    seek_time=$(echo "scale=2; $duration * 0.1" | bc 2>/dev/null || echo "0")
    fi

    # Run idet analysis - don't trust metadata, analyze actual content
    local idet_output=$(ffmpeg -ss "$seek_time" -i "$input" -vf idet -frames:v 200 -an -f null - 2>&1)

    # Parse the "Multi frame detection" line
    local tff_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'TFF:\s*\K[0-9]+' || echo "0")
    local bff_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'BFF:\s*\K[0-9]+' || echo "0")
    local prog_count=$(echo "$idet_output" | grep "Multi frame detection:" | tail -1 | grep -oP 'Progressive:\s*\K[0-9]+' || echo "0")

    # Use threshold-based detection: if >80% of frames are interlaced, treat as interlaced
    # This avoids false positives from progressive content with bad metadata
    local total=$((tff_count + bff_count + prog_count))
    if [[ $total -gt 0 ]]; then
	    local interlaced_count=$((tff_count + bff_count))
	    local interlaced_pct=$((interlaced_count * 100 / total))

	    if [[ $interlaced_pct -gt 80 ]]; then
		    if [[ $tff_count -gt $bff_count ]]; then
			    echo "tff"
			    return
		    else
			    echo "bff"
			    return
		    fi
	    fi
    fi

    echo "progressive"
}

# Detect crop
detect_crop() {
	local input="$1"

    # Get total duration and seek to ~10% in to avoid title cards
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    duration=${duration//,/}

    local seek_time="0"
    if [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
	    seek_time=$(echo "scale=2; $duration * 0.1" | bc 2>/dev/null || echo "0")
    fi

    # Don't use -v quiet here - we need the cropdetect output!
    local crop_line=$(ffmpeg -ss "$seek_time" -i "$input" -vf cropdetect=0.1:16:100 -frames:v 1000 -f null - 2>&1 | grep 'crop=' | tail -20 | sort | uniq -c | sort -nr | head -1 | grep -o 'crop=[0-9:]*' | cut -d'=' -f2)

    if [[ -z "$crop_line" ]]; then
	    echo ""
	    return
    fi

    local w=$(echo "$crop_line" | cut -d: -f1)
    local h=$(echo "$crop_line" | cut -d: -f2)
    local x=$(echo "$crop_line" | cut -d: -f3)
    local y=$(echo "$crop_line" | cut -d: -f4)

    if [[ -z "$w" || -z "$h" || -z "$x" || -z "$y" ]]; then
	    echo ""
	    return
    fi

    # Remove any commas from locale-formatted numbers
    w=${w//,/}
    h=${h//,/}
    x=${x//,/}
    y=${y//,/}

    # Validate they're actually numbers
    if ! [[ "$w" =~ ^[0-9]+$ ]] || ! [[ "$h" =~ ^[0-9]+$ ]] || ! [[ "$x" =~ ^[0-9]+$ ]] || ! [[ "$y" =~ ^[0-9]+$ ]]; then
	    echo ""
	    return
    fi

    w=$((w - (w % 16)))
    h=$((h - (h % 16)))

    local orig_w=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input")
    local orig_h=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input")

    # Remove any commas from locale-formatted numbers
    orig_w=${orig_w//,/}
    orig_h=${orig_h//,/}

    # Validate they're numbers
    if ! [[ "$orig_w" =~ ^[0-9]+$ ]] || ! [[ "$orig_h" =~ ^[0-9]+$ ]]; then
	    echo ""
	    return
    fi

    if [[ "$w" -eq "$orig_w" && "$h" -eq "$orig_h" ]]; then
	    echo ""
	    return
    fi

    echo "$w:$h:$x:$y"
}

# Build video filter chain - works for both VAAPI and software encoding
build_vf() {
	local input="$1"
	local encoder_type="$2"  # "vaapi" or "software"
	local bit_depth="$3"
	local vf=""
	local vf_cpu=""  # CPU-side filters (before hwupload)
	local vf_gpu=""  # GPU-side filters (after hwupload)

    # Get height for later use
    local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input")
    height=${height//,/}

    # Crop detection (always done on CPU first)
    if [[ "$DETECT_CROP" == "true" ]]; then
	    local crop=$(detect_crop "$input")
	    if [[ -n "$crop" ]]; then
		    vf_cpu="crop=$crop"
	    fi
    fi

    if [[ "$encoder_type" == "vaapi" ]]; then
	    # ============================================================
	    # VAAPI PATH: Minimize CPU processing, use GPU deinterlacer
	    # ============================================================

	# Determine if we should check for telecine
	local should_check_telecine=false
	if [[ "$DETECT_PULLDOWN" == "true" ]]; then
		should_check_telecine=true
	elif [[ "$DETECT_PULLDOWN" == "auto" && "$height" =~ ^[0-9]+$ && $height -le 576 ]]; then
		should_check_telecine=true
	fi

	# Check for telecine first (only on SD content by default)
	local telecine="none"
	local skip_interlace=false
	if [[ "$should_check_telecine" == "true" ]]; then
		telecine=$(detect_telecine "$input")
		if [[ "$telecine" == "telecine" ]]; then
			# Telecine MUST be done on CPU (no GPU equivalent)
			[[ -n "$vf_cpu" ]] && vf_cpu="$vf_cpu,"
			vf_cpu="${vf_cpu}fieldmatch=order=tff:mode=pc_n:mchroma=false,yadif=deint=interlaced,decimate"
			echo "    Telecine detected - using CPU inverse telecine (will be slower)" >&2
			skip_interlace=true
		fi
	fi

	# Check if adaptive deinterlacing is requested (for mixed content)
	if [[ "$ADAPTIVE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		# Force adaptive deinterlacing regardless of detection
		vf_gpu="deinterlace_vaapi=mode=motion_adaptive:rate=frame"
		echo "    Added adaptive GPU deinterlacer: deinterlace_vaapi (motion adaptive)" >&2
		# Interlacing detection - use VAAPI deinterlacer for speed
	elif [[ "$DETECT_INTERLACING" == "true" && "$skip_interlace" == "false" ]]; then
		local interlacing=$(detect_interlacing "$input")
		echo "    Interlacing detected: $interlacing" >&2

	    # Only add deinterlacer if we explicitly detected interlacing
	    if [[ "$interlacing" == "tff" || "$interlacing" == "bff" ]]; then
		    vf_gpu="deinterlace_vaapi=rate=frame"
		    echo "    Using GPU deinterlacer: deinterlace_vaapi" >&2
	    fi
	fi

	# Build complete filter chain
	# Format and upload to GPU
	[[ -n "$vf_cpu" ]] && vf="$vf_cpu,"
	if [[ "$bit_depth" == "10" ]]; then
		vf="${vf}format=p010le,hwupload"
	else
		vf="${vf}format=nv12,hwupload"
	fi

	# Add GPU filters if any
	[[ -n "$vf_gpu" ]] && vf="$vf,$vf_gpu"

else
	# ============================================================
	# SOFTWARE PATH: Use CPU filters
	# ============================================================

	vf="$vf_cpu"

	# Determine if we should check for telecine
	local should_check_telecine=false
	if [[ "$DETECT_PULLDOWN" == "true" ]]; then
		should_check_telecine=true
	elif [[ "$DETECT_PULLDOWN" == "auto" && "$height" =~ ^[0-9]+$ && $height -le 576 ]]; then
		should_check_telecine=true
	fi

	# Check for telecine first
	local telecine="none"
	local skip_interlace=false
	if [[ "$should_check_telecine" == "true" ]]; then
		telecine=$(detect_telecine "$input")
		if [[ "$telecine" == "telecine" ]]; then
			[[ -n "$vf" ]] && vf="$vf,"
			vf="${vf}fieldmatch=order=tff:mode=pc_n:mchroma=false,yadif=deint=interlaced,decimate"
			echo "    Detected telecine - using fieldmatch+yadif+decimate for inverse telecine" >&2
			skip_interlace=true
		fi
	fi

	# Check if adaptive deinterlacing is requested
	if [[ "$ADAPTIVE_DEINTERLACE" == "true" && "$skip_interlace" == "false" ]]; then
		# Force adaptive deinterlacing regardless of detection
		[[ -n "$vf" ]] && vf="$vf,"
		vf="${vf}yadif=mode=0:parity=-1:deint=1"
		echo "    Added adaptive deinterlacer: yadif (deint=interlaced only)" >&2
		# Normal interlacing detection (use CPU bwdif for software encoding)
	elif [[ "$DETECT_INTERLACING" == "true" && "$skip_interlace" == "false" ]]; then
		local interlacing=$(detect_interlacing "$input")
		echo "    Interlacing detected: $interlacing" >&2

	    # Only add deinterlacer if we explicitly detected interlacing
	    if [[ "$interlacing" == "tff" || "$interlacing" == "bff" ]]; then
		    local parity
		    if [[ "$interlacing" == "tff" ]]; then
			    parity="0"
		    else
			    parity="1"
		    fi
		    [[ -n "$vf" ]] && vf="$vf,"
		    vf="${vf}bwdif=mode=0:parity=$parity:deint=0"
		    echo "    Added deinterlacer: bwdif with parity=$parity" >&2
	    fi
	fi

	# Add color matrix conversion for SD content
	if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
		[[ -n "$vf" ]] && vf="$vf,"
		vf="${vf}scale=in_color_matrix=bt601:out_color_matrix=bt601:flags=lanczos"
		echo "    Applied bt601 color matrix conversion" >&2
	fi
    fi

    echo "$vf"
}

# Build x265 parameters
build_x265_params() {
	local bit_depth="$1"
	local height="$2"

    # Optimize for maximum CPU utilization
    local params="keyint=${GOP_SIZE}:min-keyint=${MIN_KEYINT}:bframes=${BFRAMES}:ref=${REFS}"

    # Add thread pooling for better multi-core utilization
    # "+" means auto-detect optimal thread count and distribution
    params="${params}:pools=${X265_POOLS}"

    # Set appropriate profile and pixel format based on bit depth
    local profile pix_fmt
    if [[ "$bit_depth" == "10" ]]; then
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
	local pix_fmt=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

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

	if [[ "$bit_depth" == "10" ]]; then
		echo "main10"
	else
		echo "main"
	fi
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

# Determine subtitle disposition based on audio/subtitle languages
get_subtitle_disposition() {
	local input="$1"
	local audio_lang="$2"      # Language of the default audio track
	local native_langs="$3"    # User's native language(s) - comma-separated (e.g., "eng" or "eng,spa")

    # Get all subtitle tracks with their language
    local sub_info=$(ffprobe -v quiet -select_streams s -show_entries stream_tags=language -of csv=p=0 "$input" 2>/dev/null)

    # Parse native languages into array
    IFS=',' read -ra NATIVE_LANGS <<< "$native_langs"

    # If audio is already in one of the native languages, no default subtitle needed
    for native in "${NATIVE_LANGS[@]}"; do
	    native=$(echo "$native" | xargs)  # Trim whitespace
	    if [[ "$audio_lang" == "$native" ]]; then
		    echo "-1"
		    return
	    fi
    done

    # Audio is NOT in native language, find first matching native language subtitle
    local track_index=0
    while IFS=',' read -r lang; do
	    for native in "${NATIVE_LANGS[@]}"; do
		    native=$(echo "$native" | xargs)  # Trim whitespace
		    if [[ "$lang" == "$native" ]]; then
			    echo "$track_index"
			    return
		    fi
	    done
	    track_index=$((track_index + 1))
    done <<< "$sub_info"

    # No native language subtitle found
    echo "-1"
}

# Check if file should be split by chapters
should_split_by_chapters() {
	local input="$1"
	local content_type="$2"

    # Get chapter count and duration
    local chapter_count=$(ffprobe -v quiet -show_chapters "$input" 2>/dev/null | grep -c "^\[CHAPTER\]")
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)

    # Clean duration value
    duration=${duration//,/}

    # Check split mode
    if [[ "$SPLIT_CHAPTERS" == "true" ]]; then
	    # Force on - split if there are chapters
	    if [[ $chapter_count -gt 0 ]]; then
		    echo "true"
		    return
	    fi
    elif [[ "$SPLIT_CHAPTERS" == "auto" ]]; then
	    # Auto mode - only for series with files >60 minutes and multiple chapters
	    if [[ "$content_type" == "series" ]] && [[ $chapter_count -gt 1 ]]; then
		    if [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$duration > 3600" | bc -l 2>/dev/null || echo 0) )); then
			    echo "true"
			    return
		    fi
	    fi
    fi

    echo "false"
}

# Get chapter times for splitting
get_chapter_times() {
	local input="$1"

    # Extract only chapter start times using a more reliable method
    ffprobe -v quiet -show_chapters "$input" 2>/dev/null | grep "start_time=" | cut -d'=' -f2
}

# Detect optimal chapters per episode grouping
detect_chapters_per_episode() {
	local input="$1"

    # Get all chapter times
    local chapter_times=($(get_chapter_times "$input"))
    local chapter_count=${#chapter_times[@]}

    if [[ $chapter_count -eq 0 ]]; then
	    echo "1"
	    return
    fi

    # Get total duration
    local total_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    total_duration=${total_duration//,/}

    # Validate total duration
    if ! [[ "$total_duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
	    echo "1"
	    return
    fi

    # Calculate duration of each chapter
    local durations=()
    for ((i=0; i<chapter_count; i=i+1)); do
	    local start="${chapter_times[$i]}"
	    local end
	    if [[ $((i + 1)) -lt $chapter_count ]]; then
	    end="${chapter_times[$((i + 1))]}"
    else
    end="$total_duration"
	    fi

	# Validate start and end are numbers
	if ! [[ "$start" =~ ^[0-9]+\.?[0-9]*$ ]] || ! [[ "$end" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		echo "1"
		return
	fi

	local duration=$(echo "$end - $start" | bc 2>/dev/null)
	if [[ -z "$duration" ]] || ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		echo "1"
		return
	fi
	durations+=("$duration")
done

    # Try different groupings (1-6 chapters per episode)
    local best_grouping=1
    local best_stddev=999999

    for grouping in 1 2 3 4 5 6; do
	    # Check if grouping divides evenly
	    if [[ $((chapter_count % grouping)) -ne 0 ]]; then
		    continue
	    fi

	# Calculate episode durations for this grouping
	local episode_durations=()
	for ((ep=0; ep<chapter_count; ep=ep+grouping)); do
		local ep_duration=0
		for ((ch=0; ch<grouping; ch=ch+1)); do
			local idx=$((ep + ch))
			if [[ $idx -lt ${#durations[@]} ]]; then
				ep_duration=$(echo "$ep_duration + ${durations[$idx]}" | bc 2>/dev/null)
			fi
		done
		episode_durations+=("$ep_duration")
	done

	# Calculate mean
	local sum=0
	for dur in "${episode_durations[@]}"; do
		sum=$(echo "$sum + $dur" | bc 2>/dev/null)
	done
	local mean=$(echo "scale=2; $sum / ${#episode_durations[@]}" | bc -l 2>/dev/null)

	# Validate mean
	if [[ -z "$mean" ]] || ! [[ "$mean" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		continue
	fi

	# Calculate standard deviation
	local variance=0
	for dur in "${episode_durations[@]}"; do
		local diff=$(echo "scale=2; $dur - $mean" | bc 2>/dev/null)
		local sq=$(echo "scale=2; $diff * $diff" | bc 2>/dev/null)
		variance=$(echo "scale=2; $variance + $sq" | bc 2>/dev/null)
	done
	variance=$(echo "scale=2; $variance / ${#episode_durations[@]}" | bc -l 2>/dev/null)

	# Validate variance
	if [[ -z "$variance" ]] || ! [[ "$variance" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		continue
	fi

	local stddev=$(echo "scale=2; sqrt($variance)" | bc -l 2>/dev/null)

	# Validate stddev
	if [[ -z "$stddev" ]] || ! [[ "$stddev" =~ ^[0-9]+\.?[0-9]*$ ]]; then
		continue
	fi

	# Check if average episode length is reasonable (15-35 minutes = 900-2100 seconds)
	local mean_int=$(printf "%.0f" "$mean" 2>/dev/null)
	if [[ -z "$mean_int" ]] || [[ $mean_int -lt 900 ]] || [[ $mean_int -gt 2100 ]]; then
		continue
	fi

	# Update best if this has lower standard deviation
	local stddev_int=$(printf "%.0f" "$stddev" 2>/dev/null)
	if [[ -n "$stddev_int" ]] && [[ $stddev_int -lt $best_stddev ]]; then
		best_stddev=$stddev_int
		best_grouping=$grouping
	fi
done

echo "$best_grouping"
}

# Infer content type from directory structure
infer_type() {
	local source="$1"

    # Check for season/disc patterns (case-insensitive)
    if [[ "$source" =~ [Ss][0-9]+[Dd][0-9]+ ]] || [[ "$source" =~ [Ss]eason.*[0-9]+ ]]; then
	    echo "series"
	    return
    fi

    # Check if directory contains S#D# subdirectories (multi-season series, case-insensitive)
    shopt -s nullglob nocaseglob
    local season_dirs=("$source"/[Ss][0-9]*[Dd][0-9]*)
    shopt -u nullglob nocaseglob
    if [[ ${#season_dirs[@]} -gt 0 ]]; then
	    echo "series"
	    return
    fi

    # Check if directory contains multiple video files
    local mkv_count=$(find "$source" -maxdepth 1 -name "*.mkv" 2>/dev/null | wc -l)
    if [[ $mkv_count -gt 1 ]]; then
	    echo "series"
	    return
    fi

    # Default to movie for single file
    echo "movie"
}

# Get all seasons present in directory
get_all_seasons() {
	local source="$1"
	local seasons=()

	shopt -s nullglob nocaseglob
	local season_dirs=("$source"/[Ss][0-9]*[Dd][0-9]*)
	shopt -u nullglob nocaseglob

	for dir in "${season_dirs[@]}"; do
		local basename=$(basename "$dir")
		if [[ "$basename" =~ [Ss]([0-9]+)[Dd][0-9]+ ]]; then
			local season_num="${BASH_REMATCH[1]}"
			# Remove leading zeros
			season_num=$((10#$season_num))
			seasons+=("$season_num")
		fi
	done

    # Remove duplicates and sort
    if [[ ${#seasons[@]} -gt 0 ]]; then
	    printf '%s\n' "${seasons[@]}" | sort -nu
    fi
}

# Extract season number from path
extract_season() {
	local source="$1"

    # Try S#D# pattern (case-insensitive)
    if [[ "$source" =~ [Ss]([0-9]+)[Dd][0-9]+ ]]; then
	    echo "${BASH_REMATCH[1]}"
	    return
    fi

    # Try "Season #" pattern (case-insensitive)
    if [[ "$source" =~ [Ss]eason[[:space:]]*([0-9]+) ]]; then
	    echo "${BASH_REMATCH[1]}"
	    return
    fi

    # Try S## pattern (case-insensitive)
    if [[ "$source" =~ [Ss]([0-9]{2}) ]]; then
	    echo "${BASH_REMATCH[1]}"
	    return
    fi

    echo "1"  # Default to season 1
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
    if [[ "$(basename "$source")" =~ ^[Ss][0-9]+[Dd][0-9]+$ ]]; then
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

    # Detect bit depth and height
    local bit_depth=$(detect_bit_depth "$source_file")
    local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$source_file")
    height=${height//,/}

    # Determine encoder
    local actual_codec=""
    local encoder_type=""
    if [[ "$VIDEO_CODEC" == "auto" ]]; then
	    if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
		    actual_codec="libx265"
		    encoder_type="software"
	    else
		    actual_codec="hevc_vaapi"
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
    local vf=$(build_vf "$source_file" "$encoder_type" "$bit_depth")

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

    # Map the preferred audio track first
    if [[ "$AUDIO_COPY_FIRST" == "true" && $num_audio -gt 0 ]]; then
	    audio_opts="-map 0:a:$default_audio_idx -c:a:0 copy"
    else
	    local bitrate=$(get_audio_bitrate "$source_file" $default_audio_idx)
	    audio_opts="-map 0:a:$default_audio_idx -c:a:0 $AUDIO_CODEC -profile:a:0 $AUDIO_PROFILE -b:a:0 $bitrate"
    fi

    # Map remaining audio tracks
    if [[ $num_audio -gt 1 ]]; then
	    local track_idx=1
	    for ((i=0; i<num_audio; i=i+1)); do
		    if [[ $i -eq $default_audio_idx ]]; then
			    continue
		    fi

	    # Check if we should include this track
	    if [[ "$(should_include_audio_track "$source_file" $i)" != "true" ]]; then
		    continue
	    fi

	    local bitrate=$(get_audio_bitrate "$source_file" $i)
	    audio_opts="$audio_opts -map 0:a:$i -c:a:$track_idx $AUDIO_CODEC -profile:a:$track_idx $AUDIO_PROFILE -b:a:$track_idx $bitrate"
	    track_idx=$((track_idx + 1))
    done
    fi
    audio_opts="$audio_opts -disposition:a:0 default"

    # Smart subtitle handling with language filtering
    local num_subs=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$source_file" 2>/dev/null | wc -l)

    # Build subtitle mapping - only include subtitles in our language(s)
    local sub_opts=""
    local sub_track_idx=0
    declare -A input_to_output_sub_map

    for ((i=0; i<num_subs; i=i+1)); do
	    # Check if we should include this subtitle track
	    if [[ "$(should_include_subtitle_track "$source_file" $i)" == "true" ]]; then
		    sub_opts="$sub_opts -map 0:s:$i"
		    input_to_output_sub_map[$i]=$sub_track_idx
		    sub_track_idx=$((sub_track_idx + 1))
	    fi
    done

    # Add codec if we have any subtitles
    if [[ $sub_track_idx -gt 0 ]]; then
	    sub_opts="$sub_opts -c:s copy"

	# Determine which subtitle should be default based on audio language
	local sub_default_input_idx=$(get_subtitle_disposition "$source_file" "$default_audio_lang" "$LANGUAGE")

	# Check if the default subtitle exists in our filtered set
	if [[ "$sub_default_input_idx" != "-1" ]] && [[ -v input_to_output_sub_map[$sub_default_input_idx] ]]; then
		# Map input index to output index
		local sub_default_output_idx="${input_to_output_sub_map[$sub_default_input_idx]}"
		sub_opts="$sub_opts -disposition:s 0 -disposition:s:$sub_default_output_idx default"
	else
		sub_opts="$sub_opts -disposition:s 0"
	fi
    fi

    # Build command based on encoder type
    local cmd=""
    local priority_prefix=$(build_priority_prefix)

    if [[ "$encoder_type" == "vaapi" ]]; then
	    local vaapi_profile=$(get_vaapi_profile "$bit_depth")

	    cmd="$priority_prefix ffmpeg${input_opts:+ $input_opts} -i \"$source_file\""
	    cmd="$cmd -map 0:v:0"
	    cmd="$cmd $audio_opts"
	    [[ -n "$sub_opts" ]] && cmd="$cmd $sub_opts"
	    cmd="$cmd -c:v \"$actual_codec\" -vaapi_device \"$VAAPI_DEVICE\" -rc_mode CQP -qp \"$QUALITY\""
	    cmd="$cmd -g \"$GOP_SIZE\" -keyint_min \"$MIN_KEYINT\" -bf \"$BFRAMES\" -low_power false"
	    cmd="$cmd -refs \"$REFS\" -profile:v \"$vaapi_profile\""
	    [[ -n "$vf" ]] && cmd="$cmd -vf \"$vf\""
	    cmd="$cmd -map_chapters 0"
	    cmd="$cmd -f \"$CONTAINER\" \"$output_file\" -y"
    else
	    local x265_profile pix_fmt x265_params
	    IFS='|' read -r x265_profile pix_fmt x265_params <<< "$(build_x265_params "$bit_depth" "$height")"

	    cmd="$priority_prefix ffmpeg${input_opts:+ $input_opts} -i \"$source_file\""
	    cmd="$cmd -map 0:v:0"
	    cmd="$cmd $audio_opts"
	    [[ -n "$sub_opts" ]] && cmd="$cmd $sub_opts"
	    cmd="$cmd -c:v $actual_codec -preset $PRESET -crf $QUALITY -pix_fmt $pix_fmt"
	    [[ -n "$vf" ]] && cmd="$cmd -vf \"$vf\""
	    cmd="$cmd -x265-params \"$x265_params\""
	    cmd="$cmd -map_chapters 0"
	    cmd="$cmd -f \"$CONTAINER\" \"$output_file\" -y"
    fi

    echo "$cmd"
}

# ============================================================================
# PARSE COMMAND LINE ARGUMENTS (Priority 3: CLI)
# ============================================================================

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
		--no-pulldown)
			DETECT_PULLDOWN="false"
			shift
			;;
		--force-ivtc)
			DETECT_PULLDOWN="true"
			shift
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
		--overwrite)
			OVERWRITE="true"
			shift
			;;
		-d|--dry-run)
			DRY_RUN=true
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

# ============================================================================
# VALIDATE ARGUMENTS
# ============================================================================

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
if [[ ${#SOURCE_ARGS[@]} -gt 0 ]]; then
	normalize_source "${SOURCE_ARGS[@]}"
else
	echo -e "${RED}Error: No source files or directories specified${RESET}"
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

# ============================================================================
# CONTENT DETECTION
# ============================================================================

# Auto-detect if not specified
if [[ -z "$CONTENT_TYPE" ]]; then
	if [[ "$FILE_MODE" == true ]]; then
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

if [[ "$CONTENT_TYPE" == "movie" && ${#SOURCE_FILES[@]} -gt 1 ]]; then
	echo -e "${RED}Error: Multiple files specified for movie mode. Movie mode supports only a single file or directory.${RESET}"
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

# Add year to movie name if specified
if [[ "$CONTENT_TYPE" == "movie" && -n "$YEAR" ]]; then
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

echo -e "${BLUE}============================================${RESET}"
echo -e "${BOLDBLUE}Transcode Monster v${SCRIPT_VERSION}${RESET}"
echo -e "${BLUE}============================================${RESET}"
echo -e "${BOLD}Source:${RESET}       $SOURCE_DIR"
echo -e "${BOLD}Output:${RESET}       $OUTPUT_DIR"
echo -e "${BOLD}Type:${RESET}         $CONTENT_TYPE"
echo -e "${BOLD}Name:${RESET}         $CONTENT_NAME"
[[ "$CONTENT_TYPE" == "series" ]] && echo -e "${BOLD}Seasons:${RESET}      ${SEASONS_TO_PROCESS[*]}"
[[ "$CONTENT_TYPE" == "series" && -n "$EPISODE_NUM" ]] && echo -e "${BOLD}Episode:${RESET}      $EPISODE_NUM"
echo -e "${BOLD}Quality:${RESET}      $QUALITY (CQP)"
echo -e "${BOLD}Codec:${RESET}        $VIDEO_CODEC"
echo -e "${BOLD}Crop:${RESET}         $DETECT_CROP"
echo -e "${BOLD}Deinterlace:${RESET}  $DETECT_INTERLACING"
[[ "$ADAPTIVE_DEINTERLACE" == "true" ]] && echo -e "${BOLD}Adaptive:${RESET}     $ADAPTIVE_DEINTERLACE"
echo -e "${BOLD}Pulldown:${RESET}     $DETECT_PULLDOWN"
echo -e "${BOLD}Split Chapters:${RESET} $SPLIT_CHAPTERS"
[[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}Mode:         DRY RUN${RESET}"
echo -e "${BLUE}============================================${RESET}"
echo ""

# ============================================================================
# PROCESS FILES
# ============================================================================

if [[ "$CONTENT_TYPE" == "movie" ]]; then
	# ========================================
	# MOVIE MODE
	# ========================================

	CURRENT_OPERATION="Finding movie file"

    # Find the file to process
    mkv_file=""
    if [[ "$FILE_MODE" == true ]]; then
	    # Use the specified file
	    mkv_file="${SOURCE_FILES[0]}"
    else
	    # Directory mode: find the .mkv file with the longest duration
	    shopt -s nullglob
	    mkv_files=("$SOURCE_DIR"/*.mkv)
	    shopt -u nullglob

	    if [[ ${#mkv_files[@]} -eq 0 ]]; then
		    echo -e "${RED}Error: No .mkv files found in directory${RESET}"
		    exit 1
	    fi

	    max_duration=0
	    max_file=""
	    for file in "${mkv_files[@]}"; do
		    duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
		    duration=${duration//,/}
		    if [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$duration > $max_duration" | bc -l) )); then
			    max_duration="$duration"
			    max_file="$file"
		    fi
	    done

	    if [[ -z "$max_file" ]]; then
		    echo -e "${RED}Error: Could not determine longest .mkv file${RESET}"
		    exit 1
	    fi

	    mkv_file="$max_file"
	    echo -e "${CYAN}Selected longest file: $(basename "$mkv_file") (duration: $max_duration seconds)${RESET}"
    fi

    if [[ -z "$mkv_file" ]]; then
	    echo -e "${RED}Error: No .mkv files found${RESET}"
	    exit 1
    fi

    CURRENT_FILE="$mkv_file"
    CURRENT_OPERATION="Preparing output"

    output_file="${OUTPUT_DIR%/}/${CONTENT_NAME}.mkv"

    if [[ -f "$output_file" && "$OVERWRITE" != "true" ]]; then
	    echo -e "${YELLOW}Output file already exists: $output_file${RESET}"
	    echo "Use --overwrite to replace existing files"
	    exit 0
    fi

    echo -e "${BOLD}Processing:${RESET} $mkv_file"
    echo -e "${BOLD}Output:${RESET} $output_file"

    # Build the ffmpeg command
    ffmpeg_cmd=$(build_ffmpeg_command "$mkv_file" "$output_file")

    if [[ "$DRY_RUN" == true ]]; then
	    echo -e "${YELLOW}[DRY RUN] Would transcode to: $output_file${RESET}"
	    echo ""
	    echo -e "${CYAN}Command that would be executed:${RESET}"
	    echo ""
	    echo "$ffmpeg_cmd"
	    echo ""
	    exit 0
    fi

    CURRENT_OPERATION="Detecting video properties"

    # Detect bit depth and height for informational output
    bit_depth=$(detect_bit_depth "$mkv_file")
    height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$mkv_file")
    height=${height//,/}

    # Determine encoder for informational output
    if [[ "$VIDEO_CODEC" == "auto" ]]; then
	    if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
		    echo "Using libx265 (software) for SD content - ensures correct colors"
	    else
		    echo "Using hevc_vaapi (hardware) for HD content - fast encoding"
	    fi
    fi

    # Determine profile based on bit depth
    if [[ "$bit_depth" == "10" ]]; then
	    detected_profile="main10"
    else
	    detected_profile="main"
    fi

    echo -e "${CYAN}Bit depth: ${bit_depth}-bit, Height: ${height}p, Profile: $detected_profile${RESET}"

    CURRENT_OPERATION="Encoding"

    # Execute the ffmpeg command
    eval $ffmpeg_cmd

    CURRENT_OPERATION=""
    CURRENT_FILE=""

    echo -e "${BOLDGREEN}Complete: $output_file${RESET}"

else
	# ========================================
	# SERIES MODE
	# ========================================

    # Process each season
    for SEASON_NUM in "${SEASONS_TO_PROCESS[@]}"; do
	    echo -e "${BLUE}========================================${RESET}"
	    echo -e "${BOLDBLUE}PROCESSING SEASON $SEASON_NUM${RESET}"
	    echo -e "${BLUE}========================================${RESET}"
	    echo ""

	    episode_files=()

	    if [[ "$FILE_MODE" == true ]]; then
		    # File mode: use specified files directly
		    echo -e "${CYAN}Processing ${#SOURCE_FILES[@]} specified file(s)${RESET}"

		    for source_file in "${SOURCE_FILES[@]}"; do
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
		    chapter_count=$(ffprobe -v quiet -show_chapters "$source_file" 2>/dev/null | grep -c "^\[CHAPTER\]")
		    episode_count=$((chapter_count / chapters_per_ep))
		    echo "  File has $chapter_count chapters - will split into $episode_count episodes"

		    # Add each episode (group of chapters)
		    for ((ep=0; ep<episode_count; ep=ep+1)); do
			    start_chapter=$((ep * chapters_per_ep))
			    end_chapter=$((start_chapter + chapters_per_ep - 1))
			    ep_num=$((ep + 1))
			    # Store: disc_dir|episode_num|source_file|start_chapter|end_chapter
			    episode_files+=("$(dirname "$source_file")|$ep_num|$source_file|$start_chapter|$end_chapter")
		    done
	    else
		    # Regular file - parse episode number from filename
		    ep_num=$(get_episode_num "$(basename "$source_file")")
		    if [[ "$ep_num" != "UNKNOWN" ]]; then
			    # Store with chapter markers as -1 to indicate whole file
			    episode_files+=("$(dirname "$source_file")|$ep_num|$source_file|-1|-1")
		    else
			    # No episode number, use sequential numbering
			    episode_files+=("$(dirname "$source_file")|${#episode_files[@]}|$source_file|-1|-1")
		    fi
		fi
	done
else
	# Directory mode: use existing disc directory logic
	# Find all disc directories for this season
	shopt -s nullglob nocaseglob
	disc_dirs=("$SOURCE_DIR"/[Ss]${SEASON_NUM}[Dd]*)
	shopt -u nullglob nocaseglob

	if [[ ${#disc_dirs[@]} -eq 0 ]]; then
		# No S#D# subdirectories found - check if files are directly in the source directory
		shopt -s nullglob
		direct_mkv_files=("$SOURCE_DIR"/*.mkv)
		shopt -u nullglob

		if [[ ${#direct_mkv_files[@]} -gt 0 ]]; then
			# Files are directly in the source directory (single-disc series)
			echo -e "${CYAN}Processing ${#direct_mkv_files[@]} file(s) directly from source directory${RESET}"
			disc_dirs=("$SOURCE_DIR")
		else
			echo -e "${YELLOW}Warning: No disc directories found for season $SEASON_NUM (S${SEASON_NUM}D*) and no .mkv files in source directory${RESET}"
			echo ""
			continue
		fi
	else
		echo -e "${CYAN}Processing ${#disc_dirs[@]} disc(s)/directory(ies) for season $SEASON_NUM${RESET}"
	fi

	    # Collect episodes
	    for disc_dir in "${disc_dirs[@]}"; do
		    echo "Scanning: $disc_dir"

		    shopt -s nullglob
		    mkv_files=("$disc_dir"/*.mkv)
		    shopt -u nullglob

		    if [[ ${#mkv_files[@]} -eq 0 ]]; then
			    echo -e "${YELLOW}  Warning: No .mkv files found${RESET}"
			    continue
		    fi

		    echo "  Found ${#mkv_files[@]} file(s)"

		    for source_file in "${mkv_files[@]}"; do
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
			chapter_count=$(ffprobe -v quiet -show_chapters "$source_file" 2>/dev/null | grep -c "^\[CHAPTER\]")
			episode_count=$((chapter_count / chapters_per_ep))
			echo "  File has $chapter_count chapters - will split into $episode_count episodes"

			# Add each episode (group of chapters)
			for ((ep=0; ep<episode_count; ep=ep+1)); do
				start_chapter=$((ep * chapters_per_ep))
				end_chapter=$((start_chapter + chapters_per_ep - 1))
				ep_num=$((ep + 1))
				# Store: disc_dir|episode_num|source_file|start_chapter|end_chapter
				episode_files+=("$disc_dir|$ep_num|$source_file|$start_chapter|$end_chapter")
			done
		else
			# Regular file - parse episode number from filename
			ep_num=$(get_episode_num "$(basename "$source_file")")
			if [[ "$ep_num" != "UNKNOWN" ]]; then
				# Store with chapter markers as -1 to indicate whole file
				episode_files+=("$disc_dir|$ep_num|$source_file|-1|-1")
			else
				echo -e "${YELLOW}    Warning: Could not parse episode number from $(basename "$source_file")${RESET}"
			fi
			    fi
		    done
	    done
	    fi

	    if [[ ${#episode_files[@]} -eq 0 ]]; then
		    echo -e "${YELLOW}Warning: No valid episode files found for season $SEASON_NUM${RESET}"
		    echo ""
		    continue
	    fi

	# Sort episodes: first by disc directory, then by episode number within disc
	readarray -t sorted_files < <(
	for line in "${episode_files[@]}"; do
		echo "$line"
	done | sort -t'|' -k1,1 -k2,2n
)

	# Now display with sequential episode numbers
	echo ""
	echo -e "${CYAN}Episode mapping:${RESET}"
	ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
		if [[ "$start_ch" == "-1" ]]; then
			echo "    $(basename "$source_file") -> Episode $ep_index"
		else
			if [[ "$start_ch" == "$end_ch" ]]; then
				echo "    $(basename "$source_file") [Chapter $((start_ch + 1))] -> Episode $ep_index"
			else
				echo "    $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))] -> Episode $ep_index"
			fi
		fi
		ep_index=$((ep_index + 1))
	done

	echo ""
	echo -e "${CYAN}Processing ${#sorted_files[@]} episode(s) for season $SEASON_NUM${RESET}"
	echo ""

	if [[ "$DRY_RUN" == true ]]; then
		ep_index=1
		for sorted_line in "${sorted_files[@]}"; do
			IFS='|' read -r disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
			episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $ep_index)"
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
			ep_index=$((ep_index + 1))
		done
		echo ""

	    # Show command for first episode as an example
	    echo -e "${CYAN}Example command for first episode:${RESET}"
	    IFS='|' read -r disc_path parsed_ep_num source_file start_ch end_ch <<< "${sorted_files[0]}"
	    episode_num="S$(printf "%02d" $SEASON_NUM)E01"
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

	    ffmpeg_cmd=$(build_ffmpeg_command "$source_file" "$output_file" "$input_opts")
	    echo ""
	    echo "$ffmpeg_cmd"
	    echo ""

	    continue
	fi

	# Process episodes
	ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"

	    # Skip if user specified a specific episode and this isn't it
	    if [[ -n "$EPISODE_NUM" ]] && [[ "$ep_index" -ne "$EPISODE_NUM" ]]; then
		    ep_index=$((ep_index + 1))
		    continue
	    fi

	    episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $ep_index)"
	    output_file="${OUTPUT_DIR%/}/${CONTENT_NAME} - ${episode_num}.mkv"

	    if [[ -f "$output_file" && "$OVERWRITE" != "true" ]]; then
		    echo -e "${YELLOW}[$ep_index/${#sorted_files[@]}] Skipping: $(basename "$output_file") (already exists)${RESET}"
		    ep_index=$((ep_index + 1))
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
			ep_index=$((ep_index + 1))
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

	    CURRENT_OPERATION="Detecting video properties"

	    # Detect bit depth and height
	    bit_depth=$(detect_bit_depth "$source_file")
	    height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$source_file")
	    height=${height//,/}

	    # Choose encoder based on resolution
	    actual_codec=""
	    if [[ "$VIDEO_CODEC" == "auto" ]]; then
		    if [[ "$height" =~ ^[0-9]+$ ]] && [[ $height -le 576 ]]; then
			    actual_codec="libx265"
		    else
			    actual_codec="hevc_vaapi"
		    fi
	    else
		    actual_codec="$VIDEO_CODEC"
	    fi

	    # Determine profile based on bit depth
	    if [[ "$bit_depth" == "10" ]]; then
		    detected_profile="main10"
	    else
		    detected_profile="main"
	    fi

	    echo "    Bit depth: ${bit_depth}-bit, Encoder: $actual_codec, Profile: $detected_profile"

	    CURRENT_OPERATION="Analyzing audio and subtitles"

	    # Get audio track info for display
	    preferred_audio_lang=""
	    if [[ "$PREFER_ORIGINAL" == "true" && -n "$ORIGINAL_LANGUAGE" ]]; then
		    preferred_audio_lang="$ORIGINAL_LANGUAGE"
	    fi

	    IFS='|' read -r default_audio_idx default_audio_lang <<< "$(get_audio_track_info "$source_file" "$preferred_audio_lang")"
	    echo -e "${CYAN}    Audio: Track $default_audio_idx ($default_audio_lang) default${RESET}"

	    # Check subtitle disposition
	    sub_default_idx=$(get_subtitle_disposition "$source_file" "$default_audio_lang" "$LANGUAGE")
	    if [[ "$sub_default_idx" != "-1" ]]; then
		    echo -e "${CYAN}    Subs: Track $sub_default_idx ($LANGUAGE) default${RESET}"
	    fi

	    CURRENT_OPERATION="Encoding episode $ep_index"

	    # Build and execute the ffmpeg command
	    ffmpeg_cmd=$(build_ffmpeg_command "$source_file" "$output_file" "$input_opts")
	    eval $ffmpeg_cmd

	    echo "    Complete!"
	    echo ""
	    ep_index=$((ep_index + 1))
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
