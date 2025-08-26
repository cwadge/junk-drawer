#!/bin/bash

# PS2/PSP Disc Shrink Ray - ISO/CUE to CHD Converter Script
# Converts .iso/.cue files to .chd format using chdman and removes original files after successful conversion
# Designed for PS2 and PSP disc images with proper 2K sector alignment

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
total_files=0
converted_files=0
failed_files=0

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
			echo "PS2/PSP Disc Shrink Ray - ISO/CUE to CHD Converter"
			echo ""
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  -f, --force, --overwrite    Overwrite existing CHD files"
			echo "  -h, --help                  Show this help message"
			echo ""
			echo "Converts all .iso/.cue files in the current directory to .chd format"
			echo "and removes the original files after successful conversion."
			echo "Designed for PS2 and PSP disc images with proper 2K sector alignment."
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Use -h or --help for usage information"
			exit 1
			;;
	esac
done

echo -e "${BLUE}PS2/PSP Disc Shrink Ray - ISO/CUE to CHD Converter${NC}"
echo "=================================="

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

# Parse version numbers for comparison
IFS='.' read -ra VERSION_PARTS <<< "$CHDMAN_VERSION"
MAJOR=${VERSION_PARTS[0]:-0}
MINOR=${VERSION_PARTS[1]:-0}

# Check if version is at least 0.255 (required for createdvd)
if [[ $MAJOR -eq 0 && $MINOR -lt 255 ]]; then
	echo -e "${RED}Error: chdman version $CHDMAN_VERSION is too old${NC}"
	echo "This script requires chdman 0.255 or later for DVD creation support"
	exit 1
fi

# Determine if we need -hs 2048 flag for PS2/PSP compatibility (version >= 0.263)
HUNK_SIZE_FLAG=""
if [[ $MAJOR -gt 0 || ($MAJOR -eq 0 && $MINOR -ge 263) ]]; then
	HUNK_SIZE_FLAG="-hs 2048"
	echo -e "${YELLOW}Note: Using -hs 2048 for PS2/PSP compatibility (chdman >= 0.263)${NC}"
fi

# Function to convert a single ISO file
convert_iso() {
	local disc_file="$1"
	# Remove .iso or .cue extension case-insensitively
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

    # Run chdman conversion
    if chdman createdvd -i "$disc_file" -o "$chd_file" $HUNK_SIZE_FLAG; then
	    echo -e "${GREEN}✓ Successfully converted:${NC} $chd_file"

	# Verify the CHD file was created and has reasonable size
	if [[ -f "$chd_file" ]] && [[ $(stat -f%z "$chd_file" 2>/dev/null || stat -c%s "$chd_file" 2>/dev/null) -gt 1000 ]]; then
		echo -e "${BLUE}Removing original file:${NC} $disc_file"
		rm "$disc_file"
		echo -e "${GREEN}✓ Original file deleted${NC}"
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

# Main conversion loop
echo "Searching for .iso/.cue files in current directory..."
if [[ "$OVERWRITE" == true ]]; then
	echo -e "${YELLOW}Overwrite mode enabled - existing CHD files will be replaced${NC}"
fi

# Find all .iso and .cue files (case-insensitive) and process them
while IFS= read -r -d '' disc_file; do
	((total_files++))
	convert_iso "$disc_file"
	echo ""  # Add spacing between files
done < <(find . -maxdepth 1 \( -iname "*.iso" -o -iname "*.cue" \) -print0)

# Summary
echo "=================================="
echo -e "${BLUE}Conversion Summary:${NC}"
echo -e "Total disc files found: ${total_files}"
echo -e "${GREEN}Successfully converted: ${converted_files}${NC}"
if [[ $failed_files -eq 0 ]]; then
	echo -e "${GREEN}Failed conversions: ${failed_files}${NC}"
else
	echo -e "${RED}Failed conversions: ${failed_files}${NC}"
fi

if [[ $total_files -eq 0 ]]; then
	echo -e "${YELLOW}No .iso/.cue files found in current directory${NC}"
elif [[ $converted_files -eq $total_files ]]; then
	echo -e "${GREEN}All files converted successfully!${NC}"
elif [[ $failed_files -gt 0 ]]; then
	echo -e "${YELLOW}Some files failed to convert. Original files preserved for failed conversions.${NC}"
fi
