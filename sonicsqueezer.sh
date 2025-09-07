#!/bin/bash

# sonicsqueezer.sh
# A multi-threaded audio converter for WAV and FLAC to MP3, AAC, OGG, WMA, FLAC, Opus, or ALAC
# Based on the original scripts `mp3-o-matic` and `flac-distiller` by Chris Wadge, 2010
# Consolidated and updated, 2025
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

PROGRAM_NAME="sonicsqueezer.sh"
PROGRAM_DATE="09/07/2025"
CONFIG_FILE="$HOME/.config/sonicsqueezer.conf"

# ANSI color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

## Default Configuration Variables ##
FFMPEG_PATH="/usr/bin/ffmpeg"
FLACDECODER="/usr/bin/flac"
METAFLAC="/usr/bin/metaflac"
PROCNICE="10" # Nice priority (19 to -20, 19 lowest)
OUTPUT_FORMAT="mp3" # Options: mp3, aac, ogg, wma, flac, opus, alac
QUALITY_OPTS="-c:a mp3 -q:a 0" # Default for mp3; overridden for other formats
NORMALIZE="false"
COPYMETA="true"
DELETE_ORIGINAL="false"
OUTPUT_DIR="" # Empty means same directory as input files
RENAME_METADATA="false" # Rename output files using metadata (tracknumber-title.extension)
THREADMAX=""
SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL_FILES=0
SKIPPED_FILES=0

## Functions ##

error() {
	local msg="$1"
	echo -e "${RED}[ERROR] $msg${NC}" >&2
	# Thread-safe increment of FAIL_COUNT
	flock "$FAIL_COUNT_FILE" bash -c 'count=$(cat "$0" 2>/dev/null || echo 0); echo $((count + 1)) > "$0"' "$FAIL_COUNT_FILE"
	local success_count=$(cat "$SUCCESS_COUNT_FILE" 2>/dev/null || echo 0)
	local fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
	# Only print progress if we haven't reached TOTAL_FILES
	[[ "$success_count" -lt "$TOTAL_FILES" ]] && echo -e "${CYAN}[INFO] Progress: [$success_count/$TOTAL_FILES] files converted successfully${NC}"
	return 1
}

warning() {
	echo -e "${YELLOW}[WARNING] $1${NC}" >&2
}

info() {
	echo -e "${CYAN}[INFO] $1${NC}"
}

success() {
	local msg="$1"
	echo -e "${GREEN}[INFO] $msg${NC}"
	# Thread-safe increment of SUCCESS_COUNT
	flock "$SUCCESS_COUNT_FILE" bash -c 'count=$(cat "$0" 2>/dev/null || echo 0); echo $((count + 1)) > "$0"' "$SUCCESS_COUNT_FILE"
	local success_count=$(cat "$SUCCESS_COUNT_FILE" 2>/dev/null || echo 0)
	local fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
	# Print progress if we haven't exceeded TOTAL_FILES
	[[ "$success_count" -le "$TOTAL_FILES" ]] && echo -e "${CYAN}[INFO] Progress: [$success_count/$TOTAL_FILES] files converted successfully${NC}"
}

validate_bool() {
	local value="$1"
	local option="$2"
	local lower_value="${value,,}"
	if [[ "$lower_value" == "true" || "$value" == "1" ]]; then
		return 0
	elif [[ "$lower_value" == "false" || "$value" == "0" ]]; then
		return 1
	else
		error "Invalid boolean value '$value' for $option. Must be 'true', 'false', 'TRUE', 'FALSE' (case-insensitive), '1', or '0'."
		exit 1
	fi
}

