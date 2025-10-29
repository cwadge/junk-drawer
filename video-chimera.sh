#!/bin/bash

# Video Chimera - macOS Video Transcoding Script
# Optimized for Apple Silicon and VideoToolbox hardware acceleration
# Supports both single titles (movies) and series with automatic detection
# Usage: video-chimera.sh [options] <source> [output_dir]
#
# Fork of transcode-monster.sh, specialized for macOS
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

SCRIPT_VERSION="0.9.0"
CONFIG_FILE="${HOME}/.config/video-chimera.conf"

# ============================================================================
# DEFAULT SETTINGS (Priority 1: Built-ins)
# ============================================================================

# Hardware acceleration (VideoToolbox)
DEFAULT_VIDEOTOOLBOX_QUALITY="70"  # Quality scale 1-100 (higher = better, opposite of CRF)
                                    # 70-75 for high quality, 65-70 for balanced, 60-65 for space savings
DEFAULT_ALLOW_SOFTWARE_VT="false"  # Allow VideoToolbox to fall back to software encoding
DEFAULT_VIDEOTOOLBOX_REALTIME="false"  # Hint for real-time encoding (e.g., camera capture)

# Video encoding settings
DEFAULT_VIDEO_CODEC="auto"  # Will choose hevc_videotoolbox or libx265 based on resolution/platform
DEFAULT_X265_QUALITY="20.6"  # CRF for software encoding fallback (10-bit optimized)
DEFAULT_PRESET="medium"  # For libx265 (software encoding only)
DEFAULT_X265_POOLS="+"  # Thread pools for libx265: "+" = auto-detect, or specify count
DEFAULT_X265_TUNE=""  # x265 tuning: "" (none), "fastdecode", "grain", "psnr", "ssim", "zerolatency"
DEFAULT_GOP_SIZE="120"
DEFAULT_MIN_KEYINT="12"
DEFAULT_BFRAMES="0"  # B-frames: 0=max compatibility, 1-2=balanced, 3-4=best compression
DEFAULT_REFS="4"

# Process priority
DEFAULT_USE_NICE="true"
DEFAULT_NICE_LEVEL="10"  # 0-19, higher = lower priority
# Note: ionice not available on macOS

# Output options
DEFAULT_OVERWRITE="false"  # Overwrite existing output files
DEFAULT_UPGRADE_8BIT_TO_10BIT="true"  # Upgrade 8-bit sources to 10-bit
DEFAULT_DOWNGRADE_12BIT_TO_10BIT="false"  # Downgrade 12-bit to 10-bit for compatibility
DEFAULT_COLORSPACE="auto"  # Color space: auto, bt709, bt601, or none

# Audio encoding settings
DEFAULT_AUDIO_COPY_FIRST="true"  # Copy first audio track
DEFAULT_AUDIO_CODEC="aac_at"  # Apple AudioToolbox AAC (hardware-accelerated)
DEFAULT_AUDIO_PROFILE="aac_he"  # HE-AAC profile
DEFAULT_AUDIO_BITRATE_MONO="96k"
DEFAULT_AUDIO_BITRATE_STEREO="128k"
DEFAULT_AUDIO_BITRATE_SURROUND="192k"
DEFAULT_AUDIO_BITRATE_SURROUND_PLUS="256k"
DEFAULT_AUDIO_FILTER_LANGUAGES="true"

# Language and subtitle settings
DEFAULT_LANGUAGE="eng"  # ISO 639-2 code(s), comma-separated
DEFAULT_PREFER_ORIGINAL="false"  # Prefer original audio + native subs over dubs
DEFAULT_ORIGINAL_LANGUAGE=""  # Set for original language mode (e.g., "jpn" for anime)

# Processing options
DEFAULT_DETECT_INTERLACING="true"
DEFAULT_ADAPTIVE_DEINTERLACE="false"
DEFAULT_DETECT_CROP="true"
DEFAULT_DETECT_PULLDOWN="auto"  # auto = SD only, true = force on, false = force off
DEFAULT_SPLIT_CHAPTERS="auto"  # auto = series files >60min, true/false = force
DEFAULT_CHAPTERS_PER_EPISODE="auto"  # auto = detect optimal grouping

# Output settings
DEFAULT_OUTPUT_DIR="${HOME}/Movies"
DEFAULT_CONTAINER="matroska"  # mkv
DEFAULT_INPUT_VIDEO_EXTENSIONS="mkv mp4 m4v avi mpg mpeg ts m2ts mov webm flv wmv asf vob ogv"
DEFAULT_FFMPEG_LOGLEVEL="warning"
DEFAULT_FFMPEG_ANALYZEDURATION="120000000"  # 2 minutes
DEFAULT_FFMPEG_PROBESIZE="128000000"  # 128MB

# ============================================================================
# ERROR HANDLING
# ============================================================================

CURRENT_OPERATION=""
CURRENT_FILE=""

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

interrupt_handler() {
	echo ""
	echo -e "${YELLOW}Transcoding interrupted by user${RESET}"
	exit 130
}

trap 'error_handler ${LINENO}' ERR
trap 'interrupt_handler' INT

# ============================================================================
# TERMINAL SETUP
# ============================================================================

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
# PLATFORM DETECTION
# ============================================================================

