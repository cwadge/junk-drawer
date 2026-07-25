#!/bin/bash

# Disc Crusher - Universal Disc Image to CHD Converter
# Converts disc images (.iso, .cue, .toc, .gdi, .nrg) to .chd format using chdman
# Automatically detects CD vs DVD format via header inspection
# Supports: PSX, Saturn, Dreamcast, PS2, PSP, PC-Engine CD, and more
# Automatically creates .m3u playlists for multi-disc games

VERSION="2.0.0"

# ┌─────────────────────────────────────────────────────────────┐
# │ Color codes                                                 │
# └─────────────────────────────────────────────────────────────┘
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ┌─────────────────────────────────────────────────────────────┐
# │ Box drawing constants (60 chars wide)                       │
# └─────────────────────────────────────────────────────────────┘
BOX_TOP='╔══════════════════════════════════════════════════════════╗'
BOX_BOT='╚══════════════════════════════════════════════════════════╝'
BOX_SEP='╠══════════════════════════════════════════════════════════╣'
BOX_DIV='╟──────────────────────────────────────────────────────────╢'
HR='══════════════════════════════════════════════════════════'

# Print a padded box row (58 chars of inner content)
box_row() {
	local text="$1"
	local len=${#text}
	local inner=58
	local pad_left=$(( (inner - len) / 2 ))
	local pad_right=$(( inner - len - pad_left ))
	printf '║'
	printf '%*s' "$pad_left" ''
	printf '%s' "$text"
	printf '%*s' "$pad_right" ''
	printf '║\n'
}

# Print a left-aligned key/value row with correct right border.
# Color codes are applied outside the padding calculation so ${#} counts
# only visible characters and the closing ║ always lands in the right place.
# Border characters are always printed in BLUE to match box_row / BOX_* constants.
# Usage: box_row_kv "Label:" "value" [label_color] [value_color]
box_row_kv() {
	local label="$1"
	local value="$2"
	local lcol="${3:-}"
	local vcol="${4:-}"
	# Visible width: 2 (indent) + len(label) + 1 (space) + len(value)
	local pad=$(( 58 - 2 - ${#label} - 1 - ${#value} ))
	[[ $pad -lt 0 ]] && pad=0
	printf '%b║%b  ' "$BLUE" "$NC"
	[[ -n "$lcol" ]] && printf '%b' "$lcol"
	printf '%s' "$label"
	[[ -n "$lcol" ]] && printf '%b' "$NC"
	printf ' '
	[[ -n "$vcol" ]] && printf '%b' "$vcol"
	printf '%s' "$value"
	[[ -n "$vcol" ]] && printf '%b' "$NC"
	printf '%*s%b║%b\n' "$pad" '' "$BLUE" "$NC"
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Counters                                                    │
# └─────────────────────────────────────────────────────────────┘
total_files=0
converted_files=0
failed_files=0
fallback_files=0
skipped_files=0
total_space_saved=0

# ┌─────────────────────────────────────────────────────────────┐
# │ Runtime state                                               │
# └─────────────────────────────────────────────────────────────┘
CHDMAN_MAJOR=0
CHDMAN_MINOR=0
HUNK_SIZE_FLAG=""
CREATEDVD_AVAILABLE=false
DELETE_SOURCES=false

# ┌─────────────────────────────────────────────────────────────┐
# │ Settings                                                    │
# │                                                             │
# │ Precedence: built-in defaults < config file < environment   │
# │ < command line. The same variable names are used at every   │
# │ level so there is one vocabulary to learn.                  │
# └─────────────────────────────────────────────────────────────┘
CONFIG_FILE="${DISC_CRUSHER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/disc-crusher.conf}"

# Environment values are captured before the config file is sourced so that
# sourcing cannot clobber them; env outranks config.
_env_input="${DISC_CRUSHER_INPUT:-}"
_env_output="${DISC_CRUSHER_OUTPUT:-}"
_env_recursive="${DISC_CRUSHER_RECURSIVE:-}"
_env_depth="${DISC_CRUSHER_DEPTH:-}"
_env_delete="${DISC_CRUSHER_DELETE:-}"
_env_overwrite="${DISC_CRUSHER_OVERWRITE:-}"
_env_mode="${DISC_CRUSHER_MODE:-}"

DISC_CRUSHER_INPUT="."
DISC_CRUSHER_OUTPUT=""      # empty means PWD
DISC_CRUSHER_RECURSIVE=false
DISC_CRUSHER_DEPTH=2        # levels below the input directory; 0 means unlimited
DISC_CRUSHER_DELETE="auto"  # auto | always | never
DISC_CRUSHER_OVERWRITE=false
DISC_CRUSHER_MODE=""        # cd | dvd | empty for auto-detect

# shellcheck source=/dev/null
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

[[ -n "$_env_input"     ]] && DISC_CRUSHER_INPUT="$_env_input"
[[ -n "$_env_output"    ]] && DISC_CRUSHER_OUTPUT="$_env_output"
[[ -n "$_env_recursive" ]] && DISC_CRUSHER_RECURSIVE="$_env_recursive"
[[ -n "$_env_depth"     ]] && DISC_CRUSHER_DEPTH="$_env_depth"
[[ -n "$_env_delete"    ]] && DISC_CRUSHER_DELETE="$_env_delete"
[[ -n "$_env_overwrite" ]] && DISC_CRUSHER_OVERWRITE="$_env_overwrite"
[[ -n "$_env_mode"      ]] && DISC_CRUSHER_MODE="$_env_mode"

DRY_RUN=false
WRITE_CONFIG=false

# --write-config borrows -f to mean "replace the existing file". That sense of
# the flag must not leak into the saved settings, or asking to regenerate a
# config would silently pin overwrite-everything on for every future run.
_overwrite_preflag="$DISC_CRUSHER_OVERWRITE"
_overwrite_from_flag=false

# Quote a value so the generated config survives re-sourcing intact
cq() { printf '%q' "$1"; }

# Write the current settings to the config file. Values are taken from the raw
# settings rather than the normalised ones: DISC_CRUSHER_OUTPUT is empty to mean
# "wherever I am", and baking in the resolved path would pin the config to
# whichever directory happened to be current when it was generated.
write_config() {
	local dir saved_overwrite
	dir=$(dirname "$CONFIG_FILE")
	if [[ "$_overwrite_from_flag" == true ]]; then
		saved_overwrite="$_overwrite_preflag"
	else
		saved_overwrite="$DISC_CRUSHER_OVERWRITE"
	fi

	if [[ -e "$CONFIG_FILE" ]] && [[ "$DISC_CRUSHER_OVERWRITE" == false ]]; then
		echo -e "${RED}Error: $CONFIG_FILE already exists${NC}"
		echo "Use -f to replace it."
		return 1
	fi

	if ! mkdir -p "$dir" 2>/dev/null; then
		echo -e "${RED}Error: could not create $dir${NC}"
		return 1
	fi

	{
		echo "# Disc Crusher configuration"
		echo "# Generated by disc-crusher $VERSION on $(date '+%Y-%m-%d')"
		echo "#"
		echo "# Sourced as bash. Precedence is:"
		echo "#   built-in defaults < this file < environment < command line"
		echo "#"
		echo "# Deleting a line restores the built-in default for that setting,"
		echo "# which is the safer choice if a later version changes it."
		echo ""
		echo "# Source directory to scan."
		echo "DISC_CRUSHER_INPUT=$(cq "$DISC_CRUSHER_INPUT")"
		echo ""
		echo "# Destination for .chd files. Empty means the current working directory."
		echo "DISC_CRUSHER_OUTPUT=$(cq "$DISC_CRUSHER_OUTPUT")"
		echo ""
		echo "# Descend into subdirectories: true or false."
		echo "DISC_CRUSHER_RECURSIVE=$DISC_CRUSHER_RECURSIVE"
		echo ""
		echo "# Levels below the input directory to scan. 0 means unlimited."
		echo "DISC_CRUSHER_DEPTH=$DISC_CRUSHER_DEPTH"
		echo ""
		echo "# Source deletion policy: auto, always or never."
		echo "# Under auto, sources are deleted only when every .chd lands in the"
		echo "# directory its source came from — a non-recursive run writing in place."
		echo "DISC_CRUSHER_DELETE=$(cq "$DISC_CRUSHER_DELETE")"
		echo ""
		echo "# Overwrite existing .chd files: true or false."
		echo "DISC_CRUSHER_OVERWRITE=$saved_overwrite"
		echo ""
		echo "# Force a conversion mode: cd, dvd, or empty to auto-detect."
		echo "DISC_CRUSHER_MODE=$(cq "$DISC_CRUSHER_MODE")"
	} > "$CONFIG_FILE" || return 1

	echo -e "${GREEN}✓ Wrote${NC} $CONFIG_FILE"
	return 0
}

show_help() {
	echo "$BOX_TOP"
	box_row "Disc Crusher $VERSION - Universal CHD Converter"
	echo "$BOX_BOT"
	echo ""
	echo "Usage: $0 [OPTIONS] [INPUT_DIR]"
	echo ""
	echo "Options:"
	echo "  -i, --input DIR             Source directory (default: current directory)"
	echo "  -o, --output DIR            Destination for .chd files (default: current directory)"
	echo "  -r, --recursive             Descend into subdirectories"
	echo "  -d, --depth N               Levels below the input dir to scan (default: 2, 0 = unlimited)"
	echo "  -k, --keep                  Never delete source files"
	echo "      --delete MODE           Source deletion policy: auto, always, never (default: auto)"
	echo "  -n, --dry-run               Show the conversion plan and exit"
	echo "      --write-config          Write current settings to the config file and exit"
	echo "      --cd                    Force CD mode for all files (createcd)"
	echo "      --dvd                   Force DVD mode for all files (createdvd)"
	echo "  -f, --force, --overwrite    Overwrite existing .chd files"
	echo "  -h, --help                  Show this help message"
	echo ""
	echo "Formats supported:"
	echo "  .gdi   Dreamcast disc image (always CD)"
	echo "  .cue   CD/DVD cue sheet + binary tracks"
	echo "  .toc   cdrdao track sheet + binary tracks (always CD)"
	echo "  .nrg   Nero disc image, self-contained (always CD)"
	echo "  .iso   Raw disc image (CD or DVD, auto-detected)"
	echo ""
	echo "CD vs DVD detection (in priority order):"
	echo "  1. .gdi / .toc / .nrg extension   → always CD"
	echo "  2. File size > 870 MB             → always DVD"
	echo "  3. .cue with raw sectors          → always CD"
	echo "     (AUDIO, MODE1/2352, MODE2/2352)"
	echo "  4. UDF filesystem header          → DVD"
	echo "  5. No UDF found                   → CD (default)"
	echo ""
	echo "If a DVD conversion fails, CD is automatically retried."
	echo "Source files are preserved on any fallback conversion."
	echo "Use --dvd or --cd to suppress auto-detection."
	echo ""
	echo "Output is always flat: every .chd lands directly in the output"
	echo "directory regardless of how deep its source was found. Names that"
	echo "would collide are disambiguated with their parent directory name."
	echo ""
	echo "Source deletion is a whole-run policy, not per-file. Under 'auto',"
	echo "sources are deleted only when every .chd lands in the directory its"
	echo "source came from — that is, a non-recursive run writing in place."
	echo "Any recursion or redirected output disables deletion for the run."
	echo ""
	echo "Multi-disc games are collected into .m3u playlists. A playlist"
	echo "shipped alongside the source images is used for grouping and disc"
	echo "order when present, in preference to filename heuristics."
	echo ""
	echo "Config file: $CONFIG_FILE"
	echo "  --write-config generates it from the settings in effect, so any flags"
	echo "  given alongside it are captured as the new defaults. -f is the"
	echo "  exception: there it only grants permission to replace an existing"
	echo "  file, and is not saved. DISC_CRUSHER_CONFIG points elsewhere."
	echo "Environment: DISC_CRUSHER_INPUT, DISC_CRUSHER_OUTPUT, DISC_CRUSHER_RECURSIVE,"
	echo "             DISC_CRUSHER_DEPTH, DISC_CRUSHER_DELETE, DISC_CRUSHER_OVERWRITE,"
	echo "             DISC_CRUSHER_MODE"
	echo ""
	echo "Requires chdman (MAME tools) in PATH."
	echo "DVD mode (PS2/PSP) requires chdman >= 0.255."
}

_positional_input=""
while [[ $# -gt 0 ]]; do
	case $1 in
		-i|--input)
			[[ -z "${2:-}" ]] && { echo "Error: $1 requires a directory"; exit 1; }
			DISC_CRUSHER_INPUT="$2"
			shift 2
			;;
		-o|--output)
			[[ -z "${2:-}" ]] && { echo "Error: $1 requires a directory"; exit 1; }
			DISC_CRUSHER_OUTPUT="$2"
			shift 2
			;;
		-r|--recursive)
			DISC_CRUSHER_RECURSIVE=true
			shift
			;;
		-d|--depth)
			[[ -z "${2:-}" ]] && { echo "Error: $1 requires a number"; exit 1; }
			DISC_CRUSHER_DEPTH="$2"
			DISC_CRUSHER_RECURSIVE=true
			shift 2
			;;
		-k|--keep)
			DISC_CRUSHER_DELETE="never"
			shift
			;;
		--delete)
			[[ -z "${2:-}" ]] && { echo "Error: --delete requires a mode"; exit 1; }
			DISC_CRUSHER_DELETE="$2"
			shift 2
			;;
		-n|--dry-run)
			DRY_RUN=true
			shift
			;;
		--write-config)
			WRITE_CONFIG=true
			shift
			;;
		-f|--force|--overwrite)
			DISC_CRUSHER_OVERWRITE=true
			_overwrite_from_flag=true
			shift
			;;
		--cd)
			DISC_CRUSHER_MODE="cd"
			shift
			;;
		--dvd)
			DISC_CRUSHER_MODE="dvd"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		--)
			shift
			[[ -n "${1:-}" ]] && _positional_input="$1"
			break
			;;
		-*)
			echo "Unknown option: $1"
			echo "Use -h or --help for usage information"
			exit 1
			;;
		*)
			[[ -n "$_positional_input" ]] && { echo "Error: only one input directory may be given"; exit 1; }
			_positional_input="$1"
			shift
			;;
	esac