create_config() {
	# Ensure ~/.config exists
	mkdir -p "$HOME/.config" || error "Failed to create directory $HOME/.config"

    # Write sample config file with comments
    cat > "$CONFIG_FILE" << EOF
# SonicSqueezer configuration file
# Located at $CONFIG_FILE
# Uncomment and modify variables to customize settings

# Path to FFmpeg encoder
# FFMPEG_PATH="/usr/bin/ffmpeg"

# Path to FLAC decoder (required for FLAC input files)
# FLACDECODER="/usr/bin/flac"

# Path to metaflac (optional, for copying FLAC metadata)
# METAFLAC="/usr/bin/metaflac"

# Process priority (19 to -20, 19 lowest)
# PROCNICE="10"

# Output format: mp3, aac, ogg, wma, flac, opus, alac
# OUTPUT_FORMAT="mp3"

# Quality options for FFmpeg (high-quality VBR for lossy formats; empty for lossless)
# QUALITY_OPTS="-c:a mp3 -q:a 0"

# Enable/disable volume normalization using FFmpeg loudnorm (true/false/1/0)
# NORMALIZE="false"

# Enable/disable metadata copying for FLAC input files (true/false/1/0)
# COPYMETA="true"

# Enable/disable deletion of original files after successful conversion (true/false/1/0)
# DELETE_ORIGINAL="false"

# Output directory (leave empty to use same directory as input files)
# OUTPUT_DIR=""

# Enable/disable metadata-based renaming (tracknumber-title.extension) (true/false/1/0)
# RENAME_METADATA="false"

# Maximum number of threads (leave empty for auto-detection)
# THREADMAX=""
EOF
success "Created sample configuration file at $CONFIG_FILE"
exit 0
}

print_help() {
	echo -e "${BLUE}==== $PROGRAM_NAME ($PROGRAM_DATE) ====${NC}"
	echo ""
	echo "Description: A multi-threaded audio converter for WAV and FLAC to MP3, AAC, OGG, WMA, FLAC, Opus, or ALAC"
	echo ""
	echo "Usage: $0 [options] [path to '.wav' or '.flac' file(s) or directory]"
	echo "       Supports wildcards (e.g., '*.wav', '*.flac')."
	echo "       Without file arguments, processes all WAV and FLAC files in the current directory."
	echo ""
	echo "Options:"
	echo "  -h, --help                  Show this help message"
	echo "  -f, --format TYPE           Set output format (mp3, aac, ogg, wma, flac, opus, alac)"
	echo "  -n, --nice LEVEL            Set process priority (19 to -20, 19 lowest)"
	echo "  -t, --threads NUM           Set max number of threads (1 or more)"
	echo "  -N, --normalize BOOL        Enable/disable FFmpeg loudnorm normalization (true/false/1/0, case-insensitive)"
	echo "  -m, --copymeta BOOL         Enable/disable metadata copying (true/false/1/0, case-insensitive)"
	echo "  -d, --delete-original BOOL  Enable/disable deletion of original files (true/false/1/0, case-insensitive)"
	echo "  -F, --ffmpeg-opts OPTS      Extra options for FFmpeg"
	echo "  -o, --output-dir DIR        Output directory (default: same as input files)"
	echo "  -r, --rename-metadata BOOL  Enable/disable metadata-based renaming (true/false/1/0, case-insensitive)"
	echo "  -c, --create-config         Create a sample config file at $CONFIG_FILE"
	echo ""
	echo "Notes:"
	echo "  - Options with values can use spaces (e.g., '-f opus', '-r true') or equals (e.g., '-f=opus', '--rename-metadata=true')."
	echo "  - Boolean options (-N, -m, -d, -r) accept 'true', 'false', 'TRUE', 'FALSE' (case-insensitive), '1', or '0'."
	echo "  - Converting FLAC to FLAC is skipped with a warning to avoid redundant processing."
	echo "  - Progress and success/failure counts are displayed during and after conversion."
	echo "  - Normalization uses FFmpeg's loudnorm filter for consistent loudness."
	echo "  - Metadata-based renaming requires TRACKNUMBER and TITLE metadata; falls back to original basename if missing."
	echo ""
	echo "Configuration:"
	echo "  Settings can be customized in $CONFIG_FILE"
	echo "  Precedence: CLI options > $CONFIG_FILE > built-in defaults"
	echo "  Create sample config: '$0 -c'"
	echo ""
	echo "Dependencies:"
	echo "  - Bourne Again SHell (bash)"
	echo "  - FFmpeg (required, includes loudnorm for normalization)"
	echo "  - For FLAC input: 'flac' (decoder), 'metaflac' (optional for metadata)"
	echo ""
	exit 0
}

load_config() {
	if [[ -r "$CONFIG_FILE" ]]; then
		info "Loading configuration from $CONFIG_FILE"
		# shellcheck source=/dev/null
		source "$CONFIG_FILE"
	else
		info "No configuration file found at $CONFIG_FILE, using defaults"
	fi
}

