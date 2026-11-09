#!/usr/bin/env bash
# =============================================================================
# net-core-status — Network Core Services Dashboard
# Services: unbound (DNS), kea (DHCP), chrony (NTP)
# Target:   Debian 13
# =============================================================================

# checkwinsize keeps $COLUMNS/$LINES fresh after foreground external commands.
# extglob is needed by the whitespace-trimming patterns.
shopt -s checkwinsize extglob

# ── Defaults ──────────────────────────────────────────────────────────────────
DEF_REFRESH_INTERVAL=2
DEF_NICE_VALUE=10
DEF_SLOW_INTERVAL=30
DEF_SOCAT_TIMEOUT=1

REFRESH_INTERVAL=$DEF_REFRESH_INTERVAL
NICE_VALUE=$DEF_NICE_VALUE
ONE_SHOT=false
# unbound-control, chronyc and Kea's statistic-get-all run in the background
# every SLOW_INTERVAL seconds (never more often than the refresh interval).
# This used to be a multiple of the refresh interval, which at a 60 s refresh
# meant DNS and NTP figures up to 20 minutes old.
SLOW_INTERVAL=$DEF_SLOW_INTERVAL
SOCAT_TIMEOUT=$DEF_SOCAT_TIMEOUT        # per-call timeout for Kea control socket queries
SLOW_PROBE_TIMEOUT=20                   # ceiling per probe inside the background poll

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
_DIRTY=true         # frame must be re-rendered (data, layout or UI state changed)
_RESIZED=false      # set by the WINCH trap; handled by the main loop
_CLEAR=false        # wipe the screen before the next draw (after a resize)
_FOOTER_ROW=0       # 1-based terminal row of the footer status line (set by do_draw)
_TTY_STATE=''       # tty state captured at startup, before any read -s
_HOSTNAME=''        # cached once — hostname -f can trigger a DNS lookup
_NOW=0              # epoch of the last fast fetch; the frame's notion of "now"
_PLAIN=false        # true when output is not a terminal (one-shot to a pipe)
_SCROLL=0           # first body line shown when the frame is taller than the screen
_PAGE=10
_FLASH='' _FLASH_UNTIL=0
_TMP=''             # private scratch dir for the background poll
_CLEANED=false
TERM_WIDTH=80 TERM_HEIGHT=0 INNER_WIDTH=78

# ── Slow-cadence background poll ──────────────────────────────────────────────
_SLOW_PID=''        # in-flight poll
_SLOW_START=0       # epoch when the in-flight (or most recent) poll began
_SLOW_START_US=0
_SLOW_LAST_TS=0     # epoch when the data now on screen was collected
_SLOW_SECS=0        # effective slow interval, seconds
_FORCE_SLOW=false
_NEXT_FAST_US=0     # µs deadline of the next fast fetch

# ── systemd state, fetched for every unit in one call per fast fetch ──────────
SVC_UNITS=('unbound' 'kea-dhcp4-server' 'kea-dhcp6-server' 'kea-dhcp-ddns-server' 'chrony')
declare -A _SVC_ACTIVE=() _SVC_ENABLED=() _SVC_START=() _TS_CACHE=()

# ── Fast cache: Kea leases ────────────────────────────────────────────────────
_K4_LINE='' _K6_LINE=''   # pre-rendered lease lines ('' = section hidden)
declare -A _KS=()         # kea_sum_columns result: column name → sum, or "huge"
_KS_ROWS=0

# ── Slow cache: unbound ───────────────────────────────────────────────────────
_UB_OK=false
declare -A _UB=()                       # selected stats_noreset keys → values
_UB_QPS='' _UB_HIT_NOW=''               # rates over the last poll interval
_UB_PREV_Q=-1 _UB_PREV_H=0 _UB_PREV_US=0
_UB_EXC_NEW=0 _UB_OVW_NEW=0             # requestlist growth over the last interval
_UB_PREV_EXC=-1 _UB_PREV_OVW=0

# ── Slow cache: Kea packet counters ───────────────────────────────────────────
_PKT4_RCV=0 _PKT4_SENT=0 _PKT4_DROP=0 _PKT4_OK=false
_PKT4_RATE='' _PKT4_PREV=-1 _PKT4_PREV_US=0

# ── Slow cache: chrony ────────────────────────────────────────────────────────
_CHR_TRACKING_RAW='' _CHR_SOURCES_RAW=''
_CHR_SRV_OK=false _CHR_NTP_RX=0 _CHR_NTP_DROP=0 _CHR_RATE=''
_CHR_PREV_RX=-1 _CHR_PREV_US=0

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

# Read a one-line file without forking; open and read errors are swallowed.
read_file1() {   # $1 = path, $2 = target var
	local __v=''
	[[ -r "$1" ]] && { IFS= read -r __v 2>/dev/null < "$1" || :; }
	printf -v "$2" '%s' "$__v"
}

# Whole file into a variable, no fork.  read returns 1 at EOF, which is normal.
slurp() {        # $1 = path, $2 = target var
	local __s=''
	[[ -r "$1" ]] && { IFS= read -r -d '' __s 2>/dev/null < "$1" || :; }
	printf -v "$2" '%s' "$__s"
}

# Peer-controlled text (NTP source names) is printed into a root terminal:
# strip control characters so nobody can put escape sequences on the screen.
_SAN=''
sanitize() { _SAN="${1//[[:cntrl:]]/?}"; }

