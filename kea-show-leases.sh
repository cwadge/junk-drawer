#!/usr/bin/env bash
# kea-show-leases - Display Kea DHCP leases
# Supports DHCPv4, DHCPv6, or both simultaneously.
#
# Usage: kea-show-leases [-4] [-6] [-a] [-e] [-c] [-p] [-r] [-f PATH] [-h] [-V]
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
readonly VERSION="1.1.0"

# Kea lease file search paths, in preference order. The script tries these in
# sequence and uses the first one it finds. Override with -f.
readonly KEA_SEARCH_PATHS=(
    /var/lib/kea          # Debian / Ubuntu / most Linux distros
    /var/db/kea           # FreeBSD / OpenBSD
    /usr/local/var/db/kea # FreeBSD ports prefix
    /var/kea              # Some RPM-based distros
    /etc/kea              # Fallback (non-standard but seen in the wild)
)

# Directories searched for kea4-ctrl-socket / kea6-ctrl-socket.
readonly KEA_SOCKET_DIRS=(
    /run/kea              # Debian / Ubuntu
    /var/run/kea          # FreeBSD and older Linux layouts
    /tmp                  # Kea's compiled-in example location
)

readonly LEASE4_FILENAME="kea-leases4.csv"
readonly LEASE6_FILENAME="kea-leases6.csv"

# Renew time is estimated as lease_time / RENEW_FACTOR (T1 = 1/2 by default;
# a configured renew-timer or t1-percent changes the real value).
readonly RENEW_FACTOR=2

# Internal record separator.  A control character: it can't survive the
# hostname sanitising below, and unlike tab it isn't IFS whitespace, so an
# empty field (no hostname, no hwaddr) doesn't collapse into its neighbour
# when a record is split with `read`.
readonly SEP=$'\037'

# ---------------------------------------------------------------------------
# Globals (set by parse_args)
# ---------------------------------------------------------------------------

show_v4=false          # set true by -4 or by default in normalisation
show_v6=false          # set true by -6
show_all=false         # set true by -a; shows both v4 and v6
include_inactive=false # -e: also show expired, declined and released leases
force_csv=false        # -c: read the lease files even when the socket works
no_pager=false         # if true, write directly to stdout without invoking a pager
raw_mode=false         # if true, emit TSV with untranslated values
use_color=false        # set by setup_color; never set directly
lease_file_override=""

printf -v NOW '%(%s)T' -1     # bash builtin strftime: no date(1) fork

OUT=()                 # rendered output lines, paged once at the end

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
    printf '%s\n' "Display current Kea DHCP leases, newest first."
    printf '%s\n' "Output is paged through \$PAGER (default: less) when stdout is a terminal."
    printf '%s\n' ""
    printf '%s\n' "${BOLD}Options:${RESET}"
    printf '%s\n' "  ${CYAN}-4${RESET}          Show DHCPv4 leases only (default)"
    printf '%s\n' "  ${CYAN}-6${RESET}          Show DHCPv6 leases only"
    printf '%s\n' "  ${CYAN}-a${RESET}          Show all leases (both DHCPv4 and DHCPv6)"
    printf '%s\n' "  ${CYAN}-e${RESET}          Also show expired, declined and released leases"
    printf '%s\n' "              (default: only leases that are active right now)"
    printf '%s\n' "  ${CYAN}-c${RESET}          Read the lease files even if the control socket is usable"
    printf '%s\n' "  ${CYAN}-p${RESET}          Disable pager; write directly to stdout"
    printf '%s\n' "              (e.g. $SCRIPT_NAME -p | grep myhost)"
    printf '%s\n' "  ${CYAN}-f PATH${RESET}     Use PATH as the lease file (disables auto-detection;"
    printf '%s\n' "              combined with -a this sets the base directory instead)"
    printf '%s\n' "  ${CYAN}-r${RESET}          Raw mode: tab-separated output with a header row and"
    printf '%s\n' "              untranslated values (ISO timestamps, seconds, state"
    printf '%s\n' "              numbers), for other tools or spreadsheets"
    printf '%s\n' "  ${CYAN}-h${RESET}          Show this help and exit"
    printf '%s\n' "  ${CYAN}-V${RESET}          Show version and exit"
    printf '%s\n' ""
    printf '%s\n' "${BOLD}Lease source:${RESET}"
    printf '%s\n' "  When Kea's lease_cmds hook is loaded and socat and jq are installed,"
    printf '%s\n' "  leases are read from the control socket: Kea's own in-memory table."
    printf '%s\n' "  Otherwise the lease files are read the way Kea loads them at startup:"
    printf '%s\n' "  the cleaned-up snapshot (.completed, or .1 and .2) followed by the live"
    printf '%s\n' "  journal, keeping only the latest record for each address."
    printf '%s\n' ""
}

