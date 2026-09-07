#!/usr/bin/env bash
# =============================================================================
# fs-status — File Server Services Dashboard
# Sections:  ZFS (pools · ARC · L2ARC · datasets) · mdadm · Disk I/O · SMART
#            Volumes · NFS · Samba (if installed) · Network interfaces
# Target:   Debian 13 / Linux
# =============================================================================

shopt -s checkwinsize

# ── Defaults ──────────────────────────────────────────────────────────────────
DEF_REFRESH_INTERVAL=3
DEF_NICE_VALUE=10
DEF_SMART_INTERVAL_MULT=20

REFRESH_INTERVAL=$DEF_REFRESH_INTERVAL
NICE_VALUE=$DEF_NICE_VALUE
ONE_SHOT=false
# Cadence divisor for every expensive poll, not just SMART: smartctl, zpool
# status, smbstatus, and showmount all ride this.  Config key name kept for
# backward compatibility with existing fs-status.conf files.
SMART_INTERVAL_MULT=$DEF_SMART_INTERVAL_MULT

# ── Live state ────────────────────────────────────────────────────────────────
PAUSED=false
SHOW_HELP=false
LAST_REFRESH='—'
_NEED_REDRAW=false
_FOOTER_ROW=0
_TTY_STATE=''
_HOSTNAME=''
_NOW=0
_PLAIN=false        # true when output is not a terminal (one-shot to a pipe)

# ── Network throughput state — persist across refreshes (not in subshells) ────
declare -A _NET_PREV_RX=()
declare -A _NET_PREV_TX=()
_NET_PREV_TS=0

# ── Disk I/O throughput state — same persistence model as network ─────────────
declare -A _DISK_PREV_R=()
declare -A _DISK_PREV_W=()
_DISK_PREV_TS=0

# ── Slow-cadence caches — polled every SMART_INTERVAL_MULT × REFRESH_INTERVAL ─
declare -A _SMART_HS=()    # health string  (PASSED / OK / FAILED / ?)
declare -A _SMART_HC=()    # health color escape sequence
declare -A _SMART_TC=()    # temperature integer (°C); empty if unknown
declare -A _SMART_RL=()    # reallocated sectors
declare -A _SMART_PD=()    # pending sectors
declare -A _SMART_UC=()    # uncorrectable sectors
declare -A _SMART_MDL=()   # model string (pre-truncated)
declare -A _SMART_CAP=()   # capacity string
declare -A _ZPOOL_STATUS=()  # `zpool status <pool>` output, keyed by pool
_SMB_BRIEF=''              # smbstatus --brief output
_SMB_SHARES=''             # smbstatus --shares output
_NFS_MOUNTS=''             # showmount -a output
_SLOW_LAST_TS=0
_DO_SLOW=false
_SLOW_SECS=0

# ── systemd state, fetched for every unit in one call per frame ───────────────
declare -a SVC_UNITS=()
declare -A _SVC_ACTIVE=() _SVC_ENABLED=() _SVC_START=() _TS_CACHE=()

# ── Optional-section presence — checked once at startup ──────────────────────
_ZFS_PRESENT=false
_MDADM_PRESENT=false
_NFS_PRESENT=false
_SAMBA_PRESENT=false
_NMBD_PRESENT=false
_WINBIND_PRESENT=false

# ── Two-column layout support ─────────────────────────────────────────────────
_MID_COL=0   # terminal column of the center │ divider; set by rebuild_fills

_PAD10='          '   # ten spaces, reused instead of $(printf '%-10s' '')

# ── Config (XDG-compliant) ────────────────────────────────────────────────────
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CFG_FILE="$CFG_DIR/fs-status.conf"

# ── Utility ───────────────────────────────────────────────────────────────────

# Validate then clamp.  Values from argv and the config file reach arithmetic
# contexts, where bash evaluates array subscripts — so nothing unvalidated is
# ever allowed into (( )).  Result in _CLAMP; returns 1 on non-integer input.
_CLAMP=0
clamp() {
	local raw="$1" lo="$2" hi="$3" n v neg=0
	[[ "$raw" =~ ^[+-]?[0-9]+$ ]] || return 1
	n="${raw#[+-]}"
	[[ "$raw" == -* ]] && neg=1
	# Reject absurd lengths before 10# to avoid silent 64-bit wraparound.
	if (( ${#n} > 10 )); then
		(( neg )) && _CLAMP=$lo || _CLAMP=$hi
		return 0
	fi
	v=$(( 10#$n ))
	(( neg )) && v=$(( -v ))
	(( v < lo )) && v=$lo
	(( v > hi )) && v=$hi
	_CLAMP=$v
}

load_config() {
	[[ -r "$CFG_FILE" ]] || return 0
	local line key val
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*#  ]] && continue
		[[ "$line" =~ ^[[:space:]]*$  ]] && continue
		key="${line%%=*}";  key="${key//[[:space:]]/}"
		val="${line#*=}";   val="${val//[[:space:]]/}"
		# Every value is range-checked here; invalid entries are ignored
		# rather than inherited into arithmetic later.
		case "$key" in
			REFRESH_INTERVAL)    clamp "$val" 1 300 && REFRESH_INTERVAL=$_CLAMP    ;;
			NICE_VALUE)          clamp "$val" -20 19 && NICE_VALUE=$_CLAMP         ;;
			SMART_INTERVAL_MULT) clamp "$val" 1 600 && SMART_INTERVAL_MULT=$_CLAMP ;;
		esac
	done < "$CFG_FILE"
}

save_config() {
	mkdir -p "$CFG_DIR"
	{
		printf '# fs-status — saved %s\n' "$(date '+%F %T')"
		printf 'REFRESH_INTERVAL=%s\n'    "$REFRESH_INTERVAL"
		printf 'NICE_VALUE=%s\n'          "$NICE_VALUE"
		printf 'SMART_INTERVAL_MULT=%s\n' "$SMART_INTERVAL_MULT"
	} > "$CFG_FILE"
}

prompt_input() {
	local mode="$1"
	local was_paused="$PAUSED"
	PAUSED=true

	local label
	[[ "$mode" == 'interval' ]] \
		&& label="Refresh interval (1–300 s)" \
		|| label="Nice value (-20–19)"

	printf '\033[%dH\033[K' $(( _FOOTER_ROW + 1 ))
	printf '%s   %s%s▶  %s:%s  ' "$B" "$FG_BCYAN" "$BOLD" "$label" "$RESET"

	[[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null
	printf '\033[?25h'

	local raw_val=''
	IFS= read -r raw_val

	printf '\033[?25l'
	stty -echo 2>/dev/null

	if [[ "$mode" == 'interval' ]]; then
		clamp "$raw_val" 1 300 && { REFRESH_INTERVAL=$_CLAMP; save_config; }
	else
		clamp "$raw_val" -20 19 && { NICE_VALUE=$_CLAMP; apply_nice; save_config; }
	fi

	PAUSED="$was_paused"
}

draw_footer_row() {
	local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"
	local content
	if [[ "$PAUSED" == "true" ]]; then
		content="   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nice_disp}   p resume · r refresh · i interval · n nice · h help · q quit${RESET}"
	else
		content="   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nice_disp}${RESET}  ${DIM}Last: ${LAST_REFRESH}   p pause · r refresh · i interval · n nice · h help · q quit${RESET}"
	fi
	printf '\033[%dH\033[K' $(( _FOOTER_ROW + 1 ))
	printf '%s %s\033[%dG%s' "$B" "$content" "$TERM_WIDTH" "$B"
}

# util-linux renice treats -n as an ABSOLUTE nice value unless POSIXLY_CORRECT
# is set, so --priority is passed directly; no delta arithmetic needed.
# Children inherit it, so there are no per-command wrappers.
apply_nice() {
	renice --priority "$NICE_VALUE" -p $$ >/dev/null 2>&1 || true
}

usage() {
	cat <<EOF
Usage: ${0##*/} [OPTIONS]

File server services status dashboard.
Always shown: DRIVES (SMART + I/O) · VOLUMES · NETWORK
Optional (shown when present): ZFS · mdadm · NFS · Samba

Options:
  -i, --interval SECS  Auto-refresh interval, seconds  (1–300,  default: $DEF_REFRESH_INTERVAL)
  -n, --nice     N     Nice value for the dashboard    (-20–19, default: $DEF_NICE_VALUE)
  -1, --once           Render once and exit (non-interactive / scriptable)
  -h, --help           Show this help and exit

Live key bindings (while running):
  q / Q / Ctrl-C   Quit
  p / P            Pause / unpause auto-refresh
  r / R            Force immediate refresh
  i                Set refresh interval (prompted, 1–300 s)
  n                Set nice value      (prompted, -20–19)
  h / ?            Toggle this help overlay

Polling cadence:
  Cheap sources (/proc, df, zpool list, zfs list) refresh every interval.
  Expensive ones (smartctl, zpool status, smbstatus, showmount) refresh every
  SMART_INTERVAL_MULT × interval — currently every $(( REFRESH_INTERVAL * SMART_INTERVAL_MULT ))s.
  Set SMART_INTERVAL_MULT in the config file to change it (default: $DEF_SMART_INTERVAL_MULT).

Privilege notes:
  Run as root for full access: exportfs, smbstatus, mdadm detail, smartctl.

Settings changed interactively are persisted to:
  $CFG_FILE

Current effective settings: interval=${REFRESH_INTERVAL}s  nice=${NICE_VALUE}
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-i|--interval)
				[[ -z "${2-}" ]] && { printf 'Error: %s requires a value\n' "$1" >&2; exit 1; }
				clamp "$2" 1 300 || { printf 'Error: %s expects an integer\n' "$1" >&2; exit 1; }
				REFRESH_INTERVAL=$_CLAMP; shift 2 ;;
			-n|--nice)
				[[ -z "${2-}" ]] && { printf 'Error: %s requires a value\n' "$1" >&2; exit 1; }
				clamp "$2" -20 19 || { printf 'Error: %s expects an integer\n' "$1" >&2; exit 1; }
				NICE_VALUE=$_CLAMP; shift 2 ;;
			-1|--once)
				ONE_SHOT=true; shift ;;
			-h|--help)
				usage; exit 0 ;;
			--) shift; break ;;
			-*)
				printf 'Unknown option: %s\n' "$1" >&2
				usage >&2; exit 1 ;;
			*) break ;;
		esac
	done
}