# Left-justify to a width in characters.  printf's %-Ns pads by bytes.
rpad() {        # $1 = string, $2 = width, $3 = target var
	local __s="$1" __n=$(( $2 - ${#1} ))
	(( __n > 0 )) && printf -v __s '%s%*s' "$1" "$__n" ''
	printf -v "$3" '%s' "$__s"
}

# Visible width of a coloured string.  A split loop rather than an extglob
# substitution: bash's ${s//pattern/} with *(…) is quadratic and slow.
_VW=0
vis_width() {
	local __s="$1" __o=''
	while [[ "$__s" == *$'\033'* ]]; do
		__o+=${__s%%$'\033'*}
		__s=${__s#*$'\033'}
		__s=${__s#*m}
	done
	__o+=$__s
	_VW=${#__o}
}

flash() { _FLASH="$1"; _FLASH_UNTIL=$(( EPOCHSECONDS + 8 )); _DIRTY=true; }

# Memoised timestamp → epoch, so `date -d` runs once per distinct string.
_EPOCH=''
ts_to_epoch() {
	local ts="$1" e="${_TS_CACHE[$1]-}"
	if [[ -z "$e" ]]; then
		e=$(date -d "$ts" +%s 2>/dev/null) || e=''
		[[ "$e" =~ ^[0-9]+$ ]] || e='-'
		_TS_CACHE["$ts"]="$e"
	fi
	[[ "$e" == '-' ]] && { _EPOCH=''; return 1; }
	_EPOCH=$e
}

# "1.2/s", "12/min" style rate from a delta over µs.  '' when unknown.
_RATE=''
fmt_rate_per() {   # $1 = delta count, $2 = elapsed µs, $3 = per-unit seconds, $4 = unit label
	_RATE=''
	(( $2 > 0 && $1 >= 0 )) || return 1
	local tenths=$(( $1 * $3 * 10000000 / $2 ))
	_RATE="$(( tenths / 10 )).$(( tenths % 10 ))$4"
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
		# rather than inherited into arithmetic later.  An old
		# SLOW_INTERVAL_MULT line is ignored.
		case "$key" in
			REFRESH_INTERVAL) clamp "$val" 1 300   && REFRESH_INTERVAL=$_CLAMP ;;
			NICE_VALUE)       clamp "$val" -20 19  && NICE_VALUE=$_CLAMP       ;;
			SLOW_INTERVAL)    clamp "$val" 5 3600  && SLOW_INTERVAL=$_CLAMP    ;;
			SOCAT_TIMEOUT)    clamp "$val" 1 30    && SOCAT_TIMEOUT=$_CLAMP    ;;
		esac
	done < "$CFG_FILE"
}

# Written to a temp file and renamed, so an interrupted save never leaves a
# half-written config; failures become a footer notice, not text on screen.
save_config() {
	local tmp="$CFG_FILE.tmp.$$" ts
	printf -v ts '%(%F %T)T' -1
	if { mkdir -p -- "$CFG_DIR" \
		&& printf '# net-core-status — saved %s\nREFRESH_INTERVAL=%s\nNICE_VALUE=%s\nSLOW_INTERVAL=%s\nSOCAT_TIMEOUT=%s\n' \
			"$ts" "$REFRESH_INTERVAL" "$NICE_VALUE" "$SLOW_INTERVAL" "$SOCAT_TIMEOUT" > "$tmp" \
		&& mv -f -- "$tmp" "$CFG_FILE"; } 2>/dev/null
	then
		return 0
	fi
	rm -f -- "$tmp" 2>/dev/null
	flash "couldn't save ${CFG_FILE}"
	return 1
}

# Apply NICE_VALUE, then read back what the kernel actually granted: an
# unprivileged process can't lower its nice value, and the footer and saved
# config must not claim a value that isn't in effect.  util-linux renice
# treats --priority as absolute.  /proc/PID/stat field 19 is nice; comm
# (field 2) may contain spaces, so parsing starts after ") ".
apply_nice() {
	renice --priority "$NICE_VALUE" -p $$ >/dev/null 2>&1
	local s; local -a f
	IFS= read -r s 2>/dev/null < "/proc/$$/stat" || return 0
	s=${s##*) }
	read -ra f <<< "$s"
	[[ "${f[16]-}" =~ ^-?[0-9]+$ ]] && NICE_VALUE=${f[16]}
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
  q / Q / Ctrl-C       Quit
  p / P                Pause / unpause auto-refresh
  r / R                Refresh now, including unbound / chrony / Kea packet stats
  i                    Set refresh interval (prompted, 1–300 s)
  n                    Set nice value      (prompted, -20–19)
  ↑ ↓ / j k            Scroll one line (when the frame is taller than the screen)
  PgUp PgDn / b Space  Scroll one page
  Home End / g G       Jump to top / bottom
  h / ?                Toggle key-binding help overlay

Polling cadence:
  Service state and Kea lease counts refresh every interval.  unbound-control,
  chronyc and Kea's packet statistics run in the background every
  SLOW_INTERVAL seconds (config file; default $DEF_SLOW_INTERVAL, currently $SLOW_INTERVAL),
  so a slow or hung probe never stalls the display.

Resource use:
  The dashboard renices itself (children inherit it) and drops to the lowest
  best-effort I/O priority.  Lowering the nice value requires root.

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

What the lease line shows
   From the socket: assigned leases out of the pool's total addresses, the
   pool utilisation, and the free remainder.  Columns are located by name,
   so the layout differences between Kea releases don't matter.

Fallback behavior
   If the socket is absent, unresponsive, or returns a non-zero result
   (e.g. missing hook), the dashboard falls back to parsing the lease CSV
   at /var/lib/kea/kea-leases4.csv.  CSV counts are marked "(≈ csv)" and
   are approximate: the file is an append log flushed only on LFC cycles,
   does not include static reservations, and may contain stale entries
   between cleanup runs.  There the third figure really is "expired".

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
# Lowest best-effort I/O priority rather than the idle class, which can starve
# outright under load — exactly when the dashboard is needed.
command -v ionice &>/dev/null && ionice -c 2 -n 7 -p $$ >/dev/null 2>&1

_HAS_SOCAT=false _HAS_UBCTL=false _HAS_CHRONYC=false
command -v socat           &>/dev/null && _HAS_SOCAT=true
command -v unbound-control &>/dev/null && _HAS_UBCTL=true
command -v chronyc         &>/dev/null && _HAS_CHRONYC=true
declare -a _TO=()
command -v timeout &>/dev/null && _TO=(timeout -k 5 "$SLOW_PROBE_TIMEOUT")

SOCK4='/run/kea/kea4-ctrl-socket'
SOCK6='/run/kea/kea6-ctrl-socket'

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

B="${FG_BLUE}${BOX_V}${RESET}"
[[ "$_PLAIN" == "true" ]] && B=''

_FILL_MID='' _FILL_THIN='' _FILL_DASH='' _FILL_OUTER=''
_LAST_WIDTH=0

repeat_char() {   # fill $2 spaces, substitute each with $1, assign to $3
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

# `stty size` reads the terminal on stdin; used at startup and after SIGWINCH,
# since $LINES/$COLUMNS only refresh after a foreground external command.
read_winsize() {
	local s
	s=$(stty size 2>/dev/null) || return 0
	[[ "$s" =~ ^([0-9]+)\ ([0-9]+)$ ]] || return 0
	LINES=${BASH_REMATCH[1]}; COLUMNS=${BASH_REMATCH[2]}
}

sync_dimensions() {
	local w=${COLUMNS:-80} h=${LINES:-0}
	[[ "$w" =~ ^[0-9]+$ ]] && (( w >= 40 )) || w=80
	[[ "$h" =~ ^[0-9]+$ ]] || h=0
	[[ "$ONE_SHOT" == "true" ]] && h=0
	if (( w != TERM_WIDTH || h != TERM_HEIGHT || _LAST_WIDTH == 0 )); then
		# A resize (not the first sizing) clears the screen once: terminals
		# that reflow on resize can leave debris outside the new frame.
		(( _LAST_WIDTH > 0 )) && _CLEAR=true
		TERM_WIDTH=$w; TERM_HEIGHT=$h; INNER_WIDTH=$(( w - 2 ))
		rebuild_fills
		_DIRTY=true
	fi
}

# ── Output buffer ─────────────────────────────────────────────────────────────
# One array element per frame line.  _FOOT_START marks where the pinned footer
# begins; do_draw windows the body above it when the frame outgrows the screen.
declare -a _LINES=()
_FOOT_START=0
_n() { _LINES+=("$*"); }

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
# Unicode/ANSI byte-width accounting.  Autowrap is disabled while the
# dashboard runs, so an over-long line is clipped instead of wrapping.
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

center_line() { vis_width "$1"; box_line "$1" $(( (INNER_WIDTH - _VW) / 2 )); }

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

_PCOL=''
pct_col() {     # $1 = pct, $2 = warn, $3 = crit → _PCOL
	if   (( $1 >= $3 )); then _PCOL="$FG_BRED"
	elif (( $1 >= $2 )); then _PCOL="$FG_BYELLOW"
	else                      _PCOL="$FG_BGREEN"
	fi
}

# "· stats polled 12s ago (every 30s)" — yellow once the data is clearly
# stale (a stuck probe keeps the background poll from finishing).
_SN=''
slow_note() {
	_SN=''
	[[ "$ONE_SHOT" == "true" ]] && return
	if (( _SLOW_LAST_TS == 0 )); then
		[[ -n "$_SLOW_PID" ]] && _SN="  ${DIM}· stats polling…${RESET}"
		return
	fi
	local age=$(( _NOW - _SLOW_LAST_TS )) col="$DIM"
	(( age < 0 )) && age=0
	(( age > 2 * _SLOW_SECS + 30 )) && col="$FG_YELLOW"
	_SN="  ${col}· stats polled ${age}s ago (every ${_SLOW_SECS}s)${RESET}"
}

# ── Service helpers ───────────────────────────────────────────────────────────

# One systemctl call per fetch for every unit.  `systemctl show` emits one
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

# ActiveEnterTimestamp survives a stop, so uptime is only meaningful while the
# unit is active — otherwise a stopped service would show a running clock.
_UPTIME=''
svc_uptime() {
	local ts="${_SVC_START[$1]-}"
	if [[ "${_SVC_ACTIVE[$1]-}" != "active" || -z "$ts" || "$ts" == "n/a" ]] \
		|| ! ts_to_epoch "$ts"; then
		_UPTIME="${DIM}n/a${RESET}"; return
	fi
	local elapsed=$(( _NOW - _EPOCH ))
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
# ── KEA (fast fetch) ──────────────────────────────────────────────────────────
# =============================================================================

kea_query() {   # $1 = socket, $2 = JSON command → stdout
	printf '%s' "$2" | socat -t"${SOCAT_TIMEOUT}" - UNIX-CONNECT:"$1" 2>/dev/null
}

kea_ok() { [[ "$1" == *'"result": 0'* || "$1" == *'"result":0'* ]]; }

# Sum a stat-lease*-get result set per column, locating columns by NAME: the
# column list differs between Kea releases (2.x added cumulative-assigned-*),
# so fixed positions silently read the wrong figure.  DHCPv6 pools can hold
# 2^64 addresses, beyond bash arithmetic; such sums become "huge".
kea_sum_columns() {   # $1 = JSON reply → _KS[column] = sum | huge, _KS_ROWS
	local raw="$1" cols rest row v i re='^[[:space:],]*\[([^][]*)\]'
	local -a names vals
	_KS=(); _KS_ROWS=0
	[[ "$raw" == *'"columns"'* && "$raw" == *'"rows"'* ]] || return 1
	cols=${raw#*\"columns\"}; cols=${cols#*\[}; cols=${cols%%]*}
	cols=${cols//\"/}; cols=${cols//[[:space:]]/}
	IFS=, read -ra names <<< "$cols"
	rest=${raw#*\"rows\"}; rest=${rest#*\[}
	while [[ "$rest" =~ $re ]]; do
		row=${BASH_REMATCH[1]}; rest=${rest:${#BASH_REMATCH[0]}}
		row=${row//[[:space:]]/}
		IFS=, read -ra vals <<< "$row"
		for i in "${!names[@]}"; do
			v=${vals[i]-}
			[[ "$v" =~ ^[0-9]+$ ]] || continue
			if (( ${#v} > 15 )) || [[ "${_KS[${names[i]}]-}" == huge ]]; then
				_KS[${names[i]}]=huge; continue
			fi
			_KS[${names[i]}]=$(( ${_KS[${names[i]}]:-0} + 10#$v ))
		done
		_KS_ROWS=$(( _KS_ROWS + 1 ))
	done
	return 0
}

# The files Kea itself loads for a lease file, in Kea's order.  Lease-file
# cleanup compacts the state into BASE.1 and restarts BASE as a fresh journal,
# so BASE alone misses every lease that hasn't renewed since the last cleanup.
# A finished-but-unrenamed cleanup (.completed) replaces .1 and .2.
_LEASE_FILES=()
lease_file_set() {   # $1 = base path → _LEASE_FILES
	_LEASE_FILES=()
	if [[ -r "$1.completed" ]]; then _LEASE_FILES+=("$1.completed")
	else
		[[ -r "$1.1" ]] && _LEASE_FILES+=("$1.1")
		[[ -r "$1.2" ]] && _LEASE_FILES+=("$1.2")
	fi
	[[ -r "$1" ]] && _LEASE_FILES+=("$1")
	return 0
}

# Lease CSV counts, v4 and v6 alike — the fallback when the socket is unusable.
# Replays the file set as a journal: the LAST row for an address wins, and a
# zero valid lifetime is Kea's deletion marker.  Columns are resolved from
# each file's own header by name.
# Lease states: 0=assigned  1=declined  2=expired-reclaimed  3=released.
# Prints "total active expired declined", or "-1 0 0 0" if no header is usable.
csv_lease_counts() {   # FILE...
	awk -F, -v now="$_NOW" '
		FNR==1 {
			split("", col)
			for (i = 1; i <= NF; i++) col[$i] = i
			ca = col["address"]; ce = col["expire"]; cs = col["state"]; cv = col["valid_lifetime"]
			ct = col["lease_type"]
			if (ca && ce) usable = 1
			next
		}
		ca && ce && $ca != "" {
			k = ct ? $ca "/" $ct : $ca
			if (cv && $cv != "" && $cv + 0 == 0) { delete e[k]; delete s[k]; next }
			e[k] = $ce + 0
			s[k] = cs ? $cs + 0 : 0
		}
		END {
			if (!usable) { print "-1 0 0 0"; exit }
			for (a in e) {
				t++
				if      (s[a] == 1)                             d++
				else if (s[a] == 2 || s[a] == 3 || e[a] <= now) ex++
				else                                            act++
			}
			printf "%d %d %d %d\n", t+0, act+0, ex+0, d+0
		}
	' "$@"
}

# Assigned of total, utilisation and the free remainder.  Kea reports no
# "expired" figure: total − assigned − declined is simply the unused part of
# the pool, so it is labelled free.
_LEASE_LINE=''
fmt_pool_line() {   # $1 = total, $2 = assigned, $3 = declined, $4 = noun
	local t="$1" a="$2" d="$3" noun="$4" ap tp dc util='' free_txt
	printf -v ap '%5d' "$a"
	(( d > 0 )) && dc="$FG_BRED" || dc="$FG_BGREEN"
	if [[ "$t" == huge ]]; then
		tp='  2⁶⁴+'; free_txt="${DIM}pool too large to exhaust${RESET}"
	else
		local free=$(( t - a - d ))
		(( free < 0 )) && free=0
		printf -v tp '%-5d' "$t"
		if (( t > 0 )); then
			local u=$(( a * 100 / t ))
			pct_col "$u" 80 95
			printf -v util '  %s%3d%%%s' "$_PCOL" "$u" "$RESET"
		fi
		free_txt="${DIM}free${RESET} ${FG_WHITE}${free}${RESET}"
	fi
	_LEASE_LINE="${FG_BGREEN}${ap}${RESET} ${DIM}of${RESET} ${FG_BWHITE}${tp}${RESET} ${DIM}${noun}${RESET}${util}   ${free_txt}   ${DIM}declined${RESET} ${dc}${d}${RESET}"
}

fmt_csv_line() {   # $1..$4 = total active expired declined
	local tp ap ep dp dc
	printf -v tp '%4d' "$1"; printf -v ap '%4d' "$2"
	printf -v ep '%4d' "$3"; printf -v dp '%4d' "$4"
	(( $4 > 0 )) && dc="$FG_BRED" || dc="$FG_BGREEN"
	_LEASE_LINE="Total: ${FG_BWHITE}${tp}${RESET}   Active: ${FG_BGREEN}${ap}${RESET}   Expired: ${FG_YELLOW}${ep}${RESET}   Declined: ${dc}${dp}${RESET}  ${DIM}(≈ csv)${RESET}"
}

csv_fallback_line() {   # $1 = csv base path → _LEASE_LINE
	local t a e d
	lease_file_set "$1"
	if (( ${#_LEASE_FILES[@]} == 0 )); then
		_LEASE_LINE="${FG_YELLOW}socket unavailable · lease file not readable${RESET}"; return
	fi
	read -r t a e d <<< "$(csv_lease_counts "${_LEASE_FILES[@]}")"
	[[ "$t" =~ ^-?[0-9]+$ ]] || t=-1
	if (( t < 0 )); then
		_LEASE_LINE="${FG_YELLOW}socket unavailable · lease CSV header unrecognised${RESET}"
	else
		fmt_csv_line "$t" "${a:-0}" "${e:-0}" "${d:-0}"
	fi
}

fetch_kea() {
	_K4_LINE=''; _K6_LINE=''
	local raw
	if [[ "${_SVC_ACTIVE[kea-dhcp4-server]-}" == "active" ]]; then
		if [[ "$_HAS_SOCAT" == true && -S "$SOCK4" ]]; then
			raw=$(kea_query "$SOCK4" '{"command":"stat-lease4-get","service":["dhcp4"]}')
			if kea_ok "$raw" && kea_sum_columns "$raw"; then
				fmt_pool_line "${_KS[total-addresses]:-0}" "${_KS[assigned-addresses]:-0}" \
					"${_KS[declined-addresses]:-0}" 'addresses'
				_K4_LINE=$_LEASE_LINE
			fi
		fi
		if [[ -z "$_K4_LINE" ]]; then
			csv_fallback_line /var/lib/kea/kea-leases4.csv
			_K4_LINE=$_LEASE_LINE
		fi
	fi
	if [[ "${_SVC_ACTIVE[kea-dhcp6-server]-}" == "active" ]]; then
		if [[ "$_HAS_SOCAT" == true && -S "$SOCK6" ]]; then
			raw=$(kea_query "$SOCK6" '{"command":"stat-lease6-get","service":["dhcp6"]}')
			if kea_ok "$raw" && kea_sum_columns "$raw"; then
				fmt_pool_line "${_KS[total-nas]:-0}" "${_KS[assigned-nas]:-0}" \
					"${_KS[declined-nas]:-0}" 'NAs'
				_K6_LINE=$_LEASE_LINE
				if [[ -n "${_KS[total-pds]+x}" && "${_KS[total-pds]}" != 0 ]]; then
					_K6_LINE+="   ${DIM}PD${RESET} ${FG_BGREEN}${_KS[assigned-pds]:-0}${RESET}${DIM}/${RESET}${FG_BWHITE}${_KS[total-pds]}${RESET}"
				fi
			fi
		fi
		if [[ -z "$_K6_LINE" ]]; then
			csv_fallback_line /var/lib/kea/kea-leases6.csv
			_K6_LINE=$_LEASE_LINE
		fi
	fi
}

fetch_fast() {
	_NOW=$EPOCHSECONDS
	svc_fetch_all
	fetch_kea
	printf -v LAST_REFRESH '%(%H:%M:%S)T' "$_NOW"
}

# =============================================================================
# ── SLOW POLL — background subshell, harvested when its marker appears ────────
# =============================================================================

start_slow_poll() {
	[[ -n "$_SLOW_PID" ]] && return 0
	local d="$_TMP/poll" kea4=false
	[[ "${_SVC_ACTIVE[kea-dhcp4-server]-}" == "active" && "$_HAS_SOCAT" == true && -S "$SOCK4" ]] && kea4=true
	_SLOW_START=$EPOCHSECONDS
	_SLOW_START_US=${EPOCHREALTIME/[.,]/}
	(
		# An inherited EXIT trap would run cleanup in the child and pull the
		# parent's terminal out of the alternate screen.  Be explicit.
		trap - EXIT INT TERM HUP QUIT WINCH
		rm -rf -- "$d" && mkdir -- "$d" || exit 1
		[[ "$_HAS_UBCTL" == true ]] && "${_TO[@]}" unbound-control stats_noreset > "$d/unbound"
		if [[ "$_HAS_CHRONYC" == true ]]; then
			# -N prints the configured source names instead of reverse-resolving
			# every source IP — those PTR lookups go through unbound, so with
			# plain `chronyc sources` the dashboard stalled exactly when DNS was
			# the thing that was broken.
			"${_TO[@]}" chronyc -N tracking    > "$d/tracking"
			"${_TO[@]}" chronyc -N sources     > "$d/sources"
			"${_TO[@]}" chronyc serverstats    > "$d/serverstats"
		fi
		[[ "$kea4" == true ]] \
			&& printf '%s' '{"command":"statistic-get-all","service":["dhcp4"]}' \
			| "${_TO[@]}" socat -t"$SOCAT_TIMEOUT" - UNIX-CONNECT:"$SOCK4" > "$d/kea4stats"
		: > "$d/done"
	) </dev/null >/dev/null 2>&1 &
	_SLOW_PID=$!
}

harvest_slow() {
	[[ -n "$_SLOW_PID" ]] || return 1
	local d="$_TMP/poll"
	if [[ ! -e "$d/done" ]]; then
		kill -0 "$_SLOW_PID" 2>/dev/null && return 1
		wait "$_SLOW_PID" 2>/dev/null; _SLOW_PID=''   # died before finishing
		return 1
	fi
	wait "$_SLOW_PID" 2>/dev/null; _SLOW_PID=''

	local raw
	slurp "$d/unbound" raw;     parse_unbound "$raw"
	slurp "$d/tracking" _CHR_TRACKING_RAW
	slurp "$d/sources"  _CHR_SOURCES_RAW
	slurp "$d/serverstats" raw; parse_serverstats "$raw"
	slurp "$d/kea4stats" raw;   parse_kea_pkts "$raw"
	_SLOW_LAST_TS=$_SLOW_START
	return 0
}

# stats_noreset is a few hundred key=value lines; a bash loop picks out the
# handful shown, with no awk fork.  Keys absent from the output (the mem.* and
# num.answer.* families need `extended-statistics: yes`) stay absent and
# render as n/a, rather than as a misleading zero.
parse_unbound() {
	local raw="$1" k v
	_UB=(); _UB_OK=false
	[[ -n "$raw" ]] || { _UB_QPS=''; _UB_HIT_NOW=''; return; }
	while IFS='=' read -r k v; do
		case "$k" in
			total.num.queries|total.num.cachehits|total.num.cachemiss|total.num.prefetch|\
			total.recursion.time.avg|total.recursion.time.median|\
			mem.cache.message|mem.cache.rrset|\
			total.requestlist.exceeded|total.requestlist.overwritten|\
			num.answer.rcode.SERVFAIL|num.answer.bogus)
				[[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _UB[$k]=$v ;;
		esac
	done <<< "$raw"
	[[ -n "${_UB[total.num.queries]-}" ]] || return
	_UB_OK=true

	# Rates over the last poll interval: the since-start figures barely move
	# once the resolver has been up for a day.
	local q=${_UB[total.num.queries]} h=${_UB[total.num.cachehits]:-0}
	local exc=${_UB[total.requestlist.exceeded]:-0} ovw=${_UB[total.requestlist.overwritten]:-0}
	_UB_QPS=''; _UB_HIT_NOW=''; _UB_EXC_NEW=0; _UB_OVW_NEW=0
	if (( _UB_PREV_Q >= 0 && q >= _UB_PREV_Q )); then      # < means unbound restarted
		local dq=$(( q - _UB_PREV_Q )) dh=$(( h - _UB_PREV_H ))
		fmt_rate_per "$dq" $(( _SLOW_START_US - _UB_PREV_US )) 1 ' q/s' && _UB_QPS=$_RATE
		(( dq > 0 && dh >= 0 )) && _UB_HIT_NOW=$(( dh * 1000 / dq ))
		(( _UB_PREV_EXC >= 0 )) && _UB_EXC_NEW=$(( exc - _UB_PREV_EXC )) && _UB_OVW_NEW=$(( ovw - _UB_PREV_OVW ))
	fi
	_UB_PREV_Q=$q; _UB_PREV_H=$h; _UB_PREV_US=$_SLOW_START_US
	_UB_PREV_EXC=$exc; _UB_PREV_OVW=$ovw
}

# NTP requests this server has answered for the LAN — the side of chrony the
# tracking output doesn't show.  `chronyc serverstats` needs root.
parse_serverstats() {
	local raw="$1" line k v rx='' drop=''
	_CHR_SRV_OK=false; _CHR_RATE=''
	while IFS= read -r line; do
		k=${line%%:*}; k=${k%%+([[:space:]])}
		v=${line#*:}; v=${v##+([[:space:]])}
		case "$k" in
			'NTP packets received') rx=$v ;;
			'NTP packets dropped')  drop=$v ;;
		esac
	done <<< "$raw"
	[[ "$rx" =~ ^[0-9]+$ ]] || return
	[[ "$drop" =~ ^[0-9]+$ ]] || drop=0
	_CHR_SRV_OK=true; _CHR_NTP_RX=$rx; _CHR_NTP_DROP=$drop
	if (( _CHR_PREV_RX >= 0 && rx >= _CHR_PREV_RX )); then
		fmt_rate_per $(( rx - _CHR_PREV_RX )) $(( _SLOW_START_US - _CHR_PREV_US )) 60 '/min' && _CHR_RATE=$_RATE
	fi
	_CHR_PREV_RX=$rx; _CHR_PREV_US=$_SLOW_START_US
}

# statistic-get-all values look like  "pkt4-received": [ [ 159, "2026-…" ] ].
# A failed poll clears the cache, so a stopped daemon's last figures aren't
# left on screen looking current.
parse_kea_pkts() {
	local raw="$1" v
	_PKT4_OK=false; _PKT4_RATE=''
	[[ -n "$raw" ]] && kea_ok "$raw" || return
	local -A got=()
	for v in pkt4-received pkt4-sent pkt4-receive-drop; do
		[[ "$raw" =~ \"$v\":[[:space:]]*\[[[:space:]]*\[[[:space:]]*([0-9]+) ]] && got[$v]=${BASH_REMATCH[1]}
	done
	[[ -n "${got[pkt4-received]-}" ]] || return
	_PKT4_RCV=${got[pkt4-received]}; _PKT4_SENT=${got[pkt4-sent]:-0}; _PKT4_DROP=${got[pkt4-receive-drop]:-0}
	_PKT4_OK=true
	if (( _PKT4_PREV >= 0 && _PKT4_RCV >= _PKT4_PREV )); then
		fmt_rate_per $(( _PKT4_RCV - _PKT4_PREV )) $(( _SLOW_START_US - _PKT4_PREV_US )) 60 '/min' && _PKT4_RATE=$_RATE
	fi
	_PKT4_PREV=$_PKT4_RCV; _PKT4_PREV_US=$_SLOW_START_US
}

# =============================================================================
# ── UNBOUND ───────────────────────────────────────────────────────────────────
# =============================================================================
_MS=''
secs_to_ms() {   # "0.151760" → "151.76 ms"; n/a when absent
	_MS="${DIM}n/a${RESET}"
	[[ -n "$1" ]] && float_ns "$1" || return
	local hund=$(( _FNS / 10000 ))     # hundredths of a millisecond
	printf -v _MS '%d.%02d ms' $(( hund / 100 )) $(( hund % 100 ))
}
_MIB=''
bytes_to_mib() {
	_MIB='n/a'
	[[ "$1" =~ ^[0-9]+$ ]] || return
	local t=$(( $1 * 10 / 1048576 ))
	_MIB="$(( t / 10 )).$(( t % 10 )) MiB"
}

render_unbound() {
	local svc='unbound'
	slow_note
	section_header "UNBOUND" "Recursive DNS Resolver${_SN}" "🔍"

	svc_status_badge  "$svc"; local st="$_BADGE"
	svc_enabled_badge "$svc"; local en="$_BADGE"
	svc_uptime        "$svc"
	kv_line "Status " "${st}  Boot: ${en}"
	kv_line "Uptime " "$_UPTIME"

	if [[ "$_HAS_UBCTL" != true ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  unbound-control not found${RESET}"
		box_blank; return
	fi
	if [[ "$_UB_OK" != true ]]; then
		inner_rule dash
		if (( _SLOW_LAST_TS == 0 )); then box_line "   ${DIM}waiting for the first stats poll…${RESET}"
		else box_line "   ${FG_YELLOW}⚠  unbound-control unavailable or remote-control not configured${RESET}"
		fi
		box_blank; return
	fi

	local q=${_UB[total.num.queries]} h=${_UB[total.num.cachehits]:-0} m=${_UB[total.num.cachemiss]:-0}
	local tq th tm tp pct_boot='' pct_now='' hits_pad avg med msgc rrsc rate=''
	group_num "$q"; tq=$_GN
	group_num "$h"; th=$_GN
	group_num "$m"; tm=$_GN
	group_num "${_UB[total.num.prefetch]:-0}"; tp=$_GN
	(( q > 0 )) && { local pb=$(( h * 1000 / q )); pct_boot="$(( pb / 10 )).$(( pb % 10 ))%"; }
	[[ -n "$_UB_HIT_NOW" ]] && pct_now="$(( _UB_HIT_NOW / 10 )).$(( _UB_HIT_NOW % 10 ))%"
	[[ -n "$_UB_QPS" ]] && rate="   ${FG_BCYAN}${_UB_QPS}${RESET} ${DIM}now${RESET}"

	rpad "$th" 12 hits_pad
	secs_to_ms "${_UB[total.recursion.time.avg]-}";    avg=$_MS
	secs_to_ms "${_UB[total.recursion.time.median]-}"; med=$_MS
	rpad "$avg" 12 avg
	bytes_to_mib "${_UB[mem.cache.message]-}"; rpad "$_MIB" 12 msgc
	bytes_to_mib "${_UB[mem.cache.rrset]-}";   rrsc=$_MIB

	local hit_txt=''
	[[ -n "$pct_boot" ]] && hit_txt="   ${FG_BCYAN}${pct_now:+${pct_now} now · }${pct_boot} since start${RESET}"

	inner_rule dash
	kv_line "Queries (total)" "${FG_BWHITE}${tq}${RESET}${rate}"
	kv_line "Cache hits     " "${FG_BGREEN}${hits_pad}${RESET}misses:  ${FG_YELLOW}${tm}${RESET}${hit_txt}"
	kv_line "Prefetches     " "${FG_WHITE}${tp}${RESET}"
	kv_line "Avg recursion  " "${FG_WHITE}${avg}${RESET}median:  ${FG_WHITE}${med}${RESET}"
	if [[ -n "${_UB[mem.cache.message]-}" ]]; then
		kv_line "Msg cache      " "${FG_WHITE}${msgc}${RESET}RRset:   ${FG_WHITE}${rrsc}${RESET}"
	else
		kv_line "Msg cache      " "${DIM}n/a         RRset:   n/a   (needs extended-statistics: yes)${RESET}"
	fi

	# Overload and failure signals.  requestlist overflow means queries are
	# being dropped or evicted; colour only on growth during the last interval.
	local exc=${_UB[total.requestlist.exceeded]:-0} ovw=${_UB[total.requestlist.overwritten]:-0}
	local ec="$DIM" oc="$DIM" en='' on=''
	(( _UB_EXC_NEW > 0 )) && { ec="$FG_BRED";    en=" (+${_UB_EXC_NEW})"; }
	(( _UB_OVW_NEW > 0 )) && { oc="$FG_BYELLOW"; on=" (+${_UB_OVW_NEW})"; }
	local fail="${ec}requestlist exceeded ${exc}${en}${RESET}   ${oc}overwritten ${ovw}${on}${RESET}"
	if [[ -n "${_UB[num.answer.rcode.SERVFAIL]-}" ]]; then
		local sf=${_UB[num.answer.rcode.SERVFAIL]} bg=${_UB[num.answer.bogus]:-0} bc="$DIM"
		(( bg > 0 )) && bc="$FG_BYELLOW"
		fail+="   ${DIM}SERVFAIL ${sf}${RESET}   ${bc}DNSSEC bogus ${bg}${RESET}"
	fi
	kv_line "Failures       " "$fail"
	box_blank
}

# =============================================================================
# ── KEA ───────────────────────────────────────────────────────────────────────
# =============================================================================
render_kea() {
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

	if [[ -n "$_K4_LINE" || -n "$_K6_LINE" ]]; then
		inner_rule dash
		[[ -n "$_K4_LINE" ]] && kv_line "DHCPv4 leases" "$_K4_LINE"
		[[ -n "$_K6_LINE" ]] && kv_line "DHCPv6 leases" "$_K6_LINE"
	fi

	# Packet counters ride the slow poll; shown only while DHCPv4 is up.
	if [[ "$_PKT4_OK" == "true" && "${_SVC_ACTIVE[kea-dhcp4-server]-}" == "active" ]]; then
		# Rate-based colouring.  Per-mille integer maths — no float shell-out.
		local drop_pm=0 drop_c drop_pct=''
		(( _PKT4_RCV > 0 )) && drop_pm=$(( _PKT4_DROP * 1000 / _PKT4_RCV ))
		if   (( _PKT4_DROP == 0 ));             then drop_c="$FG_BGREEN"
		elif (( _PKT4_RCV < DROP_MIN_SAMPLE )); then drop_c="$FG_WHITE"
		elif (( drop_pm >= DROP_CRIT_PM ));     then drop_c="$FG_BRED"
		elif (( drop_pm >= DROP_WARN_PM ));     then drop_c="$FG_BYELLOW"
		else                                         drop_c="$FG_WHITE"
		fi
		(( _PKT4_DROP > 0 && _PKT4_RCV > 0 )) \
			&& printf -v drop_pct ' (%d.%d%%)' $(( drop_pm / 10 )) $(( drop_pm % 10 ))
		local rp sp dp rate=''
		printf -v rp '%6d' "$_PKT4_RCV"
		printf -v sp '%6d' "$_PKT4_SENT"
		printf -v dp '%4d' "$_PKT4_DROP"
		[[ -n "$_PKT4_RATE" ]] && rate="   ${FG_BCYAN}${_PKT4_RATE}${RESET} ${DIM}received now${RESET}"
		kv_line "DHCPv4 pkts  " \
			"Rcvd : ${FG_BWHITE}${rp}${RESET}   Sent  : ${FG_BGREEN}${sp}${RESET}   Dropped: ${drop_c}${dp}${drop_pct}${RESET}${rate}"
	fi
	box_blank
}

# =============================================================================
# ── CHRONY ────────────────────────────────────────────────────────────────────
# =============================================================================
render_chrony() {
	local svc='chrony'
	slow_note
	section_header "CHRONY" "NTP Time Synchronization${_SN}" "🕐"

	svc_status_badge  "$svc"; local st="$_BADGE"
	svc_enabled_badge "$svc"; local en="$_BADGE"
	svc_uptime        "$svc"
	kv_line "Status " "${st}  Boot: ${en}"
	kv_line "Uptime " "$_UPTIME"

	if [[ "$_HAS_CHRONYC" != true ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  chronyc not found${RESET}"
		box_blank; return
	fi
	if (( _SLOW_LAST_TS == 0 )) && [[ -z "$_CHR_TRACKING_RAW" ]]; then
		inner_rule dash
		box_line "   ${DIM}waiting for the first stats poll…${RESET}"
		box_blank; return
	fi

	if [[ -n "$_CHR_TRACKING_RAW" ]]; then
		inner_rule dash
		# Parsed with shell builtins — never eval'd: the Reference ID line can
		# carry a peer-supplied name, in a process running as root.
		local line key val
		local ref_id='' stratum='' sys_time='' rms_offset='' freq_err='' leap=''
		while IFS= read -r line; do
			[[ "$line" == *": "* ]] || continue
			key="${line%%:*}"; key="${key%%+([[:space:]])}"
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
		sanitize "$ref_id"; ref_id=$_SAN

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
		if [[ "$_CHR_SRV_OK" == true ]]; then
			local rx dc="$DIM" rate=''
			group_num "$_CHR_NTP_RX"; rx=$_GN
			(( _CHR_NTP_DROP > 0 )) && dc="$FG_BYELLOW"
			[[ -n "$_CHR_RATE" ]] && rate="   ${FG_BCYAN}${_CHR_RATE}${RESET} ${DIM}now${RESET}"
			kv_line "Serving     " "${FG_WHITE}${rx}${RESET} ${DIM}NTP requests answered${RESET}${rate}   ${dc}dropped ${_CHR_NTP_DROP}${RESET}"
		fi
	fi

	if [[ -n "$_CHR_SOURCES_RAW" ]]; then
		inner_rule dash
		box_line "   ${FG_BCYAN}NTP Sources${RESET}"
		# Hardcoded header matches chronyc's own fixed-width layout, so columns
		# align regardless of chrony version.
		box_line "   ${DIM}MS Name/IP address         Stratum Poll Reach LastRx Last sample${RESET}"
		inner_rule dash
		# Mode char at index 0 (^ server, = peer, # local ref clock), selection
		# state at index 1.
		local sc
		while IFS= read -r line; do
			[[ "$line" == [=#^][*+?x~-]* ]] || continue
			case "${line:1:1}" in
				'*') sc="$FG_BGREEN"  ;;
				'+') sc="$FG_BWHITE"  ;;
				'x') sc="$FG_BRED"    ;;
				*)   sc="$FG_YELLOW"  ;;   # - ? ~
			esac
			sanitize "$line"
			box_line "   ${sc}${_SAN}${RESET}"
		done <<< "$_CHR_SOURCES_RAW"
	fi

	box_blank
}

# =============================================================================
# ── FRAME ─────────────────────────────────────────────────────────────────────
# =============================================================================

render() {
	_LINES=()
	_SLOW_SECS=$SLOW_INTERVAL
	(( _SLOW_SECS < REFRESH_INTERVAL )) && _SLOW_SECS=$REFRESH_INTERVAL
	local ts nd
	printf -v ts '%(%A %d %B %Y  %H:%M:%S %Z)T' "$_NOW"
	printf -v nd '%+d' "$NICE_VALUE"

	box_blank
	center_line "${BOLD}${FG_BCYAN}⬡  Network Core Services — Status Dashboard${RESET}"
	center_line "${DIM}${FG_WHITE}${_HOSTNAME}   ·   ${ts}${RESET}"
	box_blank
	inner_rule mid
	render_unbound
	inner_rule mid
	render_kea
	inner_rule mid
	render_chrony

	# ── Pinned footer ─────────────────────────────────────────────────────────
	_FOOT_START=${#_LINES[@]}
	inner_rule thin
	if [[ "$_PLAIN" != "true" ]]; then
		local flash=''
		if [[ -n "$_FLASH" ]] && (( EPOCHSECONDS < _FLASH_UNTIL )); then
			flash="   ${FG_BYELLOW}${_FLASH}${RESET}"
		else
			_FLASH=''
		fi
		# @@SCROLL@@ is filled by do_draw, where the visible window is known.
		local head hints
		if [[ "$PAUSED" == "true" ]]; then
			head="   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nd}${RESET}"
			hints="p resume · r refresh · i interval · n nice · h help · q quit"
		else
			head="   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nd}${RESET}  ${DIM}Last: ${LAST_REFRESH}${RESET}"
			hints="p pause · r refresh · i interval · n nice · h help · q quit"
		fi
		vis_width "${head}${flash}   ${hints}"
		(( _VW + 28 > INNER_WIDTH )) && hints="h help · q quit"
		box_line "${head}@@SCROLL@@${flash}   ${DIM}${hints}${RESET}"
	fi

	if (( EUID != 0 )); then
		box_line "   ${FG_YELLOW}⚠  Run with sudo for full unbound-control / chronyc / kea socket access${RESET}"
	fi

	if [[ "$SHOW_HELP" == "true" && "$_PLAIN" != "true" ]]; then
		inner_rule dash
		box_line "   ${FG_BCYAN}${BOLD}Key Bindings${RESET}"
		inner_rule dash
		box_line "   ${FG_CYAN}q / Q / Ctrl-C       ${RESET}  Quit"
		box_line "   ${FG_CYAN}p / P                ${RESET}  Pause / unpause auto-refresh"
		box_line "   ${FG_CYAN}r / R                ${RESET}  Refresh now, including unbound / chrony / Kea packet stats"
		box_line "   ${FG_CYAN}i                    ${RESET}  Set refresh interval  (prompted, 1–300 s)"
		box_line "   ${FG_CYAN}n                    ${RESET}  Set nice value        (prompted, -20–19)"
		box_line "   ${FG_CYAN}↑ ↓ / j k            ${RESET}  Scroll one line"
		box_line "   ${FG_CYAN}PgUp PgDn / b Space  ${RESET}  Scroll one page"
		box_line "   ${FG_CYAN}Home End / g G       ${RESET}  Top / bottom"
		box_line "   ${FG_CYAN}h / ?                ${RESET}  Toggle this help overlay"
		box_line "   ${DIM}Settings auto-saved to: ${CFG_FILE}${RESET}"
	fi
}

# Draw the frame in one write.  When it's taller than the terminal, the body
# is windowed at _SCROLL and the footer stays pinned to the bottom rows.
do_draw() {
	local nb=$_FOOT_START n=${#_LINES[@]} nf avail i out l ind=''
	nf=$(( n - nb ))
	avail=$nb
	if (( TERM_HEIGHT > 0 )); then
		avail=$(( TERM_HEIGHT - 2 - nf ))
		(( avail < 1 )) && avail=1
		(( avail > nb )) && avail=$nb
	fi
	local maxoff=$(( nb - avail ))
	(( _SCROLL > maxoff )) && _SCROLL=$maxoff
	(( _SCROLL < 0 )) && _SCROLL=0
	_PAGE=$(( avail > 2 ? avail - 1 : 1 ))
	if (( maxoff > 0 )); then
		local below=$(( maxoff - _SCROLL ))
		ind="   ${FG_BCYAN}"
		(( _SCROLL > 0 )) && ind+="▲${_SCROLL} "
		(( below > 0 ))   && ind+="▼${below} "
		ind+="${RESET}${DIM}↑↓ PgUp/PgDn${RESET}"
	fi
	_FOOTER_ROW=$(( avail + 3 ))   # top border, body rows, footer rule, then the status line

	out="${FG_BLUE}${BOX_TL}${_FILL_OUTER}${BOX_TR}${RESET}"$'\n'
	for (( i=_SCROLL; i<_SCROLL+avail; i++ )); do out+="${_LINES[i]}"$'\n'; done
	for (( i=nb; i<n; i++ )); do l=${_LINES[i]}; out+="${l/@@SCROLL@@/$ind}"$'\n'; done
	out+="${FG_BLUE}${BOX_BL}${_FILL_OUTER}${BOX_BR}${RESET}"
	# A newline after the bottom border on the last row would scroll the
	# screen, so stale rows below are only erased when there's room for one.
	(( TERM_HEIGHT == 0 || avail + nf + 2 < TERM_HEIGHT )) && out+=$'\n\033[J'
	if [[ "$_CLEAR" == "true" ]]; then _CLEAR=false; out=$'\033[2J'"$out"; fi
	printf '\033[H%s' "$out"
}

print_oneshot() {
	local l
	[[ "$_PLAIN" == "true" ]] || printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_TL" "$_FILL_OUTER" "${BOX_TR}${RESET}"
	for l in "${_LINES[@]}"; do printf '%s\n' "${l/@@SCROLL@@/}"; done
	[[ "$_PLAIN" == "true" ]] || printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_BL" "$_FILL_OUTER" "${BOX_BR}${RESET}"
}

# Minimal placeholder so the alternate screen is never blank during startup.
draw_loading() {
	_LINES=()
	box_blank
	center_line "${BOLD}${FG_BCYAN}⬡  Network Core Services — Status Dashboard${RESET}"
	box_blank
	inner_rule mid
	box_blank
	box_line "   ${DIM}Gathering service data…${RESET}"
	box_blank
	_FOOT_START=${#_LINES[@]}
	do_draw
}

# Overwrite the footer row with a prompt; restoring _TTY_STATE gives
# echo-on canonical mode, so backspace and Ctrl-U work as usual.
prompt_input() {
	local mode="$1" label raw_val=''
	[[ "$mode" == 'interval' ]] \
		&& label="Refresh interval (1–300 s)" \
		|| label="Nice value (-20–19)"

	printf '\033[%dH\033[K%s   %s%s▶  %s:%s  ' "$_FOOTER_ROW" "$B" "$FG_BCYAN" "$BOLD" "$label" "$RESET"
	[[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null
	printf '\033[?25h'
	IFS= read -r raw_val
	printf '\033[?25l'
	stty -echo 2>/dev/null

	if [[ "$mode" == 'interval' ]]; then
		if clamp "$raw_val" 1 300; then
			REFRESH_INTERVAL=$_CLAMP
			_NEXT_FAST_US=0
			save_config
		fi
	elif clamp "$raw_val" -20 19; then
		local want=$_CLAMP prev=$NICE_VALUE
		NICE_VALUE=$want
		apply_nice
		if (( NICE_VALUE == want )); then
			save_config
		else
			local wd; printf -v wd '%+d' "$want"
			flash "renice to ${wd} refused (lowering needs root)"
			(( NICE_VALUE != prev )) && save_config
		fi
	fi
	_DIRTY=true
}

# After ESC: read the rest of a CSI/SS3 sequence one byte at a time, so arrow
# keys cost no fixed delay and a bare Esc times out harmlessly.
_ESC=''
read_escape() {
	local c s=''
	_ESC=''
	IFS= read -r -s -n 1 -t 0.05 c 2>/dev/null || return 0
	s=$c
	if [[ "$c" == '[' || "$c" == 'O' ]]; then
		while IFS= read -r -s -n 1 -t 0.05 c 2>/dev/null; do
			s+=$c
			[[ "$c" == [A-Za-z~] ]] && break
		done
	fi
	_ESC=$s
}

scroll_by() { _SCROLL=$(( _SCROLL + $1 )); (( _SCROLL < 0 )) && _SCROLL=0; _DIRTY=true; }

# After a pause, the next sample becomes a fresh baseline: a rate averaged
# over a long pause would be labelled as current.
reset_rate_baselines() { _UB_PREV_Q=-1; _UB_PREV_EXC=-1; _PKT4_PREV=-1; _CHR_PREV_RX=-1; }

cleanup() {
	[[ "$_CLEANED" == "true" ]] && return
	_CLEANED=true
	[[ -n "$_SLOW_PID" ]] && kill "$_SLOW_PID" 2>/dev/null
	[[ -n "$_TMP" && -d "$_TMP" ]] && rm -rf -- "$_TMP" 2>/dev/null
	[[ "$ONE_SHOT" == "true" ]] && return
	printf '\033[?7h\033[?25h\033[?1049l'   # autowrap on, cursor on, leave alt screen
	if [[ -n "$_TTY_STATE" ]]; then
		stty "$_TTY_STATE" 2>/dev/null || stty echo 2>/dev/null
	else
		stty echo 2>/dev/null
	fi
}
# Terminal restoration must survive every exit path, including SIGHUP from a
# closed terminal; signal exits keep the conventional 128+N status.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
# A trapped signal does NOT interrupt bash's `read`: the handler runs and the
# read restarts.  So the trap only flags the resize; the main loop waits in
# short slices and notices it within a quarter second (including while paused).
trap '_RESIZED=true' WINCH

main() {
	_TMP=$(mktemp -d "${TMPDIR:-/tmp}/net-core-status.XXXXXX" 2>/dev/null) || _TMP=''
	_SLOW_SECS=$SLOW_INTERVAL
	(( _SLOW_SECS < REFRESH_INTERVAL )) && _SLOW_SECS=$REFRESH_INTERVAL

	if [[ "$ONE_SHOT" == "true" ]]; then
		_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
		[[ -t 0 ]] && read_winsize
		sync_dimensions
		fetch_fast
		if [[ -n "$_TMP" ]]; then
			start_slow_poll
			[[ -n "$_SLOW_PID" ]] && wait "$_SLOW_PID" 2>/dev/null
			harvest_slow
		fi
		render
		print_oneshot
		return
	fi

	printf '\033[?1049h\033[?25l\033[?7l'   # alt screen, hide cursor, autowrap off
	_TTY_STATE=$(stty -g 2>/dev/null)
	stty -echo 2>/dev/null

	read_winsize
	sync_dimensions
	draw_loading
	# hostname -f may do a DNS lookup; run it after the loading frame is up.
	_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')

	local key now_us wait_us t t0 t1 iv
	while true; do
		if [[ "$_RESIZED" == "true" ]]; then _RESIZED=false; read_winsize; fi
		sync_dimensions

		if [[ "$PAUSED" == "false" ]]; then
			now_us=${EPOCHREALTIME/[.,]/}
			if (( now_us >= _NEXT_FAST_US )); then
				t0=$now_us
				fetch_fast
				t1=${EPOCHREALTIME/[.,]/}; iv=$(( REFRESH_INTERVAL * 1000000 ))
				# Keep the cadence, but never re-fetch back to back if the
				# fetch itself is slower than the interval.
				_NEXT_FAST_US=$(( t0 + iv ))
				(( _NEXT_FAST_US < t1 + iv / 2 )) && _NEXT_FAST_US=$(( t1 + iv / 2 ))
				_DIRTY=true
			fi
			harvest_slow && _DIRTY=true
			_SLOW_SECS=$SLOW_INTERVAL
			(( _SLOW_SECS < REFRESH_INTERVAL )) && _SLOW_SECS=$REFRESH_INTERVAL
			if [[ -z "$_SLOW_PID" && -n "$_TMP" ]] \
				&& { [[ "$_FORCE_SLOW" == "true" ]] || (( _SLOW_START == 0 || EPOCHSECONDS - _SLOW_START >= _SLOW_SECS )); }; then
				_FORCE_SLOW=false
				start_slow_poll
				_DIRTY=true      # headers show "polling…"
			fi
		fi

		if [[ "$_DIRTY" == "true" ]]; then
			_DIRTY=false
			render
			do_draw
		fi

		# Wait in ≤250 ms slices: keys, resizes and finished background polls
		# are all picked up promptly without anything heavier than a [[ ]] test.
		wait_us=250000
		if [[ "$PAUSED" == "false" ]]; then
			now_us=${EPOCHREALTIME/[.,]/}
			(( _NEXT_FAST_US - now_us < wait_us )) && wait_us=$(( _NEXT_FAST_US - now_us ))
			(( wait_us < 10000 )) && wait_us=10000
		fi
		printf -v t '%d.%06d' $(( wait_us / 1000000 )) $(( wait_us % 1000000 ))
		key=''
		IFS= read -r -s -n 1 -t "$t" key 2>/dev/null

		[[ "$key" == $'\033' ]] && { read_escape; key="ESC$_ESC"; }

		case "$key" in
			'') ;;
			$'\003'|q|Q) exit 0 ;;
			p|P)
				if [[ "$PAUSED" == "true" ]]; then
					PAUSED=false; reset_rate_baselines; _NEXT_FAST_US=0
				else
					PAUSED=true
				fi
				_DIRTY=true ;;
			r|R)
				[[ "$PAUSED" == "true" ]] && reset_rate_baselines
				PAUSED=false; _NEXT_FAST_US=0
				[[ -z "$_SLOW_PID" ]] && _FORCE_SLOW=true ;;
			i|I) prompt_input 'interval' ;;
			n|N) prompt_input 'nice' ;;
			h|'?')
				[[ "$SHOW_HELP" == "true" ]] && SHOW_HELP=false || SHOW_HELP=true
				_DIRTY=true ;;
			j|'ESC[B'|'ESCOB')                   scroll_by 1 ;;
			k|'ESC[A'|'ESCOA')                   scroll_by -1 ;;
			' '|'ESC[6~')                        scroll_by "$_PAGE" ;;
			b|'ESC[5~')                          scroll_by "-$_PAGE" ;;
			g|'ESC[H'|'ESCOH'|'ESC[1~'|'ESC[7~') _SCROLL=0; _DIRTY=true ;;
			G|'ESC[F'|'ESCOF'|'ESC[4~'|'ESC[8~') _SCROLL=999999; _DIRTY=true ;;
		esac
	done
}

main "$@"