done
[[ -n "$_positional_input" ]] && DISC_CRUSHER_INPUT="$_positional_input"

# ── Validate and normalise settings ──────────────────────────────────────────

case "$DISC_CRUSHER_DELETE" in
	auto|always|never) ;;
	*) echo "Error: --delete must be one of: auto, always, never"; exit 1 ;;
esac

if [[ ! "$DISC_CRUSHER_DEPTH" =~ ^[0-9]+$ ]]; then
	echo "Error: depth must be a non-negative integer"
	exit 1
fi

if [[ "$WRITE_CONFIG" == true ]]; then
	write_config
	exit $?
fi

if [[ ! -d "$DISC_CRUSHER_INPUT" ]]; then
	echo "Error: input directory not found: $DISC_CRUSHER_INPUT"
	exit 1
fi

INPUT_DIR=$(readlink -f "$DISC_CRUSHER_INPUT")
OUTPUT_DIR=$(readlink -f "${DISC_CRUSHER_OUTPUT:-$PWD}")

OVERWRITE="$DISC_CRUSHER_OVERWRITE"
FORCE_MODE="$DISC_CRUSHER_MODE"
RECURSIVE="$DISC_CRUSHER_RECURSIVE"

# find's -maxdepth counts the start directory itself as depth 0, so the
# user-facing "levels below the input dir" is one less than the flag value.
declare -a DEPTH_ARGS=()
if [[ "$RECURSIVE" == true ]]; then
	[[ "$DISC_CRUSHER_DEPTH" -gt 0 ]] && DEPTH_ARGS=(-maxdepth $(( DISC_CRUSHER_DEPTH + 1 )))