# ---------------------------------------------------------------------------
# Timestamp, duration and state formatting
# All assign into _FMT via printf -v: no date(1) and no subshell per row.
# ---------------------------------------------------------------------------

_FMT=''

# format_epoch EPOCH_SECS
# Raw mode:    compact ISO-8601 timestamp  — YYYYMMDDThhmmss
# Human mode:  readable datetime           — YYYY-MM-DD HH:MM
# Numeric strftime fields don't vary by locale, so no LC_ALL is needed.
format_epoch() {
    if [[ "$raw_mode" == true ]]; then
        printf -v _FMT '%(%Y%m%dT%H%M%S)T' "$1"
    else
        printf -v _FMT '%(%Y-%m-%d %H:%M)T' "$1"
    fi
}

# format_duration SECONDS
# Raw mode:    plain integer seconds
# Human mode:  compact human string — e.g. "2d 3h", "45m", "30s"
format_duration() {
    local secs=$1
    if [[ "$raw_mode" == true ]]; then
        _FMT=$secs
        return
    fi
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if   (( d > 0 )); then printf -v _FMT '%dd %dh' "$d" "$h"
    elif (( h > 0 )); then printf -v _FMT '%dh %dm' "$h" "$m"
    elif (( m > 0 )); then printf -v _FMT '%dm %ds' "$m" "$s"
    else                   printf -v _FMT '%ds'     "$s"
    fi
}

# format_state STATE EXPIRE
# Raw mode:    plain integer
# Human mode:  label, coloured when use_color=true
#   0 = active    (or "expired" once its expiry time has passed: Kea only
#                  moves a lease to state 2 when it reclaims it)
#   1 = declined  (yellow — needs investigation but not an outage)
#   2 = expired   (dim    — reclaimed, normal end-of-life)
#   3 = released  (dim    — client gave it back)
#   * = unknown   (prefixed with ?)
format_state() {
    local s=$1 expire=$2 label color=''
    if [[ "$raw_mode" == true ]]; then
        _FMT=$s
        return
    fi
    case "$s" in
        0) if (( expire <= NOW )); then label=expired; color=$DIM
           else label=active
           fi ;;
        1) label=declined; color=$YELLOW ;;
        2) label=expired;  color=$DIM ;;
        3) label=released; color=$DIM ;;
        *) label="?${s}" ;;
    esac
    if [[ "$use_color" == true && -n "$color" ]]; then
        _FMT="${color}${label}${RESET}"
    else
        _FMT=$label
    fi
}

# ---------------------------------------------------------------------------
# Lease source discovery
# ---------------------------------------------------------------------------

