#!/usr/bin/env bash
# kea-show-leases - Display active Kea DHCP lease records
# Supports DHCPv4, DHCPv6, or both simultaneously.
#
# Usage: kea-show-leases [-4] [-6] [-a] [-p] [-r] [-f FILE] [-h]
#
# Based loosely on kea-show-leases4.sh and kea-show-leases6.sh by
# the.attic@mgm51.com — https://archive.mgm51.com/sources/kea-scripts.html
#
# MIT License — https://github.com/cwadge

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

# Kea lease file search paths, in preference order. The script tries these in
# sequence and uses the first one it finds. Override with -f.
readonly KEA_SEARCH_PATHS=(
    /var/lib/kea          # Debian / Ubuntu / most Linux distros
    /var/db/kea           # FreeBSD / OpenBSD
    /usr/local/var/db/kea # FreeBSD ports prefix
    /var/kea              # Some RPM-based distros
    /etc/kea              # Fallback (non-standard but seen in the wild)
)

readonly LEASE4_FILENAME="kea-leases4.csv"
readonly LEASE6_FILENAME="kea-leases6.csv"

# Renew time is calculated as lease_time / RENEW_FACTOR (default: T1 = 1/2)
readonly RENEW_FACTOR=2

# ---------------------------------------------------------------------------
# Globals (set by parse_args)
# ---------------------------------------------------------------------------

show_v4=false     # set true by -4 or by default in normalisation
show_v6=false     # set true by -6
show_all=false    # set true by -a; shows both v4 and v6
no_pager=false    # if true, write directly to stdout without invoking a pager
raw_mode=false    # if true, suppress human-readable translations (CSV-safe)
use_color=false   # set by setup_color; never set directly
lease_file_override=""

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

die() {
    printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
    exit 1
}

warn() {
    printf '%s: warning: %s\n' "$SCRIPT_NAME" "$*" >&2
}

usage() {
    printf '%s\n' "${BOLD}Usage:${RESET} $SCRIPT_NAME [OPTIONS]"
    printf '%s\n' ""
    printf '%s\n' "Display active Kea DHCP lease records from the lease CSV files."
    printf '%s\n' "Output is paged through \$PAGER (default: less) when stdout is a terminal."
    printf '%s\n' ""
    printf '%s\n' "${BOLD}Options:${RESET}"
    printf '%s\n' "  ${CYAN}-4${RESET}          Show DHCPv4 leases only (default)"
    printf '%s\n' "  ${CYAN}-6${RESET}          Show DHCPv6 leases only"
    printf '%s\n' "  ${CYAN}-a${RESET}          Show all leases (both DHCPv4 and DHCPv6)"
    printf '%s\n' "  ${CYAN}-p${RESET}          Disable pager; write directly to stdout"
    printf '%s\n' "              (e.g. $SCRIPT_NAME -p | grep myhost)"
    printf '%s\n' "  ${CYAN}-f FILE${RESET}     Use FILE as the lease file (disables auto-detection;"
    printf '%s\n' "              combined with -a this sets the base directory instead)"
    printf '%s\n' "  ${CYAN}-h${RESET}          Show this help and exit"
    printf '%s\n' "  ${CYAN}-r${RESET}          Raw mode: disable human-readable translations"
    printf '%s\n' "              (timestamps, durations, state labels); useful for"
    printf '%s\n' "              piping raw output to other tools or spreadsheets"
    printf '%s\n' "  ${CYAN}-V${RESET}          Show version and exit"
    printf '%s\n' ""
    printf '%s\n' "Without options, DHCPv4 leases are shown, auto-detecting the lease"
    printf '%s\n' "file from standard Kea install locations."
    printf '%s\n' ""
}

# ---------------------------------------------------------------------------
# Timestamp and duration formatting
# Handles GNU date (Linux) and BSD date (FreeBSD/macOS).
# ---------------------------------------------------------------------------

# Detect which date(1) flavour we have, once, at startup.
if date --version >/dev/null 2>&1; then
    _DATE_IS_GNU=true