detect_platform() {
	if [[ "$OSTYPE" == "darwin"* ]]; then
		echo "macos"
	else
		echo "unsupported"
	fi
}

PLATFORM=$(detect_platform)

if [[ "$PLATFORM" != "macos" ]]; then
	echo -e "${RED}Error: Video Chimera is designed for macOS only.${RESET}"
	echo "For Linux, please use transcode-monster.sh instead."
	exit 1
fi

# Detect Apple Silicon vs Intel
detect_chip_type() {
	local arch=$(uname -m)
	if [[ "$arch" == "arm64" ]]; then
		echo "apple_silicon"
	else
		echo "intel"
	fi
}

CHIP_TYPE=$(detect_chip_type)

# Detect specific Apple Silicon chip if possible
detect_chip_generation() {
	if [[ "$CHIP_TYPE" == "apple_silicon" ]]; then
		local chip_info=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
		if [[ "$chip_info" == *"M1"* ]]; then
			echo "M1"
		elif [[ "$chip_info" == *"M2"* ]]; then
			echo "M2"
		elif [[ "$chip_info" == *"M3"* ]]; then
			echo "M3"
		elif [[ "$chip_info" == *"M4"* ]]; then
			echo "M4"
		else
			echo "unknown"
		fi
	else
		echo "intel"
	fi
}

CHIP_GENERATION=$(detect_chip_generation)

# ============================================================================
# LOAD USER CONFIG (Priority 2: User .conf)
# ============================================================================

