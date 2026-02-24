#!/bin/bash

# Disc Crusher - Universal Disc Image to CHD Converter
# Converts disc images (.iso, .cue, .toc, .gdi, .nrg) to .chd format using chdman
# Automatically detects CD vs DVD format via header inspection
# Supports: PSX, Saturn, Dreamcast, PS2, PSP, PC-Engine CD, and more
# Automatically creates .m3u playlists for multi-disc games

# ┌─────────────────────────────────────────────────────────────┐
# │ Color codes                                                  │
# └─────────────────────────────────────────────────────────────┘
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ┌─────────────────────────────────────────────────────────────┐
# │ Box drawing constants (60 chars wide)                        │
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
# │ Counters                                                     │
# └─────────────────────────────────────────────────────────────┘
total_files=0
converted_files=0
failed_files=0
fallback_files=0
total_space_saved=0

# Arrays for M3U generation and deduplication
declare -A game_discs
declare -A cue_referenced_files  # tracks files referenced by .cue/.gdi to avoid double-processing

# ┌─────────────────────────────────────────────────────────────┐
# │ Runtime state                                                │
# └─────────────────────────────────────────────────────────────┘
CHDMAN_MAJOR=0
CHDMAN_MINOR=0
HUNK_SIZE_FLAG=""
CREATEDVD_AVAILABLE=false

# ┌─────────────────────────────────────────────────────────────┐
# │ Command line options                                         │
# └─────────────────────────────────────────────────────────────┘
OVERWRITE=false
FORCE_MODE=""  # "cd", "dvd", or "" for auto-detect

while [[ $# -gt 0 ]]; do
	case $1 in
		-f|--force|--overwrite)
			OVERWRITE=true
			shift
			;;
		--cd)
			FORCE_MODE="cd"
			shift
			;;
		--dvd)
			FORCE_MODE="dvd"
			shift
			;;
		-h|--help)
			echo "$BOX_TOP"
			box_row "Disc Crusher - Universal CHD Converter"
			echo "$BOX_BOT"
			echo ""
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --cd                        Force CD mode for all files (createcd)"
			echo "  --dvd                       Force DVD mode for all files (createdvd)"
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
			echo "  1. .gdi / .toc / .nrg extension  → always CD"
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
			echo "Automatically creates .m3u playlists for multi-disc games."
			echo "Requires chdman (MAME tools) in PATH."
			echo "DVD mode (PS2/PSP) requires chdman >= 0.255."
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Use -h or --help for usage information"
			exit 1
			;;
	esac
done

# ┌─────────────────────────────────────────────────────────────┐
# │ Banner                                                       │
# └─────────────────────────────────────────────────────────────┘
echo -e "${BLUE}${BOX_TOP}${NC}"
echo -e "${BLUE}$(box_row "Disc Crusher - Universal CHD Converter")${NC}"
echo -e "${BLUE}$(box_row "ISO · CUE · TOC · GDI · NRG  →  CHD")${NC}"
echo -e "${BLUE}${BOX_BOT}${NC}"
echo ""

# ┌─────────────────────────────────────────────────────────────┐
# │ Dependency check                                             │
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
# │ Utility functions                                            │
# └─────────────────────────────────────────────────────────────┘

get_file_size() {
	stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
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
	base=$(echo "$base" | sed -E 's/[[:space:]]*(([-_]+[[:space:]]*)|[][{(]?)([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*[0-9]+[])}]?[[:space:]]*$//')
	echo "$base"
}

