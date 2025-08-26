#!/bin/bash

#########################################################
# midi2wav: A multi-threaded MIDI to WAV encoder        #
#                                                       #
# By Chris Wadge, 09/04/2010                            #
# Updated: August 2025                                  #
#                                                       #
# https://github.com/cwadge/misc-utils                  #
#                                                       #
# Licensed under the MIT License:                       #
# https://opensource.org/license/MIT                    #
#########################################################

# Enable strict mode for better error handling
set -euo pipefail

## DEFAULT VARIABLES ##
# These can be overridden by config file or command-line arguments
FLUIDSYNTH="/usr/bin/fluidsynth"
SOUNDFONT="/usr/share/sounds/sf2/FatBoy.sf2"
PROCNICE="10"
SAMPLERATE="44100"
FSGAIN="0.5"
FSCHORUS="yes"
FSREVERB="yes"
THREADMAX=""
TIMEOUT="30"  # 30-second timeout per file to prevent hung notes; increase for slow hardware or long MIDI files
OUTPUT_FORMAT="wav"  # Default output format
CONFIG_FILE="$HOME/.midi2wav.conf"

## COLOR CODES ##
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

## FUNCTIONS ##

# Print error message and exit
error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

# Print warning message
warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}" >&2
}

# Print success message (green)
success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# Print info message (cyan)
info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

# Cleanup function for SIGINT (Ctrl+C)
cleanup() {
    echo -e "${RED}[INTERRUPTED] Caught Ctrl+C, terminating all rendering processes...${NC}" >&2
    # Send SIGTERM to all child processes in the process group
    pkill -P $$ >/dev/null 2>&1
    # Wait briefly and check for lingering fluidsynth/ffmpeg processes
    sleep 1
    if pgrep -u "$USER" -f "(fluidsynth|ffmpeg)" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARNING] Some processes still running, sending SIGKILL...${NC}" >&2
        pkill -9 -u "$USER" -f "(fluidsynth|ffmpeg)" >/dev/null 2>&1
    fi
    exit 130  # Standard exit code for SIGINT
}

# Print help message
print_help() {
    cat << EOF
Usage: $0 [OPTIONS] [FILE|DIRECTORY|PATTERN ...]

Description: A multi-threaded front-end to render MIDI files to WAV or compressed audio formats.

Options:
  -h, --help                Show this help message and exit
  -v, --version             Show version information and exit
  -c, --config FILE         Specify custom config file (default: $CONFIG_FILE)
  -f, --fluidsynth PATH     Path to FluidSynth binary (default: $FLUIDSYNTH)
  -s, --soundfont FILE      Path to SF2 SoundFont file (default: $SOUNDFONT)
  -r, --sample-rate RATE    Sample rate for rendering (default: $SAMPLERATE)
  -g, --gain GAIN           FluidSynth master gain (0-10, default: $FSGAIN)
      --chorus [yes|no]     Enable/disable chorus (default: $FSCHORUS)
      --reverb [yes|no]     Enable/disable reverb (default: $FSREVERB)
  -t, --threads NUM         Max number of encoder threads (default: auto-detect)
  -n, --nice LEVEL          Nice priority level (19 to -20, default: $PROCNICE)
  -o, --output-format FMT   Output format (wav, mp3, flac; default: $OUTPUT_FORMAT)
      --timeout SECS        Timeout per file in seconds (default: $TIMEOUT)

Without arguments, searches current directory for '*.mid' files.

Dependencies:
  - FluidSynth
  - A compatible SoundFont
  - bash
  - ffmpeg (for mp3/flac output)
EOF
    exit 0
}

# Print version information
print_version() {
    echo -e "${CYAN}midi2wav v2.0 - A multi-threaded MIDI to WAV encoder${NC}"
    echo "By Chris Wadge, 2010-2025"
    echo "Licensed under the MIT License"
    exit 0
}

# Load configuration from file
load_config() {
    if [[ -r "$CONFIG_FILE" ]]; then
        info "Loading configuration from $CONFIG_FILE"
        # Source the config file, ignoring comments and empty lines
        while IFS='=' read -r key value; do
            # Skip empty lines and comments
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | tr -d '[:space:]')
            case "$key" in
                FLUIDSYNTH) FLUIDSYNTH="$value" ;;
                SOUNDFONT) SOUNDFONT="$value" ;;
                PROCNICE) PROCNICE="$value" ;;
                SAMPLERATE) SAMPLERATE="$value" ;;
                FSGAIN) FSGAIN="$value" ;;
                FSCHORUS) FSCHORUS="$value" ;;
                FSREVERB) FSREVERB="$value" ;;
                THREADMAX) THREADMAX="$value" ;;
                TIMEOUT) TIMEOUT="$value" ;;
                OUTPUT_FORMAT) OUTPUT_FORMAT="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        info "No config file found at $CONFIG_FILE; using defaults"
    fi
}

# Detect number of CPU threads
detect_threads() {
    if [[ -z "$THREADMAX" ]]; then
        if [[ "$(uname)" == "Linux" ]]; then
            THREADMAX=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
        elif [[ "$(uname)" =~ (BSD|Darwin) ]]; then
            THREADMAX=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
        else
            warn "Unable to detect CPU threads; falling back to 1 thread"
            THREADMAX=1
        fi
    elif ! [[ "$THREADMAX" =~ ^[0-9]+$ ]] || (( THREADMAX < 1 )); then
        warn "Invalid thread count ($THREADMAX); falling back to 1 thread"
        THREADMAX=1
    fi
    info "Using $THREADMAX rendering threads"
}