if [[ -f "$CONFIG_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
fi

# Apply config values
VIDEOTOOLBOX_QUALITY="${VIDEOTOOLBOX_QUALITY:-$DEFAULT_VIDEOTOOLBOX_QUALITY}"
ALLOW_SOFTWARE_VT="${ALLOW_SOFTWARE_VT:-$DEFAULT_ALLOW_SOFTWARE_VT}"
VIDEOTOOLBOX_REALTIME="${VIDEOTOOLBOX_REALTIME:-$DEFAULT_VIDEOTOOLBOX_REALTIME}"

VIDEO_CODEC="${VIDEO_CODEC:-$DEFAULT_VIDEO_CODEC}"
X265_QUALITY="${X265_QUALITY:-$DEFAULT_X265_QUALITY}"
PRESET="${PRESET:-$DEFAULT_PRESET}"
X265_POOLS="${X265_POOLS:-$DEFAULT_X265_POOLS}"
X265_TUNE="${X265_TUNE:-$DEFAULT_X265_TUNE}"
GOP_SIZE="${GOP_SIZE:-$DEFAULT_GOP_SIZE}"
MIN_KEYINT="${MIN_KEYINT:-$DEFAULT_MIN_KEYINT}"
BFRAMES="${BFRAMES:-$DEFAULT_BFRAMES}"
REFS="${REFS:-$DEFAULT_REFS}"

USE_NICE="${USE_NICE:-$DEFAULT_USE_NICE}"
NICE_LEVEL="${NICE_LEVEL:-$DEFAULT_NICE_LEVEL}"

OVERWRITE="${OVERWRITE:-$DEFAULT_OVERWRITE}"
UPGRADE_8BIT_TO_10BIT="${UPGRADE_8BIT_TO_10BIT:-$DEFAULT_UPGRADE_8BIT_TO_10BIT}"
DOWNGRADE_12BIT_TO_10BIT="${DOWNGRADE_12BIT_TO_10BIT:-$DEFAULT_DOWNGRADE_12BIT_TO_10BIT}"
COLORSPACE="${COLORSPACE:-$DEFAULT_COLORSPACE}"

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
INPUT_VIDEO_EXTENSIONS="${INPUT_VIDEO_EXTENSIONS:-$DEFAULT_INPUT_VIDEO_EXTENSIONS}"
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-$DEFAULT_FFMPEG_LOGLEVEL}"
FFMPEG_ANALYZEDURATION="${FFMPEG_ANALYZEDURATION:-$DEFAULT_FFMPEG_ANALYZEDURATION}"
FFMPEG_PROBESIZE="${FFMPEG_PROBESIZE:-$DEFAULT_FFMPEG_PROBESIZE}"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

SEASON_NUM=""
EPISODE_NUM=""
CONTENT_NAME=""
DRY_RUN=false

usage() {
	cat << EOF
${BOLD}Video Chimera v${SCRIPT_VERSION} - macOS Video Transcoding${RESET}
Optimized for Apple Silicon and VideoToolbox hardware acceleration

${BOLD}Usage:${RESET}
  $(basename "$0") [options] <source> [output_dir]

${BOLD}Arguments:${RESET}
  source        Source video file or directory
  output_dir    Output directory (default: $DEFAULT_OUTPUT_DIR)

${BOLD}Mode Selection:${RESET}
  -s, --season NUM          Process as season NUM of a series
  -e, --episode NUM         Process specific episode (requires -s)
  -n, --name "NAME"         Content name for series
  --dry-run                 Show what would be done without encoding

${BOLD}VideoToolbox Options:${RESET}
  --vt-quality NUM          Quality 1-100 (higher=better, default: $DEFAULT_VIDEOTOOLBOX_QUALITY)
  --allow-sw-vt            Allow VideoToolbox software fallback
  --vt-realtime            Enable real-time encoding hint

${BOLD}Video Options:${RESET}
  --codec CODEC            Video codec: auto, hevc_videotoolbox, libx265
  --x265-quality NUM       CRF for software encoding (default: $DEFAULT_X265_QUALITY)
  --8bit                   Force 8-bit output
  --10bit                  Force 10-bit output (upgrade 8-bit sources)
  --12bit                  Allow 12-bit output
  --colorspace SPACE       Color space: auto, bt709, bt601, none

${BOLD}Audio Options:${RESET}
  --audio-codec CODEC      Audio codec (default: $DEFAULT_AUDIO_CODEC)
  --audio-copy-first       Copy first audio track (default)
  --audio-transcode-all    Transcode all audio tracks

${BOLD}Processing Options:${RESET}
  --no-interlace-detect    Disable interlacing detection
  --adaptive-deinterlace   Force adaptive deinterlacing
  --no-crop-detect         Disable crop detection
  --split-chapters         Force chapter splitting for series
  --no-split-chapters      Disable chapter splitting

${BOLD}Output Options:${RESET}
  --overwrite              Overwrite existing files
  --language LANG          Language code (default: $DEFAULT_LANGUAGE)

${BOLD}System Information:${RESET}
  Detected Platform: macOS ($CHIP_TYPE)
  Chip Generation: $CHIP_GENERATION
  Config File: $CONFIG_FILE

${BOLD}Examples:${RESET}
  # Transcode a single movie
  $(basename "$0") "Movie.mkv"

  # Transcode a TV series season
  $(basename "$0") -s 1 -n "Show Name" "/path/to/discs"

  # Use custom VideoToolbox quality
  $(basename "$0") --vt-quality 75 "Movie.mkv"

  # Force software encoding with x265
  $(basename "$0") --codec libx265 "Movie.mkv"

EOF
	exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		-h|--help)
			usage
			;;
		-s|--season)
			SEASON_NUM="$2"
			shift 2
			;;
		-e|--episode)
			EPISODE_NUM="$2"
			shift 2
			;;
		-n|--name)
			CONTENT_NAME="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--vt-quality)
			VIDEOTOOLBOX_QUALITY="$2"
			shift 2
			;;
		--allow-sw-vt)
			ALLOW_SOFTWARE_VT="true"
			shift
			;;
		--vt-realtime)
			VIDEOTOOLBOX_REALTIME="true"
			shift
			;;
		--codec)
			VIDEO_CODEC="$2"
			shift 2
			;;
		--x265-quality)
			X265_QUALITY="$2"
			shift 2
			;;
		--8bit)
			UPGRADE_8BIT_TO_10BIT="false"
			DOWNGRADE_12BIT_TO_10BIT="true"
			shift
			;;
		--10bit)
			UPGRADE_8BIT_TO_10BIT="true"
			DOWNGRADE_12BIT_TO_10BIT="true"
			shift
			;;
		--12bit)
			DOWNGRADE_12BIT_TO_10BIT="false"
			shift
			;;
		--colorspace)
			COLORSPACE="$2"
			shift 2
			;;
		--audio-codec)
			AUDIO_CODEC="$2"
			shift 2
			;;
		--audio-copy-first)
			AUDIO_COPY_FIRST="true"
			shift
			;;
		--audio-transcode-all)
			AUDIO_COPY_FIRST="false"
			shift
			;;
		--no-interlace-detect)
			DETECT_INTERLACING="false"
			shift
			;;
		--adaptive-deinterlace)
			ADAPTIVE_DEINTERLACE="true"
			shift
			;;
		--no-crop-detect)
			DETECT_CROP="false"
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
		--overwrite)
			OVERWRITE="true"
			shift
			;;
		--language)
			LANGUAGE="$2"
			shift 2
			;;
		*)
			# Positional arguments
			if [[ -z "${SOURCE:-}" ]]; then
				SOURCE="$1"
			elif [[ -z "${OUTPUT_DIR:-}" ]]; then
				OUTPUT_DIR="$1"
			else
				echo "Error: Unknown argument '$1'"
				exit 1
			fi
			shift
			;;
	esac
done

# Validate required arguments
if [[ -z "${SOURCE:-}" ]]; then
	echo "Error: Source file or directory required"
	usage
fi

if [[ ! -e "$SOURCE" ]]; then
	echo "Error: Source '$SOURCE' does not exist"
	exit 1
fi

# Set default output dir if not specified
if [[ -z "${OUTPUT_DIR:-}" ]]; then
	OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
fi

# ============================================================================
# DEPENDENCY CHECKS
# ============================================================================