load_config
parse_args "$@"
apply_nice

# ── Optional section detection — each checked once to avoid per-frame overhead ─
command -v zpool &>/dev/null && _ZFS_PRESENT=true

# mdadm: only show if arrays actually exist — binary alone is not enough
[[ -r /proc/mdstat ]] && grep -q '^md[[:alnum:]]' /proc/mdstat 2>/dev/null \
	&& _MDADM_PRESENT=true

# NFS: exportfs present, or the nfs-server unit file is installed
command -v exportfs &>/dev/null && _NFS_PRESENT=true
[[ "$_NFS_PRESENT" == "false" ]] \
	&& systemctl cat nfs-server.service &>/dev/null \
	&& _NFS_PRESENT=true

# Samba: smbd present, or the smbd unit file is installed
command -v smbd &>/dev/null && _SAMBA_PRESENT=true
[[ "$_SAMBA_PRESENT" == "false" ]] \
	&& systemctl list-unit-files smbd.service 2>/dev/null | grep -q 'smbd' \
	&& _SAMBA_PRESENT=true

# nmbd/winbind unit presence: resolved once here rather than shelling out to
# `systemctl cat` on every frame.
if [[ "$_SAMBA_PRESENT" == "true" ]]; then
	systemctl cat nmbd.service    &>/dev/null && _NMBD_PRESENT=true
	systemctl cat winbind.service &>/dev/null && _WINBIND_PRESENT=true
fi

# Unit list for the single batched `systemctl show` per frame.
[[ "$_NFS_PRESENT"     == "true" ]] && SVC_UNITS+=('nfs-server' 'rpcbind')
[[ "$_SAMBA_PRESENT"   == "true" ]] && SVC_UNITS+=('smbd')
[[ "$_NMBD_PRESENT"    == "true" ]] && SVC_UNITS+=('nmbd')
[[ "$_WINBIND_PRESENT" == "true" ]] && SVC_UNITS+=('winbind')

# ── Colors ────────────────────────────────────────────────────────────────────
RESET=$'\033[0m';  BOLD=$'\033[1m';  DIM=$'\033[2m'
FG_RED=$'\033[0;31m';    FG_GREEN=$'\033[0;32m';   FG_YELLOW=$'\033[0;33m'
FG_BLUE=$'\033[0;34m';   FG_CYAN=$'\033[0;36m';    FG_WHITE=$'\033[0;37m'
FG_BWHITE=$'\033[1;37m'; FG_BCYAN=$'\033[1;36m';   FG_BGREEN=$'\033[1;32m'
FG_BRED=$'\033[1;31m';   FG_BYELLOW=$'\033[1;33m'; FG_BBLUE=$'\033[1;34m'
FG_HGREEN=$'\033[92m'  # high-intensity bright green (for "Excellent" ratings)

# Piped one-shot output gets no escapes and no box borders, so `-1 | mail`
# and `-1 > file` produce something readable.
if [[ "$ONE_SHOT" == "true" && ! -t 1 ]]; then
	_PLAIN=true
	RESET='' BOLD='' DIM=''
	FG_RED='' FG_GREEN='' FG_YELLOW='' FG_BLUE='' FG_CYAN='' FG_WHITE=''
	FG_BWHITE='' FG_BCYAN='' FG_BGREEN='' FG_BRED='' FG_BYELLOW='' FG_BBLUE=''
	FG_HGREEN=''
fi

# ── Box-drawing ───────────────────────────────────────────────────────────────
BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'
BOX_H='═';  BOX_V='║';  BOX_ML='╠'; BOX_MR='╣'
DIV_H='─';  DIV_ML='├'; DIV_MR='┤'; DASH_H='╌'

# ── Layout ────────────────────────────────────────────────────────────────────
TERM_WIDTH=${COLUMNS:-80}
INNER_WIDTH=$(( TERM_WIDTH - 2 ))
B="${FG_BLUE}${BOX_V}${RESET}"
[[ "$_PLAIN" == "true" ]] && B=''

_FILL_MID=''
_FILL_THIN=''
_FILL_DASH=''
_FILL_OUTER=''
_LAST_WIDTH=0

# Fill a string of $2 spaces, substitute every space with $1, assign to $3.
# printf -v throughout: no subshell, no loop.
repeat_char() {
	local out=''
	(( $2 > 0 )) && { printf -v out "%${2}s" ''; out="${out// /$1}"; }
	printf -v "$3" '%s' "$out"
}

rebuild_fills() {
	local fill=$(( INNER_WIDTH - 2 ))
	repeat_char "$BOX_H"  "$fill"        _FILL_MID
	repeat_char "$DIV_H"  "$fill"        _FILL_THIN
	repeat_char "$DASH_H" "$fill"        _FILL_DASH
	repeat_char "$BOX_H"  "$INNER_WIDTH" _FILL_OUTER
	_LAST_WIDTH=$INNER_WIDTH
	_MID_COL=$(( TERM_WIDTH / 2 ))   # center column for two-column sections
}

# ── Output buffer ─────────────────────────────────────────────────────────────
_BUF=''
_n() { _BUF+="$*"$'\n'; }

# ── Drawing primitives ────────────────────────────────────────────────────────

inner_rule() {
	local style="${1:-mid}"
	if [[ "$_PLAIN" == "true" ]]; then
		case "$style" in
			mid)  _n "$_FILL_MID"  ;;
			thin) _n "$_FILL_THIN" ;;
			dash) _n "$_FILL_DASH" ;;
		esac
		return
	fi
	case "$style" in
		mid)  _n "${B}${FG_BLUE}${BOX_ML}${_FILL_MID}${BOX_MR}${RESET}${B}"  ;;
		thin) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_THIN}${DIV_MR}${RESET}${B}" ;;
		dash) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_DASH}${DIV_MR}${RESET}${B}" ;;
	esac
}

# CHA (\033[NG) snaps the right border to column TERM_WIDTH, bypassing
# Unicode/ANSI byte-width accounting entirely.
box_line() {
	local content="$1" padding="${2:-1}" pad=''
	(( padding < 0 )) && padding=0
	(( padding > 0 )) && printf -v pad '%*s' "$padding" ''
	if [[ "$_PLAIN" == "true" ]]; then
		_n "${pad}${content}"
	else
		_n "${B}${pad}${content}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	fi
}

box_blank() {
	if [[ "$_PLAIN" == "true" ]]; then _n ''
	else _n "${B}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	fi
}

outer_top() {
	[[ "$_PLAIN" == "true" ]] && return
	printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_TL" "$_FILL_OUTER" "${BOX_TR}${RESET}"
}
outer_bottom() {
	[[ "$_PLAIN" == "true" ]] && return
	printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_BL" "$_FILL_OUTER" "${BOX_BR}${RESET}"
}

kv_line() {
	local key="$1" val="$2" pad
	printf -v pad '%*s' "${3:-3}" ''
	box_line "${pad}${FG_CYAN}${key}:${RESET}  ${val}"
}

section_header() {   # title subtitle icon
	box_line "${3}  ${BOLD}${FG_BWHITE}${1}${RESET}${FG_BLUE} — ${RESET}${FG_WHITE}${2}${RESET}" 2
	inner_rule thin
}

# Render one line with content in two columns separated by a │ at _MID_COL.
# Left and right are arbitrary colored strings; CHA handles ANSI-safe positioning.
# Falls back to showing only left content when _MID_COL is 0 (shouldn't happen
# after the first rebuild_fills call, but guards against early-startup edge cases).
two_col_row() {
	local left="$1" right="${2:-}"
	if [[ "$_PLAIN" == "true" ]]; then
		[[ -n "$left"  ]] && _n "$left"
		[[ -n "$right" ]] && _n "$right"
		return
	fi
	if (( _MID_COL > 0 )); then
		_n "${B}${left}${RESET}"$'\033'"[${_MID_COL}G${FG_BLUE}│${RESET}${right}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	else
		_n "${B}${left}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	fi
}

# ── Byte / rate formatting (pure bash, no subprocesses) ───────────────────────
# These assign via printf -v into a caller-named variable.  The originals
# printf'd to stdout, which meant every call site paid for a $() fork — the
# single largest source of subprocess churn in the old script.

_FMT=''
fmt_bytes() {   # $1 = bytes, $2 = target var (default _FMT)
	local b="${1:-0}" out
	if   (( b >= 1073741824 )); then
		printf -v out '%d.%d GiB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
	elif (( b >= 1048576 )); then
		printf -v out '%d.%d MiB' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
	elif (( b >= 1024 )); then
		printf -v out '%d.%d KiB' $(( b / 1024 )) $(( (b % 1024) * 10 / 1024 ))
	else
		printf -v out '%d B' "$b"
	fi
	printf -v "${2:-_FMT}" '%s' "$out"
}

fmt_rate() {    # $1 = bytes/sec, $2 = target var (default _FMT)
	local b="${1:-0}" out
	if   (( b >= 1073741824 )); then
		printf -v out '%d.%d GiB/s' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
	elif (( b >= 1048576 )); then
		printf -v out '%d.%d MiB/s' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
	elif (( b >= 1024 )); then
		printf -v out '%d.%d KiB/s' $(( b / 1024 )) $(( (b % 1024) * 10 / 1024 ))
	else
		printf -v out '%d B/s' "$b"
	fi
	printf -v "${2:-_FMT}" '%s' "$out"
}

# Render a filled/empty bar string for a 0–100 percentage value.
_BAR=''
pct_bar() {     # $1 = pct, $2 = width, $3 = target var (default _BAR)
	local pct="${1:-0}" width="${2:-20}"
	local filled=$(( pct * width / 100 ))
	(( filled > width )) && filled=$width
	(( filled < 0 )) && filled=0
	local empty=$(( width - filled ))
	local bar_col
	if   (( pct >= 90 )); then bar_col="$FG_BRED"
	elif (( pct >= 75 )); then bar_col="$FG_BYELLOW"
	else                       bar_col="$FG_BGREEN"
	fi
	local fs='' es=''
	(( filled > 0 )) && { printf -v fs '%*s' "$filled" ''; fs="${fs// /█}"; }
	(( empty  > 0 )) && { printf -v es '%*s' "$empty"  ''; es="${es// /░}"; }
	printf -v "${3:-_BAR}" '%s' "${bar_col}${fs}${DIM}${es}${RESET}"
}

