#!/usr/bin/env bash
# =============================================================================
# net-core-status — Network Core Services Dashboard
# Services: unbound (DNS), kea (DHCP), chrony (NTP)
# Target:   Debian 13
# =============================================================================

# checkwinsize keeps $COLUMNS fresh after external commands complete.
shopt -s checkwinsize

# ── Defaults ──────────────────────────────────────────────────────────────────
DEF_REFRESH_INTERVAL=2
DEF_NICE_VALUE=10
DEF_SLOW_INTERVAL_MULT=20
DEF_SOCAT_TIMEOUT=1

REFRESH_INTERVAL=$DEF_REFRESH_INTERVAL
NICE_VALUE=$DEF_NICE_VALUE
ONE_SHOT=false
SLOW_INTERVAL_MULT=$DEF_SLOW_INTERVAL_MULT  # unbound/chrony/kea-stats polled every MULT × REFRESH_INTERVAL s
SOCAT_TIMEOUT=$DEF_SOCAT_TIMEOUT            # per-call timeout for Kea control socket queries

# ── Drop-rate thresholds (per-mille of pkt4-received) ─────────────────────────
# pkt4-receive-drop is not a loss counter: it also counts packets addressed to
# another server, malformed frames, and class-rejected clients.  A small
# nonzero baseline is normal, so colour on rate, not on the raw count.
DROP_WARN_PM=1     # 0.1%
DROP_CRIT_PM=10    # 1.0%
DROP_MIN_SAMPLE=200

# ── Live state ────────────────────────────────────────────────────────────────
PAUSED=false
SHOW_HELP=false
LAST_REFRESH='—'
_NEED_REDRAW=false
_FOOTER_ROW=0       # terminal row the footer occupies; set each draw
_TTY_STATE=''       # tty state captured at startup, before any read -s
_HOSTNAME=''        # cached once — hostname -f can trigger a DNS lookup
_NOW=0              # epoch seconds, set once per draw_dashboard call
_PLAIN=false        # true when output is not a terminal (one-shot to a pipe)

# ── Slow-cadence data cache ───────────────────────────────────────────────────
# unbound-control, chronyc, and Kea's statistic-get-all output are cached here
# and re-polled only every SLOW_INTERVAL_MULT × REFRESH_INTERVAL seconds.
# Kea *lease* queries stay on the fast cycle for live lease visibility.
_UB_STATS_RAW=''      # unbound-control stats_noreset output
_CHR_TRACKING_RAW=''  # chronyc tracking output
_CHR_SOURCES_RAW=''   # chronyc sources output
_PKT4_RCV=0 _PKT4_SENT=0 _PKT4_DROP=0 _PKT4_OK=false
_SLOW_LAST_TS=0       # epoch of last slow-cadence poll
_DO_SLOW=false        # true on frames that trigger a slow poll
_SLOW_SECS=0          # effective slow interval in seconds (computed each frame)

# ── systemd state, fetched for every unit in one call per frame ───────────────
SVC_UNITS=('unbound' 'kea-dhcp4-server' 'kea-dhcp6-server' 'kea-dhcp-ddns-server' 'chrony')
declare -A _SVC_ACTIVE _SVC_ENABLED _SVC_START _TS_CACHE

# ── Config (XDG-compliant) ────────────────────────────────────────────────────
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CFG_FILE="$CFG_DIR/net-core-status.conf"

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