parse_cli_options() {
	local i=1
	args=()
	while [ $i -le $# ]; do
		eval "arg=\${$i}"
		case "$arg" in
			-h|--help)
				print_help
				;;
			-f|--format)
				i=$((i + 1))
				eval "OUTPUT_FORMAT=\${$i}"
				;;
			--format=*)
				OUTPUT_FORMAT="${arg#*=}"
				;;
			-n|--nice)
				i=$((i + 1))
				eval "PROCNICE=\${$i}"
				;;
			--nice=*)
				PROCNICE="${arg#*=}"
				;;
			-t|--threads)
				i=$((i + 1))
				eval "THREADMAX=\${$i}"
				;;
			--threads=*)
				THREADMAX="${arg#*=}"
				;;
			-N|--normalize)
				i=$((i + 1))
				eval "NORMALIZE=\${$i}"
				validate_bool "$NORMALIZE" "--normalize" && NORMALIZE="true" || NORMALIZE="false"
				;;
			--normalize=*)
				NORMALIZE="${arg#*=}"
				validate_bool "$NORMALIZE" "--normalize" && NORMALIZE="true" || NORMALIZE="false"
				;;
			-m|--copymeta)
				i=$((i + 1))
				eval "COPYMETA=\${$i}"
				validate_bool "$COPYMETA" "--copymeta" && COPYMETA="true" || COPYMETA="false"
				;;
			--copymeta=*)
				COPYMETA="${arg#*=}"
				validate_bool "$COPYMETA" "--copymeta" && COPYMETA="true" || COPYMETA="false"
				;;
			-d|--delete-original)
				i=$((i + 1))
				eval "DELETE_ORIGINAL=\${$i}"
				validate_bool "$DELETE_ORIGINAL" "--delete-original" && DELETE_ORIGINAL="true" || DELETE_ORIGINAL="false"
				;;
			--delete-original=*)
				DELETE_ORIGINAL="${arg#*=}"
				validate_bool "$DELETE_ORIGINAL" "--delete-original" && DELETE_ORIGINAL="true" || DELETE_ORIGINAL="false"
				;;
			-F|--ffmpeg-opts)
				i=$((i + 1))
				eval "QUALITY_OPTS=\${$i}"
				;;
			--ffmpeg-opts=*)
				QUALITY_OPTS="${arg#*=}"
				;;
			-o|--output-dir)
				i=$((i + 1))
				eval "OUTPUT_DIR=\${$i}"
				;;
			--output-dir=*)
				OUTPUT_DIR="${arg#*=}"
				;;
			-r|--rename-metadata)
				i=$((i + 1))
				eval "RENAME_METADATA=\${$i}"
				validate_bool "$RENAME_METADATA" "--rename-metadata" && RENAME_METADATA="true" || RENAME_METADATA="false"
				;;
			--rename-metadata=*)
				RENAME_METADATA="${arg#*=}"
				validate_bool "$RENAME_METADATA" "--rename-metadata" && RENAME_METADATA="true" || RENAME_METADATA="false"
				;;
			-c|--create-config)
				create_config
				;;
			*)
				args+=("$arg") # Collect non-option arguments
				;;
		esac
		i=$((i + 1))
	done
}

set_quality_opts() {
	# Set QUALITY_OPTS based on OUTPUT_FORMAT if not overridden by CLI or config
	if [[ -z "$QUALITY_OPTS" || "$QUALITY_OPTS" == "-c:a mp3 -q:a 0" ]]; then
		case "$OUTPUT_FORMAT" in
			mp3)
				QUALITY_OPTS="-c:a mp3 -q:a 0"
				;;
			aac)
				QUALITY_OPTS="-c:a aac -q:a 1"
				;;
			ogg)
				QUALITY_OPTS="-c:a libvorbis -q:a 8"
				;;
			wma)
				QUALITY_OPTS="-c:a wmav2 -q:a 0"
				;;
			flac)
				QUALITY_OPTS="-c:a flac"
				;;
			opus)
				QUALITY_OPTS="-c:a libopus -vbr on -b:a 192k"
				;;
			alac)
				QUALITY_OPTS="-c:a alac"
				;;
			*)
				error "Invalid output format: $OUTPUT_FORMAT. Use mp3, aac, ogg, wma, flac, opus, or alac."
				exit 1
				;;
		esac
	fi
}