else
    _DATE_IS_GNU=false
fi

# format_epoch EPOCH_SECS
# Raw mode:    compact ISO-8601 timestamp  — YYYYMMDDThhmmss
# Human mode:  readable datetime           — YYYY-MM-DD HH:MM
# LC_ALL=C is scoped to the date call to ensure consistent strftime
# output regardless of the user's locale, without affecting less(1)
# or any other process that needs to handle multi-byte characters.
format_epoch() {
    local epoch=$1
    local fmt
    if [[ "$raw_mode" == true ]]; then
        fmt="%Y%m%dT%H%M%S"
    else
        fmt="%Y-%m-%d %H:%M"
    fi
    if [[ "$_DATE_IS_GNU" == true ]]; then
        LC_ALL=C date -d "@${epoch}" +"$fmt"
    else
        LC_ALL=C date -j -r "${epoch}" +"$fmt"
    fi
}

# format_duration SECONDS
# Raw mode:    plain integer seconds
# Human mode:  compact human string — e.g. "2d 3h", "45m", "30s"
format_duration() {
    local secs=$1
    if [[ "$raw_mode" == true ]]; then
        printf '%s' "$secs"
        return
    fi
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if   (( d > 0 )); then printf '%dd %dh' "$d" "$h"
    elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
    elif (( m > 0 )); then printf '%dm %ds' "$m" "$s"
    else                   printf '%ds'     "$s"
    fi
}

# format_state STATE_INT [COLOR_VAR_PREFIX]
# Raw mode:    plain integer (0, 1, 2, …)
# Human mode:  labeled string, with color when use_color=true
#   0 = active    (default color)
#   1 = declined  (yellow — needs investigation but not an outage)
#   2 = expired   (dim    — informational, normal end-of-life)
#   * = unknown   (default color, prefixed with ?)
format_state() {
    local s=$1
    if [[ "$raw_mode" == true ]]; then
        printf '%s' "$s"
        return
    fi
    case "$s" in
        0) printf '%s' "active" ;;
        1) if [[ "$use_color" == true ]]; then
               printf '%s' "${YELLOW}declined${RESET}"
           else
               printf '%s' "declined"
           fi ;;
        2) if [[ "$use_color" == true ]]; then
               printf '%s' "${DIM}expired${RESET}"
           else
               printf '%s' "expired"
           fi ;;
        *) printf '?%s' "$s" ;;
    esac
}

# ---------------------------------------------------------------------------
# Lease file discovery
# ---------------------------------------------------------------------------

# find_lease_file FILENAME
# Search KEA_SEARCH_PATHS for FILENAME and print the full path if found.
# Returns 1 if not found.
find_lease_file() {
    local filename=$1
    local dir
    for dir in "${KEA_SEARCH_PATHS[@]}"; do
        if [[ -f "${dir}/${filename}" ]]; then
            printf '%s/%s\n' "$dir" "$filename"
            return 0
        fi
    done
    return 1
}