# Thousands separators without awk: mawk (Debian's default awk) silently
# ignores printf's ' flag, and gawk needs a locale that defines a separator.
_GN=''
group_num() {
	local n="$1" out='' neg=''
	[[ "$n" == -* ]] && { neg='-'; n="${n#-}"; }
	while (( ${#n} > 3 )); do
		out=",${n: -3}$out"
		n="${n:0:${#n}-3}"
	done
	_GN="${neg}${n}${out}"
}

# Decimal string → integer nanoseconds, so float comparisons stay in bash.
_FNS=0
float_ns() {
	local f="$1" ip fp
	[[ "$f" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { _FNS=-1; return 1; }
	ip="${f%%.*}"
	fp="${f#*.}"
	[[ "$fp" == "$f" ]] && fp=0
	fp="${fp}000000000"; fp="${fp:0:9}"
	_FNS=$(( 10#$ip * 1000000000 + 10#$fp ))
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
			SLOW_INTERVAL_MULT)  clamp "$val" 1 600 && SLOW_INTERVAL_MULT=$_CLAMP  ;;
			SOCAT_TIMEOUT)       clamp "$val" 1 30 && SOCAT_TIMEOUT=$_CLAMP        ;;
		esac
	done < "$CFG_FILE"
}

save_config() {
	mkdir -p "$CFG_DIR"
	{
		printf '# net-core-status — saved %s\n' "$(date '+%F %T')"
		printf 'REFRESH_INTERVAL=%s\n'   "$REFRESH_INTERVAL"
		printf 'NICE_VALUE=%s\n'         "$NICE_VALUE"
		printf 'SLOW_INTERVAL_MULT=%s\n' "$SLOW_INTERVAL_MULT"
		printf 'SOCAT_TIMEOUT=%s\n'      "$SOCAT_TIMEOUT"
	} > "$CFG_FILE"
}

# Overwrite only the footer row so the rest of the frame stays visible.
# Restoring _TTY_STATE gives echo-on canonical mode for comfortable editing.
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

# Write just the footer line in-place; called after prompt_input so the new
# value is visible before the next full service re-query completes.
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

Network core services status dashboard — unbound · kea · chrony.

Options:
  -i, --interval SECS  Auto-refresh interval, seconds  (1–300,  default: $DEF_REFRESH_INTERVAL)
  -n, --nice     N     Nice value for the dashboard    (-20–19, default: $DEF_NICE_VALUE)
  -1, --once           Render once and exit (non-interactive / scriptable)
  -h, --help           Show this help and exit
      --help-kea       Show Kea DHCP socket setup requirements and exit

Live key bindings (while running):
  q / Q / Ctrl-C   Quit
  p / P            Pause / unpause auto-refresh
  r / R            Force immediate refresh
  i                Set refresh interval (prompted, 1–300 s)
  n                Set nice value      (prompted, -20–19)
  h / ?            Toggle key-binding help overlay

Settings changed interactively are persisted to:
  $CFG_FILE

Current effective settings: interval=${REFRESH_INTERVAL}s  nice=${NICE_VALUE}
EOF
}

usage_kea() {
	cat <<EOF
Kea DHCP lease counting — socket requirements
==============================================

Accurate lease counts are read live from the Kea control socket using the
stat-lease4-get / stat-lease6-get commands.  Two things must be in place:

1. Control socket
   Add the following stanza inside the "Dhcp4": { } block in kea-dhcp4.conf
   (and equivalently in kea-dhcp6.conf if DHCPv6 is in use):

     "control-socket": {
         "socket-type": "unix",
         "socket-name": "/run/kea/kea4-ctrl-socket"
     },

   The socket directory /run/kea/ is owned by _kea:_kea and not world-
   readable, so the dashboard must be run as root (via sudo, su, or
   equivalent).

2. stat_cmds hook library
   The stat-lease4-get command is provided by the stat_cmds hook, which is
   not loaded by default.  Add it to the "hooks-libraries" array:

     "hooks-libraries": [
         {
             "library": "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_stat_cmds.so"
         }
     ],

   Verify the library path on your system:
     find /usr/lib -name 'libdhcp_stat_cmds.so' 2>/dev/null

   After editing the config, restart the service:
     systemctl restart kea-dhcp4-server

3. Verify the socket is responding correctly
   The following should return JSON with "result": 0 and row data:

     printf '{"command":"stat-lease4-get","service":["dhcp4"]}' \\
       | sudo socat -t2 - UNIX-CONNECT:/run/kea/kea4-ctrl-socket

Fallback behavior
   If the socket is absent, unresponsive, or returns a non-zero result
   (e.g. missing hook), the dashboard falls back to parsing the lease CSV
   at /var/lib/kea/kea-leases4.csv.  CSV counts are marked "(≈ csv)" and
   are approximate: the file is an append log flushed only on LFC cycles,
   does not include static reservations, and may contain stale entries
   between cleanup runs.

Packet drop colouring
   pkt4-receive-drop counts packets Kea declined to process — including
   packets addressed to another server, malformed frames, and clients
   rejected by class.  A small nonzero baseline is normal, so the field is
   coloured by rate: green at zero, plain below $(( DROP_WARN_PM ))‰ (0.1%),
   yellow from 0.1% to 1%, red above 1%.  Counters are cumulative since the
   daemon started; restart kea-dhcp4-server to reset the baseline.
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
			--help-kea)
				usage_kea; exit 0 ;;
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

# ── Colors ────────────────────────────────────────────────────────────────────
RESET=$'\033[0m';  BOLD=$'\033[1m';  DIM=$'\033[2m'
FG_YELLOW=$'\033[0;33m'; FG_BLUE=$'\033[0;34m';   FG_CYAN=$'\033[0;36m'
FG_WHITE=$'\033[0;37m';  FG_BWHITE=$'\033[1;37m'; FG_BCYAN=$'\033[1;36m'
FG_BGREEN=$'\033[1;32m'; FG_BRED=$'\033[1;31m';   FG_BYELLOW=$'\033[1;33m'

# Piped one-shot output gets no escapes and no box borders, so `-1 | mail`
# and `-1 > file` produce something readable.
if [[ "$ONE_SHOT" == "true" && ! -t 1 ]]; then
	_PLAIN=true
	RESET='' BOLD='' DIM=''
	FG_YELLOW='' FG_BLUE='' FG_CYAN='' FG_WHITE='' FG_BWHITE=''
	FG_BCYAN='' FG_BGREEN='' FG_BRED='' FG_BYELLOW=''
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

# Cached fill strings for rule/border lines — rebuilt only on resize, not every frame.
_FILL_MID=''   # BOX_H  × (INNER_WIDTH-2)  used by inner_rule mid
_FILL_THIN=''  # DIV_H  × (INNER_WIDTH-2)  used by inner_rule thin
_FILL_DASH=''  # DASH_H × (INNER_WIDTH-2)  used by inner_rule dash
_FILL_OUTER='' # BOX_H  × INNER_WIDTH      used by outer_top / outer_bottom
_LAST_WIDTH=0  # tracks when a rebuild is needed

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
}

# ── Output buffer ─────────────────────────────────────────────────────────────
_BUF=''
_n() { _BUF+="$*"$'\n'; }

# ── Drawing primitives ────────────────────────────────────────────────────────

inner_rule() {   # mid(╠═╣)  thin(├─┤)  dash(├╌┤)
	if [[ "$_PLAIN" == "true" ]]; then
		case "${1:-mid}" in
			mid)  _n "$_FILL_MID"  ;;
			thin) _n "$_FILL_THIN" ;;
			dash) _n "$_FILL_DASH" ;;
		esac
		return
	fi
	case "${1:-mid}" in
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
	box_blank
	box_line "${3}  ${BOLD}${FG_BWHITE}${1}${RESET}${FG_BLUE} — ${RESET}${FG_WHITE}${2}${RESET}" 2
	inner_rule thin
}

