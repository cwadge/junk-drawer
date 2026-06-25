#!/usr/bin/env bash
# dirloot.sh — Download files matching a glob pattern from an HTML directory index.
#
# Parses href links from a web index page (e.g. archive.org file listings), filters
# them by a shell glob pattern, and downloads matching files with resume support.
#
# Usage:
#   dirloot.sh [OPTIONS] <URL> [PATTERN]
#
# Arguments:
#   URL       URL of the HTML directory index page
#   PATTERN   Shell glob pattern to filter filenames (default: '*')
#             Examples: '*.mkv', '*.mp4', 'episode_??.mkv'
#             Matched against the human-readable (percent-decoded) filename,
#             so you can write patterns with real spaces and brackets.
#
# Options:
#   -o DIR    Output directory (default: current directory)
#   -x GLOB   Exclude files matching this glob; repeatable. Applied after the
#             include PATTERN, so you can keep an intuitive include and subtract
#             the cases you don't want instead of writing one gnarly pattern.
#             e.g. on archive.org, derivative preview files often shadow the
#             real ones under a near-identical name:
#                 Buster Keaton Reel 043.ia.mp4   <- 320p auto-preview
#                 Buster Keaton Reel 043.mp4      <- the source you want
#             Grab only the sources with:  -x '*.ia.*'   PATTERN '*.mp4'
#   -w SECS   Wait this many seconds between files; pairs with a random
#             jitter to be polite to busy servers (default: 0)
#   -n        Dry run — list matched files without downloading
#   -C        Disable colored output (also honors NO_COLOR)
#   -h        Show this help
#
# Resumption ("the machine is the state"):
#   Resume is delegated entirely to `wget --continue`, which is the whole point
#   of this design. On each file wget issues a single ranged request:
#     - already complete -> server answers 416, wget reports it's done, moves on
#     - partially fetched -> transfer resumes from the existing byte offset
#     - missing           -> normal download
#   There is no separate size-checking pass: probing every file with a HEAD
#   request before downloading would roughly double the connection count against
#   the origin for no benefit, since `-c` already determines all three states in
#   one request. The entire match list is handed to a single wget invocation so
#   the TCP connection is kept alive and reused across files rather than
#   reopened per file.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
OUTPUT_DIR="."
WAIT_SECS=0
DRY_RUN=false
USE_COLOR=true
EXCLUDES=()

# ── Color setup ───────────────────────────────────────────────────────────────
# Only colorize when writing to a terminal and not suppressed. NO_COLOR is an
# informal cross-tool convention (https://no-color.org/) worth respecting.
setup_colors() {
	if ! $USE_COLOR || [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
		C_RESET= C_DIM= C_BOLD= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN=
		return
	fi
	C_RESET=$'\e[0m'   C_DIM=$'\e[2m'      C_BOLD=$'\e[1m'
	C_RED=$'\e[31m'    C_GREEN=$'\e[32m'   C_YELLOW=$'\e[33m'
	C_BLUE=$'\e[34m'   C_CYAN=$'\e[36m'
}

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
	sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,3\}//; p }' "$0"
	exit "${1:-0}"
}

die()  { printf '%serror:%s %s\n' "${C_RED:-}${C_BOLD:-}" "${C_RESET:-}" "$*" >&2; exit 1; }
info() { printf '%s::%s %s\n'      "${C_BLUE:-}${C_BOLD:-}" "${C_RESET:-}" "$*"; }
warn() { printf '%swarn:%s %s\n'   "${C_YELLOW:-}" "${C_RESET:-}" "$*" >&2; }

# Percent-decode a string for display and matching (e.g. %20 -> space, %5B -> [).
# printf '%b' turns \xNN escapes into bytes; we convert each %NN to \xNN first
# and leave literal '+' alone (it only means space in query strings, not paths).
urldecode() {
	local s="${1//+/+}"   # no-op; documents that we intentionally don't touch '+'
	printf '%b' "${s//%/\\x}"
}

# ── Argument parsing ───────────────────────────────────────────────────────────
while getopts ":o:x:w:nCh" opt; do
	case $opt in
		o) OUTPUT_DIR="$OPTARG" ;;
		x) EXCLUDES+=("$OPTARG") ;;
		w) WAIT_SECS="$OPTARG"  ;;
		n) DRY_RUN=true          ;;
		C) USE_COLOR=false       ;;
		h) setup_colors; usage 0 ;;
		:) setup_colors; die "Option -$OPTARG requires an argument." ;;
		?) setup_colors; die "Unknown option: -$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

setup_colors