# Extract disc number from filename (returns empty string if not found)
get_disc_number() {
	if [[ "$1" =~ ([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*([0-9]+) ]]; then
		echo "${BASH_REMATCH[2]}"
	fi
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Referenced-file parsers (CUE and GDI)                        │
# └─────────────────────────────────────────────────────────────┘

get_cue_referenced_files() {
	local cue_file="$1"
	local cue_dir=$(dirname "$cue_file")
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
	local gdi_dir=$(dirname "$gdi_file")
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
	local toc_dir=$(dirname "$toc_file")
	while IFS= read -r line; do
		# Match: DATAFILE "name" / AUDIOFILE "name" / FILE "name"
		if [[ "$line" =~ ^[[:space:]]*(DATAFILE|AUDIOFILE|FILE)[[:space:]]+\"([^\"]+)\" ]]; then
			local full="${toc_dir}/${BASH_REMATCH[2]}"
			[[ -f "$full" ]] && echo "$full"
		fi
	done < "$toc_file"
}

# Sum sizes of all files referenced by a CUE sheet
get_cue_total_size() {
	local cue_file="$1"
	local cue_dir=$(dirname "$cue_file")
	local total=0
	while IFS= read -r line; do
		if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || \
		   [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
			local full="${cue_dir}/${BASH_REMATCH[1]}"
			if [[ -f "$full" ]]; then
				local sz=$(get_file_size "$full")
				total=$((total + sz))
			fi
		fi
	done < "$cue_file"
	echo "$total"
}

# Sum sizes of all track files referenced by a GDI
get_gdi_total_size() {
	local gdi_file="$1"
	local gdi_dir=$(dirname "$gdi_file")
	local total=0
	local line_num=0
	while IFS= read -r line; do
		((line_num++))
		[[ $line_num -eq 1 ]] && continue
		local fields=($line)
		local fname="${fields[4]}"
		[[ -z "$fname" ]] && continue
		local full="${gdi_dir}/${fname}"
		if [[ -f "$full" ]]; then
			local sz=$(get_file_size "$full")
			total=$((total + sz))
		fi
	done < "$gdi_file"
	echo "$total"
}

get_toc_total_size() {
	local toc_file="$1"
	local toc_dir=$(dirname "$toc_file")
	local total=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*(DATAFILE|AUDIOFILE|FILE)[[:space:]]+\"([^\"]+)\" ]]; then
			local full="${toc_dir}/${BASH_REMATCH[2]}"
			if [[ -f "$full" ]]; then
				local sz=$(get_file_size "$full")
				total=$(( total + sz ))
			fi
		fi
	done < "$toc_file"
	echo "$total"
}

# Build the list of files to delete for a given image
get_files_to_delete_cue() {
	local cue_file="$1"
	local cue_dir=$(dirname "$cue_file")
	echo "$cue_file"
	while IFS= read -r line; do
		if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || \
		   [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
			local full="${cue_dir}/${BASH_REMATCH[1]}"
			[[ -f "$full" ]] && echo "$full"
		fi
	done < "$cue_file"
}

get_files_to_delete_gdi() {
	local gdi_file="$1"
	local gdi_dir=$(dirname "$gdi_file")
	echo "$gdi_file"
	local line_num=0
	while IFS= read -r line; do
		((line_num++))
		[[ $line_num -eq 1 ]] && continue
		local fields=($line)
		local fname="${fields[4]}"
		[[ -z "$fname" ]] && continue
		local full="${gdi_dir}/${fname}"
		[[ -f "$full" ]] && echo "$full"
	done < "$gdi_file"
}

get_files_to_delete_toc() {
	local toc_file="$1"
	local toc_dir=$(dirname "$toc_file")
	echo "$toc_file"
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*(DATAFILE|AUDIOFILE|FILE)[[:space:]]+\"([^\"]+)\" ]]; then
			local full="${toc_dir}/${BASH_REMATCH[2]}"
			[[ -f "$full" ]] && echo "$full"
		fi
	done < "$toc_file"
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Format detection                                             │
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
# │ Core conversion function                                     │
# └─────────────────────────────────────────────────────────────┘

# convert_disc <input_file> <forced_mode|""> [mode_reason]
# forced_mode : "cd" or "dvd" overrides detect_disc_mode for this file
# mode_reason : human-readable label for why the mode was chosen
#               "format"   — inherent to the file format (gdi/toc/nrg)
#               "fallback" — DVD failed, retried as CD
#               ""         — auto-detected or flag-forced (derived from FORCE_MODE)
convert_disc() {
	local disc_file="$1"
	local forced_mode="${2:-}"
	local mode_reason="${3:-}"

	# Determine CHD output path (strip extension case-insensitively)
	local base_name="$disc_file"
	local lower_file
	lower_file=$(echo "$disc_file" | tr '[:upper:]' '[:lower:]')
	for ext in iso cue gdi toc nrg; do
		if [[ "$lower_file" == *."$ext" ]]; then
			base_name="${disc_file%.*}"
			break
		fi
	done
	local chd_file="${base_name}.chd"

	echo -e "${YELLOW}Converting :${NC} $disc_file"

	# Overwrite check
	if [[ -f "$chd_file" ]] && [[ "$OVERWRITE" == false ]]; then
		echo -e "${YELLOW}Skipping   :${NC} $chd_file already exists (use -f to overwrite)"
		return 1
	elif [[ -f "$chd_file" ]] && [[ "$OVERWRITE" == true ]]; then
		echo -e "${YELLOW}Overwriting:${NC} $chd_file"
		rm "$chd_file"
	fi

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

	# Collect original file list and total size
	local ext
	ext=$(echo "${disc_file##*.}" | tr '[:upper:]' '[:lower:]')
	local original_size=0
	local -a files_to_delete=()

	if [[ "$ext" == "cue" ]]; then
		original_size=$(get_cue_total_size "$disc_file")
		while IFS= read -r f; do files_to_delete+=("$f"); done < <(get_files_to_delete_cue "$disc_file")
	elif [[ "$ext" == "gdi" ]]; then
		original_size=$(get_gdi_total_size "$disc_file")
		while IFS= read -r f; do files_to_delete+=("$f"); done < <(get_files_to_delete_gdi "$disc_file")
	elif [[ "$ext" == "toc" ]]; then
		original_size=$(get_toc_total_size "$disc_file")
		while IFS= read -r f; do files_to_delete+=("$f"); done < <(get_files_to_delete_toc "$disc_file")
	else
		# .iso and .nrg are self-contained — single file
		original_size=$(get_file_size "$disc_file")
		files_to_delete+=("$disc_file")
	fi

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
			echo -e "${YELLOW}⚠ Converted via CD fallback:${NC} $chd_file"
		else
			echo -e "${GREEN}✓ Converted :${NC} $chd_file"
		fi
		echo -e "${CYAN}  Original  :${NC} $(format_bytes "$original_size")"
		echo -e "${CYAN}  Compressed:${NC} $(format_bytes "$chd_size")"
		echo -e "${CYAN}  Saved      :${NC} $(format_bytes "$space_saved") (${compression_ratio}% reduction)"
		echo -e "${CYAN}  Duration   :${NC} $(format_duration "$duration")"

		total_space_saved=$(( total_space_saved + space_saved ))

		# M3U tracking
		local base_game
		base_game=$(get_base_game_name "$(basename "$chd_file")")
		local disc_num
		disc_num=$(get_disc_number "$(basename "$chd_file")")
		if [[ -n "$disc_num" ]]; then
			game_discs["${base_game}"]="${game_discs["${base_game}"]}|${disc_num}:$(basename "$chd_file")"
		fi

		if [[ "$used_fallback" == true ]]; then
			# Fallback: CHD was produced but something unexpected happened.
			# Preserve source files so the user can verify the result.
			echo -e "${YELLOW}  Source files preserved for manual verification.${NC}"
			((fallback_files++))
		else
			echo -e "${BLUE}  Removing source file(s):${NC}"
			for f in "${files_to_delete[@]}"; do
				rm "$f"
				echo -e "${BLUE}    Removed: $(basename "$f")${NC}"
			done
			echo -e "${GREEN}  Source file(s) deleted.${NC}"
			((converted_files++))
		fi
		return 0

	else
		echo -e "${RED}✗ Failed    :${NC} $disc_file"
		[[ -f "$chd_file" ]] && rm "$chd_file"
		((failed_files++))
		return 1
	fi
}

# ┌─────────────────────────────────────────────────────────────┐
# │ M3U playlist generation                                      │
# └─────────────────────────────────────────────────────────────┘

create_m3u_playlists() {
	local m3u_count=0

	for game_base in "${!game_discs[@]}"; do
		IFS='|' read -ra disc_array <<< "${game_discs[$game_base]}"

		# <= 2 entries means the array is just the leading empty element + one disc
		[[ ${#disc_array[@]} -le 2 ]] && continue

		declare -A sorted_discs
		for entry in "${disc_array[@]}"; do
			[[ -z "$entry" ]] && continue
			IFS=':' read -r disc_num disc_file <<< "$entry"
			sorted_discs[$disc_num]="$disc_file"
		done

		local m3u_file="${game_base}.m3u"
		echo -e "${MAGENTA}Playlist   :${NC} $m3u_file"
		> "$m3u_file"
		for disc_num in $(echo "${!sorted_discs[@]}" | tr ' ' '\n' | sort -n); do
			echo "${sorted_discs[$disc_num]}" >> "$m3u_file"
			echo -e "${CYAN}  Added    :${NC} ${sorted_discs[$disc_num]}"
		done

		((m3u_count++))
		unset sorted_discs
	done

	[[ $m3u_count -gt 0 ]] && echo -e "${GREEN}✓ Created $m3u_count M3U playlist(s)${NC}"
}

# ┌─────────────────────────────────────────────────────────────┐
# │ Main                                                         │
# └─────────────────────────────────────────────────────────────┘

echo "Searching for disc images in current directory..."
[[ "$OVERWRITE" == true ]] && echo -e "${YELLOW}Overwrite mode enabled.${NC}"
echo ""

# ── Phase 1: Register all files referenced by .cue, .toc, and .gdi ──────────

echo -e "${CYAN}Phase 1/6: Scanning manifests (.cue, .toc, .gdi)...${NC}"
while IFS= read -r -d '' cue_file; do
	while IFS= read -r ref; do
		ref=$(realpath "$ref" 2>/dev/null || echo "$ref")
		cue_referenced_files["$ref"]=1
	done < <(get_cue_referenced_files "$cue_file")
done < <(find . -maxdepth 1 -iname "*.cue" -print0)

while IFS= read -r -d '' toc_file; do
	while IFS= read -r ref; do
		ref=$(realpath "$ref" 2>/dev/null || echo "$ref")
		cue_referenced_files["$ref"]=1
	done < <(get_toc_referenced_files "$toc_file")
done < <(find . -maxdepth 1 -iname "*.toc" -print0)

while IFS= read -r -d '' gdi_file; do
	while IFS= read -r ref; do
		ref=$(realpath "$ref" 2>/dev/null || echo "$ref")
		cue_referenced_files["$ref"]=1
	done < <(get_gdi_referenced_files "$gdi_file")
done < <(find . -maxdepth 1 -iname "*.gdi" -print0)

if [[ ${#cue_referenced_files[@]} -gt 0 ]]; then
	echo -e "  ${#cue_referenced_files[@]} referenced track file(s) will be excluded from standalone ISO scan."
fi
echo ""

# ── Phase 2: Process .gdi files (always CD) ──────────────────────────────────

echo -e "${CYAN}Phase 2/6: Processing .gdi files...${NC}"
echo ""
_gdi_count=0
while IFS= read -r -d '' gdi_file; do
	(( _gdi_count++ )) || true
done < <(find . -maxdepth 1 -iname "*.gdi" -print0)

if [[ $_gdi_count -eq 0 ]]; then
	echo "  No .gdi files found."
	echo ""
else
	while IFS= read -r -d '' gdi_file; do
		((total_files++))
		convert_disc "$gdi_file" "cd" "format"
		echo ""
	done < <(find . -maxdepth 1 -iname "*.gdi" -print0)
fi

# ── Phase 3: Process .cue files ──────────────────────────────────────────────

echo -e "${CYAN}Phase 3/6: Processing .cue files...${NC}"
echo ""
_cue_count=0
while IFS= read -r -d '' f; do
	(( _cue_count++ )) || true
done < <(find . -maxdepth 1 -iname "*.cue" -print0)

if [[ $_cue_count -eq 0 ]]; then
	echo "  No .cue files found."
	echo ""
else
	while IFS= read -r -d '' cue_file; do
		((total_files++))
		convert_disc "$cue_file"
		echo ""
	done < <(find . -maxdepth 1 -iname "*.cue" -print0)
fi

# ── Phase 4: Process .toc files (always CD) ──────────────────────────────────

echo -e "${CYAN}Phase 4/6: Processing .toc files...${NC}"
echo ""
_toc_count=0
while IFS= read -r -d '' f; do
	(( _toc_count++ )) || true
done < <(find . -maxdepth 1 -iname "*.toc" -print0)

if [[ $_toc_count -eq 0 ]]; then
	echo "  No .toc files found."
	echo ""
else
	while IFS= read -r -d '' toc_file; do
		((total_files++))
		convert_disc "$toc_file" "cd" "format"
		echo ""
	done < <(find . -maxdepth 1 -iname "*.toc" -print0)
fi

# ── Phase 5: Process .nrg files (always CD, self-contained) ──────────────────

echo -e "${CYAN}Phase 5/6: Processing .nrg files...${NC}"
echo ""
_nrg_count=0
while IFS= read -r -d '' f; do
	(( _nrg_count++ )) || true
done < <(find . -maxdepth 1 -iname "*.nrg" -print0)

if [[ $_nrg_count -eq 0 ]]; then
	echo "  No .nrg files found."
	echo ""
else
	while IFS= read -r -d '' nrg_file; do
		((total_files++))
		convert_disc "$nrg_file" "cd" "format"
		echo ""
	done < <(find . -maxdepth 1 -iname "*.nrg" -print0)
fi

# ── Phase 6: Process standalone .iso files ───────────────────────────────────

echo -e "${CYAN}Phase 6/6: Processing standalone .iso files...${NC}"
echo ""
_iso_found=0
while IFS= read -r -d '' iso_file; do
	iso_path=$(realpath "$iso_file" 2>/dev/null || echo "$iso_file")
	if [[ -n "${cue_referenced_files[$iso_path]}" ]]; then
		echo -e "${CYAN}Skipping   :${NC} $iso_file (referenced by a manifest)"
		echo ""
		continue
	fi
	(( _iso_found++ ))
	((total_files++))
	convert_disc "$iso_file"
	echo ""
done < <(find . -maxdepth 1 -iname "*.iso" -print0)

if [[ $_iso_found -eq 0 ]]; then
	echo "  No standalone .iso files found."
	echo ""
fi

# ── M3U playlists ─────────────────────────────────────────────────────────────

if [[ ${#game_discs[@]} -gt 0 ]]; then
	echo -e "${HR}"
	echo ""
	create_m3u_playlists
	echo ""
fi

# ┌─────────────────────────────────────────────────────────────┐
# │ Summary                                                      │
# └─────────────────────────────────────────────────────────────┘
echo -e "${BLUE}${BOX_TOP}${NC}"
echo -e "${BLUE}$(box_row "Summary")${NC}"
echo -e "${BLUE}${BOX_SEP}${NC}"
echo -e "${BLUE}$(box_row "")${NC}"

total_outcome=$(( converted_files + fallback_files ))

box_row_kv "Total found:"     "$total_files"
box_row_kv "Converted:"       "$converted_files"       "" "$GREEN"

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

if [[ $total_files -eq 0 ]]; then
	echo -e "${BLUE}$(box_row "No disc images found in current directory.")${NC}"
elif [[ $failed_files -eq 0 && $fallback_files -eq 0 && $converted_files -eq $total_files ]]; then
	echo -e "${BLUE}$(box_row "All files converted successfully.")${NC}"
else
	if [[ $fallback_files -gt 0 ]]; then
		echo -e "${BLUE}$(box_row "Verify fallback CHD(s) before deleting sources.")${NC}"
	fi
	if [[ $failed_files -gt 0 ]]; then
		echo -e "${BLUE}$(box_row "Source files preserved for failed conversions.")${NC}"
	fi
fi

echo -e "${BLUE}$(box_row "")${NC}"
echo -e "${BLUE}${BOX_BOT}${NC}"