# ── Service helpers ───────────────────────────────────────────────────────────

# One systemctl call per frame for every unit.  `systemctl show` emits one
# property block per unit, in argument order, separated by a blank line.
svc_fetch_all() {
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
svc_status_badge() {
	case "${_SVC_ACTIVE[$1]-}" in
		active)   _BADGE="${FG_BGREEN}● Active  ${RESET}" ;;
		inactive)
			# Dim when deliberately disabled/masked; red only when enabled but not running.
			case "${_SVC_ENABLED[$1]-}" in
				disabled|masked) _BADGE="${DIM}✖ Inactive${RESET}"     ;;
				*)               _BADGE="${FG_BRED}✖ Inactive${RESET}" ;;
			esac ;;
		failed)   _BADGE="${FG_BRED}✖ Failed  ${RESET}" ;;
		*)        printf -v _BADGE '%s%-10s%s' "$FG_YELLOW" "? ${_SVC_ACTIVE[$1]:-unknown}" "$RESET" ;;
	esac
}

svc_enabled_badge() {
	case "${_SVC_ENABLED[$1]-}" in
		enabled)  _BADGE="${FG_BGREEN}Enabled ${RESET}" ;;
		disabled) _BADGE="${FG_YELLOW}Disabled${RESET}" ;;
		masked)   _BADGE="${FG_BRED}Masked  ${RESET}"   ;;
		*)        printf -v _BADGE '%s%-8s%s' "$FG_WHITE" "${_SVC_ENABLED[$1]:-unknown}" "$RESET" ;;
	esac
}

# Timestamp strings are memoised, so `date -d` runs at most once per unit per
# restart instead of once per unit per frame.
_UPTIME=''
svc_uptime() {
	local ts="${_SVC_START[$1]-}" epoch
	if [[ -z "$ts" || "$ts" == "n/a" ]]; then
		_UPTIME="${DIM}n/a${RESET}"; return
	fi
	epoch="${_TS_CACHE[$ts]-}"
	if [[ -z "$epoch" ]]; then
		epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=''
		[[ "$epoch" =~ ^[0-9]+$ ]] || epoch='-'
		_TS_CACHE["$ts"]="$epoch"
	fi
	if [[ "$epoch" == '-' ]]; then
		_UPTIME="${DIM}n/a${RESET}"; return
	fi
	local elapsed=$(( _NOW - epoch ))
	(( elapsed < 0 )) && elapsed=0
	local d=$(( elapsed/86400 )) h=$(( (elapsed%86400)/3600 ))
	local m=$(( (elapsed%3600)/60 )) s=$(( elapsed%60 ))
	if   (( d > 0 )); then printf -v _UPTIME '%s%dd %dh %dm%s' "$FG_BWHITE" "$d" "$h" "$m" "$RESET"
	elif (( h > 0 )); then printf -v _UPTIME '%s%dh %dm %ds%s' "$FG_BWHITE" "$h" "$m" "$s" "$RESET"
	elif (( m > 0 )); then printf -v _UPTIME '%s%dm %ds%s'     "$FG_BWHITE" "$m" "$s" "$RESET"
	else                   printf -v _UPTIME '%s%ds%s'         "$FG_BWHITE" "$s" "$RESET"
	fi
}