detect_threads() {
	if [[ -n "$THREADMAX" && "$THREADMAX" =~ ^[0-9]+$ && "$THREADMAX" -ge 1 ]]; then
		info "Using user-specified $THREADMAX threads"
	else
		if [[ "$(uname -s)" == "Linux" ]]; then
			THREADMAX=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)
		elif [[ "$(uname -s)" =~ ^(Darwin|*BSD)$ ]]; then
			THREADMAX=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
		else
			THREADMAX=1
		fi
		[[ -z "$THREADMAX" || "$THREADMAX" -lt 1 ]] && THREADMAX=1
		info "Detected $THREADMAX CPU threads for parallel processing"
	fi
}

sanity_check() {
	local notsane=0

	[[ -x "/bin/bash" ]] || { error "Bourne Again SHell (bash) not found"; notsane=1; }
	[[ -x "$FFMPEG_PATH" ]] || { error "FFmpeg not found at $FFMPEG_PATH"; notsane=1; }

	if [[ "$COPYMETA" == "true" || "$RENAME_METADATA" == "true" ]]; then
		[[ -x "$METAFLAC" ]] || {
			warning "metaflac not found at $METAFLAC. Disabling metadata copying and renaming."
					COPYMETA="false"
					RENAME_METADATA="false"
				}
	fi

	if [[ "$OUTPUT_FORMAT" == "flac" && "$RENAME_METADATA" == "true" ]]; then
		warning "Metadata-based renaming is disabled for FLAC output to avoid redundant processing."
		RENAME_METADATA="false"
	fi

	if [[ -n "$OUTPUT_DIR" ]]; then
		mkdir -p "$OUTPUT_DIR" || error "Failed to create output directory $OUTPUT_DIR"
	fi

	[[ "$notsane" -eq 1 ]] && error "Missing dependencies prevent this script from proceeding"
}

convert_wav() {
	local file="$1"
	local basename=$(basename "${file%.[wW][aA][vV]}")
	local dir=$(dirname "$file")
	local fileout

	[[ -r "$file" ]] || { error "Unable to read file: $file"; return 1; }

	if [[ "$RENAME_METADATA" == "true" ]]; then
		# Try to extract metadata using FFmpeg (WAV may have limited metadata)
		local tracknumber=$("$FFMPEG_PATH" -i "$file" -f ffmetadata - 2>/dev/null | grep -i "^track=" | awk -F= '{print $2}' | head -n1)
		local title=$("$FFMPEG_PATH" -i "$file" -f ffmetadata - 2>/dev/null | grep -i "^title=" | awk -F= '{print $2}' | head -n1)
		if [[ -n "$tracknumber" && -n "$title" ]]; then
			# Pad tracknumber to two digits
			tracknumber=$(printf "%02d" "$tracknumber")
			# Sanitize title for filesystem safety
			title=$(echo "$title" | tr -d '/:*?"<>|' | tr -s ' ')
			fileout="${OUTPUT_DIR:-$dir}/${tracknumber} - ${title}.${OUTPUT_FORMAT}"
		else
			warning "Missing TRACKNUMBER or TITLE metadata for $file, using original basename"
			fileout="${OUTPUT_DIR:-$dir}/${basename}.${OUTPUT_FORMAT}"
		fi
	else
		fileout="${OUTPUT_DIR:-$dir}/${basename}.${OUTPUT_FORMAT}"
	fi

	info "Processing WAV: $file"
	local normalize_opts=""
	[[ "$NORMALIZE" == "true" ]] && normalize_opts="-af loudnorm=I=-16:LRA=11:TP=-1.5"

	"$FFMPEG_PATH" -i "$file" $normalize_opts $QUALITY_OPTS "$fileout" -y -loglevel error || { error "FFmpeg encoding failed for $file"; return 1; }
	if [[ "$DELETE_ORIGINAL" == "true" && -f "$fileout" ]]; then
		rm -f "$file" && info "Deleted original file: $file"
	fi
	success "Converted to: $fileout"
}