check_dependencies() {
	local missing_deps=()

	if ! command -v ffmpeg &> /dev/null; then
		missing_deps+=("ffmpeg")
	fi

	if ! command -v ffprobe &> /dev/null; then
		missing_deps+=("ffprobe")
	fi

	if ! command -v bc &> /dev/null; then
		missing_deps+=("bc")
	fi

	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		echo -e "${RED}Error: Missing required dependencies:${RESET}"
		for dep in "${missing_deps[@]}"; do
			echo "  - $dep"
		done
		echo ""
		echo "Install via Homebrew:"
		echo "  brew install ffmpeg bc"
		exit 1
	fi

	# Check for VideoToolbox support in ffmpeg
	if ! ffmpeg -encoders 2>/dev/null | grep -q hevc_videotoolbox; then
		echo -e "${YELLOW}Warning: hevc_videotoolbox not found in ffmpeg build${RESET}"
		echo "VideoToolbox hardware encoding may not be available"
		echo "Consider reinstalling ffmpeg: brew reinstall ffmpeg"
		echo ""
	fi

	# Check for Apple AudioToolbox AAC
	if ! ffmpeg -encoders 2>/dev/null | grep -q aac_at; then
		echo -e "${YELLOW}Warning: aac_at (AudioToolbox) not found, falling back to libfdk_aac${RESET}"
		if [[ "$AUDIO_CODEC" == "aac_at" ]]; then
			AUDIO_CODEC="libfdk_aac"
		fi
	fi
}

check_dependencies

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Detect bit depth of video
detect_bit_depth() {
	local file="$1"
	local bit_depth=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$file")
	
	if [[ -z "$bit_depth" ]] || [[ "$bit_depth" == "N/A" ]]; then
		bit_depth=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$file")
		case "$bit_depth" in
			*"10"*|*"p010"*|*"p210"*|*"p410"*)
				echo "10"
				;;
			*"12"*|*"p012"*|*"p212"*|*"p412"*)
				echo "12"
				;;
			*)
				echo "8"
				;;
		esac
	else
		echo "$bit_depth"
	fi
}

# Determine encoder to use based on content and platform
should_use_software_encoder() {
	local file="$1"
	local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$file")
	local bit_depth=$(detect_bit_depth "$file")
	
	# For Apple Silicon, VideoToolbox handles most content well
	if [[ "$CHIP_TYPE" == "apple_silicon" ]]; then
		# M1/M2/M3 can handle 4K 10-bit well
		if [[ "$bit_depth" == "12" ]]; then
			# 12-bit requires software encoding
			echo "libx265"
		else
			echo "hevc_videotoolbox"
		fi
	else
		# Intel Macs: Use VideoToolbox for SD/HD, software for 4K+
		if [[ "$height" -ge 2160 ]]; then
			echo "libx265"
		else
			echo "hevc_videotoolbox"
		fi
	fi
}

# Get chapter times for chapter-based splitting
get_chapter_times() {
	local file="$1"
	ffprobe -v quiet -print_format json -show_chapters "$file" | \
		grep -o '"start_time": *"[^"]*"' | \
		cut -d'"' -f4
}