# Read a one-line sysfs attribute without forking.  $(< file) looks fork-free
# but its open error is NOT suppressed by a redirection on the assignment, so
# a missing attribute (duplex on a down link, speed on a bridge or tun device)
# leaks "No such file or directory" straight into the alternate screen.
read_sysfs() {   # $1 = path, $2 = target var
	local v=''
	[[ -r "$1" ]] && { read -r v < "$1" 2>/dev/null || v=''; }
	printf -v "$2" '%s' "$v"
}

# ── Service helpers ───────────────────────────────────────────────────────────

# One systemctl call per frame for every unit.  `systemctl show` emits one
# property block per unit, in argument order, separated by a blank line.
svc_fetch_all() {
	(( ${#SVC_UNITS[@]} == 0 )) && return 0
	local raw line key val idx=0 unit="${SVC_UNITS[0]}"
	raw=$(systemctl show "${SVC_UNITS[@]}" \
		--property=ActiveState,UnitFileState,ActiveEnterTimestamp 2>/dev/null)
	while IFS= read -r line; do
		if [[ -z "$line" ]]; then
			idx=$(( idx + 1 )); unit="${SVC_UNITS[$idx]-}"
			continue
		fi
		[[ -n "$unit" ]] || continue
		key="${line%%=*}"; val="${line#*=}"
		case "$key" in
			ActiveState)          _SVC_ACTIVE["$unit"]="$val"  ;;
			UnitFileState)        _SVC_ENABLED["$unit"]="$val" ;;
			ActiveEnterTimestamp) _SVC_START["$unit"]="$val"   ;;
		esac
	done <<< "$raw"
}

_BADGE=''
svc_status_badge() {   # $1 = unit, $2 = target var (default _BADGE)
	local out
	case "${_SVC_ACTIVE[$1]-}" in
		active)   out="${FG_BGREEN}● Active  ${RESET}" ;;
		inactive)
			# Dim when deliberately disabled/masked; red only when enabled but not running.
			case "${_SVC_ENABLED[$1]-}" in
				disabled|masked) out="${DIM}✖ Inactive${RESET}"     ;;
				*)               out="${FG_BRED}✖ Inactive${RESET}" ;;
			esac ;;
		failed)   out="${FG_BRED}✖ Failed  ${RESET}" ;;
		*)        printf -v out '%s%-10s%s' "$FG_YELLOW" "? ${_SVC_ACTIVE[$1]:-unknown}" "$RESET" ;;
	esac
	printf -v "${2:-_BADGE}" '%s' "$out"
}

svc_enabled_badge() {  # $1 = unit, $2 = target var (default _BADGE)
	local out
	case "${_SVC_ENABLED[$1]-}" in
		enabled)  out="${FG_BGREEN}Enabled ${RESET}" ;;
		disabled) out="${FG_YELLOW}Disabled${RESET}" ;;
		masked)   out="${FG_BRED}Masked  ${RESET}"   ;;
		*)        printf -v out '%s%-8s%s' "$FG_WHITE" "${_SVC_ENABLED[$1]:-unknown}" "$RESET" ;;
	esac
	printf -v "${2:-_BADGE}" '%s' "$out"
}

# Timestamp strings are memoised, so `date -d` runs at most once per unit per
# restart instead of once per unit per frame.
_UPTIME=''
svc_uptime() {         # $1 = unit, $2 = target var (default _UPTIME)
	local ts="${_SVC_START[$1]-}" epoch out
	if [[ -z "$ts" || "$ts" == "n/a" ]]; then
		printf -v "${2:-_UPTIME}" '%s' "${DIM}n/a${RESET}"; return
	fi
	epoch="${_TS_CACHE[$ts]-}"
	if [[ -z "$epoch" ]]; then
		epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=''
		[[ "$epoch" =~ ^[0-9]+$ ]] || epoch='-'
		_TS_CACHE["$ts"]="$epoch"
	fi
	if [[ "$epoch" == '-' ]]; then
		printf -v "${2:-_UPTIME}" '%s' "${DIM}n/a${RESET}"; return
	fi
	local elapsed=$(( _NOW - epoch ))
	(( elapsed < 0 )) && elapsed=0
	local d=$(( elapsed/86400 )) h=$(( (elapsed%86400)/3600 ))
	local m=$(( (elapsed%3600)/60 )) s=$(( elapsed%60 ))
	if   (( d > 0 )); then printf -v out '%s%dd %dh %dm%s' "$FG_BWHITE" "$d" "$h" "$m" "$RESET"
	elif (( h > 0 )); then printf -v out '%s%dh %dm %ds%s' "$FG_BWHITE" "$h" "$m" "$s" "$RESET"
	elif (( m > 0 )); then printf -v out '%s%dm %ds%s'     "$FG_BWHITE" "$m" "$s" "$RESET"
	else                   printf -v out '%s%ds%s'         "$FG_BWHITE" "$s" "$RESET"
	fi
	printf -v "${2:-_UPTIME}" '%s' "$out"
}