convert_flac() {
	local file="$1"
	local basename=$(basename "${file%.[fF][lL][aA][cC]}")
	local dir=$(dirname "$file")
	local fileout

	[[ -r "$file" ]] || { error "Unable to read file: $file"; return 1; }
	[[ -x "$FLACDECODER" ]] || { error "FLAC decoder not found at $FLACDECODER"; return 1; }

    # Check if the file is a valid FLAC before processing metadata
    if ! "$FLACDECODER" --test "$file" >/dev/null 2>&1; then
	    warning "Invalid FLAC file: $file, using original basename"
	    fileout="${OUTPUT_DIR:-$dir}/${basename}.${OUTPUT_FORMAT}"
	    info "Processing FLAC: $file"
	    "$FFMPEG_PATH" -i "$file" $QUALITY_OPTS "$fileout" -y -loglevel error || { error "FFmpeg encoding failed for $file"; return 1; }
	    if [[ "$DELETE_ORIGINAL" == "true" && -f "$fileout" ]]; then
		    rm -f "$file" && info "Deleted original file: $file"
	    fi
	    success "Converted to: $fileout"
	    return 0
    fi

    if [[ "$RENAME_METADATA" == "true" ]]; then
	    local tracknumber=$("$METAFLAC" --show-tag=TRACKNUMBER "$file" | awk -F= '{print $2}' | head -n1)
	    local title=$("$METAFLAC" --show-tag=TITLE "$file" | awk -F= '{print $2}' | head -n1)
	    if [[ -n "$tracknumber" && -n "$title" ]]; then
		    # Pad tracknumber to two digits
		    tracknumber=$(printf "%02d" "$tracknumber")
		    # Sanitize title for filesystem safety
		    title=$(echo "$title" | tr -d '/:*?"<>|' | tr -s ' ')
		    fileout="${OUTPUT_DIR:-$dir}/${tracknumber} - ${title}.${OUTPUT_FORMAT}"
	    else
		    warning "Missing TRACKNUMBER or TITLE metadata for $file, using original basename"
		    fileout="${OUTPUT_DIR:-$dir}/${basename}.${OUTPUT_FORMAT}"
	    fi
    else
	    fileout="${OUTPUT_DIR:-$dir}/${basename}.${OUTPUT_FORMAT}"
    fi

    info "Processing FLAC: $file"
    local metadata=()
    if [[ "$COPYMETA" == "true" ]]; then
	    for tag in TITLE ALBUM ARTIST TRACKNUMBER GENRE COMMENT DATE; do
		    value=$("$METAFLAC" --show-tag="$tag" "$file" | awk -F= '{print $2}' | head -n1)
		    [[ -n "$value" ]] && metadata+=(-metadata "${tag,,}=${value}")
	    done
    fi
    local normalize_opts=""
    [[ "$NORMALIZE" == "true" ]] && normalize_opts="-af loudnorm=I=-16:LRA=11:TP=-1.5"

    "$FFMPEG_PATH" -i "$file" "${metadata[@]}" $normalize_opts $QUALITY_OPTS "$fileout" -y -loglevel error || { error "FFmpeg encoding failed for $file"; return 1; }
    if [[ "$DELETE_ORIGINAL" == "true" && -f "$fileout" ]]; then
	    rm -f "$file" && info "Deleted original file: $file"
    fi
    success "Converted to: $fileout"
}

convert_file() {
	# Wrapper function to dispatch to the correct converter based on file extension
	local file="$1"
	case "${file,,}" in
		*.wav)
			convert_wav "$file"
			;;
		*.flac)
			if [[ "$OUTPUT_FORMAT" == "flac" ]]; then
				warning "Skipping redundant FLAC to FLAC conversion: $file"
				flock "$SKIP_COUNT_FILE" bash -c 'count=$(cat "$0" 2>/dev/null || echo 0); echo $((count + 1)) > "$0"' "$SKIP_COUNT_FILE"
				return 0
			fi
			convert_flac "$file"
			;;
		*)
			warning "Skipping unsupported file: $file"
			flock "$SKIP_COUNT_FILE" bash -c 'count=$(cat "$0" 2>/dev/null || echo 0); echo $((count + 1)) > "$0"' "$SKIP_COUNT_FILE"
			return 0
			;;
	esac
}

## Main Script ##

# Initialize args array
args=()

