#!/bin/bash

# DiscSquasher - ISO/CUE to CHD Converter Script
# Converts CD-based disc images to .chd format using chdman
# Designed for PSX, Saturn, PC-Engine CD, and other CD-based systems
# Automatically creates .m3u playlists for multi-disc games

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Counters
total_files=0
converted_files=0
failed_files=0
total_space_saved=0

# Arrays to track converted games for M3U generation
declare -A game_discs

# Track files referenced by .cue files to avoid duplicate processing
declare -A cue_referenced_files

# Command line options
OVERWRITE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		-f|--force|--overwrite)
			OVERWRITE=true
			shift
			;;
		-h|--help)
			echo "DiscSquasher - ISO/CUE to CHD Converter"
			echo ""
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  -f, --force, --overwrite    Overwrite existing CHD files"
			echo "  -h, --help                  Show this help message"
			echo ""
			echo "Converts all .iso/.cue files in the current directory to .chd format"
			echo "and removes the original files after successful conversion."
			echo "Automatically creates .m3u playlists for multi-disc games."
			echo "Designed for PSX, Saturn, PC-Engine CD, and other CD-based systems."
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Use -h or --help for usage information"
			exit 1
			;;
	esac
done

echo -e "${BLUE}DiscSquasher - ISO/CUE to CHD Converter${NC}"
echo "========================================"

# Check if chdman is available
if ! command -v chdman &> /dev/null; then
	echo -e "${RED}Error: chdman not found in PATH${NC}"
	echo "Please install MAME tools or add chdman to your PATH"
	exit 1
fi

# Get chdman version
CHDMAN_VERSION=$(chdman --help 2>&1 | head -1 | grep -o 'v\?[0-9]\+\.[0-9]\+' | head -1 | sed 's/^v//')
if [[ -z "$CHDMAN_VERSION" ]]; then
	echo -e "${RED}Error: Could not determine chdman version${NC}"
	exit 1
fi

echo "Detected chdman version: $CHDMAN_VERSION"
echo ""

# Function to get file size in bytes
get_file_size() {
	local file="$1"
	# Try BSD stat first (macOS), then GNU stat (Linux)
	stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null
}

# Function to format bytes to human readable
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

# Function to format time duration
format_duration() {
	local total_seconds=$1
	local hours=$((total_seconds / 3600))
	local minutes=$(( (total_seconds % 3600) / 60 ))
	local seconds=$((total_seconds % 60))

	if [[ $hours -gt 0 ]]; then
		printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
	elif [[ $minutes -gt 0 ]]; then
		printf "%dm %ds" "$minutes" "$seconds"
	else
		printf "%ds" "$seconds"
	fi
}

# Function to extract base game name (without disc number)
get_base_game_name() {
	local filename="$1"
	# Remove extension first
	local base="${filename%.*}"

	# Remove disc/CD number patterns in various formats with a single comprehensive pattern:
	# - Bracketed: (Disc 1), [CD 1], {Disc 2}
	# - Separated: - Disc 1, _CD1, -Disc1, _CD 2
	# - Compact: disc1, CD1, DISC1, cd 01
	# The pattern matches: optional spaces, then either (separator+spaces) or (optional bracket),
	# then "disc" or "cd" (case insensitive), optional spaces, digits, optional closing bracket, optional trailing spaces
	base=$(echo "$base" | sed -E 's/[[:space:]]*(([-_]+[[:space:]]*)|[][{(]?)([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*[0-9]+[])}]?[[:space:]]*$//')

	echo "$base"
}