# Emit a list of pre-built lines either as a two-column grid (wide terminals)
# or one per row.  Consolidates the identical pairing loop that appeared in
# five different sections.
render_pairs() {       # $1 = name of an array variable holding the lines
	local -n _lines="$1"
	local n=${#_lines[@]} i j
	(( n == 0 )) && return
	if (( INNER_WIDTH >= 140 )); then
		i=0
		while (( i < n )); do
			j=$(( i + 1 ))
			two_col_row "${_lines[$i]}" "${_lines[$j]:-}"
			i=$(( i + 2 ))
		done
	else
		for (( i=0; i<n; i++ )); do box_line "${_lines[$i]}"; done
	fi
}

# =============================================================================
# ── ZFS ───────────────────────────────────────────────────────────────────────
# =============================================================================
section_zfs() {
	section_header "ZFS" "OpenZFS Pool & Cache Status" "🗄"

	if ! command -v zpool &>/dev/null; then
		box_line "   ${FG_YELLOW}⚠  zpool not found — ZFS not installed${RESET}"
		box_blank; return
	fi

	# ── ARC / L2ARC stats from /proc ──────────────────────────────────────────
	# Parsed with shell builtins: the old awk+eval spawned a subprocess and
	# executed its output as code for what is a fixed set of integers.
	local arcstats='/proc/spl/kstat/zfs/arcstats'
	if [[ -r "$arcstats" ]]; then
		local -A _a=()
		local an _at av
		while read -r an _at av _; do
			case "$an" in
				size|c|l2_size|l2_asize|l2_hits|l2_misses|\
				demand_data_hits|demand_metadata_hits|\
				demand_data_misses|demand_metadata_misses)
					[[ "$av" =~ ^[0-9]+$ ]] && _a[$an]=$av ;;
			esac
		done < "$arcstats"

		# demand-only hits: excludes prefetch, which inflates totals
		local arc_hits=$(( ${_a[demand_data_hits]:-0} + ${_a[demand_metadata_hits]:-0} ))
		local arc_misses=$(( ${_a[demand_data_misses]:-0} + ${_a[demand_metadata_misses]:-0} ))
		local arc_tot=$(( arc_hits + arc_misses ))
		local arc_size arc_max
		fmt_bytes "${_a[size]:-0}" arc_size
		fmt_bytes "${_a[c]:-0}"    arc_max

		# One decimal place, integer maths only (x10 then split).
		local arc_pm=-1 arc_hit_pct='' arc_int=0
		if (( arc_tot > 0 )); then
			arc_pm=$(( arc_hits * 1000 / arc_tot ))
			arc_int=$(( arc_pm / 10 ))
			printf -v arc_hit_pct '%d.%d' "$arc_int" $(( arc_pm % 10 ))
		fi

		local arc_col arc_hit_str
		# Cold <50% · Poor 50–75% · Normal 75–90% · Good 90–95% · Excellent >95%
		# (Poor and Normal share a colour by design — only the extremes are tinted.)
		if   (( arc_pm < 0 ));   then arc_col="$FG_WHITE"
		elif (( arc_int >= 95 )); then arc_col="$FG_HGREEN"
		elif (( arc_int >= 90 )); then arc_col="$FG_GREEN"
		elif (( arc_int >= 50 )); then arc_col="$FG_WHITE"
		else                           arc_col="$FG_CYAN"
		fi
		[[ -n "$arc_hit_pct" ]] \
			&& arc_hit_str="${arc_col}${arc_hit_pct}%${RESET}" \
			|| arc_hit_str="${DIM}n/a${RESET}"

		local arc_right=''
		if (( ${_a[l2_size]:-0} > 0 )); then
			local l2_hits=${_a[l2_hits]:-0} l2_misses=${_a[l2_misses]:-0}
			local l2_tot=$(( l2_hits + l2_misses ))
			local l2arc_size l2arc_asize
			fmt_bytes "${_a[l2_size]:-0}"  l2arc_size
			fmt_bytes "${_a[l2_asize]:-0}" l2arc_asize

			local l2_pm=-1 l2_hit_pct='' l2_int=0
			if (( l2_tot > 0 )); then
				l2_pm=$(( l2_hits * 1000 / l2_tot ))
				l2_int=$(( l2_pm / 10 ))
				printf -v l2_hit_pct '%d.%d' "$l2_int" $(( l2_pm % 10 ))
			fi

			local l2_col l2_hit_str
			# Cold <10% · Poor 10–20% · Normal 20–40% · Good 40–60% · Excellent >60%
			if   (( l2_pm < 0 ));    then l2_col="$FG_WHITE"
			elif (( l2_int > 60 ));  then l2_col="$FG_HGREEN"
			elif (( l2_int >= 40 )); then l2_col="$FG_GREEN"
			elif (( l2_int >= 10 )); then l2_col="$FG_WHITE"
			else                          l2_col="$FG_CYAN"
			fi
			[[ -n "$l2_hit_pct" ]] \
				&& l2_hit_str="${l2_col}${l2_hit_pct}%${RESET}" \
				|| l2_hit_str="${DIM}n/a${RESET}"

			arc_right=" ${FG_BCYAN}L2ARC${RESET}  ${l2_hit_str}  ${DIM}size:${RESET} ${FG_WHITE}${l2arc_size}${RESET}  ${DIM}on-disk:${RESET} ${FG_WHITE}${l2arc_asize}${RESET}  ${DIM}hits: ${l2_hits}  misses: ${l2_misses}${RESET}"
		fi

		inner_rule dash
		two_col_row " ${FG_BCYAN}ARC${RESET}  ${arc_hit_str}  ${DIM}size:${RESET} ${FG_WHITE}${arc_size}${RESET}  ${DIM}of${RESET} ${FG_WHITE}${arc_max}${RESET}  ${DIM}hits: ${arc_hits}  misses: ${arc_misses}${RESET}"  "$arc_right"
	fi

	# ── Per-pool status ───────────────────────────────────────────────────────
	# One zpool call for every pool instead of one per pool, plus one zfs call
	# for every dataset on the system instead of one per pool.
	local pool_raw
	pool_raw=$(zpool list -H -p -o name,size,alloc,free,frag,cap,health 2>/dev/null) || pool_raw=''

	if [[ -z "$pool_raw" ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  No ZFS pools imported${RESET}"
		box_blank; return
	fi

	# Bucket every dataset under its pool in one pass.
	local -A _ds_by_pool=()
	local ds_name ds_used ds_avail ds_refer ds_mp
	while IFS=$'\t' read -r ds_name ds_used ds_avail ds_refer ds_mp; do
		[[ -z "$ds_name" ]] && continue
		_ds_by_pool["${ds_name%%/*}"]+="${ds_name}"$'\t'"${ds_used}"$'\t'"${ds_avail}"$'\t'"${ds_refer}"$'\t'"${ds_mp}"$'\n'
	done < <(zfs list -H -p -o name,used,avail,refer,mountpoint 2>/dev/null)

	local pool p_size p_alloc p_free p_frag p_cap p_health
	while IFS=$'\t' read -r pool p_size p_alloc p_free p_frag p_cap p_health; do
		[[ -z "$pool" ]] && continue
		inner_rule dash

		# -p gives raw bytes; compute human-readable with fmt_bytes and integer cap/frag
		local p_size_h p_alloc_h p_free_h
		fmt_bytes "${p_size:-0}"  p_size_h
		fmt_bytes "${p_alloc:-0}" p_alloc_h
		fmt_bytes "${p_free:-0}"  p_free_h

		local health_col
		case "$p_health" in
			ONLINE)                  health_col="$FG_BGREEN"  ;;
			DEGRADED)                health_col="$FG_BYELLOW" ;;
			FAULTED|REMOVED|UNAVAIL) health_col="$FG_BRED"    ;;
			*)                       health_col="$FG_WHITE"   ;;
		esac

		box_line " ${FG_BWHITE}${pool}${RESET}  ${health_col}${p_health:-?}${RESET}"
		kv_line "Capacity    " \
			"${FG_BWHITE}${p_alloc_h}${RESET}${DIM} used of ${RESET}${FG_WHITE}${p_size_h}${RESET}${DIM},  free: ${RESET}${FG_BWHITE}${p_free_h}${RESET}  ${DIM}frag: ${p_frag}%  cap: ${p_cap}%${RESET}"

		# Scrub and error info from zpool status.  `zpool status` stats every
		# vdev, so it rides the slow cadence; scrub progress and error counts
		# move on hour/day timescales anyway.
		[[ "$_DO_SLOW" == "true" ]] && _ZPOOL_STATUS["$pool"]=$(zpool status "$pool" 2>/dev/null)
		local zs_out="${_ZPOOL_STATUS[$pool]-}"

		if [[ -n "$zs_out" ]]; then
			# Grab scan: line plus any immediately following detail lines
			local scan_text='' zline found=false
			while IFS= read -r zline; do
				if [[ "$found" == "false" && "$zline" == *"scan:"* ]]; then
					found=true
					scan_text="${zline#*scan:}"
					scan_text="${scan_text#"${scan_text%%[![:space:]]*}"}"
					continue
				fi
				if [[ "$found" == "true" ]]; then
					[[ "$zline" =~ ^[[:space:]]+[0-9] ]] || break
					scan_text+=$'\n'"$zline"
				fi
			done <<< "$zs_out"

			if [[ "$scan_text" == *"scrub in progress"* ]]; then
				local pct_done=''
				[[ "$scan_text" =~ ([0-9]+\.[0-9]+)%\ done ]] && pct_done="${BASH_REMATCH[1]}"
				kv_line "Scrub       " "${FG_BYELLOW}⟳ In progress${RESET}${pct_done:+  ${FG_WHITE}${pct_done}% done${RESET}}"
			elif [[ "$scan_text" == *"resilver in progress"* ]]; then
				kv_line "Scrub       " "${FG_BYELLOW}⟳ Resilver in progress${RESET}"
			elif [[ "$scan_text" == *"scrub repaired"* ]]; then
				local s_errs=0
				[[ "$scan_text" =~ ([0-9]+)\ error ]] && s_errs="${BASH_REMATCH[1]}"
				if [[ "$s_errs" != "0" ]]; then
					# Restrict the date match to the first line: bash ERE '.'
					# matches newlines, so an unanchored (.*) would swallow the
					# whole scan block.
					local s_first="${scan_text%%$'\n'*}" s_date=''
					[[ "$s_first" =~ on\ (.*)$ ]] && s_date="${BASH_REMATCH[1]}"
					kv_line "Scrub       " "${FG_BRED}⚠ ${s_errs} error(s)${RESET}${s_date:+  ${DIM}${s_date}${RESET}}"
				fi
				# Clean scrubs (0 errors) are not shown — pool line already shows ONLINE
			fi

			# Data errors — only show the row when there's something to report
			local err_line=''
			while IFS= read -r zline; do
				[[ "$zline" == *"errors:"* ]] && { err_line="$zline"; break; }
			done <<< "$zs_out"
			if [[ -n "$err_line" && "$err_line" != *"No known data errors"* ]]; then
				kv_line "Data errors " "${FG_BRED}${err_line##*errors: }${RESET}"
			fi
		fi

		# ── Per-dataset space usage ───────────────────────────────────────────
		inner_rule dash
		local -a _ds_lines=()
		local ds_rel ds_used_h ds_avail_h ds_refer_h mp_str name_pad
		while IFS=$'\t' read -r ds_name ds_used ds_avail ds_refer ds_mp; do
			[[ -z "$ds_name" ]] && continue

			ds_rel="${ds_name#"${pool}/"}"
			[[ "$ds_rel" == "$ds_name" ]] && ds_rel="${ds_name##*/}"

			fmt_bytes "$ds_used"  ds_used_h
			fmt_bytes "$ds_avail" ds_avail_h
			fmt_bytes "$ds_refer" ds_refer_h

			mp_str=''
			[[ "$ds_mp" != "-" && "$ds_mp" != "none" && "$ds_mp" != "legacy" ]] \
				&& mp_str="  ${DIM}→ ${ds_mp}${RESET}"

			printf -v name_pad '%-18s' "$ds_rel"
			_ds_lines+=( " ${FG_WHITE}${name_pad}${RESET}  ${DIM}used:${RESET} ${FG_BWHITE}${ds_used_h}${RESET}  ${DIM}avail:${RESET} ${FG_WHITE}${ds_avail_h}${RESET}  ${DIM}refer:${RESET} ${FG_WHITE}${ds_refer_h}${RESET}${mp_str}" )
		done <<< "${_ds_by_pool[$pool]-}"

		if (( ${#_ds_lines[@]} == 0 )); then
			box_line "   ${DIM}(no datasets)${RESET}"
		else
			render_pairs _ds_lines
		fi

	done <<< "$pool_raw"

	box_blank
}

# =============================================================================
# ── MDADM ─────────────────────────────────────────────────────────────────────
# =============================================================================

# Builds a compact one-line summary of one mdadm array into _MD_LINE.
# Previously printed to stdout and was captured with $(), costing a fork per
# array plus two sed forks inside it.
_MD_LINE=''
_mdadm_format_array() {
	local name="$1" state="$2" level="$3" devs="$4" status="$5" sync_info="$6"

	local total=${#status} up=0 down=0 i
	for (( i=0; i<total; i++ )); do
		if [[ "${status:$i:1}" == "U" ]]; then up=$(( up + 1 ))
		else down=$(( down + 1 ))
		fi
	done

	local state_str
	if   [[ "$state" == "inactive" ]]; then state_str="${FG_BRED}✖ Inactive${RESET}"
	elif (( down > 0 ));               then state_str="${FG_BYELLOW}⚠ Degraded${RESET}"
	else                                    state_str="${FG_BGREEN}● Active${RESET}"
	fi

	local colored_status=''
	for (( i=0; i<total; i++ )); do
		[[ "${status:$i:1}" == "U" ]] \
			&& colored_status+="${FG_BGREEN}U${RESET}" \
			|| colored_status+="${FG_BRED}_${RESET}"
	done
	local sdisplay=''
	[[ -n "$colored_status" ]] && sdisplay="  ${DIM}[${RESET}${colored_status}${DIM}]${RESET}  ${DIM}${up}/${total}${RESET}"

	# Strip the [N] slot index and (F)/(S) role markers: "sdb1[0] sdc1[1](F)"
	# becomes "sdb1 sdc1".  Word-wise parameter expansion replaces two seds.
	local -a _dw=()
	local w clean_devs=''
	read -r -a _dw <<< "$devs"
	for w in "${_dw[@]}"; do
		w="${w%%\[*}"
		w="${w%%(*}"
		[[ -n "$w" ]] && clean_devs+="${clean_devs:+ }$w"
	done

	local name_pad; printf -v name_pad '%-6s' "$name"
	local line=" ${FG_BWHITE}${name_pad}${RESET}  ${FG_WHITE}${level}${RESET}  ${state_str}${sdisplay}  ${FG_WHITE}${clean_devs}${RESET}"
	[[ -n "$sync_info" ]] && line+="  ${FG_BYELLOW}⟳ ${sync_info}${RESET}"
	_MD_LINE="$line"
}

section_mdadm() {
	section_header "mdadm" "Linux Software RAID" "⚙"

	if [[ ! -r /proc/mdstat ]]; then
		box_line "   ${FG_YELLOW}⚠  /proc/mdstat not readable${RESET}"
		box_blank; return
	fi

	local md_found=false line
	local in_array=false arr_name='' arr_state='' arr_level='' arr_devs='' arr_status='' arr_sync=''
	local -a _arr_lines=()

	while IFS= read -r line; do
		if [[ "$line" =~ ^(md[[:alnum:]]+)[[:space:]]+:[[:space:]]+(active|inactive|read-auto)[[:space:]] ]]; then
			# Flush previous array before starting a new one
			if [[ "$in_array" == "true" ]]; then
				_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync"
				_arr_lines+=( "$_MD_LINE" )
			fi
			arr_name="${BASH_REMATCH[1]}"
			arr_state="${BASH_REMATCH[2]}"
			local _rest="${line#*"${arr_state}" }"
			[[ "${_rest:0:1}" == "(" ]] && _rest="${_rest#*) }"
			arr_level="${_rest%% *}"
			arr_devs="${_rest#* }"
			arr_status=''; arr_sync=''
			in_array=true; md_found=true

		elif [[ "$in_array" == "true" && "$line" =~ \[([U_]+)\] ]]; then
			arr_status="${BASH_REMATCH[1]}"

		elif [[ "$in_array" == "true" && "$line" =~ (resync|recovery|reshape|check)[[:space:]]*= ]]; then
			# The operation name comes from this match, not from ${line%%=*}:
			# the first '=' in the line sits inside the "[====>" progress bar,
			# so trimming there yields "[= 23.4%" instead of "recovery = 23.4%".
			local _op="${BASH_REMATCH[1]}" pct=''
			[[ "$line" =~ ([0-9]+\.[0-9]+)% ]] && pct="${BASH_REMATCH[1]}"
			if [[ -n "$pct" ]]; then
				arr_sync="${_op} = ${pct}%"
			else
				arr_sync="${line#"${line%%[![:space:]]*}"}"   # ltrim
			fi
		fi
	done < /proc/mdstat

	# Flush the last array
	if [[ "$in_array" == "true" ]]; then
		_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync"
		_arr_lines+=( "$_MD_LINE" )
	fi

	inner_rule dash

	if [[ "$md_found" == "false" || ${#_arr_lines[@]} -eq 0 ]]; then
		box_line "   ${DIM}No mdadm arrays configured${RESET}"
	else
		render_pairs _arr_lines
	fi

	box_blank
}


# =============================================================================
# ── DRIVES ────────────────────────────────────────────────────────────────────
# I/O throughput is read from /proc/diskstats on every fast frame.
# SMART data (health, temp, model, error counters) is expensive — smartctl
# blocks per device — so it is cached and re-polled only on slow frames.
# The cache is keyed by device name and persists across draw_dashboard calls
# in the main shell.
# =============================================================================
section_drives() {
	local smart_avail=false
	command -v smartctl &>/dev/null && smart_avail=true

	local _do_smart=false
	[[ "$smart_avail" == "true" && "$_DO_SLOW" == "true" ]] && _do_smart=true

	# ── Section header — show SMART poll age when data is cached ─────────────
	# _SLOW_LAST_TS is advanced by draw_dashboard before any section runs, so
	# this reads 0s on the frame that actually refreshed rather than showing
	# the previous interval's age.
	local _smart_note='' _smart_lbl=''
	if [[ "$smart_avail" == "true" ]]; then
		_smart_lbl=' · SMART Health'
		(( _SLOW_LAST_TS > 0 )) && \
			_smart_note="  ${DIM}· SMART polled $(( _NOW - _SLOW_LAST_TS ))s ago (every ${_SLOW_SECS}s)${RESET}"
	fi
	section_header "DRIVES" "I/O Throughput${_smart_lbl}${_smart_note}" "💾"

	# ── Pre-parse diskstats into lookup tables ────────────────────────────────
	local elapsed=0
	(( _DISK_PREV_TS > 0 && _NOW > _DISK_PREV_TS )) && elapsed=$(( _NOW - _DISK_PREV_TS ))

	# Fields: 3 = device name, 6 = sectors read, 10 = sectors written.
	# Read straight from the loop instead of a here-string per line — the old
	# form created a temp file for every one of ~50 diskstats rows, per frame.
	local -A _ds_r=() _ds_w=()
	local _dn _dr _dw
	if [[ -r /proc/diskstats ]]; then
		while read -r _ _ _dn _ _ _dr _ _ _ _dw _; do
			[[ -n "$_dn" ]] || continue
			_ds_r[$_dn]=$(( _dr * 512 ))
			_ds_w[$_dn]=$(( _dw * 512 ))
		done < /proc/diskstats
	fi

	# ── Device enumeration: physical + software RAID, straight from sysfs ─────
	# Whole disks have a device/ link; md arrays have an md/ directory and no
	# device/ link.  Globs replace the old lsblk|awk and awk|sort pipelines.
	local -a _devs=()
	local _p _b
	for _p in /sys/block/*; do
		[[ -e "$_p/device" ]] || continue
		_b="${_p##*/}"; _devs+=( "$_b" )
	done
	for _p in /sys/block/md*; do
		[[ -d "$_p/md" ]] || continue
		_b="${_p##*/}"; _devs+=( "$_b" )
	done

	if (( ${#_devs[@]} == 0 )); then
		inner_rule dash
		box_line "   ${DIM}No drives found${RESET}"
		box_blank; return
	fi

	# ── Collect per-drive data into parallel arrays before rendering ──────────
	local -a _line1=() _line2=()
	local devname

	for devname in "${_devs[@]}"; do
		# Fast path: I/O throughput from /proc/diskstats — no subprocess
		local bytes_r="${_ds_r[$devname]:-0}"
		local bytes_w="${_ds_w[$devname]:-0}"
		local rrc="$FG_BGREEN" rwc="$FG_BYELLOW" rrs rws
		if (( elapsed > 0 )); then
			local pr="${_DISK_PREV_R[$devname]:-0}" pw="${_DISK_PREV_W[$devname]:-0}"
			local dr=$(( bytes_r - pr )) dw=$(( bytes_w - pw ))
			(( dr < 0 )) && dr=0
			(( dw < 0 )) && dw=0
			fmt_rate $(( dr / elapsed )) rrs
			fmt_rate $(( dw / elapsed )) rws
		else
			rrs='—'; rws='—'; rrc="$DIM"; rwc="$DIM"
		fi
		_DISK_PREV_R[$devname]="$bytes_r"
		_DISK_PREV_W[$devname]="$bytes_w"

		local rrs_p rws_p tot_r tot_w tot_r_p
		printf -v rrs_p '%-12s' "$rrs"
		printf -v rws_p '%-12s' "$rws"
		fmt_bytes "$bytes_r" tot_r
		fmt_bytes "$bytes_w" tot_w
		printf -v tot_r_p '%-10s' "$tot_r"
		local io_col=" ↓ ${rrc}${rrs_p}${RESET}  ↑ ${rwc}${rws_p}${RESET}  ${DIM}R:${RESET} ${FG_WHITE}${tot_r_p}${RESET}  ${DIM}W:${RESET} ${FG_WHITE}${tot_w}${RESET}"

		# Slow path: SMART — run smartctl and update cache only on slow frames.
		# md* arrays have no SMART data and are always skipped.
		local hs hc tc rl pd uc mdl cap
		if [[ "$smart_avail" == "true" && "$devname" != md* ]]; then
			if [[ "$_do_smart" == "true" ]]; then
				local sout
				sout=$(smartctl -i -H -A "/dev/${devname}" 2>/dev/null)
				if [[ -n "$sout" ]]; then
					if   [[ "$sout" == *"PASSED"* ]]; then hs='PASSED'; hc="$FG_BGREEN"
					elif [[ "$sout" == *": OK"*   ]]; then hs='OK';     hc="$FG_BGREEN"
					elif [[ "$sout" == *"FAILED"* ]]; then hs='FAILED'; hc="$FG_BRED"
					else                                   hs='?';      hc="$FG_YELLOW"
					fi

					# One awk pass for attributes, model and capacity (was three,
					# one of them eval'd).  \037 (unit separator) delimits fields:
					# it cannot occur in a model string and is not IFS whitespace,
					# so empty fields survive the read.
					IFS=$'\037' read -r tc rl pd uc mdl cap < <(awk '
						BEGIN { OFS = "\037" }
						# Field 10 is raw value; avoids mis-parsing "34 (Min/Max 22/45)"
						$1+0==5   && NF>=10 && /Reallocated/ { rl = $10+0 }
						$1+0==190 && NF>=10 && !tc           { tc = $10+0 }
						$1+0==194 && NF>=10                  { tc = $10+0 }
						$1+0==197 && NF>=10 && /Pending/     { pd = $10+0 }
						$1+0==198 && NF>=10 && /Uncorrect/   { uc = $10+0 }
						/^Temperature:[ \t]/ && NF>=2 && !tc              { tc = $2+0 }
						/^Temperature Sensor 1:[ \t]/ && NF>=4 && !tc     { tc = $4+0 }
						/^Current Drive Temperature:[ \t]/ && NF>=4 && !tc { tc = $4+0 }
						/^(Device Model|Model Number|Model Family|Product):/ && mdl=="" {
							s = $0; sub(/^[^:]+:[ \t]*/, "", s); mdl = s
						}
						/^(User Capacity|Namespace 1 Size):/ && cap=="" {
							if (match($0, /\[[^\]]+\]/))       cap = substr($0, RSTART+1, RLENGTH-2)
							else if (match($0, /[0-9.]+ [KMGT]iB/)) cap = substr($0, RSTART, RLENGTH)
						}
						END { print (tc=="" ? "" : tc+0), rl+0, pd+0, uc+0, mdl, cap }
					' <<< "$sout")
					[[ ${#mdl} -gt 30 ]] && mdl="${mdl:0:27}…"
				else
					hs='?'; hc="$DIM"   # no output — likely not root
					tc=''; rl=''; pd=''; uc=''; mdl=''; cap=''
				fi
				# Write to cache
				_SMART_HS[$devname]="$hs";      _SMART_HC[$devname]="$hc"
				_SMART_TC[$devname]="${tc:-}";  _SMART_RL[$devname]="${rl:-0}"
				_SMART_PD[$devname]="${pd:-0}"; _SMART_UC[$devname]="${uc:-0}"
				_SMART_MDL[$devname]="${mdl:-}"; _SMART_CAP[$devname]="${cap:-}"
			fi

			# Read from cache (always — ensures consistent fast-frame rendering)
			hs="${_SMART_HS[$devname]:-}";   hc="${_SMART_HC[$devname]:-$DIM}"
			tc="${_SMART_TC[$devname]:-}";   rl="${_SMART_RL[$devname]:-0}"
			pd="${_SMART_PD[$devname]:-0}";  uc="${_SMART_UC[$devname]:-0}"
			mdl="${_SMART_MDL[$devname]:-}"; cap="${_SMART_CAP[$devname]:-}"
		else
			hs=''; hc="$DIM"; tc=''; rl=0; pd=0; uc=0; mdl=''; cap=''
		fi

		# Build display strings from (possibly cached) raw values
		local temps='      ' mdls='' errs=''
		if [[ "$tc" =~ ^[0-9]+$ ]] && (( tc > 0 )); then
			local tcol
			if   (( tc >= 55 )); then tcol="$FG_BRED"
			elif (( tc >= 45 )); then tcol="$FG_BYELLOW"
			else                      tcol="$FG_BGREEN"
			fi
			# Fixed 6 visual-char slot: "   9°C" / "  34°C" / " 100°C"
			local tc_lead
			case ${#tc} in
				1) tc_lead="   " ;;
				2) tc_lead="  "  ;;
				*) tc_lead=" "   ;;
			esac
			temps="${tc_lead}${tcol}${tc}°C${RESET}"
		fi
		if [[ -n "$mdl" ]]; then
			mdls="  ${DIM}${mdl}${cap:+  (${cap})}${RESET}"
		fi
		if [[ "${rl:-0}" != "0" || "${pd:-0}" != "0" || \
			"${uc:-0}" != "0" || "$hs" == "FAILED" ]]; then
			local rc pc ucc
			[[ "${rl:-0}" != "0" ]] && rc="$FG_BRED"    || rc="$DIM"
			[[ "${pd:-0}" != "0" ]] && pc="$FG_BYELLOW" || pc="$DIM"
			[[ "${uc:-0}" != "0" ]] && ucc="$FG_BRED"   || ucc="$DIM"
			errs=" ${_PAD10}  ⚠  ${rc}Reallocated: ${rl:-0}${RESET}   ${pc}Pending: ${pd:-0}${RESET}   ${ucc}Uncorrectable: ${uc:-0}${RESET}"
		fi

		local dev_pad hs_pad
		printf -v dev_pad '%-10s' "$devname"
		printf -v hs_pad  '%-8s'  "${hs:-n/a}"
		_line1+=( " ${FG_BWHITE}${dev_pad}${RESET}  ${hc}${hs_pad}${RESET}${temps}${io_col}${mdls}" )
		_line2+=( "$errs" )
	done

	_DISK_PREV_TS="$_NOW"

	# ── Render ────────────────────────────────────────────────────────────────
	local n=${#_line1[@]}
	inner_rule dash

	if (( n == 0 )); then
		box_line "   ${DIM}No drives found${RESET}"
	elif (( INNER_WIDTH >= 140 )); then
		# Two-column grid: drives paired left/right, one band per pair.
		# Not render_pairs — each drive owns two lines that must stay together.
		local i=0
		while (( i < n )); do
			local j=$(( i + 1 ))
			local l1="${_line1[$i]}" l2="${_line2[$i]}" r1='' r2=''
			(( j < n )) && { r1="${_line1[$j]}"; r2="${_line2[$j]}"; }

			two_col_row "$l1" "$r1"
			[[ -n "$l2" || -n "$r2" ]] && two_col_row "$l2" "$r2"

			i=$(( i + 2 ))
		done
	else
		# Narrow terminal — single column
		local i
		for (( i=0; i<n; i++ )); do
			box_line "${_line1[$i]}"
			[[ -n "${_line2[$i]}" ]] && box_line "${_line2[$i]}"
		done
	fi

	box_blank
}


# =============================================================================
# ── VOLUMES ───────────────────────────────────────────────────────────────────
# =============================================================================
section_volumes() {
	section_header "VOLUMES" "Filesystem Space Usage" "📊"

	local df_out
	df_out=$(df -k --output=target,size,used,avail,pcent,fstype 2>/dev/null)

	if [[ -z "$df_out" ]]; then
		box_line "   ${FG_YELLOW}⚠  df failed${RESET}"
		box_blank; return
	fi

	# Collect formatted volume entries so we can pair them for two-column output
	local -a _vols=()
	local mp sz_k used_k avail_k pct_str fstype

	# Fields are split by the loop's own read — the old inner `read <<< "$line"`
	# created a temp file per filesystem.
	while read -r mp sz_k used_k avail_k pct_str fstype; do
		[[ "$mp" == 'Mounted' ]] && continue

		case "$fstype" in
			tmpfs|devtmpfs|squashfs|overlay|sysfs|proc|cgroup|cgroup2|\
			fusectl|debugfs|tracefs|securityfs|pstore|bpf|hugetlbfs|\
			mqueue|ramfs|autofs|rpc_pipefs|nfsd|configfs|efivarfs|\
			iso9660|udf) continue ;;
		esac
		case "$mp" in
			/proc|/proc/*|/sys|/sys/*|/dev/pts|/run/user/*|/snap/*) continue ;;
		esac
		[[ -z "$mp" || -z "$fstype" || -z "$sz_k" ]] && continue

		local pct="${pct_str//%/}"
		[[ "$pct" =~ ^[0-9]+$ ]] || pct=0

		local used_b=$(( used_k * 1024 ))
		local sz_b=$(( sz_k * 1024 ))

		local pct_col
		if   (( pct >= 90 )); then pct_col="$FG_BRED"
		elif (( pct >= 75 )); then pct_col="$FG_BYELLOW"
		else                       pct_col="$FG_BGREEN"
		fi

		local bar mp_pad fs_pad pct_pad used_h sz_h
		pct_bar "$pct" 12 bar
		printf -v mp_pad  '%-20s' "$mp"
		printf -v fs_pad  '%-6s'  "$fstype"
		printf -v pct_pad '%3d'   "$pct"
		fmt_bytes "$used_b" used_h
		fmt_bytes "$sz_b"   sz_h

		_vols+=( " ${FG_BWHITE}${mp_pad}${RESET}  ${DIM}${fs_pad}${RESET}  ${bar}  ${pct_col}${pct_pad}%${RESET}  ${FG_WHITE}${used_h}${RESET}${DIM}/${RESET}${FG_WHITE}${sz_h}${RESET}" )
	done <<< "$df_out"

	inner_rule dash

	if (( ${#_vols[@]} == 0 )); then
		box_line "   ${DIM}No real filesystems found${RESET}"
	else
		render_pairs _vols
	fi

	box_blank
}

# =============================================================================
# ── NFS ───────────────────────────────────────────────────────────────────────
# =============================================================================
section_nfs() {
	section_header "NFS" "NFS Kernel Server" "📂"

	local svc='nfs-server'   # systemd unit name on Debian (pkg: nfs-kernel-server)
	local nfs_active="${_SVC_ACTIVE[$svc]-}"
	local nfs_badge nfs_enabled nfs_uptime rpc_badge rpc_enabled
	svc_status_badge  "$svc"     nfs_badge
	svc_enabled_badge "$svc"     nfs_enabled
	svc_uptime        "$svc"     nfs_uptime
	svc_status_badge  'rpcbind'  rpc_badge
	svc_enabled_badge 'rpcbind'  rpc_enabled

	two_col_row " ${nfs_badge}  ${DIM}Boot:${RESET} ${nfs_enabled}  ${DIM}Up:${RESET} ${nfs_uptime}" " ${DIM}rpcbind:${RESET}  ${rpc_badge}  ${DIM}Boot:${RESET} ${rpc_enabled}"

	# ── Exports ───────────────────────────────────────────────────────────────
	inner_rule dash
	if command -v exportfs &>/dev/null; then
		local exports_raw
		exports_raw=$(exportfs -v 2>/dev/null)
		if [[ -n "$exports_raw" ]]; then
			# Counted in the loop rather than with a separate grep -c pass.
			local _xre='^(/[^[:space:]]+)[[:space:]]+([^(]+)'
			local -a _exp_lines=()
			local xline xpath xclient export_count=0
			while IFS= read -r xline; do
				[[ "$xline" == /* ]] || continue
				export_count=$(( export_count + 1 ))
				[[ "$xline" =~ $_xre ]] || continue
				xpath="${BASH_REMATCH[1]}"
				xclient="${BASH_REMATCH[2]%% }"   # trim trailing space
				_exp_lines+=( " ${FG_BWHITE}${xpath}${RESET}  ${DIM}→  ${xclient}${RESET}" )
			done <<< "$exports_raw"
			kv_line "Exports     " "${FG_BWHITE}${export_count}${RESET}  ${DIM}active${RESET}"
			render_pairs _exp_lines
		else
			kv_line "Exports     " "${DIM}none (or exportfs requires root)${RESET}"
		fi
	else
		kv_line "Exports     " "${DIM}exportfs not found${RESET}"
	fi

	# ── Active client mounts ──────────────────────────────────────────────────
	# showmount contacts the local mountd and can block; it rides the slow
	# cadence with the other expensive probes.
	if command -v showmount &>/dev/null && [[ "$nfs_active" == "active" ]]; then
		[[ "$_DO_SLOW" == "true" ]] && _NFS_MOUNTS=$(showmount -a --no-headers 2>/dev/null)
		if [[ -n "$_NFS_MOUNTS" ]]; then
			local -A _hosts=()
			local mline
			while IFS= read -r mline; do
				[[ -z "$mline" ]] && continue
				_hosts["${mline%%:*}"]=1
			done <<< "$_NFS_MOUNTS"
			kv_line "Clients     " "${FG_BWHITE}${#_hosts[@]}${RESET}  ${DIM}unique host(s) with active mounts${RESET}"
		fi
	fi

	# ── Server I/O and RPC stats from /proc ───────────────────────────────────
	local nfsd_rpc='/proc/net/rpc/nfsd'
	if [[ -r "$nfsd_rpc" ]]; then
		inner_rule dash
		local io_r=0 io_w=0 net_tcp=0 rpc_calls=0 th_count='?'
		local tag f2 f3 f4
		while read -r tag f2 f3 f4 _; do
			case "$tag" in
				io)  io_r="$f2"; io_w="$f3" ;;
				net) net_tcp="$f4"          ;;
				rpc) rpc_calls="$f2"        ;;
				th)  th_count="$f2"         ;;
			esac
		done < "$nfsd_rpc"

		local io_r_h io_w_h
		fmt_bytes "${io_r:-0}" io_r_h
		fmt_bytes "${io_w:-0}" io_w_h
		kv_line "RPC calls   " "${FG_BWHITE}${rpc_calls:-0}${RESET}  ${DIM}threads: ${th_count:-?}   TCP conn: ${net_tcp:-0}${RESET}"
		kv_line "I/O (total) " "Read: ${FG_BWHITE}${io_r_h}${RESET}   Write: ${FG_BWHITE}${io_w_h}${RESET}  ${DIM}since mount${RESET}"
	fi

	box_blank
}

# =============================================================================
# ── SAMBA ─────────────────────────────────────────────────────────────────────
# =============================================================================
section_samba() {
	# smbstatus locks the Samba tdb files and is slow on a busy server, so both
	# calls ride the slow cadence.  The age is shown in the header rather than
	# left implicit, since a new session can take up to one slow interval to
	# appear.
	local _smb_note=''
	(( _SLOW_LAST_TS > 0 )) && \
		_smb_note="  ${DIM}· sessions polled $(( _NOW - _SLOW_LAST_TS ))s ago (every ${_SLOW_SECS}s)${RESET}"
	section_header "SAMBA" "SMB/CIFS File Server${_smb_note}" "🖧"

	local st en
	svc_status_badge  'smbd' st
	svc_enabled_badge 'smbd' en
	kv_line "smbd   " "${st}  Boot: ${en}"

	# nmbd and winbind are optional — presence resolved once at startup
	if [[ "$_NMBD_PRESENT" == "true" ]]; then
		svc_status_badge  'nmbd' st
		svc_enabled_badge 'nmbd' en
		kv_line "nmbd   " "${st}  Boot: ${en}"
	fi
	if [[ "$_WINBIND_PRESENT" == "true" ]]; then
		svc_status_badge  'winbind' st
		svc_enabled_badge 'winbind' en
		kv_line "winbind" "${st}  Boot: ${en}"
	fi

	# ── Active sessions ───────────────────────────────────────────────────────
	inner_rule dash
	if command -v smbstatus &>/dev/null; then
		if [[ "$_DO_SLOW" == "true" ]]; then
			_SMB_BRIEF=$(smbstatus --brief 2>/dev/null)
			_SMB_SHARES=$(smbstatus --shares 2>/dev/null)
		fi

		if [[ -n "$_SMB_BRIEF" ]]; then
			# Session lines begin with a PID (digit)
			local -a _sess_lines=()
			local sline s_user s_machine s_ip
			while IFS= read -r sline; do
				[[ "$sline" == [0-9]* ]] || continue
				# columns: pid username group machine(ip)
				read -r _ s_user _ s_machine _ <<< "$sline"
				s_ip=''
				[[ "$sline" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]] \
					&& s_ip="${BASH_REMATCH[1]}"
				_sess_lines+=( "      ${FG_WHITE}${s_user}${RESET}  ${DIM}@  ${s_machine%%(*}${s_ip:+(${s_ip})}${RESET}" )
			done <<< "$_SMB_BRIEF"

			kv_line "Sessions    " "${FG_BWHITE}${#_sess_lines[@]}${RESET}  ${DIM}active${RESET}"
			local sl
			for sl in "${_sess_lines[@]}"; do box_line "$sl"; done
		else
			kv_line "Sessions    " "${DIM}smbstatus requires root${RESET}"
		fi

		# Open share connections
		if [[ -n "$_SMB_SHARES" ]]; then
			local shline share_count=0
			while IFS= read -r shline; do
				[[ "$shline" == [[:alnum:]]* ]] || continue
				[[ "$shline" == Service* ]] && continue
				share_count=$(( share_count + 1 ))
			done <<< "$_SMB_SHARES"
			kv_line "Connections " "${FG_BWHITE}${share_count}${RESET}  ${DIM}open share connection(s)${RESET}"
		fi
	else
		box_line "   ${DIM}smbstatus not found${RESET}"
	fi

	box_blank
}

# =============================================================================
# ── NETWORK ───────────────────────────────────────────────────────────────────
# =============================================================================
section_network() {
	section_header "NETWORK" "Interface Status & Throughput" "🌐"

	local net_dev='/proc/net/dev'
	if [[ ! -r "$net_dev" ]]; then
		box_line "   ${FG_YELLOW}⚠  /proc/net/dev not readable${RESET}"
		box_blank; return
	fi

	# Elapsed seconds since last sample — used for throughput rate calculation.
	# _NET_PREV_TS is set at script scope and persists across draw_dashboard calls.
	local elapsed=0
	(( _NET_PREV_TS > 0 && _NOW > _NET_PREV_TS )) && elapsed=$(( _NOW - _NET_PREV_TS ))

	# One `ip` call for every interface, parsed in-shell.  The old code ran
	# ip | awk | sed per interface — three forks each, every frame.
	local -A _ip_addrs=()
	local ifn irest
	if command -v ip &>/dev/null; then
		while read -r ifn _ irest; do
			[[ -z "$ifn" ]] && continue
			ifn="${ifn%%@*}"          # veth peers appear as "veth0@if12"
			_ip_addrs["$ifn"]="${irest// /  }"
		done < <(ip -br addr show 2>/dev/null)
	fi

	local any_shown=false line

	# /proc/net/dev columns: rx: bytes packets errors drop fifo frame compressed multicast
	#                        tx: bytes packets errors drop ...
	local _net_re='^([^:]+):[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)'
	while IFS= read -r line; do
		# Strip leading whitespace; skip header lines and loopback
		line="${line#"${line%%[![:space:]]*}"}"
		[[ "$line" == lo:* ]] && continue
		[[ "$line" =~ $_net_re ]] || continue

		local iface="${BASH_REMATCH[1]}"
		local rx_bytes="${BASH_REMATCH[2]}"  rx_pkts="${BASH_REMATCH[3]}"
		local rx_err="${BASH_REMATCH[4]}"    rx_drop="${BASH_REMATCH[5]}"
		local tx_bytes="${BASH_REMATCH[6]}"  tx_pkts="${BASH_REMATCH[7]}"
		local tx_err="${BASH_REMATCH[8]}"    tx_drop="${BASH_REMATCH[9]}"

		# Skip completely idle interfaces — zero I/O in both directions since boot
		# means the port is unused. Active ports always accumulate at least ARP traffic.
		[[ "$rx_bytes" == "0" && "$tx_bytes" == "0" ]] && continue

		# Read operstate from sysfs (see read_sysfs — no fork, no stderr leak).
		local operstate link_col
		read_sysfs "/sys/class/net/${iface}/operstate" operstate
		[[ -z "$operstate" ]] && operstate='unknown'
		case "$operstate" in
			up)      link_col="$FG_BGREEN"  ;;
			down)    link_col="$FG_BRED"    ;;
			*)       link_col="$FG_YELLOW"  ;;
		esac

		inner_rule dash
		any_shown=true

		# Speed / duplex
		local speed duplex speed_str=''
		read_sysfs "/sys/class/net/${iface}/speed"  speed
		read_sysfs "/sys/class/net/${iface}/duplex" duplex
		if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
			if (( speed >= 1000 )); then
				speed_str="  ${FG_BWHITE}$(( speed / 1000 )) Gbps${RESET}${duplex:+  ${DIM}${duplex}${RESET}}"
			else
				speed_str="  ${FG_WHITE}${speed} Mbps${RESET}${duplex:+  ${DIM}${duplex}${RESET}}"
			fi
		fi

		local ip_str="${_ip_addrs[$iface]-}"

		box_line "   ${BOLD}${FG_BWHITE}${iface}${RESET}  ${link_col}${operstate}${RESET}${speed_str}"
		[[ -n "$ip_str" ]] && box_line "      ${DIM}${ip_str}${RESET}"

		# Throughput — only meaningful after first sample
		if (( elapsed > 0 )); then
			local prev_rx="${_NET_PREV_RX[$iface]:-0}"
			local prev_tx="${_NET_PREV_TX[$iface]:-0}"
			local delta_rx=$(( rx_bytes - prev_rx ))
			local delta_tx=$(( tx_bytes - prev_tx ))
			(( delta_rx < 0 )) && delta_rx=0   # counter wrap
			(( delta_tx < 0 )) && delta_tx=0
			local rrx rtx rrx_p rtx_p tot_rx tot_tx tot_rx_p
			fmt_rate $(( delta_rx / elapsed )) rrx
			fmt_rate $(( delta_tx / elapsed )) rtx
			printf -v rrx_p '%-14s' "$rrx"
			printf -v rtx_p '%-14s' "$rtx"
			fmt_bytes "$rx_bytes" tot_rx
			fmt_bytes "$tx_bytes" tot_tx
			printf -v tot_rx_p '%-12s' "$tot_rx"
			box_line "      ↓ ${FG_BGREEN}${rrx_p}${RESET}  ↑ ${FG_BYELLOW}${rtx_p}${RESET}  ${DIM}tot ↓${RESET} ${FG_WHITE}${tot_rx_p}${RESET}  ${DIM}↑${RESET} ${FG_WHITE}${tot_tx}${RESET}  ${DIM}since boot${RESET}"
		else
			box_line "      ${DIM}↓ —   ↑ —   awaiting second sample…${RESET}"
		fi

		# Errors — only show the row when at least one counter is non-zero
		if (( rx_err + tx_err + rx_drop + tx_drop > 0 )); then
			local ec_rxe ec_txe ec_rxd ec_txd
			(( rx_err  > 0 )) && ec_rxe="$FG_BRED"    || ec_rxe="$DIM"
			(( tx_err  > 0 )) && ec_txe="$FG_BRED"    || ec_txe="$DIM"
			(( rx_drop > 0 )) && ec_rxd="$FG_BYELLOW" || ec_rxd="$DIM"
			(( tx_drop > 0 )) && ec_txd="$FG_BYELLOW" || ec_txd="$DIM"
			box_line "      ${ec_rxe}RX err: ${rx_err}${RESET}  ${ec_txe}TX err: ${tx_err}${RESET}  ${ec_rxd}RX drop: ${rx_drop}${RESET}  ${ec_txd}TX drop: ${tx_drop}${RESET}"
		fi

		# Update previous sample values (main-shell write; persists across refreshes)
		_NET_PREV_RX[$iface]="$rx_bytes"
		_NET_PREV_TX[$iface]="$tx_bytes"

	done < "$net_dev"

	# Advance timestamp after processing all interfaces
	_NET_PREV_TS="$_NOW"

	[[ "$any_shown" == "false" ]] && { inner_rule dash; box_line "   ${DIM}No active interfaces found${RESET}"; }

	box_blank
}

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================

# Minimal placeholder so the alternate screen is never blank during startup.
draw_loading() {
	_BUF=''
	box_blank
	box_line "${BOLD}${FG_BCYAN}⬡  File Server — Status Dashboard${RESET}" \
		$(( (INNER_WIDTH - 36) / 2 ))
	box_blank
	inner_rule mid
	box_blank
	box_line "   ${DIM}Gathering service data…${RESET}"
	box_blank
	printf '\033[H'
	outer_top
	printf '%s' "$_BUF"
	outer_bottom
	printf '\033[J'
	_BUF=''   # clear so the stale-frame flush in main skips on the first real draw
}

draw_dashboard() {
	_BUF=''
	local ts
	_NOW=$EPOCHSECONDS                                       # no fork
	printf -v ts '%(%A %d %B %Y  %H:%M:%S %Z)T' "$_NOW"      # bash strftime builtin

	# Slow-frame decision, shared by every expensive probe.  _SLOW_LAST_TS is
	# advanced *before* rendering so "polled Ns ago" reads 0s on the frame that
	# actually refreshed.
	_SLOW_SECS=$(( REFRESH_INTERVAL * SMART_INTERVAL_MULT ))
	_DO_SLOW=false
	(( _SLOW_LAST_TS == 0 || _NOW - _SLOW_LAST_TS >= _SLOW_SECS )) && _DO_SLOW=true
	[[ "$_DO_SLOW" == "true" ]] && _SLOW_LAST_TS=$_NOW

	local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"

	svc_fetch_all   # one systemctl call covering every unit

	box_blank
	box_line "${BOLD}${FG_BCYAN}⬡  File Server — Status Dashboard${RESET}" \
		$(( (INNER_WIDTH - 36) / 2 ))
	box_line "${DIM}${FG_WHITE}${_HOSTNAME}   ·   ${ts}${RESET}" \
		$(( (INNER_WIDTH - ${#_HOSTNAME} - ${#ts} - 7) / 2 ))
	box_blank
	inner_rule mid

	if [[ "$_ZFS_PRESENT" == "true" ]]; then
		section_zfs
		inner_rule mid
	fi
	if [[ "$_MDADM_PRESENT" == "true" ]]; then
		section_mdadm
		inner_rule mid
	fi
	section_drives
	inner_rule mid
	section_volumes
	inner_rule mid
	if [[ "$_NFS_PRESENT" == "true" ]]; then
		section_nfs
		inner_rule mid
	fi
	if [[ "$_SAMBA_PRESENT" == "true" ]]; then
		section_samba
		inner_rule mid
	fi
	section_network

	inner_rule thin

	# Count newlines already in _BUF to find the row the footer will land on.
	# outer_top prints one line before _BUF, hence +1.
	local _nl="${_BUF//[^$'\n']/}"
	_FOOTER_ROW=$(( 1 + ${#_nl} ))

	if [[ "$_PLAIN" != "true" ]]; then
		if [[ "$PAUSED" == "true" ]]; then
			box_line "   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nice_disp}   p resume · r refresh · i interval · n nice · h help · q quit${RESET}"
		else
			box_line "   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nice_disp}${RESET}  ${DIM}Last: ${LAST_REFRESH}   p pause · r refresh · i interval · n nice · h help · q quit${RESET}"
		fi
	fi

	if (( EUID != 0 )); then
		box_line "   ${FG_YELLOW}⚠  Run with sudo for full access: exportfs, smbstatus, smartctl${RESET}"
	fi

	if [[ "$SHOW_HELP" == "true" ]]; then
		inner_rule dash
		box_line "   ${FG_BCYAN}${BOLD}Key Bindings${RESET}"
		inner_rule dash
		box_line "   ${FG_CYAN}q / Q / Ctrl-C  ${RESET}  Quit"
		box_line "   ${FG_CYAN}p / P           ${RESET}  Pause / unpause auto-refresh"
		box_line "   ${FG_CYAN}r / R           ${RESET}  Force immediate refresh"
		box_line "   ${FG_CYAN}i               ${RESET}  Set refresh interval  (prompted, 1–300 s)"
		box_line "   ${FG_CYAN}n               ${RESET}  Set nice value        (prompted, -20–19)"
		box_line "   ${FG_CYAN}h / ?           ${RESET}  Toggle this help overlay"
		box_line "   ${DIM}Settings auto-saved to: ${CFG_FILE}${RESET}"
	fi

	box_blank
}

# Terminal restoration must survive every exit path — including SIGHUP from a
# closed terminal and any unexpected error — or the user is left in the
# alternate screen with echo off.  restore_tty is idempotent and never exits.
_RESTORED=false
restore_tty() {
	[[ "$_RESTORED" == "true" ]] && return
	_RESTORED=true
	[[ "$ONE_SHOT" == "true" ]] && return
	printf '\033[?25h\033[?1049l'
	if [[ -n "$_TTY_STATE" ]]; then
		stty "$_TTY_STATE" 2>/dev/null || stty echo 2>/dev/null
	else
		stty echo 2>/dev/null
	fi
}
trap restore_tty EXIT
trap 'restore_tty; exit 0' INT TERM HUP QUIT

# SIGWINCH: $COLUMNS isn't updated until after the next external command
# completes, so tput cols is used here for an accurate immediate read.
trap '_NEED_REDRAW=true
TERM_WIDTH=$(tput cols 2>/dev/null || printf "%s" "${COLUMNS:-80}")
INNER_WIDTH=$(( TERM_WIDTH - 2 ))
rebuild_fills' WINCH

do_draw() {
	printf '\033[H'
	outer_top
	printf '%s' "$_BUF"
	outer_bottom
	printf '\033[J'   # erase stale lines below (e.g. after help is toggled off)
}

sync_dimensions() {
	TERM_WIDTH=${COLUMNS:-80}
	INNER_WIDTH=$(( TERM_WIDTH - 2 ))
	(( INNER_WIDTH != _LAST_WIDTH )) && rebuild_fills
}

main() {
	if [[ "$ONE_SHOT" == "true" ]]; then
		_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
		sync_dimensions
		printf -v LAST_REFRESH '%(%H:%M:%S)T' -1
		draw_dashboard
		outer_top
		printf '%s' "$_BUF"
		outer_bottom
		return
	fi

	printf '\033[?1049h\033[?25l'   # enter alternate screen, hide cursor

	# Capture tty state before any read -s can touch it.
	_TTY_STATE=$(stty -g 2>/dev/null)
	stty -echo 2>/dev/null

	sync_dimensions
	draw_loading

	# hostname -f may do a DNS lookup; run it after the loading frame is up.
	_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')

	local force_refresh=true
	local key=''
	local _t0=0   # draw start time; used to subtract draw duration from the wait

	while true; do
		# Belt-and-suspenders resize check for multiplexers that don't send SIGWINCH.
		sync_dimensions

		if [[ "$PAUSED" == "false" || "$force_refresh" == "true" || "$_NEED_REDRAW" == "true" ]]; then
			# Show the previous frame immediately while the probes run.
			[[ -n "$_BUF" ]] && do_draw

			[[ "$PAUSED" == "false" || "$force_refresh" == "true" ]] \
				&& printf -v LAST_REFRESH '%(%H:%M:%S)T' -1
			force_refresh=false
			_NEED_REDRAW=false
			_t0=$EPOCHSECONDS
			draw_dashboard
			do_draw
		fi

		key=''
		if [[ "$PAUSED" == "true" ]]; then
			IFS= read -r -s -n 1 key 2>/dev/null || true
		else
			# Subtract draw_dashboard duration so total cycle ≈ REFRESH_INTERVAL.
			# Without this, sequential smartctl calls (one per drive) stack on top
			# of the full interval wait, doubling the apparent refresh time.
			local _elapsed=$(( EPOCHSECONDS - _t0 ))
			local _wait=$(( REFRESH_INTERVAL - _elapsed ))
			(( _wait < 1 )) && _wait=1
			IFS= read -r -s -n 1 -t "$_wait" key 2>/dev/null || true
		fi

		# Drain any multi-byte escape sequence (arrow keys, F-keys, etc.)
		if [[ "$key" == $'\033' ]]; then
			local _seq=''
			IFS= read -r -s -n 4 -t 0.05 _seq 2>/dev/null || true
		fi

		case "$key" in
			$'\003'|q|Q) restore_tty; exit 0 ;;   # Ctrl+C or q

			p|P)
				[[ "$PAUSED" == "true" ]] && PAUSED=false || PAUSED=true
				force_refresh=true ;;

			r|R)
				PAUSED=false; force_refresh=true ;;

			i|I)
				prompt_input 'interval'
				draw_footer_row   # show new value before the next re-query
				force_refresh=true ;;

			n|N)
				prompt_input 'nice'
				draw_footer_row
				force_refresh=true ;;

			'h'|'?')
				[[ "$SHOW_HELP" == "true" ]] && SHOW_HELP=false || SHOW_HELP=true
				force_refresh=true ;;
		esac
	done
}

main "$@"