# resolve_lease_file FILENAME
# Like find_lease_file but calls die() on failure — used when a file is required.
resolve_lease_file() {
    local filename=$1
    local path
    if ! path=$(find_lease_file "$filename"); then
        die "cannot locate ${filename} in any of: ${KEA_SEARCH_PATHS[*]}"$'\nUse -f to specify the file path explicitly.'
    fi
    printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------

# setup_color
# Determine whether to emit ANSI color codes. Respects the NO_COLOR env var
# (https://no-color.org) and only enables color when stdout is a terminal.
# Uses tput where available for broad terminfo compatibility; falls back to
# hardcoded ANSI escape literals, which work on virtually every modern
# terminal (xterm, VTE, iTerm2, Windows Terminal, etc.).
# Color is always off when stdout is not a terminal, so piped/redirected
# output is always clean.
setup_color() {
    # Disable color: NO_COLOR set, -p flag, or stdout is not a terminal
    if [[ -n "${NO_COLOR:-}" || "$no_pager" == true || "$raw_mode" == true || ! -t 1 ]]; then
        BOLD="" DIM="" CYAN="" YELLOW="" RESET=""
        use_color=false
        return
    fi

    if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
        BOLD=$(tput bold)
        DIM=$(tput dim 2>/dev/null || printf '')   # not all terminfo entries have dim
        CYAN=$(tput setaf 6)
        YELLOW=$(tput setaf 3)
        RESET=$(tput sgr0)
    else
        # Fallback: ANSI escape literals (ESC[ sequences, universally supported)
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        CYAN=$'\033[36m'
        YELLOW=$'\033[33m'
        RESET=$'\033[0m'
    fi
    use_color=true
}

# ---------------------------------------------------------------------------
# Pager
# ---------------------------------------------------------------------------

# page_output
# When stdout is a terminal, pipe through $PAGER so the user can scroll and
# search interactively. When stdout is not a terminal (pipe, redirect, script),
# pass through unchanged — the caller already handles buffering.
#
# less flags:
#   --RAW-CONTROL-CHARS   pass ANSI colour sequences through intact
#   --quit-if-one-screen  exit immediately if output fits; pager is invisible
#   --no-init             don't switch to the alternate screen, so output
#                         stays in the scrollback buffer after quitting
#   --chop-long-lines     truncate rather than wrap long lines; tabular data
#                         must never soft-wrap across rows
page_output() {
    if [[ "$no_pager" == false && -t 1 ]]; then
        local pager="${PAGER:-less}"
        # Pass less-specific flags only when we're actually running less;
        # other pagers (more, most) don't accept GNU long options.
        if [[ "$(basename "$pager")" == "less" ]]; then
            "$pager" --RAW-CONTROL-CHARS --quit-if-one-screen --no-init --chop-long-lines
        else
            "$pager"
        fi
    else
        cat
    fi
}

# ---------------------------------------------------------------------------
# Reversed tail without BSD tail -r
# ---------------------------------------------------------------------------

# reverse_tail
# Read all of stdin and emit it in reverse line order.
# Uses 'tac' (GNU coreutils) if available, else a pure-bash mapfile fallback.
# Entirely in-memory — no tmpfiles. The pager handles display windowing.
reverse_tail() {
    if command -v tac >/dev/null 2>&1; then
        tac
    else
        # mapfile loads all lines into a bash array; we then walk it backwards.
        local -a lines
        mapfile -t lines
        local i
        for (( i=${#lines[@]}-1; i>=0; i-- )); do
            printf '%s\n' "${lines[$i]}"
        done
    fi
}

# ---------------------------------------------------------------------------
# DHCPv4 lease display
# ---------------------------------------------------------------------------
#
# CSV field order (kea src/lib/dhcpsrv/csv_lease_file4.h):
#   address, hwaddr, client_id, valid_lifetime, expire,
#   subnet_id, fqdn_fwd, fqdn_rev, hostname, state, user_context

show_leases4() {
    local lease_file=$1

    [[ -r "$lease_file" ]] \
        || die "cannot read lease file: $lease_file"

    # Human mode uses wider timestamp columns (YYYY-MM-DD HH:MM = 16 chars)
    # and a wider duration column (e.g. "10d 12h" = 7 chars).
    # Raw mode uses compact ISO timestamps (15 chars) and plain seconds (7).
    local fmt="%-15s %-17s %7s %-17s %-17s %-17s %-20s %s\n"
    printf "${BOLD}${fmt}${RESET}" "IPv4 Address" "HW Address" "Duration" "Start" "Renew" "Expire" "Hostname" "State"
    printf '%s\n' "--------------- ----------------- ------- ----------------- ----------------- ----------------- -------------------- -----"

    local address hwaddr client_id valid_lifetime expire \
          subnet_id fqdn_fwd fqdn_rev hostname state remainder
    local start_secs renew_secs

    # Skip the CSV header (tail -n +2), reverse so the most-recently-issued
    # leases appear at the top. Display windowing is handled by the pager.
    while IFS=, read -r address hwaddr client_id valid_lifetime expire \
                         subnet_id fqdn_fwd fqdn_rev hostname state remainder
    do
        # Skip blank lines (e.g. trailing newline in file)
        [[ -z "$address" ]] && continue

        # Guard against malformed records with missing or degenerate fields.
        # valid_lifetime=0 is technically valid in Kea (immediate expiry) but
        # produces start=renew=expire which is misleading; skip with a warning.
        if [[ -z "$expire" || -z "$valid_lifetime" || "$valid_lifetime" == "0" ]]; then
            warn "skipping malformed v4 record: ${address}"
            continue
        fi

        start_secs=$(( expire - valid_lifetime ))
        renew_secs=$(( expire - valid_lifetime / RENEW_FACTOR ))

        printf "$fmt" \
            "$address" \
            "${hwaddr:--}" \
            "$(format_duration "$valid_lifetime")" \
            "$(format_epoch "$start_secs")" \
            "$(format_epoch "$renew_secs")" \
            "$(format_epoch "$expire")" \
            "${hostname:-.}" \
            "$(format_state "${state:-?}")"
    done < <(tail -n +2 "$lease_file" | reverse_tail)
}

# ---------------------------------------------------------------------------
# DHCPv6 lease display
# ---------------------------------------------------------------------------
#
# CSV field order (kea src/lib/dhcpsrv/csv_lease_file6.h):
#   address, duid, valid_lifetime, expire, subnet_id, pref_lifetime,
#   lease_type, iaid, prefix_len, fqdn_fwd, fqdn_rev, hostname, hwaddr,
#   state, user_context

show_leases6() {
    local lease_file=$1

    [[ -r "$lease_file" ]] \
        || die "cannot read lease file: $lease_file"

    # IPv6 addresses with prefix can be up to 43 chars (39 addr + / + 3 prefix)
    local fmt="%-43s %-17s %7s %-17s %-17s %-17s %-20s %s\n"
    printf "${BOLD}${fmt}${RESET}" "IPv6 Address/Prefix" "HW Address" "Duration" "Start" "Renew" "Expire" "Hostname" "State"
    printf '%s\n' "------------------------------------------- ----------------- ------- ----------------- ----------------- ----------------- -------------------- -----"

    local address duid valid_lifetime expire subnet_id pref_lifetime \
          lease_type iaid prefix_len fqdn_fwd fqdn_rev hostname hwaddr \
          state remainder
    local start_secs renew_secs display_addr

    while IFS=, read -r address duid valid_lifetime expire subnet_id pref_lifetime \
                         lease_type iaid prefix_len fqdn_fwd fqdn_rev hostname \
                         hwaddr state remainder
    do
        [[ -z "$address" ]] && continue

        if [[ -z "$expire" || -z "$valid_lifetime" || "$valid_lifetime" == "0" ]]; then
            warn "skipping malformed v6 record: ${address}"
            continue
        fi

        start_secs=$(( expire - valid_lifetime ))
        renew_secs=$(( expire - valid_lifetime / RENEW_FACTOR ))

        # Show prefix length for PD leases (lease_type 2); IA_NA (type 0)
        # and IA_TA (type 1) are single-address assignments — show bare address.
        # Only append prefix_len if the address field doesn't already include it.
        if [[ "$lease_type" == "2" && -n "$prefix_len" && "$prefix_len" != "128" \
              && "$address" != */* ]]; then
            display_addr="${address}/${prefix_len}"
        else
            display_addr="$address"
        fi

        printf "$fmt" \
            "$display_addr" \
            "${hwaddr:--}" \
            "$(format_duration "$valid_lifetime")" \
            "$(format_epoch "$start_secs")" \
            "$(format_epoch "$renew_secs")" \
            "$(format_epoch "$expire")" \
            "${hostname:-.}" \
            "$(format_state "${state:-?}")"
    done < <(tail -n +2 "$lease_file" | reverse_tail)
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    # Belt-and-suspenders: ensure color vars are always defined even if
    # setup_color somehow did not run. Empty strings are harmless.
    : "${BOLD:=}" "${DIM:=}" "${CYAN:=}" "${YELLOW:=}" "${RESET:=}"

    # Translate long options to their short equivalents before getopts sees them.
    # getopts is POSIX and handles only single-character flags; this shim gives
    # us --help and --version without pulling in getopt(1) or util-linux.
    # Unknown --long-opts are passed through unchanged so getopts rejects them.
    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help)    args+=( -h ) ;;
            --version) args+=( -V ) ;;
            --)        args+=( -- ); shift; args+=( "$@" ); break ;;
            --*)       die "unknown option: $arg" ;;
            *)         args+=( "$arg" ) ;;
        esac
    done
    set -- "${args[@]+${args[@]}}"

    local opt
    while getopts ':46aprhf:V' opt; do
        case "$opt" in
            4) show_v4=true   ;;
            6) show_v6=true   ;;
            a) show_all=true  ;;
            p) no_pager=true  ;;
            r) raw_mode=true  ;;
            f) lease_file_override="$OPTARG" ;;
            V) printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            h) usage; exit 0 ;;
            :) die "option -${OPTARG} requires an argument" ;;
            ?) die "unknown option: -${OPTARG}" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if [[ $# -gt 0 ]]; then
        die "unexpected argument: $1"
    fi

    # Normalise flag combinations after all options have been parsed.
    # We track show_v4/v6 as false by default so that "-6" alone doesn't
    # collide with the v4 default and falsely trigger both-mode.
    if [[ "$show_all" == true || ( "$show_v4" == true && "$show_v6" == true ) ]]; then
        # -a, or -4 -6 together (either order) — show everything
        show_v4=true
        show_v6=true
    elif [[ "$show_v6" == true ]]; then
        # -6 alone; suppress the v4 default
        show_v4=false
    else
        # -4 explicit, or no flags at all — default to v4
        show_v4=true
        show_v6=false
    fi

    # When both lease files are needed, -f must point to a directory so both
    # filenames can be resolved beneath it. Checked after normalisation so it
    # catches -4 -6 -f <file> as well as -a -f <file>.
    if [[ "$show_v4" == true && "$show_v6" == true           && -n "$lease_file_override" && ! -d "$lease_file_override" ]]; then
        die "-f must be a directory when showing both v4 and v6 (got: $lease_file_override)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    setup_color
    parse_args "$@"

    if [[ "$show_v4" == true && "$show_v6" == true ]]; then
        # Both: resolve each file independently
        local f4 f6
        if [[ -n "$lease_file_override" ]]; then
            f4="${lease_file_override}/${LEASE4_FILENAME}"
            f6="${lease_file_override}/${LEASE6_FILENAME}"
        else
            f4=$(resolve_lease_file "$LEASE4_FILENAME")
            f6=$(resolve_lease_file "$LEASE6_FILENAME")
        fi
        {
            printf "${CYAN}${BOLD}═══ DHCPv4 Leases (%s) ═══${RESET}\n\n" "$f4"
            show_leases4 "$f4"
            printf "\n${CYAN}${BOLD}═══ DHCPv6 Leases (%s) ═══${RESET}\n\n" "$f6"
            show_leases6 "$f6"
        } | page_output

    elif [[ "$show_v4" == true ]]; then
        local f4
        if [[ -n "$lease_file_override" ]]; then
            f4="$lease_file_override"
        else
            f4=$(resolve_lease_file "$LEASE4_FILENAME")
        fi
        show_leases4 "$f4" | page_output

    else
        # Default: v6 only
        local f6
        if [[ -n "$lease_file_override" ]]; then
            f6="$lease_file_override"
        else
            f6=$(resolve_lease_file "$LEASE6_FILENAME")
        fi
        show_leases6 "$f6" | page_output
    fi
}

main "$@"