# Function to extract disc number from filename
get_disc_number() {
	local filename="$1"
	# Look for disc/CD number patterns - handle various formats
	# Matches: disc 1, cd1, CD 01, DISC 1, etc.
	if [[ "$filename" =~ ([Dd][Ii][Ss][Cc]|[Cc][Dd])[[:space:]]*([0-9]+) ]]; then
		echo "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

# Function to get all files referenced by a .cue file
get_cue_referenced_files() {
	local cue_file="$1"
	local cue_dir=$(dirname "$cue_file")
	local -a referenced_files=()

	while IFS= read -r line; do
		# Match FILE lines - handle both quoted and unquoted filenames
		# Also match various file types: BINARY, MOTOROLA, AIFF, WAVE, MP3
		if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
			local ref_file="${BASH_REMATCH[1]}"
			# Convert to absolute path relative to cue directory
			local full_path="${cue_dir}/${ref_file}"
			if [[ -f "$full_path" ]]; then
				referenced_files+=("$full_path")
			fi
		fi
	done < "$cue_file"

	printf '%s\n' "${referenced_files[@]}"
}

# Function to convert a single disc image
convert_disc() {
	local disc_file="$1"
	# Remove extension case-insensitively
	local base_name="$disc_file"
	if [[ "$disc_file" =~ \.[Ii][Ss][Oo]$ ]]; then
		base_name="${disc_file%.[Ii][Ss][Oo]}"
	elif [[ "$disc_file" =~ \.[Cc][Uu][Ee]$ ]]; then
		base_name="${disc_file%.[Cc][Uu][Ee]}"
	fi
	local chd_file="${base_name}.chd"

	echo -e "${YELLOW}Converting:${NC} $disc_file"

	# Check if CHD file already exists
	if [[ -f "$chd_file" ]] && [[ "$OVERWRITE" == false ]]; then
		echo -e "${YELLOW}Warning:${NC} $chd_file already exists, skipping... (use -f to overwrite)"
		return 1
	elif [[ -f "$chd_file" ]] && [[ "$OVERWRITE" == true ]]; then
		echo -e "${YELLOW}Overwriting existing file:${NC} $chd_file"
		rm "$chd_file"
	fi

	# Get original file size (for .cue, sum all associated files)
	local original_size=0
	local -a files_to_delete=()

	if [[ "$disc_file" =~ \.[Cc][Uu][Ee]$ ]]; then
		# Parse .cue file to find all referenced files and sum their sizes
		files_to_delete+=("$disc_file")
		local cue_dir=$(dirname "$disc_file")
		while IFS= read -r line; do
			if [[ "$line" =~ FILE[[:space:]]+\"([^\"]+)\" ]] || [[ "$line" =~ FILE[[:space:]]+([^[:space:]]+)[[:space:]] ]]; then
				local ref_file="${cue_dir}/${BASH_REMATCH[1]}"
				if [[ -f "$ref_file" ]]; then
					local file_size=$(get_file_size "$ref_file")
					original_size=$((original_size + file_size))
					files_to_delete+=("$ref_file")
				fi
			fi
		done < "$disc_file"
	else
		original_size=$(get_file_size "$disc_file")
		files_to_delete+=("$disc_file")
	fi

	# Start timing
	local start_time=$(date +%s)

	# Run chdman conversion
	if chdman createcd -i "$disc_file" -o "$chd_file"; then
		# End timing
		local end_time=$(date +%s)
		local duration=$((end_time - start_time))

		# Verify the CHD file was created and has reasonable size
		if [[ -f "$chd_file" ]] && [[ $(get_file_size "$chd_file") -gt 1000 ]]; then
			local chd_size=$(get_file_size "$chd_file")
			local space_saved=$((original_size - chd_size))
			local compression_ratio=$(echo "scale=1; (1 - $chd_size / $original_size) * 100" | bc)

			echo -e "${GREEN}✓ Successfully converted:${NC} $chd_file"
			echo -e "${CYAN}  Original size:${NC}  $(format_bytes $original_size)"
			echo -e "${CYAN}  Compressed:${NC}    $(format_bytes $chd_size)"
			echo -e "${CYAN}  Space saved:${NC}   $(format_bytes $space_saved) (${compression_ratio}% reduction)"
			echo -e "${CYAN}  Time taken:${NC}    $(format_duration $duration)"

			# Track total space saved
			total_space_saved=$((total_space_saved + space_saved))

			# Track this disc for M3U generation
			local base_game=$(get_base_game_name "$(basename "$chd_file")")
			local disc_num=$(get_disc_number "$(basename "$chd_file")")
			if [[ -n "$disc_num" ]]; then
				# Store disc with its number for sorting later
				game_discs["${base_game}"]="${game_discs["${base_game}"]}|${disc_num}:$(basename "$chd_file")"
			fi

			# Remove original file(s)
			echo -e "${BLUE}Removing original file(s):${NC}"
			for file in "${files_to_delete[@]}"; do
				rm "$file"
				echo -e "${BLUE}  Removed:${NC} $(basename "$file")"
			done
			echo -e "${GREEN}✓ Original file(s) deleted${NC}"
			((converted_files++))
			return 0
		else
			echo -e "${RED}✗ CHD file seems invalid, keeping original${NC}"
			[[ -f "$chd_file" ]] && rm "$chd_file"
			((failed_files++))
			return 1
		fi
	else
		echo -e "${RED}✗ Failed to convert:${NC} $disc_file"
		[[ -f "$chd_file" ]] && rm "$chd_file"  # Clean up partial file
		((failed_files++))
		return 1
	fi
}

# Function to create M3U playlists for multi-disc games
create_m3u_playlists() {
	local m3u_count=0

	for game_base in "${!game_discs[@]}"; do
		# Parse the disc list for this game
		IFS='|' read -ra disc_array <<< "${game_discs[$game_base]}"

		# Skip if only one disc (no need for M3U)
		if [[ ${#disc_array[@]} -le 2 ]]; then  # <= 2 because first element is empty due to leading |
			continue
		fi

		# Sort discs by disc number
		declare -A sorted_discs
		for disc_entry in "${disc_array[@]}"; do
			if [[ -n "$disc_entry" ]]; then
				IFS=':' read -r disc_num disc_file <<< "$disc_entry"
				sorted_discs[$disc_num]="$disc_file"
			fi
		done

		# Create M3U file
		local m3u_file="${game_base}.m3u"
		echo -e "${MAGENTA}Creating M3U playlist:${NC} $m3u_file"

		> "$m3u_file"  # Create/truncate file
		for disc_num in $(echo "${!sorted_discs[@]}" | tr ' ' '\n' | sort -n); do
			echo "${sorted_discs[$disc_num]}" >> "$m3u_file"
			echo -e "${CYAN}  Added:${NC} ${sorted_discs[$disc_num]}"
		done

		((m3u_count++))
		unset sorted_discs
	done

	if [[ $m3u_count -gt 0 ]]; then
		echo -e "${GREEN}✓ Created ${m3u_count} M3U playlist(s)${NC}"
		echo ""
	fi
}

# Main conversion loop
echo "Searching for .iso/.cue files in current directory..."
if [[ "$OVERWRITE" == true ]]; then
	echo -e "${YELLOW}Overwrite mode enabled - existing CHD files will be replaced${NC}"
fi
echo ""

# PHASE 1: Parse all .cue files and track their referenced files
echo "Parsing .cue files to identify referenced images..."
while IFS= read -r -d '' cue_file; do
	while IFS= read -r ref_file; do
		# Normalize path and mark as referenced
		ref_file=$(realpath "$ref_file" 2>/dev/null || echo "$ref_file")
		cue_referenced_files["$ref_file"]=1
	done < <(get_cue_referenced_files "$cue_file")
done < <(find . -maxdepth 1 -iname "*.cue" -print0)

if [[ ${#cue_referenced_files[@]} -gt 0 ]]; then
	echo -e "${CYAN}Found ${#cue_referenced_files[@]} file(s) referenced by .cue files${NC}"
fi
echo ""

# PHASE 2: Process all .cue files
while IFS= read -r -d '' cue_file; do
	((total_files++))
	convert_disc "$cue_file"
	echo ""  # Add spacing between files
done < <(find . -maxdepth 1 -iname "*.cue" -print0)

# PHASE 3: Process standalone .iso files (not referenced by any .cue)
while IFS= read -r -d '' iso_file; do
	# Normalize path for comparison
	iso_path=$(realpath "$iso_file" 2>/dev/null || echo "$iso_file")

	# Skip if this ISO is referenced by a .cue file
	if [[ -n "${cue_referenced_files[$iso_path]}" ]]; then
		echo -e "${CYAN}Skipping $iso_file (referenced by .cue file)${NC}"
		echo ""
		continue
	fi

	((total_files++))
	convert_disc "$iso_file"
	echo ""  # Add spacing between files
done < <(find . -maxdepth 1 -iname "*.iso" -print0)

# Generate M3U playlists for multi-disc games
if [[ ${#game_discs[@]} -gt 0 ]]; then
	echo "========================================"
	create_m3u_playlists
fi

# Summary
echo "========================================"
echo -e "${BLUE}Conversion Summary:${NC}"
echo -e "Total disc files found: ${total_files}"
echo -e "${GREEN}Successfully converted: ${converted_files}${NC}"
if [[ $failed_files -eq 0 ]]; then
	echo -e "${GREEN}Failed conversions: ${failed_files}${NC}"
else
	echo -e "${RED}Failed conversions: ${failed_files}${NC}"
fi

if [[ $converted_files -gt 0 ]]; then
	echo -e "${CYAN}Total space saved: $(format_bytes $total_space_saved)${NC}"
fi

if [[ $total_files -eq 0 ]]; then
	echo -e "${YELLOW}No disc image files found in current directory${NC}"
elif [[ $converted_files -eq $total_files ]]; then
	echo -e "${GREEN}All files converted successfully!${NC}"
elif [[ $failed_files -gt 0 ]]; then
	echo -e "${YELLOW}Some files failed to convert. Original files preserved for failed conversions.${NC}"
fi