# Create temporary files in memory for counting (use /dev/shm if available)
if [[ -d "/dev/shm" ]]; then
	SUCCESS_COUNT_FILE="/dev/shm/sonicsqueezer_$$_success"
	FAIL_COUNT_FILE="/dev/shm/sonicsqueezer_$$_fail"
	SKIP_COUNT_FILE="/dev/shm/sonicsqueezer_$$_skip"
else
	SUCCESS_COUNT_FILE=$(mktemp)
	FAIL_COUNT_FILE=$(mktemp)
	SKIP_COUNT_FILE=$(mktemp)
fi
: > "$SUCCESS_COUNT_FILE"
: > "$FAIL_COUNT_FILE"
: > "$SKIP_COUNT_FILE"

# Clean up temp files on exit
trap 'rm -f "$SUCCESS_COUNT_FILE" "$FAIL_COUNT_FILE" "$SKIP_COUNT_FILE"' EXIT

# Load configuration file first
load_config

# Parse CLI options (overrides config file)
parse_cli_options "$@"

# Set QUALITY_OPTS based on OUTPUT_FORMAT
set_quality_opts

sanity_check
detect_threads

# Collect files to process and count total
shopt -s nullglob
if [[ ${#args[@]} -eq 0 ]]; then
	info "No arguments provided. Processing all WAV and FLAC files in current directory."
	files=(*.[wW][aA][vV] *.[fF][lL][aA][cC])
	[[ ${#files[@]} -eq 0 ]] && error "No WAV or FLAC files found in current directory"
else
	files=()
	for arg in "${args[@]}"; do
		if [[ -d "$arg" ]]; then
			# Use find to handle spaces and special characters in directories
			while IFS= read -r -d '' file; do
				files+=("$file")
			done < <(find "$arg" -maxdepth 1 -type f \( -iname "*.wav" -o -iname "*.flac" \) -print0)
		elif [[ -f "$arg" && "${arg,,}" =~ \.(wav|flac)$ ]]; then
			files+=("$arg")
		fi
	done
	[[ ${#files[@]} -eq 0 ]] && error "No valid WAV or FLAC files found"
fi

# Count files to be processed (excluding FLAC to FLAC if applicable)
for file in "${files[@]}"; do
	if [[ "$OUTPUT_FORMAT" == "flac" && "${file,,}" =~ \.flac$ ]]; then
		((SKIPPED_FILES++))
	else
		((TOTAL_FILES++))
	fi
done
info "Processing $TOTAL_FILES files ($SKIPPED_FILES will be skipped)"

# Export variables and functions for parallel processing
export -f convert_wav convert_flac convert_file error warning info success validate_bool
export FFMPEG_PATH FLACDECODER METAFLAC QUALITY_OPTS NORMALIZE COPYMETA DELETE_ORIGINAL OUTPUT_FORMAT OUTPUT_DIR RENAME_METADATA
export RED YELLOW GREEN BLUE CYAN NC
export SUCCESS_COUNT_FILE FAIL_COUNT_FILE SKIP_COUNT_FILE TOTAL_FILES

# Process all files in parallel and wait for completion
printf '%s\0' "${files[@]}" | xargs -0 -n 1 -P "$THREADMAX" nice -n "$PROCNICE" bash -c 'convert_file "$@"' --
wait

# Calculate final counts after all processes complete
SUCCESS_COUNT=$(cat "$SUCCESS_COUNT_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
SKIPPED_FILES=$(cat "$SKIP_COUNT_FILE" 2>/dev/null || echo 0)

# Final status message
if [[ "$TOTAL_FILES" -eq 0 ]]; then
	if [[ "$SKIPPED_FILES" -gt 0 ]]; then
		info "No files processed ($SKIPPED_FILES files skipped due to redundant FLAC to FLAC conversion or unsupported format)"
		exit 0
	else
		error "No valid files to process"
		exit 1
	fi
elif [[ "$SUCCESS_COUNT" -eq "$TOTAL_FILES" && "$FAIL_COUNT" -eq 0 ]]; then
	success "Conversion process completed successfully ($SUCCESS_COUNT/$TOTAL_FILES files converted)"
	exit 0
else
	echo -e "${YELLOW}[INFO] Conversion process completed with some issues ($SUCCESS_COUNT/$TOTAL_FILES files converted successfully, $FAIL_COUNT failed)${NC}"
	exit 1
fi