# Get audio track info
get_audio_track_info() {
	local file="$1"
	local preferred_lang="${2:-}"
	
	# Get first audio track by default
	local default_idx=0
	local default_lang=$(ffprobe -v quiet -select_streams a:0 -show_entries stream_tags=language -of csv=p=0 "$file")
	
	if [[ -n "$preferred_lang" ]]; then
		# Try to find preferred language
		local pref_idx=$(ffprobe -v quiet -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$file" | \
			grep -i "$preferred_lang" | head -1 | cut -d',' -f1)
		if [[ -n "$pref_idx" ]]; then
			default_idx=$pref_idx
			default_lang=$preferred_lang
		fi
	fi
	
	echo "${default_idx}|${default_lang}"
}

# Get subtitle disposition
get_subtitle_disposition() {
	local file="$1"
	local audio_lang="$2"
	local user_lang="$3"
	
	# Try to find matching subtitle
	local sub_idx=$(ffprobe -v quiet -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 "$file" | \
		grep -i "$user_lang" | head -1 | cut -d',' -f1)
	
	if [[ -n "$sub_idx" ]]; then
		echo "$sub_idx"
	else
		echo "-1"
	fi
}

# Detect interlacing
is_interlaced() {
	local file="$1"
	local frames_to_check=100
	
	local interlaced=$(ffmpeg -i "$file" -vf idet -frames:v $frames_to_check -an -f null - 2>&1 | \
		grep "Multi frame detection" | \
		awk '{if ($7 > $5 * 0.1) print "true"; else print "false"}')
	
	[[ "$interlaced" == "true" ]]
}

# Detect crop
detect_crop_params() {
	local file="$1"
	local duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file")
	local sample_duration=2
	local num_samples=5
	
	# Sample from different points in the video
	local crops=()
	for i in $(seq 1 $num_samples); do
		local timestamp=$(echo "$duration * $i / ($num_samples + 1)" | bc)
		local crop=$(ffmpeg -ss "$timestamp" -i "$file" -t $sample_duration -vf cropdetect -f null - 2>&1 | \
			grep -o 'crop=[0-9]*:[0-9]*:[0-9]*:[0-9]*' | tail -1)
		if [[ -n "$crop" ]]; then
			crops+=("$crop")
		fi
	done
	
	# Return most conservative crop
	if [[ ${#crops[@]} -gt 0 ]]; then
		echo "${crops[0]}"
	else
		echo ""
	fi
}

# ============================================================================
# MAIN ENCODING FUNCTION
# ============================================================================

build_ffmpeg_command() {
	local input_file="$1"
	local output_file="$2"
	local input_opts="${3:-}"
	
	local cmd=""
	
	# Add nice if enabled
	if [[ "$USE_NICE" == "true" ]]; then
		cmd="nice -n $NICE_LEVEL "
	fi
	
	cmd+="ffmpeg -hide_banner"
	cmd+=" -loglevel $FFMPEG_LOGLEVEL"
	cmd+=" -analyzeduration $FFMPEG_ANALYZEDURATION"
	cmd+=" -probesize $FFMPEG_PROBESIZE"
	
	# Input options (for chapter extraction, etc.)
	if [[ -n "$input_opts" ]]; then
		cmd+=" $input_opts"
	fi
	
	cmd+=" -i \"$input_file\""
	
	# Detect video properties
	local bit_depth=$(detect_bit_depth "$input_file")
	local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_file")
	
	# Adjust bit depth based on user preferences
	if [[ "$DOWNGRADE_12BIT_TO_10BIT" == "true" && "$bit_depth" == "12" ]]; then
		bit_depth="10"
	fi
	if [[ "$UPGRADE_8BIT_TO_10BIT" == "true" && "$bit_depth" == "8" ]]; then
		bit_depth="10"
	fi
	
	# Choose encoder
	local actual_codec=""
	if [[ "$VIDEO_CODEC" == "auto" ]]; then
		actual_codec=$(should_use_software_encoder "$input_file")
	else
		actual_codec="$VIDEO_CODEC"
	fi
	
	# Video filters
	local vf_filters=()
	
	# Crop detection
	if [[ "$DETECT_CROP" == "true" ]]; then
		local crop_params=$(detect_crop_params "$input_file")
		if [[ -n "$crop_params" && "$crop_params" != *":0:0"* ]]; then
			vf_filters+=("$crop_params")
		fi
	fi
	
	# Interlace detection and deinterlacing
	if [[ "$DETECT_INTERLACING" == "true" ]] || [[ "$ADAPTIVE_DEINTERLACE" == "true" ]]; then
		if [[ "$ADAPTIVE_DEINTERLACE" == "true" ]] || is_interlaced "$input_file"; then
			vf_filters+=("yadif=1")
		fi
	fi
	
	# Pulldown detection for SD content
	local should_detect_pulldown=false
	if [[ "$DETECT_PULLDOWN" == "auto" ]]; then
		if [[ "$height" -le 576 ]]; then
			should_detect_pulldown=true
		fi
	elif [[ "$DETECT_PULLDOWN" == "true" ]]; then
		should_detect_pulldown=true
	fi
	
	if [[ "$should_detect_pulldown" == "true" ]]; then
		vf_filters+=("pullup")
	fi
	
	# Color space conversion
	if [[ "$COLORSPACE" != "none" ]]; then
		local target_space="$COLORSPACE"
		if [[ "$target_space" == "auto" ]]; then
			if [[ "$height" -ge 720 ]]; then
				target_space="bt709"
			else
				target_space="bt601"
			fi
		fi
		vf_filters+=("colorspace=${target_space}")
	fi
	
	# Pixel format based on encoder and bit depth
	local pix_fmt=""
	if [[ "$actual_codec" == "hevc_videotoolbox" ]]; then
		if [[ "$bit_depth" == "10" ]]; then
			pix_fmt="p010le"  # VideoToolbox 10-bit format
			vf_filters+=("format=p010le")
		else
			pix_fmt="nv12"
		fi
	else
		# libx265
		if [[ "$bit_depth" == "12" ]]; then
			pix_fmt="yuv420p12le"
		elif [[ "$bit_depth" == "10" ]]; then
			pix_fmt="yuv420p10le"
		else
			pix_fmt="yuv420p"
		fi
	fi
	
	# Apply video filters
	if [[ ${#vf_filters[@]} -gt 0 ]]; then
		local filter_string=$(IFS=,; echo "${vf_filters[*]}")
		cmd+=" -vf \"$filter_string\""
	fi
	
	# Video encoding options
	cmd+=" -c:v $actual_codec"
	
	if [[ "$actual_codec" == "hevc_videotoolbox" ]]; then
		# VideoToolbox-specific options
		cmd+=" -q:v $VIDEOTOOLBOX_QUALITY"
		
		if [[ "$bit_depth" == "10" ]]; then
			cmd+=" -profile:v main10"
		else
			cmd+=" -profile:v main"
		fi
		
		if [[ "$ALLOW_SOFTWARE_VT" == "true" ]]; then
			cmd+=" -allow_sw 1"
		fi
		
		if [[ "$VIDEOTOOLBOX_REALTIME" == "true" ]]; then
			cmd+=" -realtime 1"
		fi
		
		# VideoToolbox GOP settings
		cmd+=" -g $GOP_SIZE"
		
	else
		# libx265 software encoding
		cmd+=" -preset $PRESET"
		cmd+=" -crf $X265_QUALITY"
		
		local profile=""
		if [[ "$bit_depth" == "12" ]]; then
			profile="main12"
		elif [[ "$bit_depth" == "10" ]]; then
			profile="main10"
		else
			profile="main"
		fi
		
		local x265_params="profile=$profile"
		x265_params+=":keyint=$GOP_SIZE"
		x265_params+=":min-keyint=$MIN_KEYINT"
		x265_params+=":bframes=$BFRAMES"
		x265_params+=":ref=$REFS"
		
		if [[ "$X265_POOLS" != "+" ]]; then
			x265_params+=":pools=$X265_POOLS"
		fi
		
		if [[ -n "$X265_TUNE" ]]; then
			x265_params+=":tune=$X265_TUNE"
		fi
		
		cmd+=" -x265-params \"$x265_params\""
	fi
	
	# Audio encoding
	local audio_tracks=$(ffprobe -v quiet -select_streams a -show_entries stream=index -of csv=p=0 "$input_file" | wc -l)
	
	if [[ "$AUDIO_COPY_FIRST" == "true" && "$audio_tracks" -gt 0 ]]; then
		# Copy first track
		cmd+=" -c:a:0 copy"
		
		# Transcode additional tracks
		if [[ "$audio_tracks" -gt 1 ]]; then
			for (( i=1; i<$audio_tracks; i++ )); do
				local channels=$(ffprobe -v quiet -select_streams a:$i -show_entries stream=channels -of csv=p=0 "$input_file")
				local bitrate=""
				
				if [[ "$channels" -eq 1 ]]; then
					bitrate="$AUDIO_BITRATE_MONO"
				elif [[ "$channels" -eq 2 ]]; then
					bitrate="$AUDIO_BITRATE_STEREO"
				elif [[ "$channels" -le 6 ]]; then
					bitrate="$AUDIO_BITRATE_SURROUND"
				else
					bitrate="$AUDIO_BITRATE_SURROUND_PLUS"
				fi
				
				cmd+=" -c:a:$i $AUDIO_CODEC"
				cmd+=" -b:a:$i $bitrate"
				
				if [[ "$AUDIO_CODEC" == "aac_at" ]] || [[ "$AUDIO_CODEC" == "libfdk_aac" ]]; then
					cmd+=" -profile:a:$i $AUDIO_PROFILE"
				fi
			done
		fi
	else
		# Transcode all audio tracks
		cmd+=" -c:a $AUDIO_CODEC"
		
		if [[ "$AUDIO_CODEC" == "aac_at" ]] || [[ "$AUDIO_CODEC" == "libfdk_aac" ]]; then
			cmd+=" -profile:a $AUDIO_PROFILE"
		fi
	fi
	
	# Copy subtitles
	cmd+=" -c:s copy"
	
	# Map all streams
	cmd+=" -map 0:v"
	cmd+=" -map 0:a"
	cmd+=" -map 0:s?"
	
	# Language filtering
	if [[ "$AUDIO_FILTER_LANGUAGES" == "true" && -n "$LANGUAGE" ]]; then
		IFS=',' read -ra langs <<< "$LANGUAGE"
		local lang_filter=""
		for lang in "${langs[@]}"; do
			if [[ -n "$lang_filter" ]]; then
				lang_filter+="|"
			fi
			lang_filter+="$lang"
		done
		cmd+=" -metadata:s:a language=$lang_filter"
		cmd+=" -metadata:s:s language=$lang_filter"
	fi
	
	# Output file
	cmd+=" \"$output_file\""
	
	if [[ "$OVERWRITE" == "true" ]]; then
		cmd+=" -y"
	else
		cmd+=" -n"
	fi
	
	echo "$cmd"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

echo -e "${BOLDGREEN}Video Chimera v${SCRIPT_VERSION}${RESET}"
echo -e "${CYAN}macOS Video Transcoding (VideoToolbox Optimized)${RESET}"
echo ""
echo "Platform: macOS ($CHIP_TYPE - $CHIP_GENERATION)"
echo "Source: $SOURCE"
echo "Output: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Single file mode
if [[ -f "$SOURCE" ]]; then
	echo -e "${CYAN}Processing single file...${RESET}"
	
	# Determine output filename
	local basename=$(basename "$SOURCE")
	local filename="${basename%.*}"
	local output_file="${OUTPUT_DIR%/}/${filename}.mkv"
	
	if [[ -f "$output_file" && "$OVERWRITE" != "true" ]]; then
		echo -e "${YELLOW}Output file already exists: $output_file${RESET}"
		echo "Use --overwrite to replace it"
		exit 0
	fi
	
	CURRENT_FILE="$SOURCE"
	CURRENT_OPERATION="Analyzing video"
	
	# Detect properties
	local bit_depth=$(detect_bit_depth "$SOURCE")
	local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SOURCE")
	
	# Adjust bit depth
	if [[ "$DOWNGRADE_12BIT_TO_10BIT" == "true" && "$bit_depth" == "12" ]]; then
		bit_depth="10"
	fi
	if [[ "$UPGRADE_8BIT_TO_10BIT" == "true" && "$bit_depth" == "8" ]]; then
		bit_depth="10"
	fi
	
	# Choose encoder
	local actual_codec=""
	if [[ "$VIDEO_CODEC" == "auto" ]]; then
		actual_codec=$(should_use_software_encoder "$SOURCE")
	else
		actual_codec="$VIDEO_CODEC"
	fi
	
	local profile=""
	if [[ "$bit_depth" == "12" ]]; then
		profile="main12"
	elif [[ "$bit_depth" == "10" ]]; then
		profile="main10"
	else
		profile="main"
	fi
	
	echo "Resolution: ${height}p"
	echo "Bit depth: ${bit_depth}-bit"
	echo "Encoder: $actual_codec"
	echo "Profile: $profile"
	echo ""
	
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}[DRY RUN] Would transcode: $(basename "$SOURCE") -> $(basename "$output_file")${RESET}"
		echo ""
		echo -e "${CYAN}Command:${RESET}"
		ffmpeg_cmd=$(build_ffmpeg_command "$SOURCE" "$output_file" "")
		echo "$ffmpeg_cmd"
		echo ""
		exit 0
	fi
	
	CURRENT_OPERATION="Encoding video"
	
	echo -e "${BOLD}Transcoding...${RESET}"
	ffmpeg_cmd=$(build_ffmpeg_command "$SOURCE" "$output_file" "")
	eval $ffmpeg_cmd
	
	echo ""
	echo -e "${GREEN}Complete!${RESET}"
	echo "Output: $output_file"
	echo ""
	
	exit 0
fi

# Series/directory mode  
if [[ -d "$SOURCE" ]]; then
	if [[ -z "$SEASON_NUM" ]]; then
		echo -e "${RED}Error: --season required for directory/series mode${RESET}"
		exit 1
	fi
	
	if [[ -z "$CONTENT_NAME" ]]; then
		echo -e "${RED}Error: --name required for directory/series mode${RESET}"
		exit 1
	fi
	
	echo -e "${CYAN}Processing series: $CONTENT_NAME - Season $SEASON_NUM${RESET}"
	echo ""
	
	# Find all video files
	local video_files=()
	while IFS= read -r -d '' file; do
		video_files+=("$file")
	done < <(find "$SOURCE" -type f \( $(printf -- "-iname *.%s -o " $INPUT_VIDEO_EXTENSIONS | sed 's/ -o $//') \) -print0 | sort -z)
	
	if [[ ${#video_files[@]} -eq 0 ]]; then
		echo -e "${RED}Error: No video files found in $SOURCE${RESET}"
		exit 1
	fi
	
	echo "Found ${#video_files[@]} video file(s)"
	echo ""
	
	# Check if we need chapter splitting
	local use_chapters=false
	if [[ "$SPLIT_CHAPTERS" == "auto" ]]; then
		# Check if files are long enough to warrant chapter splitting
		for file in "${video_files[@]}"; do
			local duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file")
			duration=${duration%.*}  # Remove decimals
			if [[ "$duration" -gt 3600 ]]; then  # > 60 minutes
				use_chapters=true
				break
			fi
		done
	elif [[ "$SPLIT_CHAPTERS" == "true" ]]; then
		use_chapters=true
	fi
	
	if [[ "$use_chapters" == true ]]; then
		echo -e "${CYAN}Using chapter-based episode detection${RESET}"
		echo ""
		
		# Build episode list from chapters
		declare -a sorted_files=()
		local disc_num=1
		
		for file in "${video_files[@]}"; do
			local chapter_count=$(ffprobe -v quiet -print_format json -show_chapters "$file" | grep -c '"id"')
			
			if [[ "$chapter_count" -eq 0 ]]; then
				# No chapters, treat as single episode
				sorted_files+=("${disc_num}|${file}|1|${file}|-1|-1")
				disc_num=$((disc_num + 1))
				continue
			fi
			
			# Determine chapters per episode
			local cpe="$CHAPTERS_PER_EPISODE"
			if [[ "$cpe" == "auto" ]]; then
				# Try to detect optimal grouping
				# Common patterns: 2 chapters/episode (OP+EP), 3 (OP+EP+ED), 1 (just EP)
				if [[ $((chapter_count % 2)) -eq 0 ]]; then
					cpe=2
				elif [[ $((chapter_count % 3)) -eq 0 ]]; then
					cpe=3
				else
					cpe=1
				fi
			fi
			
			# Group chapters into episodes
			local ch_idx=0
			local ep_on_disc=1
			while [[ $ch_idx -lt $chapter_count ]]; do
				local end_ch=$((ch_idx + cpe - 1))
				if [[ $end_ch -ge $chapter_count ]]; then
					end_ch=$((chapter_count - 1))
				fi
				
				sorted_files+=("${disc_num}|${file}|${ep_on_disc}|${file}|${ch_idx}|${end_ch}")
				
				ch_idx=$((end_ch + 1))
				ep_on_disc=$((ep_on_disc + 1))
			done
			
			disc_num=$((disc_num + 1))
		done
		
	else
		echo -e "${CYAN}Using file-based episode detection${RESET}"
		echo ""
		
		# One episode per file
		declare -a sorted_files=()
		local ep_num=1
		
		for file in "${video_files[@]}"; do
			sorted_files+=("${ep_num}|${file}|${ep_num}|${file}|-1|-1")
			ep_num=$((ep_num + 1))
		done
	fi
	
	# Show episode mapping
	echo -e "${CYAN}Episode mapping:${RESET}"
	local ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
		
		if [[ -n "$EPISODE_NUM" ]] && [[ "$ep_index" -ne "$EPISODE_NUM" ]]; then
			ep_index=$((ep_index + 1))
			continue
		fi
		
		if [[ "$start_ch" == "-1" ]]; then
			echo "  Episode $ep_index: $(basename "$source_file")"
		else
			if [[ "$start_ch" == "$end_ch" ]]; then
				echo "  Episode $ep_index: $(basename "$source_file") [Chapter $((start_ch + 1))]"
			else
				echo "  Episode $ep_index: $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))]"
			fi
		fi
		ep_index=$((ep_index + 1))
	done
	
	echo ""
	
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}[DRY RUN MODE]${RESET}"
		echo ""
		
		ep_index=1
		for sorted_line in "${sorted_files[@]}"; do
			IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
			
			if [[ -n "$EPISODE_NUM" ]] && [[ "$ep_index" -ne "$EPISODE_NUM" ]]; then
				ep_index=$((ep_index + 1))
				continue
			fi
			
			episode_num="S$(printf "%02d" $SEASON_NUM)E$(printf "%02d" $ep_index)"
			output_file="${OUTPUT_DIR%/}/${CONTENT_NAME} - ${episode_num}.mkv"
			
			if [[ "$start_ch" == "-1" ]]; then
				echo -e "${YELLOW}Would transcode: $(basename "$source_file") -> $(basename "$output_file")${RESET}"
			else
				if [[ "$start_ch" == "$end_ch" ]]; then
					echo -e "${YELLOW}Would transcode: $(basename "$source_file") [Chapter $((start_ch + 1))] -> $(basename "$output_file")${RESET}"
				else
					echo -e "${YELLOW}Would transcode: $(basename "$source_file") [Chapters $((start_ch + 1))-$((end_ch + 1))] -> $(basename "$output_file")${RESET}"
				fi
			fi
			ep_index=$((ep_index + 1))
		done
		
		echo ""
		echo -e "${CYAN}Example command for first episode:${RESET}"
		IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "${sorted_files[0]}"
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
		
		exit 0
	fi
	
	# Process episodes
	echo -e "${CYAN}Processing ${#sorted_files[@]} episode(s)...${RESET}"
	echo ""
	
	ep_index=1
	for sorted_line in "${sorted_files[@]}"; do
		IFS='|' read -r disc_num disc_path parsed_ep_num source_file start_ch end_ch <<< "$sorted_line"
		
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
		echo "  Output: $(basename "$output_file")"
		
		CURRENT_FILE="$source_file"
		CURRENT_OPERATION="Building chapter extraction parameters"
		
		# Build input options for chapter extraction
		input_opts=""
		if [[ "$start_ch" != "-1" ]]; then
			readarray -t chapter_times < <(get_chapter_times "$source_file")
			start_time="${chapter_times[$start_ch]}"
			start_time=$(echo "$start_time" | tr -d '[:space:]')
			
			if ! [[ "$start_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
				echo "  ERROR: Invalid chapter start time: $start_time"
				ep_index=$((ep_index + 1))
				continue
			fi
			
			end_time=""
			if [[ $((end_ch + 1)) -lt ${#chapter_times[@]} ]]; then
				end_time="${chapter_times[$((end_ch + 1))]}"
				end_time=$(echo "$end_time" | tr -d '[:space:]')
			fi
			
			input_opts="-ss $start_time"
			if [[ -n "$end_time" ]] && [[ "$end_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
				duration=$(echo "$end_time - $start_time" | bc)
				input_opts="$input_opts -t $duration"
				echo "  Extracting chapters: start=${start_time}s, duration=${duration}s"
			else
				echo "  Extracting chapters: start=${start_time}s, duration=remainder"
			fi
		fi
		
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
		
		echo "  Bit depth: ${bit_depth}-bit, Encoder: $actual_codec, Profile: $detected_profile"
		
		CURRENT_OPERATION="Analyzing audio and subtitles"
		
		# Get audio track info for display
		preferred_audio_lang=""
		if [[ "$PREFER_ORIGINAL" == "true" && -n "$ORIGINAL_LANGUAGE" ]]; then
			preferred_audio_lang="$ORIGINAL_LANGUAGE"
		fi
		
		IFS='|' read -r default_audio_idx default_audio_lang <<< "$(get_audio_track_info "$source_file" "$preferred_audio_lang")"
		echo -e "${CYAN}  Audio: Track $default_audio_idx ($default_audio_lang) default${RESET}"
		
		# Check subtitle disposition
		sub_default_idx=$(get_subtitle_disposition "$source_file" "$default_audio_lang" "$LANGUAGE")
		if [[ "$sub_default_idx" != "-1" ]]; then
			echo -e "${CYAN}  Subs: Track $sub_default_idx ($LANGUAGE) default${RESET}"
		fi
		
		CURRENT_OPERATION="Encoding episode $ep_index"
		
		# Build and execute the ffmpeg command
		ffmpeg_cmd=$(build_ffmpeg_command "$source_file" "$output_file" "$input_opts")
		eval $ffmpeg_cmd
		
		echo "  Complete!"
		echo ""
		ep_index=$((ep_index + 1))
	done
	
	echo -e "${GREEN}Season $SEASON_NUM complete!${RESET}"
	echo ""
	exit 0
fi

echo -e "${RED}Error: Source must be a file or directory${RESET}"
exit 1