else
	DEPTH_ARGS=(-maxdepth 1)
fi

# ┌─────────────────────────────────────────────────────────────┐
# │ Banner                                                      │
# └─────────────────────────────────────────────────────────────┘
echo -e "${BLUE}${BOX_TOP}${NC}"
echo -e "${BLUE}$(box_row "Disc Crusher $VERSION - Universal CHD Converter")${NC}"
echo -e "${BLUE}$(box_row "ISO · CUE · TOC · GDI · NRG  →  CHD")${NC}"
echo -e "${BLUE}${BOX_BOT}${NC}"
echo ""

# ┌─────────────────────────────────────────────────────────────┐
# │ Dependency check                                            │
# └─────────────────────────────────────────────────────────────┘
if ! command -v chdman &> /dev/null; then
	echo -e "${RED}Error: chdman not found in PATH${NC}"
	echo "Please install MAME tools or add chdman to your PATH"
	exit 1
fi

CHDMAN_VERSION=$(chdman --help 2>&1 | head -1 | grep -o 'v\?[0-9]\+\.[0-9]\+' | head -1 | sed 's/^v//')
if [[ -z "$CHDMAN_VERSION" ]]; then
	echo -e "${RED}Error: Could not determine chdman version${NC}"
	exit 1
fi

IFS='.' read -ra _VER <<< "$CHDMAN_VERSION"
CHDMAN_MAJOR=${_VER[0]:-0}
CHDMAN_MINOR=${_VER[1]:-0}

if [[ $CHDMAN_MAJOR -gt 0 || $CHDMAN_MINOR -ge 255 ]]; then
	CREATEDVD_AVAILABLE=true
fi

# -hs 2048 flag required for PS2/PSP compatibility on chdman >= 0.263
if [[ $CHDMAN_MAJOR -gt 0 || ($CHDMAN_MAJOR -eq 0 && $CHDMAN_MINOR -ge 263) ]]; then
	HUNK_SIZE_FLAG="-hs 2048"
fi