# find_lease_file FILENAME
# Search KEA_SEARCH_PATHS for FILENAME (or its cleanup snapshot) and print the
# base path if found.  Returns 1 if not found.
find_lease_file() {
    local filename=$1
    local dir
    for dir in "${KEA_SEARCH_PATHS[@]}"; do
        if [[ -f "${dir}/${filename}" || -f "${dir}/${filename}.1" \
              || -f "${dir}/${filename}.completed" ]]; then
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

# lease_file_set BASE
# Print the files Kea itself loads for BASE, in Kea's order.  Lease-file
# cleanup (LFC) compacts the lease state into BASE.1 and restarts BASE as a
# fresh journal, so reading BASE alone misses every lease that hasn't renewed
# since the last cleanup.  A finished-but-unrenamed cleanup (.completed)
# replaces .1 and the in-progress copy (.2); the live journal always comes last.
lease_file_set() {
    local base=$1
    if [[ -r "${base}.completed" ]]; then
        printf '%s\n' "${base}.completed"
    else
        [[ -r "${base}.1" ]] && printf '%s\n' "${base}.1"
        [[ -r "${base}.2" ]] && printf '%s\n' "${base}.2"
    fi
    [[ -r "$base" ]] && printf '%s\n' "$base"
    return 0
}

# find_socket FAMILY
find_socket() {
    local dir
    for dir in "${KEA_SOCKET_DIRS[@]}"; do
        if [[ -S "${dir}/kea${1}-ctrl-socket" ]]; then
            printf '%s\n' "${dir}/kea${1}-ctrl-socket"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Lease records
# Both sources emit the same SEP-separated record, one per lease:
#   start, address, hwaddr, valid_lifetime, expire, hostname, state,
#   lease_type, prefix_len
# Hostnames are client-supplied (DHCP option 12/81), so control characters
# are replaced before they can reach a terminal.
# ---------------------------------------------------------------------------

# socket_records FAMILY SOCKET
# Kea's authoritative in-memory table via the lease_cmds hook — no journal to
# reconstruct.  Returns 1 when the hook isn't loaded or the reply is unusable,
# so the caller falls back to the lease files.
socket_records() {
    local fam=$1 sock=$2 reply all=false
    [[ "$include_inactive" == true ]] && all=true
    reply=$(printf '{"command":"lease%s-get-all","service":["dhcp%s"]}' "$fam" "$fam" \
            | socat -t2 - UNIX-CONNECT:"$sock" 2>/dev/null) || return 1
    [[ -n "$reply" ]] || return 1
    jq -r --argjson now "$NOW" --argjson all "$all" '
        (if type == "array" then .[0] else . end) as $r
        | if   $r.result == 3 then empty          # "0 leases found"
          elif $r.result != 0 then error("unusable reply")
          else $r.arguments.leases[]
            | (.cltt + ."valid-lft") as $exp
            | select($all or ((.state // 0) == 0 and $exp > $now))
            | [ .cltt, ."ip-address", (."hw-address" // ""), ."valid-lft", $exp,
                ((.hostname // "") | gsub("[[:cntrl:]]"; "?")), (.state // 0),
                ({"IA_NA": 0, "IA_TA": 1, "IA_PD": 2}[.type // ""] // ""),
                (."prefix-len" // "") ]
            | map(tostring) | join("\u001f")
          end' <<< "$reply" 2>/dev/null
}

# csv_records FILE...
# Replays the lease files in order, keeping the LAST record per address — the
# file is a journal, so each renewal appends a row.  A zero valid lifetime is
# Kea's deletion marker and removes the address.  Columns are located from
# each file's header by name, so field additions between Kea releases
# (pool_id, hwtype, ...) can't shift them.  Kea writes commas inside fields as
# "&#x2c"; those are decoded for display.
csv_records() {
    awk -v now="$NOW" -v all="$include_inactive" -v prog="$SCRIPT_NAME" '
        BEGIN { FS = ","; OFS = "\037" }
        FNR == 1 {
            split("", col)
            for (i = 1; i <= NF; i++) col[$i] = i
            ca = col["address"]; cv = col["valid_lifetime"]; ce = col["expire"]
            cs = col["state"];   ch = col["hostname"];       cw = col["hwaddr"]
            ct = col["lease_type"]; cp = col["prefix_len"]
            if (!ca || !cv || !ce) unusable++
            next
        }
        !ca || !cv || !ce { next }
        $ca == "" { next }
        $cv !~ /^[0-9]+$/ || $ce !~ /^[0-9]+$/ { bad++; next }
        {
            key = ct ? $ca "/" $ct : $ca
            if ($cv + 0 == 0) {                      # deletion marker
                delete rec[key]; delete ex[key]; delete st[key]
                next
            }
            s = cs ? $cs : 0
            if (s == "") s = 0
            h = ch ? $ch : "";  gsub(/&#x2c/, ",", h); gsub(/[[:cntrl:]]/, "?", h)
            hw = cw ? $cw : ""; gsub(/&#x2c/, ",", hw); gsub(/[[:cntrl:]]/, "?", hw)
            rec[key] = ($ce - $cv) OFS $ca OFS hw OFS $cv OFS $ce OFS h OFS s OFS (ct ? $ct : "") OFS (cp ? $cp : "")
            ex[key] = $ce + 0
            st[key] = s
        }
        END {
            for (k in rec)
                if (all == "true" || (st[k] == 0 && ex[k] > now)) print rec[k]
            if (bad)
                printf "%s: warning: skipped %d malformed lease record(s)\n", prog, bad > "/dev/stderr"
            if (unusable)
                printf "%s: warning: %d lease file(s) had no address/valid_lifetime/expire header\n", prog, unusable > "/dev/stderr"
        }' "$@"
}

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------

# setup_color
# Determine whether to emit ANSI color codes. Respects the NO_COLOR env var
# (https://no-color.org) and only enables color when stdout is a terminal.
# Must run after parse_args: it reads -p and -r.
setup_color() {
    # Disable color: NO_COLOR set, -p or -r flag, or stdout is not a terminal
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
# search interactively; otherwise pass through unchanged.  $PAGER may carry
# its own arguments (PAGER='less -S'), so it is split into words.
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
        local -a pager
        read -ra pager <<< "${PAGER:-less}"
        (( ${#pager[@]} )) || pager=(less)
        if ! command -v "${pager[0]}" >/dev/null 2>&1; then
            cat
            return
        fi
        # Pass less-specific flags only when we're actually running less;
        # other pagers (more, most) don't accept GNU long options.
        if [[ "${pager[0]##*/}" == "less" ]]; then
            pager+=(--RAW-CONTROL-CHARS --quit-if-one-screen --no-init --chop-long-lines)
        fi
        "${pager[@]}"
    else
        cat
    fi
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

repeat_dash() {   # N → _FMT
    printf -v _FMT '%*s' "$1" ''
    _FMT=${_FMT// /-}
}

# show_family FAMILY
# Collect this family's leases from the best available source, then append
# the rendered table to OUT.  Everything is gathered before the pager starts,
# so errors (unreadable files) appear on a normal terminal, not under less.
show_family() {
    local fam=$1 sock='' src='' out='' base fname=$LEASE4_FILENAME
    local -a files=() recs=()
    (( fam == 6 )) && fname=$LEASE6_FILENAME

    if [[ "$force_csv" == false && -z "$lease_file_override" ]] \
       && command -v socat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
       && sock=$(find_socket "$fam") \
       && out=$(socket_records "$fam" "$sock"); then
        src="control socket ${sock}"
    else
        if [[ -n "$lease_file_override" ]]; then
            if [[ -d "$lease_file_override" ]]; then
                base="${lease_file_override%/}/${fname}"
            else
                base=$lease_file_override
            fi
        else
            base=$(resolve_lease_file "$fname")
        fi
        mapfile -t files < <(lease_file_set "$base")
        (( ${#files[@]} )) \
            || die "cannot read ${base} (or its .1/.completed snapshot)$( (( EUID )) && printf '%s' ' — run as root?')"
        out=$(csv_records "${files[@]}")
        src="${files[*]}"
    fi

    [[ -n "$out" ]] && mapfile -t recs < <(sort -t "$SEP" -k1,1nr <<< "$out")

    local start address hwaddr valid expire hostname state ltype plen
    local addr_w=15 host_w=8 i rec dur st_s rn_s ex_s state_s

    # Raw mode: one tab-separated table with a header row; the family column
    # keeps -a output in a single schema.
    if [[ "$raw_mode" == true ]]; then
        if (( ${#OUT[@]} == 0 )); then
            OUT+=( $'family\taddress\thwaddr\tvalid_lifetime\tstart\trenew_est\texpire\thostname\tstate' )
        fi
        for rec in "${recs[@]}"; do
            IFS=$SEP read -r start address hwaddr valid expire hostname state ltype plen <<< "$rec"
            [[ "$ltype" == 2 && -n "$plen" && "$plen" != 128 && "$address" != */* ]] && address+="/${plen}"
            format_epoch "$start"; st_s=$_FMT
            format_epoch $(( expire - valid / RENEW_FACTOR )); rn_s=$_FMT
            format_epoch "$expire"; ex_s=$_FMT
            OUT+=( "v${fam}"$'\t'"${address}"$'\t'"${hwaddr}"$'\t'"${valid}"$'\t'"${st_s}"$'\t'"${rn_s}"$'\t'"${ex_s}"$'\t'"${hostname}"$'\t'"${state}" )
        done
        return
    fi

    # Human mode: size the address and hostname columns to the data, so the
    # State column lines up however long the names are.
    (( fam == 6 )) && addr_w=19
    local -a disp_addr=()
    for i in "${!recs[@]}"; do
        IFS=$SEP read -r start address hwaddr valid expire hostname state ltype plen <<< "${recs[i]}"
        # Prefix length for PD leases (lease_type 2); IA_NA and IA_TA are
        # single addresses.  Only appended if the address doesn't carry it.
        [[ "$ltype" == 2 && -n "$plen" && "$plen" != 128 && "$address" != */* ]] && address+="/${plen}"
        disp_addr[i]=$address
        (( ${#address} > addr_w )) && addr_w=${#address}
        (( ${#hostname} > host_w )) && host_w=${#hostname}
    done
    (( addr_w > 43 )) && addr_w=43
    (( host_w > 40 )) && host_w=40

    local count=${#recs[@]} what='active leases'
    [[ "$include_inactive" == true ]] && what='leases (all states)'
    local fmt="%-${addr_w}s %-17s %7s %-16s %-16s %-16s %-${host_w}s %s"
    local hdr rule d1 d2
    printf -v hdr "$fmt" "IPv${fam} Address" "HW Address" "Duration" "Start" "Renew (est.)" "Expire" "Hostname" "State"
    repeat_dash "$addr_w"; d1=$_FMT
    repeat_dash "$host_w"; d2=$_FMT
    rule="${d1} ----------------- ------- ---------------- ---------------- ---------------- ${d2} --------"

    (( ${#OUT[@]} )) && OUT+=( '' )
    OUT+=( "${CYAN}${BOLD}═══ DHCPv${fam}: ${count} ${what} ═══${RESET}  ${DIM}${src}${RESET}" '' )
    OUT+=( "${BOLD}${hdr}${RESET}" "$rule" )

    local line
    for i in "${!recs[@]}"; do
        IFS=$SEP read -r start address hwaddr valid expire hostname state ltype plen <<< "${recs[i]}"
        format_duration "$valid";                           dur=$_FMT
        format_epoch "$start";                              st_s=$_FMT
        format_epoch $(( expire - valid / RENEW_FACTOR ));  rn_s=$_FMT
        format_epoch "$expire";                             ex_s=$_FMT
        format_state "$state" "$expire";                    state_s=$_FMT
        printf -v line "$fmt" "${disp_addr[i]}" "${hwaddr:--}" "$dur" "$st_s" "$rn_s" "$ex_s" "${hostname:-.}" "$state_s"
        OUT+=( "$line" )
    done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    # Colour vars are defined (empty) until setup_color runs after parsing.
    : "${BOLD:=}" "${DIM:=}" "${CYAN:=}" "${YELLOW:=}" "${RESET:=}"

    # Translate long options to their short equivalents before getopts sees them.
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
        shift
    done
    set -- "${args[@]+${args[@]}}"

    local opt
    while getopts ':46aecprhf:V' opt; do
        case "$opt" in
            4) show_v4=true   ;;
            6) show_v6=true   ;;
            a) show_all=true  ;;
            e) include_inactive=true ;;
            c) force_csv=true ;;
            p) no_pager=true  ;;
            r) raw_mode=true  ;;
            f) lease_file_override="$OPTARG" ;;
            V) printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            h) setup_color; usage; exit 0 ;;
            :) die "option -${OPTARG} requires an argument" ;;
            ?) die "unknown option: -${OPTARG}" ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    if [[ $# -gt 0 ]]; then
        die "unexpected argument: $1"
    fi

    # Normalise flag combinations after all options have been parsed.
    if [[ "$show_all" == true || ( "$show_v4" == true && "$show_v6" == true ) ]]; then
        show_v4=true
        show_v6=true
    elif [[ "$show_v6" == true ]]; then
        show_v4=false
    else
        show_v4=true
        show_v6=false
    fi

    # When both lease files are needed, -f must point to a directory so both
    # filenames can be resolved beneath it.
    if [[ "$show_v4" == true && "$show_v6" == true \
          && -n "$lease_file_override" && ! -d "$lease_file_override" ]]; then
        die "-f must be a directory when showing both v4 and v6 (got: $lease_file_override)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color

    [[ "$show_v4" == true ]] && show_family 4
    [[ "$show_v6" == true ]] && show_family 6

    # Quitting the pager early kills the writer with SIGPIPE (status 141);
    # that's the user's choice, not a failure.
    local rc=0
    printf '%s\n' "${OUT[@]}" | page_output || rc=$?
    (( rc == 0 || rc == 141 )) || exit "$rc"
}

main "$@"