# Sanity checks for dependencies
sanity_check() {
    if ! command -v bash >/dev/null 2>&1; then
        error "Bourne Again SHell (bash) not found"
    fi
    if [[ ! -x "$FLUIDSYNTH" ]]; then
        error "FluidSynth not found at $FLUIDSYNTH"
    fi
    if [[ ! -r "$SOUNDFONT" ]]; then
        error "SoundFont not found at $SOUNDFONT"
    fi
    if [[ "$OUTPUT_FORMAT" != "wav" ]]; then
        if ! command -v ffmpeg >/dev/null 2>&1; then
            error "ffmpeg required for $OUTPUT_FORMAT output format"
        fi
    fi
    info "All dependencies satisfied"
}

# Render a single MIDI file
midi_render() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        warn "Unable to read file: $file"
        return 1
    fi
    local base="${file%.[mM][iI][dD]}"
    local wavfile="${base}.wav"
    local outfile="${base}.${OUTPUT_FORMAT}"

    # Render MIDI to WAV with timeout
    info "Rendering $file to $wavfile"
    if ! timeout --foreground "$TIMEOUT" "$FLUIDSYNTH" -F "$wavfile" -r "$SAMPLERATE" -g "$FSGAIN" \
        -C "$FSCHORUS" -R "$FSREVERB" -n -l -i "$SOUNDFONT" "$file" >/dev/null; then
        warn "Rendering failed or timed out for $file"
        rm -f "$wavfile" 2>/dev/null
        return 1
    fi
    success "Successfully rendered $file to $wavfile"

    # Convert to compressed format if requested
    if [[ "$OUTPUT_FORMAT" != "wav" ]]; then
        info "Converting $wavfile to $outfile"
        if ! ffmpeg -i "$wavfile" -y "$outfile" >/dev/null 2>&1; then
            warn "Failed to convert $wavfile to $outfile"
            rm -f "$wavfile" "$outfile" 2>/dev/null
            return 1
        fi
        rm -f "$wavfile"  # Clean up intermediate WAV file
        success "Successfully converted $wavfile to $outfile"
    fi
}

## MAIN ##

# Trap Ctrl+C (SIGINT) for graceful termination
trap cleanup SIGINT

# Parse command-line arguments
TEMP=$(getopt -o hvc:f:s:r:g:t:n:o: -l help,version,config:,fluidsynth:,soundfont:,sample-rate:,gain:,chorus:,reverb:,threads:,nice:,output-format:,timeout: -n "$0" -- "$@")
if [[ $? != 0 ]]; then error "Invalid arguments"; fi
eval set -- "$TEMP"

while true; do
    case "$1" in
        -h|--help) print_help ;;
        -v|--version) print_version ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -f|--fluidsynth) FLUIDSYNTH="$2"; shift 2 ;;
        -s|--soundfont) SOUNDFONT="$2"; shift 2 ;;
        -r|--sample-rate) SAMPLERATE="$2"; shift 2 ;;
        -g|--gain) FSGAIN="$2"; shift 2 ;;
        --chorus) FSCHORUS="$2"; shift 2 ;;
        --reverb) FSREVERB="$2"; shift 2 ;;
        -t|--threads) THREADMAX="$2"; shift 2 ;;
        -n|--nice) PROCNICE="$2"; shift 2 ;;
        -o|--output-format)
            OUTPUT_FORMAT="$2"
            if [[ ! "$OUTPUT_FORMAT" =~ ^(wav|mp3|flac)$ ]]; then
                error "Unsupported output format: $OUTPUT_FORMAT (use wav, mp3, or flac)"
            fi
            shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --) shift; break ;;
        *) error "Internal error in argument parsing" ;;
    esac
done

# Load configuration file
load_config

# Validate and normalize chorus/reverb settings
FSCHORUS=$(echo "$FSCHORUS" | tr '[:upper:]' '[:lower:]')
FSREVERB=$(echo "$FSREVERB" | tr '[:upper:]' '[:lower:]')
[[ "$FSCHORUS" =~ ^(yes|no|1|0)$ ]] || error "Invalid chorus setting: $FSCHORUS"
[[ "$FSREVERB" =~ ^(yes|no|1|0)$ ]] || error "Invalid reverb setting: $FSREVERB"

# Detect threads if not specified
detect_threads

# Perform sanity checks
sanity_check

# Process input files
if [[ $# -eq 0 ]]; then
    # No arguments: search current directory
    shopt -s nullglob
    files=(*.[mM][iI][dD])
    if [[ ${#files[@]} -eq 0 ]]; then
        error "No MIDI files found in current directory"
    fi
else
    # Process arguments (files, directories, or patterns)
    files=()
    for arg in "$@"; do
        if [[ -d "$arg" ]]; then
            mapfile -t -O "${#files[@]}" files < <(find "$arg" -maxdepth 1 -type f -iname '*.mid')
        elif [[ -f "$arg" && "$arg" =~ \.[mM][iI][dD]$ ]]; then
            files+=("$arg")
        elif [[ "$arg" =~ \*\.[mM][iI][dD]$ ]]; then
            mapfile -t -O "${#files[@]}" files < <(find . -maxdepth 1 -type f -iname "$arg")
        else
            warn "Skipping invalid input: $arg"
        fi
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        error "No valid MIDI files specified"
    fi
fi

# Export functions and variables for parallel execution
export FLUIDSYNTH SOUNDFONT SAMPLERATE FSGAIN FSCHORUS FSREVERB OUTPUT_FORMAT TIMEOUT
export RED YELLOW GREEN CYAN NC
export -f midi_render error warn success info

# Render files in parallel
info "Processing ${#files[@]} MIDI file(s)..."
printf '%s\0' "${files[@]}" | xargs -0 -n 1 -P "$THREADMAX" nice -n "$PROCNICE" bash -c 'midi_render "$@"' --
success "Rendering complete"
exit 0