# =============================================================================
# ── UNBOUND ───────────────────────────────────────────────────────────────────
# =============================================================================
section_unbound() {
	local svc='unbound'

	local _ub_note=''
	if [[ "$ONE_SHOT" != "true" ]] && (( _SLOW_LAST_TS > 0 )); then
		_ub_note="  ${DIM}· stats polled $(( _NOW - _SLOW_LAST_TS ))s ago (every ${_SLOW_SECS}s)${RESET}"
	fi
	section_header "UNBOUND" "Recursive DNS Resolver${_ub_note}" "🔍"

	# Fast path: service status changes matter immediately
	svc_status_badge  "$svc"; local st="$_BADGE"
	svc_enabled_badge "$svc"; local en="$_BADGE"
	svc_uptime        "$svc"
	kv_line "Status " "${st}  Boot: ${en}"
	kv_line "Uptime " "$_UPTIME"

	if ! command -v unbound-control &>/dev/null; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  unbound-control not found${RESET}"
		box_blank; return
	fi

	# Slow path: these counters accumulate over minutes; polling every 2s buys
	# nothing but subprocess cost.
	[[ "$_DO_SLOW" == "true" ]] && _UB_STATS_RAW=$(unbound-control stats_noreset 2>/dev/null)

	if [[ -z "$_UB_STATS_RAW" ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  unbound-control unavailable or remote-control not configured${RESET}"
		box_blank; return
	fi

	# awk emits plain numbers only; formatting happens in bash.  Nothing is
	# eval'd, so no external data ever reaches the shell as code.
	local q h m p avg med msgc rrsc pct
	read -r q h m p avg med msgc rrsc pct < <(awk -F= '
		$1=="total.num.queries"           { q=$2+0 }
		$1=="total.num.cachehits"         { h=$2+0 }
		$1=="total.num.cachemiss"         { m=$2+0 }
		$1=="total.num.prefetch"          { p=$2+0 }
		$1=="total.recursion.time.avg"    { a=$2*1000 }
		$1=="total.recursion.time.median" { r=$2*1000 }
		$1=="mem.cache.message"           { mc=$2/1048576 }
		$1=="mem.cache.rrset"             { rc=$2/1048576 }
		END { printf "%d %d %d %d %.2f %.2f %.1f %.1f %.1f\n",
		      q+0, h+0, m+0, p+0, a+0, r+0, mc+0, rc+0, (q>0 ? h/q*100 : -1) }
	' <<< "$_UB_STATS_RAW")

	local total_q cache_hits cache_miss prefetch
	group_num "${q:-0}"; total_q="$_GN"
	group_num "${h:-0}"; cache_hits="$_GN"
	group_num "${m:-0}"; cache_miss="$_GN"
	group_num "${p:-0}"; prefetch="$_GN"

	local hits_pad avg_pad msg_pad pct_txt=''
	printf -v hits_pad '%-12s' "$cache_hits"
	printf -v avg_pad  '%-12s' "${avg} ms"
	printf -v msg_pad  '%-12s' "${msgc} MiB"
	[[ "$pct" != "-1.0" ]] && pct_txt="   ${FG_BCYAN}(${pct}% hit rate)${RESET}"

	inner_rule dash
	kv_line "Queries (total)" "${FG_BWHITE}${total_q}${RESET}"
	kv_line "Cache hits     " "${FG_BGREEN}${hits_pad}${RESET}misses:  ${FG_YELLOW}${cache_miss}${RESET}${pct_txt}"
	kv_line "Prefetches     " "${FG_WHITE}${prefetch}${RESET}"
	kv_line "Avg recursion  " "${FG_WHITE}${avg_pad}${RESET}median:  ${FG_WHITE}${med} ms${RESET}"
	kv_line "Msg cache      " "${FG_WHITE}${msg_pad}${RESET}RRset:   ${FG_WHITE}${rrsc} MiB${RESET}"
	box_blank
}

# =============================================================================
# ── KEA ───────────────────────────────────────────────────────────────────────
# =============================================================================

# Lease CSV counts, v4 and v6 alike.  Column positions have moved between Kea
# releases (v6 gained hwtype/hwaddr_source; v4 gained pool_id), so indices are
# resolved from the header row by name rather than hardcoded.
#
# The file is an append journal: the LAST row for an address is authoritative,
# not the one with the highest expire — a release or reclaim writes a row whose
# expire is lower than the preceding renewal's.
#
# Lease states: 0=assigned  1=declined  2=expired-reclaimed  3=released.
# Prints "total active expired declined", or "-1 0 0 0" if the header is
# unusable.
csv_lease_counts() {
	awk -F, -v now="$_NOW" '
		NR==1 {
			for (i = 1; i <= NF; i++) col[$i] = i
			ca = col["address"]; ce = col["expire"]; cs = col["state"]
			next
		}
		ca && ce && cs && NF >= cs {
			e[$ca] = $ce + 0        # last row for this address wins
			s[$ca] = $cs + 0
		}
		END {
			if (!ca) { print "-1 0 0 0"; exit }
			for (a in e) {
				t++
				if      (s[a] == 1)                          d++
				else if (s[a] == 2 || s[a] == 3 || e[a] <= now) ex++
				else                                          act++
			}
			printf "%d %d %d %d\n", t+0, act+0, ex+0, d+0
		}
	' "$1"
}

# Renders "Total/Active/Expired/Declined" from four counts.
_LEASE_LINE=''
fmt_lease_line() {
	local t="$1" a="$2" e="$3" d="$4" suffix="$5"
	local tp ap ep dp dc
	printf -v tp '%4d' "$t"; printf -v ap '%4d' "$a"
	printf -v ep '%4d' "$e"; printf -v dp '%4d' "$d"
	(( d > 0 )) && dc="$FG_BRED" || dc="$FG_BGREEN"
	_LEASE_LINE="Total: ${FG_BWHITE}${tp}${RESET}   Active: ${FG_BGREEN}${ap}${RESET}   Expired: ${FG_YELLOW}${ep}${RESET}   Declined: ${dc}${dp}${RESET}${suffix}"
}

section_kea() {
	section_header "KEA" "ISC DHCP Server (DHCPv4 / DHCPv6 / DDNS)" "📡"

	local services=('kea-dhcp4-server' 'kea-dhcp6-server' 'kea-dhcp-ddns-server')
	local labels=('DHCPv4' 'DHCPv6' 'DDNS  ')
	local i st en
	for i in "${!services[@]}"; do
		svc_status_badge  "${services[$i]}"; st="$_BADGE"
		svc_enabled_badge "${services[$i]}"; en="$_BADGE"
		svc_uptime        "${services[$i]}"
		kv_line "${labels[$i]} status" "${st}  Boot: ${en}  Up: ${_UPTIME}"
	done

	inner_rule dash

	local sock4='/run/kea/kea4-ctrl-socket'
	local sock6='/run/kea/kea6-ctrl-socket'
	local has_socat=false
	command -v socat &>/dev/null && has_socat=true

	# ── DHCPv4 leases ─────────────────────────────────────────────────────────
	if [[ "${_SVC_ACTIVE[kea-dhcp4-server]-}" == "active" ]]; then
		local leases4_line=''
		if [[ "$has_socat" == true && -S "$sock4" ]]; then
			local raw4
			raw4=$(printf '{"command":"stat-lease4-get","service":["dhcp4"]}' \
				| socat -t"${SOCAT_TIMEOUT}" - UNIX-CONNECT:"$sock4" 2>/dev/null)
			# Kea returns "result": 1/2 if the stat_cmds hook is missing or the
			# command fails; treat anything but result:0 as a socket failure.
			if [[ "$raw4" == *'"result": 0'* || "$raw4" == *'"result":0'* ]]; then
				local tot4 asgn4 decl4
				# rows: [subnet-id, total-addresses, cumulative-assigned, assigned, declined]
				read -r tot4 asgn4 decl4 < <(awk '
					{ if (match($0, /"rows": *\[/)) {
						s = substr($0, RSTART + RLENGTH)
						while (match(s, /\[ *[0-9, ]+\]/)) {
							row = substr(s, RSTART+1, RLENGTH-2)
							n = split(row, a, /, */)
							if (n >= 5) { tot += a[2]+0; asgn += a[4]+0; decl += a[5]+0 }
							s = substr(s, RSTART + RLENGTH)
						}
					} }
					END { printf "%d %d %d\n", tot+0, asgn+0, decl+0 }
				' <<< "$raw4")
				# Kea has no explicit expired count; remainder of pool = expired/available.
				local exp4=$(( tot4 - asgn4 - decl4 ))
				(( exp4 < 0 )) && exp4=0
				fmt_lease_line "$tot4" "$asgn4" "$exp4" "$decl4" ''
				leases4_line="$_LEASE_LINE"
			fi
		fi
		if [[ -z "$leases4_line" ]]; then
			local lease4='/var/lib/kea/kea-leases4.csv'
			if [[ -r "$lease4" ]]; then
				local t4 a4 e4 d4
				read -r t4 a4 e4 d4 < <(csv_lease_counts "$lease4")
				if (( t4 < 0 )); then
					leases4_line="${FG_YELLOW}socket unavailable · lease CSV header unrecognised${RESET}"
				else
					fmt_lease_line "$t4" "$a4" "$e4" "$d4" "  ${DIM}(≈ csv)${RESET}"
					leases4_line="$_LEASE_LINE"
				fi
			else
				leases4_line="${FG_YELLOW}socket unavailable · lease file not readable${RESET}"
			fi
		fi
		kv_line "DHCPv4 leases" "$leases4_line"
	fi

	# ── DHCPv6 leases ─────────────────────────────────────────────────────────
	if [[ "${_SVC_ACTIVE[kea-dhcp6-server]-}" == "active" ]]; then
		local leases6_line=''
		if [[ "$has_socat" == true && -S "$sock6" ]]; then
			local raw6
			raw6=$(printf '{"command":"stat-lease6-get","service":["dhcp6"]}' \
				| socat -t"${SOCAT_TIMEOUT}" - UNIX-CONNECT:"$sock6" 2>/dev/null)
			if [[ "$raw6" == *'"result": 0'* || "$raw6" == *'"result":0'* ]]; then
				local tna ana dna tpd apd
				# rows: [subnet-id, total-nas, assigned-nas, declined-nas, total-pds, assigned-pds]
				read -r tna ana dna tpd apd < <(awk '
					{ if (match($0, /"rows": *\[/)) {
						s = substr($0, RSTART + RLENGTH)
						while (match(s, /\[ *[0-9, ]+\]/)) {
							row = substr(s, RSTART+1, RLENGTH-2)
							n = split(row, a, /, */)
							if (n >= 6) { tna+=a[2]+0; ana+=a[3]+0; dna+=a[4]+0; tpd+=a[5]+0; apd+=a[6]+0 }
							s = substr(s, RSTART + RLENGTH)
						}
					} }
					END { printf "%d %d %d %d %d\n", tna+0, ana+0, dna+0, tpd+0, apd+0 }
				' <<< "$raw6")
				local exp_na=$(( tna - ana - dna ))
				(( exp_na < 0 )) && exp_na=0
				local tnap anap enap dnap apdp tpdp dnac
				printf -v tnap '%3d' "$tna"; printf -v anap '%3d' "$ana"
				printf -v enap '%3d' "$exp_na"; printf -v dnap '%3d' "$dna"
				printf -v apdp '%3d' "$apd";  printf -v tpdp '%3d' "$tpd"
				(( dna > 0 )) && dnac="$FG_BRED" || dnac="$FG_BGREEN"
				leases6_line="NA — Total: ${FG_BWHITE}${tnap}${RESET}  Active: ${FG_BGREEN}${anap}${RESET}  Expired: ${FG_YELLOW}${enap}${RESET}  Declined: ${dnac}${dnap}${RESET}   PD: ${FG_BGREEN}${apdp}${RESET}${DIM}/${RESET}${FG_BWHITE}${tpdp}${RESET}"
			fi
		fi
		if [[ -z "$leases6_line" ]]; then
			local lease6='/var/lib/kea/kea-leases6.csv'
			if [[ -r "$lease6" ]]; then
				local t6 a6 e6 d6
				read -r t6 a6 e6 d6 < <(csv_lease_counts "$lease6")
				if (( t6 < 0 )); then
					leases6_line="${FG_YELLOW}socket unavailable · lease CSV header unrecognised${RESET}"
				else
					fmt_lease_line "$t6" "$a6" "$e6" "$d6" "  ${DIM}(≈ csv)${RESET}"
					leases6_line="$_LEASE_LINE"
				fi
			else
				leases6_line="${FG_YELLOW}socket unavailable · lease file not readable${RESET}"
			fi
		fi
		kv_line "DHCPv6 leases" "$leases6_line"
	fi

	# ── DHCPv4 packet counters ─────────────────────────────────────────────────
	# statistic-get-all returns a large blob (every per-subnet counter) for three
	# slow-moving cumulative values, so it rides the slow cadence.
	if [[ "$has_socat" == true && -S "$sock4" ]]; then
		if [[ "$_DO_SLOW" == "true" ]]; then
			local raw rcv sent drop
			raw=$(printf '{"command":"statistic-get-all","service":["dhcp4"]}' \
				| socat -t"${SOCAT_TIMEOUT}" - UNIX-CONNECT:"$sock4" 2>/dev/null)
			if [[ -n "$raw" ]]; then
				# RS="," gives one field per record; getval() seeks past the "[ ["
				# value marker so digits inside key names like "pkt4" don't match.
				read -r rcv sent drop < <(awk 'BEGIN{RS=","}
					function getval(s,  t) {
						match(s,/\[ *\[/); t = substr(s, RSTART+RLENGTH)
						match(t,/[0-9]+/);  return substr(t, RSTART, RLENGTH) + 0
					}
					/"pkt4-received":/     { rcv  = getval($0) }
					/"pkt4-sent":/         { sent = getval($0) }
					/"pkt4-receive-drop":/ { drop = getval($0) }
					END { printf "%d %d %d\n", rcv+0, sent+0, drop+0 }
				' <<< "$raw")
				_PKT4_RCV=${rcv:-0}; _PKT4_SENT=${sent:-0}; _PKT4_DROP=${drop:-0}
				_PKT4_OK=true
			fi
		fi

		if [[ "$_PKT4_OK" == "true" ]]; then
			# Rate-based colouring.  Per-mille integer maths — no float shell-out.
			local drop_pm=0 drop_c drop_pct=''
			(( _PKT4_RCV > 0 )) && drop_pm=$(( _PKT4_DROP * 1000 / _PKT4_RCV ))
			if   (( _PKT4_DROP == 0 ));               then drop_c="$FG_BGREEN"
			elif (( _PKT4_RCV < DROP_MIN_SAMPLE ));   then drop_c="$FG_WHITE"
			elif (( drop_pm >= DROP_CRIT_PM ));       then drop_c="$FG_BRED"
			elif (( drop_pm >= DROP_WARN_PM ));       then drop_c="$FG_BYELLOW"
			else                                           drop_c="$FG_WHITE"
			fi
			(( _PKT4_DROP > 0 && _PKT4_RCV > 0 )) \
				&& printf -v drop_pct ' (%d.%d%%)' $(( drop_pm / 10 )) $(( drop_pm % 10 ))

			local rp sp dp
			printf -v rp '%6d' "$_PKT4_RCV"
			printf -v sp '%6d' "$_PKT4_SENT"
			printf -v dp '%4d' "$_PKT4_DROP"
			kv_line "DHCPv4 pkts  " \
				"Rcvd : ${FG_BWHITE}${rp}${RESET}   Sent  : ${FG_BGREEN}${sp}${RESET}   Dropped: ${drop_c}${dp}${drop_pct}${RESET}"
		fi
	fi

	box_blank
}

# =============================================================================
# ── CHRONY ────────────────────────────────────────────────────────────────────
# =============================================================================
section_chrony() {
	local svc='chrony'

	local _chr_note=''
	if [[ "$ONE_SHOT" != "true" ]] && (( _SLOW_LAST_TS > 0 )); then
		_chr_note="  ${DIM}· stats polled $(( _NOW - _SLOW_LAST_TS ))s ago (every ${_SLOW_SECS}s)${RESET}"
	fi
	section_header "CHRONY" "NTP Time Synchronization${_chr_note}" "🕐"

	svc_status_badge  "$svc"; local st="$_BADGE"
	svc_enabled_badge "$svc"; local en="$_BADGE"
	svc_uptime        "$svc"
	kv_line "Status " "${st}  Boot: ${en}"
	kv_line "Uptime " "$_UPTIME"

	if ! command -v chronyc &>/dev/null; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  chronyc not found${RESET}"
		box_blank; return
	fi

	# Slow path: NTP convergence plays out over minutes and source selection
	# rarely changes; no value in polling every 2s.
	if [[ "$_DO_SLOW" == "true" ]]; then
		_CHR_TRACKING_RAW=$(chronyc tracking 2>/dev/null)
		_CHR_SOURCES_RAW=$(chronyc sources 2>/dev/null)
	fi

	if [[ -n "$_CHR_TRACKING_RAW" ]]; then
		inner_rule dash

		# Parsed with shell builtins.  The old awk+eval executed the Reference ID
		# field as shell code — and that field carries the peer's reverse-resolved
		# hostname, i.e. attacker-supplied text, in a process running as root.
		local line key val
		local ref_id='' stratum='' sys_time='' rms_offset='' freq_err='' leap=''
		while IFS= read -r line; do
			[[ "$line" == *": "* ]] || continue
			key="${line%%:*}"; key="${key%"${key##*[![:space:]]}"}"
			val="${line#*: }"
			case "$key" in
				'Reference ID') ref_id="$val"     ;;
				'Stratum')      stratum="$val"    ;;
				'System time')  sys_time="$val"   ;;
				'RMS offset')   rms_offset="$val" ;;
				'Frequency')    freq_err="$val"   ;;
				'Leap status')  leap="$val"       ;;
			esac
		done <<< "$_CHR_TRACKING_RAW"

		local offset_col="$FG_WHITE"
		if [[ -n "$sys_time" ]] && float_ns "${sys_time%% *}"; then
			if   (( _FNS <   1000000 )); then offset_col="$FG_BGREEN"   # < 1 ms
			elif (( _FNS <  10000000 )); then offset_col="$FG_BYELLOW"  # < 10 ms
			else                              offset_col="$FG_BRED"
			fi
		fi
		local leap_col
		[[ "$leap" == "Normal" ]] && leap_col="$FG_BGREEN" || leap_col="$FG_BYELLOW"

		kv_line "Ref source  " "${FG_BWHITE}${ref_id}${RESET}"
		kv_line "Stratum     " "${FG_BWHITE}${stratum}${RESET}"
		kv_line "Sys offset  " "${offset_col}${sys_time}${RESET}"
		kv_line "RMS offset  " "${FG_WHITE}${rms_offset}${RESET}"
		kv_line "Freq error  " "${FG_WHITE}${freq_err}${RESET}"
		kv_line "Leap status " "${leap_col}${leap}${RESET}"
	fi

	if [[ -n "$_CHR_SOURCES_RAW" ]]; then
		inner_rule dash
		box_line "   ${FG_BCYAN}NTP Sources${RESET}"

		# Hardcoded header matches chronyc's own fixed-width layout, so columns
		# align regardless of chrony version.
		local NTP_HDR='MS Name/IP address         Stratum Poll Reach LastRx Last sample'
		box_line "   ${DIM}${NTP_HDR}${RESET}"
		inner_rule dash

		# Mode char at index 0 (^ server, = peer, # local ref clock), selection
		# state at index 1.  Glob match in-shell replaces the old grep fork.
		local line sc
		while IFS= read -r line; do
			[[ "$line" == [=#^][*+?x~-]* ]] || continue
			case "${line:1:1}" in
				'*') sc="$FG_BGREEN"  ;;
				'+') sc="$FG_BWHITE"  ;;
				'-') sc="$FG_YELLOW"  ;;
				'?') sc="$FG_YELLOW"  ;;
				'x') sc="$FG_BRED"    ;;
				'~') sc="$FG_YELLOW"  ;;
				*)   sc="$FG_WHITE"   ;;
			esac
			box_line "   ${sc}${line}${RESET}"
		done <<< "$_CHR_SOURCES_RAW"
	fi

	box_blank
}

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================

# Minimal placeholder so the alternate screen is never blank during startup.
draw_loading() {
	_BUF=''
	box_blank
	box_line "${BOLD}${FG_BCYAN}⬡  Network Core Services — Status Dashboard${RESET}" \
		$(( (INNER_WIDTH - 44) / 2 ))
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

	# Slow-frame decision, shared by all three sections.  _SLOW_LAST_TS is
	# advanced *before* rendering so the "polled Ns ago" note reads 0s on the
	# frame that actually refreshed.
	_SLOW_SECS=$(( REFRESH_INTERVAL * SLOW_INTERVAL_MULT ))
	_DO_SLOW=false
	(( _SLOW_LAST_TS == 0 || _NOW - _SLOW_LAST_TS >= _SLOW_SECS )) && _DO_SLOW=true
	[[ "$_DO_SLOW" == "true" ]] && _SLOW_LAST_TS=$_NOW

	local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"

	svc_fetch_all   # one systemctl call covering every unit

	box_blank
	box_line "${BOLD}${FG_BCYAN}⬡  Network Core Services — Status Dashboard${RESET}" \
		$(( (INNER_WIDTH - 44) / 2 ))
	box_line "${DIM}${FG_WHITE}${_HOSTNAME}   ·   ${ts}${RESET}" \
		$(( (INNER_WIDTH - ${#_HOSTNAME} - ${#ts} - 7) / 2 ))
	box_blank
	inner_rule mid

	section_unbound
	inner_rule mid
	section_kea
	inner_rule mid
	section_chrony

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
		box_line "   ${FG_YELLOW}⚠  Run with sudo for full unbound-control / kea socket access${RESET}"
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
# The main loop uses $COLUMNS for its steady-state resize check (cheap, fine
# there because checkwinsize will have caught up by then).
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
			# Show the previous frame immediately while service queries run.
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
			# Subtract draw_dashboard duration so the total cycle ≈ REFRESH_INTERVAL.
			# Without this, slow socat timeouts and external queries stack on top
			# of the full interval wait, multiplying the apparent refresh time.
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
			q|Q) restore_tty; exit 0 ;;

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