[[ $# -lt 1 ]] && usage 1

BASE_URL="${1%/}"   # strip trailing slash
PATTERN="${2:-*}"

# ── Dependency check ───────────────────────────────────────────────────────────
for cmd in wget grep sed awk; do
	command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found."
done

# ── Fetch and parse the index ──────────────────────────────────────────────────
info "Fetching index: ${C_CYAN}${BASE_URL}${C_RESET}"

INDEX_HTML=$(wget -q -O - "$BASE_URL") || die "Failed to fetch index page."

# Pull href values, reduce to the bare (still percent-encoded) filename, and drop
# directory links and empties. We keep the encoded form because that is what must
# go back to the server in the download URL.
mapfile -t ENCODED_FILES < <(
printf '%s' "$INDEX_HTML" \
	| grep -oiE 'href="[^"]*"' \
	| sed 's/href="//I; s/"$//' \
	| awk -F'/' '{ print $NF }' \
	| grep -vE '^$|/$|[?#]' \
	| sort -u
)

[[ ${#ENCODED_FILES[@]} -eq 0 ]] && die "No file links found in index page."

# ── Filter by glob pattern (against the decoded, human-readable name) ──────────
# Parallel arrays: ENC[i] is the URL-safe name, DEC[i] is what we show and match.
# Include test first, then subtract anything matching an -x exclude glob.
ENC=() DEC=()
for enc in "${ENCODED_FILES[@]}"; do
	dec=$(urldecode "$enc")

    # Must match the include pattern.
    [[ "$dec" == $PATTERN ]] || continue

    # Must not match any exclude pattern.
    excluded=false
    if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
	    for ex in "${EXCLUDES[@]}"; do
		    if [[ "$dec" == $ex ]]; then excluded=true; break; fi
	    done
    fi
    $excluded && continue

    ENC+=("$enc"); DEC+=("$dec")
done

if [[ ${#DEC[@]} -eq 0 ]]; then
	warn "No files matched pattern '${C_BOLD}${PATTERN}${C_RESET}' (${#ENCODED_FILES[@]} link(s) found)."
	exit 0
fi

if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
	info "Matched ${C_GREEN}${C_BOLD}${#DEC[@]}${C_RESET} file(s): include '${C_BOLD}${PATTERN}${C_RESET}', excluding ${#EXCLUDES[@]} pattern(s)."
else
	info "Matched ${C_GREEN}${C_BOLD}${#DEC[@]}${C_RESET} file(s) with pattern '${C_BOLD}${PATTERN}${C_RESET}'."
fi

# ── Dry run ────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
	for d in "${DEC[@]}"; do printf '  %s%s%s\n' "$C_CYAN" "$d" "$C_RESET"; done
	exit 0
fi

# ── Output directory ───────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"

# ── Build the URL list for a single, connection-reusing wget run ──────────────
# One wget invocation over the whole list keeps the TCP connection alive between
# files (far friendlier to a busy origin than a fresh connection each time).
URL_LIST=$(mktemp) || die "Cannot create temporary file."
trap 'rm -f "$URL_LIST"' EXIT

for enc in "${ENC[@]}"; do
	printf '%s/%s\n' "$BASE_URL" "$enc"
done > "$URL_LIST"

info "Downloading to ${C_CYAN}${OUTPUT_DIR}${C_RESET} (resume-aware; complete files are skipped)."
[[ "$WAIT_SECS" != 0 ]] && info "Politeness delay: ${C_BOLD}${WAIT_SECS}s${C_RESET} (+ jitter) between files."
echo

# ── Download ───────────────────────────────────────────────────────────────────
# --continue          : resume partials, cheaply skip completes (the state machine)
# --show-progress     : keep wget's live progress bar so big files don't look hung
# --no-verbose        : suppress connection/header noise, leaving the bar + a
#                       terse one-line result per file
# --tries/--timeout   : survive flaky links without hammering
# --wait/--random-wait: spread requests out when the user asks for politeness
#
# wget writes straight to the terminal here (no pipe), which is what lets the
# progress bar animate in place — piping it through a filter would both trip
# wget's "not a TTY" detection and swallow the carriage-return redraws. To still
# report a transferred/complete tally without parsing that live output, we snap
# each target's on-disk size before and after the run and compare. wget decodes
# percent-escapes when choosing the local filename, so DEC[] holds the real names.
WGET_OPTS=(
	--continue
	--no-verbose
	--show-progress
	--tries=5
	--timeout=30
	--retry-connrefused
	--directory-prefix="$OUTPUT_DIR"
	--input-file="$URL_LIST"
)
if [[ "$WAIT_SECS" != 0 ]]; then
	WGET_OPTS+=( --wait="$WAIT_SECS" --random-wait )
fi

# Snapshot sizes before the run (0 == not present yet).
declare -a PRE_SIZE
for i in "${!DEC[@]}"; do
	p="$OUTPUT_DIR/${DEC[i]}"
	if [[ -f "$p" ]]; then
		PRE_SIZE[i]=$(stat -c '%s' "$p" 2>/dev/null || echo 0)
	else
		PRE_SIZE[i]=0
	fi
done

# Run it. We deliberately ignore wget's exit status: with --continue, every file
# the server confirms is already complete answers a ranged request with 416
# ("Range Not Satisfiable"), which wget counts as a server-error response and
# reports as exit 8 for the whole batch — even though skipping those files is the
# correct outcome. So a perfectly good resume run where most files are already
# present would otherwise look like a failure. The on-disk size snapshot below is
# the real source of truth for what still needs fetching, so we let wget's code
# go (|| true also keeps `set -e` from aborting on that benign 8).
wget "${WGET_OPTS[@]}" || true

# Classify each target by how its size changed.
transferred=0 complete=0 incomplete=0
for i in "${!DEC[@]}"; do
	p="$OUTPUT_DIR/${DEC[i]}"
	post=0
	[[ -f "$p" ]] && post=$(stat -c '%s' "$p" 2>/dev/null || echo 0)

	if   (( post > PRE_SIZE[i] ));            then transferred=$((transferred + 1))
	elif (( post > 0 && post == PRE_SIZE[i] )); then complete=$((complete + 1))
	else                                           incomplete=$((incomplete + 1))
	fi
done

echo
summary="${C_GREEN}${transferred}${C_RESET} transferred, ${complete} already complete"
if (( incomplete > 0 )); then
	warn "${summary}, ${C_RED}${incomplete} incomplete${C_RESET} — re-run to resume."
else
	info "${C_GREEN}${C_BOLD}Done.${C_RESET} ${summary}."
fi