echo "chdman version : $CHDMAN_VERSION"
echo "createdvd      : $(${CREATEDVD_AVAILABLE} && echo "available" || echo "not available (requires >= 0.255)")"
[[ -n "$HUNK_SIZE_FLAG" ]] && echo "hunk size flag : -hs 2048 (PS2/PSP sector alignment)"
[[ -n "$FORCE_MODE" ]]     && echo -e "${YELLOW}Mode override  : $FORCE_MODE (auto-detection bypassed)${NC}"
echo ""

# ┌─────────────────────────────────────────────────────────────┐
# │ Utility functions                                           │
# └─────────────────────────────────────────────────────────────┘

get_file_size() {
	stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

get_avail_bytes() {
	df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

format_bytes() {
	local bytes=$1
	local units=("B" "KB" "MB" "GB" "TB")
	local unit=0
	local size=$bytes
	while (( $(echo "$size >= 1024" | bc -l) )) && (( unit < 4 )); do
		size=$(echo "scale=2; $size / 1024" | bc)
		((unit++))
	done
	printf "%.2f %s" "$size" "${units[$unit]}"
}

format_duration() {
	local total_seconds=$1
	local hours=$((total_seconds / 3600))
	local minutes=$(( (total_seconds % 3600) / 60 ))
	local seconds=$((total_seconds % 60))
	if   [[ $hours   -gt 0 ]]; then printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
	elif [[ $minutes -gt 0 ]]; then printf "%dm %ds" "$minutes" "$seconds"
	else                             printf "%ds" "$seconds"
	fi
}

# Extract base game name (strips disc/CD number suffix for M3U grouping)
get_base_game_name() {
	local base="${1%.*}"
	base=$(echo "$base" | sed -E 's/[[:space:]]*([-_]+[[:space:]]*|[][{(]+[[:space:]]*)?([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*[0-9]+.*//')
	echo "$base"
}

# Extract disc number from filename (returns empty string if not found)
get_disc_number() {
	if [[ "$1" =~ ([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*([0-9]+) ]]; then
		echo "${BASH_REMATCH[2]}"
	fi
}

# Render a path relative to the scan root so in-place runs read the way they
# always have, while recursive runs still show which subdirectory a file came from
display_path() {
	local p="$1"
	[[ "$p" == "$INPUT_DIR"/* ]] && echo "${p#"$INPUT_DIR"/}" || echo "$p"
}

# Shorten a path for display inside a fixed-width box row
elide_path() {
	local path="$1"
	local max="$2"
	if [[ ${#path} -le $max ]]; then
		echo "$path"
	else
		echo "…${path: -$(( max - 1 ))}"
	fi
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Referenced-file parsers (CUE, GDI and TOC)                  │
# └─────────────────────────────────────────────────────────────┘

get_cue_referenced_files() {
	local cue_file="$1"
	local cue_dir
	cue_dir=$(dirname "$cue_file")
	while IFS= read -r line; do
		if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || \
		   [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
			local full="${cue_dir}/${BASH_REMATCH[1]}"
			[[ -f "$full" ]] && echo "$full"
		fi
	done < "$cue_file"
}

get_gdi_referenced_files() {
	local gdi_file="$1"
	local gdi_dir
	gdi_dir=$(dirname "$gdi_file")
	local line_num=0
	while IFS= read -r line; do
		((line_num++))
		[[ $line_num -eq 1 ]] && continue  # first line is track count
		# GDI format: track# lba type sectorsize filename offset
		local fields=($line)
		local fname="${fields[4]}"
		[[ -z "$fname" ]] && continue
		local full="${gdi_dir}/${fname}"
		[[ -f "$full" ]] && echo "$full"
	done < "$gdi_file"
}

# cdrdao TOC format uses DATAFILE, AUDIOFILE, and FILE directives
get_toc_referenced_files() {
	local toc_file="$1"
	local toc_dir
	toc_dir=$(dirname "$toc_file")
	while IFS= read -r line; do
		# Match: DATAFILE "name" / AUDIOFILE "name" / FILE "name"
		if [[ "$line" =~ ^[[:space:]]*(DATAFILE|AUDIOFILE|FILE)[[:space:]]+\"([^\"]+)\" ]]; then
			local full="${toc_dir}/${BASH_REMATCH[2]}"
			[[ -f "$full" ]] && echo "$full"
		fi
	done < "$toc_file"
}

# Dispatch to the right parser for a manifest; self-contained formats list
# only themselves. Used for both size accounting and deletion.
get_source_files() {
	local disc_file="$1"
	local ext
	ext=$(echo "${disc_file##*.}" | tr '[:upper:]' '[:lower:]')
	echo "$disc_file"
	case "$ext" in
		cue) get_cue_referenced_files "$disc_file" ;;
		gdi) get_gdi_referenced_files "$disc_file" ;;
		toc) get_toc_referenced_files "$disc_file" ;;
	esac
}

get_source_total_size() {
	local disc_file="$1"
	local total=0 sz
	while IFS= read -r f; do
		sz=$(get_file_size "$f")
		[[ -n "$sz" ]] && total=$(( total + sz ))
	done < <(get_source_files "$disc_file")
	echo "$total"
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Format detection                                            │
# └─────────────────────────────────────────────────────────────┘

# Check for UDF filesystem signature (NSR02/NSR03) at VRS sectors 16-18
# Only valid for 2048-byte-per-sector images (ISOs and data-only BINs)
check_udf_header() {
	local file="$1"
	local sig
	# ECMA-167 Volume Recognition Area: sectors 16-18 (byte offsets for 2048-byte sectors)
	# Structure type byte is at offset+0, identifier string is at offset+1 (5 bytes)
	for sector_base in 32768 34816 36864; do
		sig=$(dd if="$file" bs=1 skip=$((sector_base + 1)) count=5 2>/dev/null)
		[[ "$sig" == "NSR02" || "$sig" == "NSR03" ]] && return 0
	done
	return 1
}

# Returns "cd" or "dvd" for a given file, respecting FORCE_MODE
detect_disc_mode() {
	local file="$1"
	local ext
	ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')

	# User override takes absolute precedence
	[[ -n "$FORCE_MODE" ]] && { echo "$FORCE_MODE"; return; }

	# GDI is always a CD-based format (Dreamcast)
	[[ "$ext" == "gdi" ]] && { echo "cd"; return; }

	# TOC (cdrdao) is a Linux CD burning format — always CD
	[[ "$ext" == "toc" ]] && { echo "cd"; return; }

	# NRG (Nero) is a self-contained CD image format — always CD
	[[ "$ext" == "nrg" ]] && { echo "cd"; return; }

	# Size > 870 MB cannot be a CD
	local size
	size=$(get_file_size "$file")
	if [[ -n "$size" ]] && (( size > 912680960 )); then
		echo "dvd"; return
	fi

	# CUE: inspect track types — raw 2352-byte sectors only exist on CDs
	if [[ "$ext" == "cue" ]]; then
		if grep -qiE 'TRACK[[:space:]]+[0-9]+[[:space:]]+(AUDIO|MODE[12]/2352)' "$file" 2>/dev/null; then
			echo "cd"; return
		fi
		# Data-only CUE (2048-byte sectors) — check UDF in the first referenced binary
		local cue_dir
		cue_dir=$(dirname "$file")
		while IFS= read -r line; do
			if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || \
			   [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
				local bin="${cue_dir}/${BASH_REMATCH[1]}"
				if [[ -f "$bin" ]]; then
					check_udf_header "$bin" && { echo "dvd"; return; }
					echo "cd"; return
				fi
			fi
		done < "$file"
		echo "cd"; return
	fi

	# ISO: check UDF header, default to CD if absent
	check_udf_header "$file" && { echo "dvd"; return; }
	echo "cd"
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Discovery and planning                                      │
# │                                                             │
# │ Everything is resolved before a single byte is written:      │
# │ what will be converted, where it will land, what collides,  │
# │ and whether sources will be removed. A name clash found     │
# │ forty minutes into a batch is a much worse discovery.       │
# └─────────────────────────────────────────────────────────────┘

declare -a plan_inputs=()      # ordered list of source manifests/images
declare -A plan_target=()      # input -> absolute .chd destination
declare -A plan_forced=()      # input -> "cd" when inherent to the format
declare -A plan_reason=()      # input -> mode reason label
declare -A plan_status=()      # input -> "convert" | "exists"
declare -A plan_size=()        # input -> total source bytes
declare -A plan_group=()       # input -> playlist group (from a shipped .m3u)
declare -A plan_order=()       # input -> playlist ordinal (from a shipped .m3u)
declare -A referenced_files=() # realpaths claimed by a manifest, excluded from standalone scan

echo -e "${CYAN}Scanning $INPUT_DIR ...${NC}"

declare -a found_gdi=() found_cue=() found_toc=() found_nrg=() found_iso=()
while IFS= read -r -d '' f; do
	case "$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')" in
		gdi) found_gdi+=("$f") ;;
		cue) found_cue+=("$f") ;;
		toc) found_toc+=("$f") ;;
		nrg) found_nrg+=("$f") ;;
		iso) found_iso+=("$f") ;;
	esac
done < <(find "$INPUT_DIR" "${DEPTH_ARGS[@]}" -type f \
	\( -iname '*.gdi' -o -iname '*.cue' -o -iname '*.toc' -o -iname '*.nrg' -o -iname '*.iso' \) \
	-print0 | sort -z)

# Manifests claim their track files first so a claimed .iso is never also
# converted standalone.
for f in "${found_cue[@]}" "${found_toc[@]}" "${found_gdi[@]}"; do
	while IFS= read -r ref; do
		ref=$(readlink -f "$ref" 2>/dev/null || echo "$ref")
		referenced_files["$ref"]=1
	done < <(get_source_files "$f" | tail -n +2)
done

# Manifest formats first, then self-contained images: this is the order the
# original phase structure used and it keeps related output together.
for f in "${found_gdi[@]}"; do
	plan_inputs+=("$f"); plan_forced["$f"]="cd"; plan_reason["$f"]="format"
done
for f in "${found_cue[@]}"; do
	plan_inputs+=("$f"); plan_forced["$f"]=""; plan_reason["$f"]=""
done
for f in "${found_toc[@]}"; do
	plan_inputs+=("$f"); plan_forced["$f"]="cd"; plan_reason["$f"]="format"
done
for f in "${found_nrg[@]}"; do
	plan_inputs+=("$f"); plan_forced["$f"]="cd"; plan_reason["$f"]="format"
done
excluded_iso=0
for f in "${found_iso[@]}"; do
	if [[ -n "${referenced_files[$(readlink -f "$f")]:-}" ]]; then
		(( excluded_iso++ ))
		continue
	fi
	plan_inputs+=("$f"); plan_forced["$f"]=""; plan_reason["$f"]=""
done

if [[ ${#plan_inputs[@]} -eq 0 ]]; then
	echo -e "${YELLOW}No disc images found.${NC}"
	echo ""
	echo -e "${BLUE}${BOX_TOP}${NC}"
	echo -e "${BLUE}$(box_row "Nothing to do")${NC}"
	echo -e "${BLUE}${BOX_BOT}${NC}"
	exit 0
fi

# ── Flat-output name assignment ──────────────────────────────────────────────
# Output is flat by design: a translated or hacked release ships its own
# directory tree, but every emulator wants the resulting images in one place.
# Flattening therefore makes basename collisions routine rather than exotic,
# so they are resolved up front and deterministically. Colliding names are
# qualified with their parent directory, which for hacks and translations is
# where the meaningful label lives.

declare -A plain_count=() cand_count=() cand_seen=()
declare -A plan_plain=() plan_cand=()

for f in "${plan_inputs[@]}"; do
	b=$(basename "$f"); b="${b%.*}"
	plan_plain["$f"]="$b"
	(( plain_count["$b"]++ )) || true
done

for f in "${plan_inputs[@]}"; do
	b="${plan_plain[$f]}"
	if [[ ${plain_count[$b]} -gt 1 ]]; then
		parent=$(basename "$(dirname "$(readlink -f "$f")")")
		# Prefix rather than suffix: in a flat directory this keeps every disc of
		# a release adjacent, and release names already carry their own brackets.
		[[ "$parent" != "$b" ]] && b="$parent - $b" || b="$parent"
	fi
	plan_cand["$f"]="$b"
	(( cand_count["$b"]++ )) || true
done

collisions=0
for f in "${plan_inputs[@]}"; do
	b="${plan_cand[$f]}"
	if [[ ${cand_count[$b]} -gt 1 ]]; then
		# Parent directory names were not unique either; fall back to ordinals.
		(( cand_seen["$b"]++ )) || true
		[[ ${cand_seen[$b]} -gt 1 ]] && b="$b-${cand_seen[$b]}"
	fi
	[[ "$b" != "${plan_plain[$f]}" ]] && (( collisions++ )) || true
	plan_target["$f"]="${OUTPUT_DIR}/${b}.chd"
done

# ── Playlist grouping from shipped .m3u files ────────────────────────────────
# Fan translations and multi-disc rips routinely ship a playlist whose ordering
# is authoritative where the filename disc-number heuristic is not. Only
# entries that resolve to something we are actually converting are honoured,
# so a stale playlist referencing missing discs is simply ignored.

declare -A input_by_real=()
for f in "${plan_inputs[@]}"; do
	input_by_real["$(readlink -f "$f")"]="$f"
done

declare -A seen_dir=()
shipped_playlists=0
for f in "${plan_inputs[@]}"; do
	d=$(dirname "$f")
	[[ -n "${seen_dir[$d]:-}" ]] && continue
	seen_dir["$d"]=1

	shopt -s nullglob nocaseglob
	m3u_candidates=("$d"/*.m3u)
	shopt -u nullglob nocaseglob

	for m in "${m3u_candidates[@]}"; do
		group=$(basename "$m"); group="${group%.*}"
		idx=0
		matched=0
		while IFS= read -r line || [[ -n "$line" ]]; do
			line="${line%$'\r'}"
			line="${line#"${line%%[![:space:]]*}"}"
			line="${line%"${line##*[![:space:]]}"}"
			[[ -z "$line" || "$line" == \#* ]] && continue
			[[ "$line" == /* ]] && entry="$line" || entry="$d/$line"
			entry=$(readlink -f "$entry" 2>/dev/null) || continue
			src="${input_by_real[$entry]:-}"
			[[ -z "$src" ]] && continue
			(( idx++ ))
			plan_group["$src"]="$group"
			plan_order["$src"]="$idx"
			(( matched++ ))
		done < "$m"
		[[ $matched -gt 0 ]] && (( shipped_playlists++ ))
	done
done

# ── Status, sizes and deletion policy ────────────────────────────────────────

planned_convert=0
planned_exists=0
total_source_bytes=0
for f in "${plan_inputs[@]}"; do
	sz=$(get_source_total_size "$f")
	plan_size["$f"]="$sz"
	total_source_bytes=$(( total_source_bytes + sz ))
	if [[ -f "${plan_target[$f]}" ]] && [[ "$OVERWRITE" == false ]]; then
		plan_status["$f"]="exists"
		(( planned_exists++ ))
	else
		plan_status["$f"]="convert"
		(( planned_convert++ ))
	fi
done

# Deletion is a whole-run decision, not per-file. A run that reclaims space for
# some sources and not others is harder to trust than one that does neither, so
# "auto" requires that every single output land in the directory its source came
# from — in practice, a non-recursive run writing in place.
all_in_place=true
for f in "${plan_inputs[@]}"; do
	if [[ "$(readlink -f "$(dirname "$f")")" != "$OUTPUT_DIR" ]]; then
		all_in_place=false
		break
	fi
done

case "$DISC_CRUSHER_DELETE" in
	always) DELETE_SOURCES=true ;;
	never)  DELETE_SOURCES=false ;;
	auto)   DELETE_SOURCES=$all_in_place ;;
esac

# ── Plan report ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}${BOX_TOP}${NC}"
echo -e "${BLUE}$(box_row "Plan")${NC}"
echo -e "${BLUE}${BOX_SEP}${NC}"
box_row_kv "Input: " "$(elide_path "$INPUT_DIR" 48)"  "" "$CYAN"
box_row_kv "Output:" "$(elide_path "$OUTPUT_DIR" 48)" "" "$CYAN"
if [[ "$RECURSIVE" == true ]]; then
	box_row_kv "Scan:  " "recursive, depth $( [[ $DISC_CRUSHER_DEPTH -eq 0 ]] && echo unlimited || echo "$DISC_CRUSHER_DEPTH" )"
else
	box_row_kv "Scan:  " "top level only"
fi
if [[ "$DELETE_SOURCES" == true ]]; then
	box_row_kv "Sources:" "delete after conversion ($DISC_CRUSHER_DELETE)" "" "$YELLOW"
else
	box_row_kv "Sources:" "preserved ($DISC_CRUSHER_DELETE)" "" "$GREEN"
fi
[[ "$OVERWRITE" == true ]] && box_row_kv "Existing:" "overwrite" "" "$YELLOW"
echo -e "${BLUE}${BOX_DIV}${NC}"
box_row_kv "To convert:" "$planned_convert"
[[ $planned_exists  -gt 0 ]] && box_row_kv "Already present:" "$planned_exists (use -f to redo)" "" "$YELLOW"
[[ $excluded_iso    -gt 0 ]] && box_row_kv "Track files skipped:" "$excluded_iso"
[[ $collisions      -gt 0 ]] && box_row_kv "Names disambiguated:" "$collisions" "" "$YELLOW"
[[ $shipped_playlists -gt 0 ]] && box_row_kv "Shipped playlists:" "$shipped_playlists" "" "$MAGENTA"
box_row_kv "Source size:" "$(format_bytes "$total_source_bytes")"
echo -e "${BLUE}${BOX_BOT}${NC}"
echo ""

# Rough headroom check: CHD typically lands near 60% of source. Only interesting
# when sources are being kept, since then nothing is reclaimed as we go.
if [[ "$DELETE_SOURCES" == false ]]; then
	avail=$(get_avail_bytes "$OUTPUT_DIR")
	estimate=$(( total_source_bytes * 6 / 10 ))
	if [[ -n "$avail" ]] && [[ $avail -lt $estimate ]]; then
		echo -e "${YELLOW}⚠ Output volume has $(format_bytes "$avail") free; estimated need is $(format_bytes "$estimate").${NC}"
		echo -e "${YELLOW}  Sources are being preserved, so nothing is reclaimed during the run.${NC}"
		echo ""
	fi
fi

if [[ $collisions -gt 0 || "$DRY_RUN" == true ]]; then
	for f in "${plan_inputs[@]}"; do
		if [[ "$DRY_RUN" == true ]]; then
			printf '%b%-8s%b %s\n' "$CYAN" "${plan_status[$f]}:" "$NC" "$(display_path "$f")"
			printf '         → %s\n' "$(basename "${plan_target[$f]}")"
		elif [[ "$(basename "${plan_target[$f]}")" != "${plan_plain[$f]}.chd" ]]; then
			printf '%b%-8s%b %s\n' "$YELLOW" "renamed:" "$NC" "$(display_path "$f")"
			printf '         → %s\n' "$(basename "${plan_target[$f]}")"
		fi
	done
	echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
	echo -e "${CYAN}Dry run — nothing written.${NC}"
	exit 0
fi

if ! mkdir -p "$OUTPUT_DIR"; then
	echo -e "${RED}Error: could not create output directory: $OUTPUT_DIR${NC}"
	exit 1
fi

# ┌─────────────────────────────────────────────────────────────┐
# │ Core conversion function                                    │
# └─────────────────────────────────────────────────────────────┘

# convert_disc <input_file> <output_chd> <forced_mode|""> [mode_reason]
# forced_mode : "cd" or "dvd" overrides detect_disc_mode for this file
# mode_reason : human-readable label for why the mode was chosen
#               "format"   — inherent to the file format (gdi/toc/nrg)
#               "fallback" — DVD failed, retried as CD
#               ""         — auto-detected or flag-forced (derived from FORCE_MODE)
convert_disc() {
	local disc_file="$1"
	local chd_file="$2"
	local forced_mode="${3:-}"
	local mode_reason="${4:-}"

	echo -e "${YELLOW}Converting :${NC} $(display_path "$disc_file")"
	# The destination directory is already stated in the plan header, so only
	# call out the name when a collision forced it to change.
	[[ "$(basename "$chd_file")" != "${plan_plain[$disc_file]}.chd" ]] && \
		echo -e "${CYAN}Renamed    :${NC} $(basename "$chd_file")"

	[[ -f "$chd_file" ]] && rm "$chd_file"

	# Detect mode for this specific file
	local mode
	if [[ -n "$forced_mode" ]]; then
		mode="$forced_mode"
	else
		mode=$(detect_disc_mode "$disc_file")
	fi

	echo -e "${CYAN}Mode       :${NC} $mode ($(
		if   [[ -n "$FORCE_MODE" ]];             then echo "forced via --$FORCE_MODE flag"
		elif [[ "$mode_reason" == "format"   ]]; then echo "inherent to format"
		elif [[ "$mode_reason" == "fallback" ]]; then echo "DVD failed, retried as CD"
		else                                          echo "auto-detected"
		fi
	))"

	# Lazy DVD availability check — only fail here if we actually need it
	if [[ "$mode" == "dvd" ]] && [[ "$CREATEDVD_AVAILABLE" == false ]]; then
		echo -e "${RED}✗ DVD mode requires chdman >= 0.255 (found $CHDMAN_VERSION)${NC}"
		((failed_files++))
		return 1
	fi

	local original_size="${plan_size[$disc_file]}"
	local -a files_to_delete=()
	while IFS= read -r f; do files_to_delete+=("$f"); done < <(get_source_files "$disc_file")

	# Run chdman
	local start_time
	start_time=$(date +%s)
	local chdman_ok=false
	local used_fallback=false

	if [[ "$mode" == "dvd" ]]; then
		if chdman createdvd -i "$disc_file" -o "$chd_file" $HUNK_SIZE_FLAG; then
			chdman_ok=true
		else
			# DVD failed — retry as CD (unless mode was user-forced)
			if [[ -z "$FORCE_MODE" ]]; then
				echo -e "${YELLOW}⚠ DVD conversion failed — retrying as CD...${NC}"
				[[ -f "$chd_file" ]] && rm "$chd_file"
				if chdman createcd -i "$disc_file" -o "$chd_file"; then
					chdman_ok=true
					used_fallback=true
					mode_reason="fallback"
				fi
			fi
		fi
	else
		chdman createcd -i "$disc_file" -o "$chd_file" && chdman_ok=true
	fi

	local end_time
	end_time=$(date +%s)
	local duration=$(( end_time - start_time ))

	# Evaluate result
	if [[ "$chdman_ok" == true ]] && [[ -f "$chd_file" ]] && \
	   [[ $(get_file_size "$chd_file") -gt 1000 ]]; then

		local chd_size
		chd_size=$(get_file_size "$chd_file")
		local space_saved=$(( original_size - chd_size ))
		local compression_ratio
		compression_ratio=$(echo "scale=1; (1 - $chd_size / $original_size) * 100" | bc)

		if [[ "$used_fallback" == true ]]; then
			echo -e "${YELLOW}⚠ Converted via CD fallback:${NC} $(basename "$chd_file")"
		else
			echo -e "${GREEN}✓ Converted :${NC} $(basename "$chd_file")"
		fi
		echo -e "${CYAN}  Original  :${NC} $(format_bytes "$original_size")"
		echo -e "${CYAN}  Compressed:${NC} $(format_bytes "$chd_size")"
		echo -e "${CYAN}  Saved      :${NC} $(format_bytes "$space_saved") (${compression_ratio}% reduction)"
		echo -e "${CYAN}  Duration   :${NC} $(format_duration "$duration")"

		total_space_saved=$(( total_space_saved + space_saved ))

		if [[ "$used_fallback" == true ]]; then
			# Fallback: CHD was produced but something unexpected happened.
			# Preserve source files so the user can verify the result.
			echo -e "${YELLOW}  Source files preserved for manual verification.${NC}"
			((fallback_files++))
		elif [[ "$DELETE_SOURCES" == true ]]; then
			echo -e "${BLUE}  Removing source file(s):${NC}"
			for f in "${files_to_delete[@]}"; do
				rm "$f"
				echo -e "${BLUE}    Removed: $(basename "$f")${NC}"
			done
			echo -e "${GREEN}  Source file(s) deleted.${NC}"
			((converted_files++))
		else
			((converted_files++))
		fi
		return 0

	else
		echo -e "${RED}✗ Failed    :${NC} $(display_path "$disc_file")"
		[[ -f "$chd_file" ]] && rm "$chd_file"
		((failed_files++))
		return 1
	fi
}

# ┌─────────────────────────────────────────────────────────────┐
# │ M3U playlist generation                                     │
# │                                                             │
# │ Candidates are every planned input whose .chd exists once    │
# │ the run is over, not merely those converted this pass, so a  │
# │ rerun over a partially-converted tree still emits a complete │
# │ playlist.                                                   │
# └─────────────────────────────────────────────────────────────┘

create_m3u_playlists() {
	local m3u_count=0
	declare -A entries=()
	local f target chd group order

	for f in "${plan_inputs[@]}"; do
		target="${plan_target[$f]}"
		[[ -f "$target" ]] || continue
		chd=$(basename "$target")

		if [[ -n "${plan_group[$f]:-}" ]]; then
			group="${plan_group[$f]}"
			order="${plan_order[$f]}"
		else
			group=$(get_base_game_name "$chd")
			order=$(get_disc_number "$chd")
			[[ -z "$order" ]] && continue
		fi
		entries["$group"]+="${order}"$'\t'"${chd}"$'\n'
	done

	for group in "${!entries[@]}"; do
		local -a lines=()
		while IFS= read -r line; do
			[[ -n "$line" ]] && lines+=("$line")
		done <<< "${entries[$group]}"

		# A single-disc "set" needs no playlist
		[[ ${#lines[@]} -lt 2 ]] && continue

		local m3u_file="${OUTPUT_DIR}/${group}.m3u"
		echo -e "${MAGENTA}Playlist   :${NC} $(basename "$m3u_file")"
		: > "$m3u_file"
		while IFS=$'\t' read -r order chd; do
			echo "$chd" >> "$m3u_file"
			echo -e "${CYAN}  Added    :${NC} $chd"
		done < <(printf '%s\n' "${lines[@]}" | sort -n -k1,1 -t$'\t')

		((m3u_count++))
	done

	[[ $m3u_count -gt 0 ]] && echo -e "${GREEN}✓ Created $m3u_count M3U playlist(s)${NC}"
	return 0
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Main                                                        │
# └─────────────────────────────────────────────────────────────┘

for f in "${plan_inputs[@]}"; do
	((total_files++))
	if [[ "${plan_status[$f]}" == "exists" ]]; then
		echo -e "${YELLOW}Skipping   :${NC} $(basename "${plan_target[$f]}") already exists (use -f to overwrite)"
		echo ""
		((skipped_files++))
		continue
	fi
	convert_disc "$f" "${plan_target[$f]}" "${plan_forced[$f]}" "${plan_reason[$f]}"
	echo ""
done

echo -e "${HR}"
echo ""
create_m3u_playlists
echo ""

# ┌─────────────────────────────────────────────────────────────┐
# │ Summary                                                     │
# └─────────────────────────────────────────────────────────────┘
echo -e "${BLUE}${BOX_TOP}${NC}"
echo -e "${BLUE}$(box_row "Summary")${NC}"
echo -e "${BLUE}${BOX_SEP}${NC}"
echo -e "${BLUE}$(box_row "")${NC}"

total_outcome=$(( converted_files + fallback_files ))

box_row_kv "Total found:"     "$total_files"
box_row_kv "Converted:"       "$converted_files"       "" "$GREEN"

if [[ $skipped_files -gt 0 ]]; then
	box_row_kv "Skipped (exists):" "$skipped_files"     "" "$YELLOW"
fi

if [[ $fallback_files -gt 0 ]]; then
	box_row_kv "Fallback (verify):" "$fallback_files"   "" "$YELLOW"
fi

if [[ $failed_files -eq 0 ]]; then
	box_row_kv "Failed:"       "$failed_files"          "" "$GREEN"
else
	box_row_kv "Failed:"       "$failed_files"          "" "$RED"
fi

if [[ $total_outcome -gt 0 ]]; then
	box_row_kv "Space saved:"  "$(format_bytes "$total_space_saved")" "" "$CYAN"
fi

echo -e "${BLUE}$(box_row "")${NC}"
echo -e "${BLUE}${BOX_SEP}${NC}"

if [[ $failed_files -eq 0 && $fallback_files -eq 0 && $converted_files -eq $total_files ]]; then
	echo -e "${BLUE}$(box_row "All files converted successfully.")${NC}"
else
	if [[ $fallback_files -gt 0 ]]; then
		echo -e "${BLUE}$(box_row "Verify fallback CHD(s) before deleting sources.")${NC}"
	fi
	if [[ $failed_files -gt 0 ]]; then
		echo -e "${BLUE}$(box_row "Source files preserved for failed conversions.")${NC}"
	fi
	if [[ $failed_files -eq 0 && $fallback_files -eq 0 ]]; then
		echo -e "${BLUE}$(box_row "Run complete.")${NC}"
	fi
fi

if [[ "$DELETE_SOURCES" == false && $converted_files -gt 0 ]]; then
	echo -e "${BLUE}$(box_row "Source files preserved (--delete $DISC_CRUSHER_DELETE).")${NC}"
fi

echo -e "${BLUE}$(box_row "")${NC}"
echo -e "${BLUE}${BOX_BOT}${NC}"
