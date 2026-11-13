#!/usr/bin/env bash
# =============================================================================
# fs-status — File Server Services Dashboard
# Sections:  ZFS (pools · vdevs · scrubs · ARC · L2ARC · datasets) · mdadm
#            Drives (I/O · busy · SMART) · Volumes · NFS · Samba · Network
# Target:   Debian 13 / Linux
# =============================================================================

# checkwinsize keeps $COLUMNS/$LINES fresh after foreground external commands.
# extglob is needed by the SGR-stripping and whitespace-trimming patterns.
shopt -s checkwinsize extglob

# ── Defaults ──────────────────────────────────────────────────────────────────
DEF_REFRESH_INTERVAL=3
DEF_NICE_VALUE=10
DEF_SMART_INTERVAL_MULT=20
DEF_SCRUB_WARN_DAYS=35

REFRESH_INTERVAL=$DEF_REFRESH_INTERVAL
NICE_VALUE=$DEF_NICE_VALUE
ONE_SHOT=false
# Cadence divisor for every expensive probe, not just SMART: smartctl,
# zpool status, exportfs, showmount and smbstatus all ride it.  The config key
# name is kept for compatibility with existing fs-status.conf files.
SMART_INTERVAL_MULT=$DEF_SMART_INTERVAL_MULT
SCRUB_WARN_DAYS=$DEF_SCRUB_WARN_DAYS   # last-scrub age (days) that turns yellow
SLOW_PROBE_TIMEOUT=30                  # ceiling per probe inside the background poll

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
_PAGE=10            # scroll page size; set by do_draw
_FLASH=''           # transient footer notice (refused renice, unsaved config)
_FLASH_UNTIL=0
_TMP=''             # private scratch dir for the background poll
_CLEANED=false
TERM_WIDTH=80 TERM_HEIGHT=0 INNER_WIDTH=78

# ── Slow-cadence background poll ──────────────────────────────────────────────
# smartctl, zpool status, exportfs, showmount and smbstatus run in a background
# subshell that writes to $_TMP/poll and drops a "done" marker.  The main loop
# harvests the results when the marker appears, so a slow or hung probe never
# freezes the UI — the age shown in each section header just keeps growing.
_SLOW_PID=''        # in-flight poll
_SLOW_START=0       # epoch when the in-flight (or most recent) poll began
_SLOW_LAST_TS=0     # epoch when the data now on screen was collected
_SLOW_SECS=0        # effective slow interval, seconds
_FORCE_SLOW=false
_NEXT_FAST_US=0     # µs deadline of the next fast fetch

# ── Fast-cadence caches (filled by fetch_*, read by render_*) ─────────────────
declare -a SVC_UNITS=()
declare -A _SVC_ACTIVE=() _SVC_ENABLED=() _SVC_START=() _TS_CACHE=()
declare -A _ARC=()
_ARC_PREV_SET=0 _ARC_PREV_H=0 _ARC_PREV_M=0 _L2_PREV_H=0 _L2_PREV_M=0
_ARC_NOW_PM=-1 _L2_NOW_PM=-1
_RAW_ZPOOL_LIST='' _RAW_ZFS_LIST='' _RAW_MDSTAT='' _RAW_DF=''
declare -A _MD_MISMATCH=()
declare -a _DEVS=()
declare -A _DISK_R=() _DISK_W=() _DISK_T=() _DISK_RR=() _DISK_RW=() _DISK_UTIL=()
_DISK_PREV_US=0
declare -a _NET_ORDER=()
declare -A _NET_RXB=() _NET_TXB=() _NET_RXE=() _NET_TXE=() _NET_RXD=() _NET_TXD=()
declare -A _NET_RXR=() _NET_TXR=() _NET_ERR_NEW=() _NET_DROP_NEW=()
declare -A _NET_OPER=() _NET_SPEED=() _NET_DUPLEX=() _NET_MTU=() _NET_CHG=() _NET_PHYS=()
declare -A _NET_MASTER=() _NET_BOND_MODE=() _NET_BOND_SLAVES=() _NET_BOND_AGG=()
declare -A _NET_SLAVE_MII=() _NET_SLAVE_AGG=() _NET_SLAVE_FAIL=() _IP_ADDRS=()
_NET_PREV_US=0
_NFS_STATS_OK=false _NFS_IO_R=0 _NFS_IO_W=0 _NFS_RR='' _NFS_RW='' _NFS_PREV_US=0
_NFS_TCPCONN=0 _NFS_CALLS=0 _NFS_BADCALLS=0 _NFS_THREADS='?'
declare -A _NFS_V4=()
_NFS_V4_IDLE=0

# ── Slow-cadence caches (filled by harvest_slow) ──────────────────────────────
declare -A _SMART_HS=() _SMART_TC=() _SMART_RL=() _SMART_PD=() _SMART_UC=()
declare -A _SMART_CRC=() _SMART_WEAR=() _SMART_MDL=() _SMART_SER=() _SMART_CAP=()
declare -A _SMART_FLAGS=() _SMART_STBY=()
_RAW_ZPOOL_STATUS='' _RAW_EXPORTS='' _RAW_SHOWMOUNT='' _RAW_SMB=''
declare -A _ZS_STATE=() _ZS_STATUS=() _ZS_SCAN=() _ZS_ERRORS=() _ZS_BAD=()
declare -A _ZS_SCRUB_EPOCH=() _ZS_SCRUB_KIND=() _ZS_SCRUB_ERRS=()
declare -A _EXP=()
declare -a _EXP_ORDER=() _SMB_SESS=()
_SMB_OK=false _SMB_SHARE_LIST='' _SMB_FILES=0

# ── Optional-section presence — checked once at startup ──────────────────────
_ZFS_PRESENT=false _MDADM_PRESENT=false _NFS_PRESENT=false _SAMBA_PRESENT=false
_NMBD_PRESENT=false _WINBIND_PRESENT=false
_SMART_AVAIL=false _HAS_EXPORTFS=false _HAS_SHOWMOUNT=false _HAS_SMBSTATUS=false _HAS_IP=false
declare -a _TO=() _DF_EXCL=()

_MID_COL=0   # terminal column of the centre │ divider; set by rebuild_fills

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

# Read a one-line file without forking.  The 2>/dev/null precedes the <
# redirect so a vanished attribute's open error is suppressed too, and read's
# own error (EINVAL from `speed` on a down link) is swallowed as well.
read_sysfs() {   # $1 = path, $2 = target var
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

# Client-supplied text (SMB user and machine names, NFS client ids, reverse
# DNS) is printed into a root terminal: strip control characters so nobody can
# put escape sequences on the operator's screen.
_SAN=''
sanitize() { _SAN="${1//[[:cntrl:]]/?}"; }

# Left-justify to a width in characters.  printf's %-Ns pads by bytes, which
# misaligns columns holding —, …, ° or non-ASCII names.
rpad() {        # $1 = string, $2 = width, $3 = target var
	local __s="$1" __n=$(( $2 - ${#1} ))
	(( __n > 0 )) && printf -v __s '%s%*s' "$1" "$__n" ''
	printf -v "$3" '%s' "$__s"
}

# Visible width of a coloured string: SGR sequences removed, then counted.
# A split loop rather than ${s//$'\033'\[*([0-9;])m/}: bash's extglob
# substitution is quadratic and cost milliseconds per line.
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
			SCRUB_WARN_DAYS)     clamp "$val" 1 365 && SCRUB_WARN_DAYS=$_CLAMP     ;;
		esac
	done < "$CFG_FILE"
}

# Written to a temp file and renamed, so an interrupted save never leaves a
# half-written config.  Failures (e.g. a root-owned file left by an earlier
# `sudo -E` run) become a footer notice instead of text on the screen.
save_config() {
	local tmp="$CFG_FILE.tmp.$$" ts
	printf -v ts '%(%F %T)T' -1
	if { mkdir -p -- "$CFG_DIR" \
		&& printf '# fs-status — saved %s\nREFRESH_INTERVAL=%s\nNICE_VALUE=%s\nSMART_INTERVAL_MULT=%s\nSCRUB_WARN_DAYS=%s\n' \
			"$ts" "$REFRESH_INTERVAL" "$NICE_VALUE" "$SMART_INTERVAL_MULT" "$SCRUB_WARN_DAYS" > "$tmp" \
		&& mv -f -- "$tmp" "$CFG_FILE"; } 2>/dev/null
	then
		return 0
	fi
	rm -f -- "$tmp" 2>/dev/null
	flash "couldn't save ${CFG_FILE}"
	return 1
}

# Apply NICE_VALUE, then read back what the kernel actually granted.  An
# unprivileged process can't lower its nice value, so a refused renice must not
# leave the footer (or the saved config) claiming a value that isn't in effect.
# util-linux renice treats --priority as absolute.  Field 19 of /proc/PID/stat
# is nice; comm (field 2) may contain spaces, so parsing starts after ") ".
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

File server services status dashboard.
Always shown: DRIVES (I/O + SMART) · VOLUMES · NETWORK
Optional (shown when present): ZFS · mdadm · NFS · Samba

Options:
  -i, --interval SECS  Auto-refresh interval, seconds  (1–300,  default: $DEF_REFRESH_INTERVAL)
  -n, --nice     N     Nice value for the dashboard    (-20–19, default: $DEF_NICE_VALUE)
  -1, --once           Render once and exit (non-interactive / scriptable)
  -h, --help           Show this help and exit

Live key bindings (while running):
  q / Q / Ctrl-C       Quit
  p / P                Pause / unpause auto-refresh
  r / R                Force immediate refresh (including SMART/zpool/smbstatus)
  i                    Set refresh interval (prompted, 1–300 s)
  n                    Set nice value      (prompted, -20–19)
  ↑ ↓ / j k            Scroll one line (when the frame is taller than the screen)
  PgUp PgDn / b Space  Scroll one page
  Home End / g G       Jump to top / bottom
  h / ?                Toggle this help overlay

Polling cadence:
  Cheap sources (/proc, /sys, df, zpool list, zfs list, ip) refresh every
  interval.  Expensive ones (smartctl, zpool status, exportfs, smbstatus,
  showmount) run in the background every SMART_INTERVAL_MULT × interval —
  currently every $(( REFRESH_INTERVAL * SMART_INTERVAL_MULT ))s — so they never stall the display.
  smartctl is run with -n standby: spun-down drives are not woken.
  Set SMART_INTERVAL_MULT in the config file to change it (default: $DEF_SMART_INTERVAL_MULT).
  SCRUB_WARN_DAYS (default: $DEF_SCRUB_WARN_DAYS) sets when a pool's last scrub turns yellow.

Resource use:
  The dashboard renices itself (children inherit it) and drops to the lowest
  best-effort I/O priority.  Lowering the nice value requires root.

Privilege notes:
  Run as root for full access: smartctl, smbstatus, exportfs, NFSv4 client list.

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
# CPU niceness doesn't touch I/O scheduling.  Lowest best-effort priority
# rather than the idle class: under heavy load idle-class I/O can starve
# outright, which would stall the dashboard exactly when it's needed.
command -v ionice &>/dev/null && ionice -c 2 -n 7 -p $$ >/dev/null 2>&1

# ── Optional section detection — each checked once to avoid per-frame overhead ─
command -v zpool     &>/dev/null && _ZFS_PRESENT=true
command -v smartctl  &>/dev/null && _SMART_AVAIL=true
command -v exportfs  &>/dev/null && _HAS_EXPORTFS=true
command -v showmount &>/dev/null && _HAS_SHOWMOUNT=true
command -v smbstatus &>/dev/null && _HAS_SMBSTATUS=true
command -v ip        &>/dev/null && _HAS_IP=true
command -v timeout   &>/dev/null && _TO=(timeout -k 5 "$SLOW_PROBE_TIMEOUT")

# mdadm: only show if arrays actually exist — the binary alone is not enough
[[ -r /proc/mdstat ]] && grep -q '^md[[:alnum:]]' /proc/mdstat 2>/dev/null \
	&& _MDADM_PRESENT=true

# NFS: exportfs present, or the nfs-server unit file is installed
[[ "$_HAS_EXPORTFS" == "true" ]] && _NFS_PRESENT=true
[[ "$_NFS_PRESENT" == "false" ]] \
	&& systemctl cat nfs-server.service &>/dev/null \
	&& _NFS_PRESENT=true

# Samba: smbd present, or the smbd unit file is installed
command -v smbd &>/dev/null && _SAMBA_PRESENT=true
[[ "$_SAMBA_PRESENT" == "false" ]] \
	&& systemctl cat smbd.service &>/dev/null \
	&& _SAMBA_PRESENT=true

if [[ "$_SAMBA_PRESENT" == "true" ]]; then
	systemctl cat nmbd.service    &>/dev/null && _NMBD_PRESENT=true
	systemctl cat winbind.service &>/dev/null && _WINBIND_PRESENT=true
fi

# Unit list for the single batched `systemctl show` per frame.
[[ "$_NFS_PRESENT"     == "true" ]] && SVC_UNITS+=('nfs-server' 'rpcbind')
[[ "$_SAMBA_PRESENT"   == "true" ]] && SVC_UNITS+=('smbd')
[[ "$_NMBD_PRESENT"    == "true" ]] && SVC_UNITS+=('nmbd')
[[ "$_WINBIND_PRESENT" == "true" ]] && SVC_UNITS+=('winbind')

# df: local filesystems only (-l), so a dead NFS/CIFS client mount can never
# block statfs and freeze the dashboard.  Pseudo filesystems are excluded up
# front so df doesn't stat them at all.  ZFS datasets are covered — correctly —
# by the ZFS section; in df each one's "size" is its own usage plus the pool's
# shared free space, which makes the percentages meaningless.
for _t in tmpfs devtmpfs squashfs overlay sysfs proc cgroup cgroup2 fusectl \
	debugfs tracefs securityfs pstore bpf hugetlbfs mqueue ramfs autofs \
	rpc_pipefs nfsd configfs efivarfs iso9660 udf nsfs binfmt_misc; do
	_DF_EXCL+=(-x "$_t")
done
[[ "$_ZFS_PRESENT" == "true" ]] && _DF_EXCL+=(-x zfs)
unset _t

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
DIV_H='─';  DIV_ML='╟'; DIV_MR='╢'; DASH_H='╌'

B="${FG_BLUE}${BOX_V}${RESET}"
[[ "$_PLAIN" == "true" ]] && B=''

_FILL_MID='' _FILL_THIN='' _FILL_DASH='' _FILL_OUTER=''
_LAST_WIDTH=0

# Fill a string of $2 spaces, substitute every space with $1, assign to $3.
repeat_char() {
	local out=''
	(( $2 > 0 )) && { printf -v out "%${2}s" ''; out="${out// /$1}"; }
	printf -v "$3" '%s' "$out"
}

rebuild_fills() {
	# Rules run between the junctions that replace the side borders, so
	# their fill spans the full inner width, like the top and bottom borders.
	local fill=$INNER_WIDTH
	repeat_char "$BOX_H"  "$fill"        _FILL_MID
	repeat_char "$DIV_H"  "$fill"        _FILL_THIN
	repeat_char "$DASH_H" "$fill"        _FILL_DASH
	repeat_char "$BOX_H"  "$INNER_WIDTH" _FILL_OUTER
	_LAST_WIDTH=$INNER_WIDTH
	_MID_COL=$(( TERM_WIDTH / 2 ))
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
# Line indices of rules and of two-column rows, so join_dividers can give a
# │ divider a junction (┬ ┴ ┼, or ╤ ╧ ╪ on double rules) where it meets a rule.
declare -A _RULE_AT=() _DIV_AT=()
frame_reset() { _LINES=(); _RULE_AT=(); _DIV_AT=(); }

# ── Drawing primitives ────────────────────────────────────────────────────────

# Rules replace the side borders with junctions (╠═╣, ╟─╢, ╟╌╢), so they
# meet the ║ border instead of stopping one column short of it.
inner_rule() {   # mid(╠═╣)  thin(╟─╢)  dash(╟╌╢)
	if [[ "$_PLAIN" == "true" ]]; then
		case "${1:-mid}" in
			mid)  _n "$_FILL_MID"  ;;
			thin) _n "$_FILL_THIN" ;;
			dash) _n "$_FILL_DASH" ;;
		esac
		return
	fi
	_RULE_AT[${#_LINES[@]}]=${1:-mid}
	case "${1:-mid}" in
		mid)  _n "${FG_BLUE}${BOX_ML}${_FILL_MID}${BOX_MR}${RESET}"  ;;
		thin) _n "${FG_BLUE}${DIV_ML}${_FILL_THIN}${DIV_MR}${RESET}" ;;
		dash) _n "${FG_BLUE}${DIV_ML}${_FILL_DASH}${DIV_MR}${RESET}" ;;
	esac
}

# CHA (\033[NG) snaps the right border to column TERM_WIDTH, bypassing
# Unicode/ANSI byte-width accounting entirely.  Autowrap is disabled while the
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
	box_line "${3}  ${BOLD}${FG_BWHITE}${1}${RESET}${FG_BLUE} — ${RESET}${FG_WHITE}${2}${RESET}" 2
	inner_rule thin
}

# Two columns separated by │ at _MID_COL.  Only used when fits_two_col says
# both sides fit: if the left side ran past the divider, the CHA jump would
# move the cursor back and the right side would overwrite it.  The \033[K
# after the left text matters: the CHA jump skips the gap up to the divider,
# so without it whatever a previous frame left on that row shows through.
two_col_row() {
	local left="$1" right="${2:-}"
	if [[ "$_PLAIN" == "true" ]]; then
		[[ -n "$left"  ]] && _n "$left"
		[[ -n "$right" ]] && _n "$right"
		return
	fi
	_DIV_AT[${#_LINES[@]}]=1
	_n "${B} ${left}${RESET}"$'\033[K\033'"[${_MID_COL}G${FG_BLUE}│${RESET} ${right}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
}

# True when every line in the named array fits in half the width.
fits_two_col() {   # $1 = array name
	[[ "$_PLAIN" == "true" ]] && return 1      # plain text: one item per line, in order
	local -n __fl="$1"
	local __s __half=$(( TERM_WIDTH - _MID_COL - 3 ))
	(( _MID_COL - 4 < __half )) && __half=$(( _MID_COL - 4 ))
	(( __half >= 30 )) || return 1
	for __s in "${__fl[@]}"; do
		vis_width "$__s"
		(( _VW <= __half )) || return 1
	done
	return 0
}

# Rebuild each rule that sits directly above or below a two-column row with
# a junction at the divider column.  The fill is rebuilt with repeat_char
# rather than sliced, so it stays correct whatever the locale's idea of a
# character is.
join_dividers() {
	[[ "$_PLAIN" == "true" ]] && return
	local i up dn h l r j a b off=$(( _MID_COL - 2 ))
	(( off > 0 && off < INNER_WIDTH - 1 )) || return
	for i in "${!_RULE_AT[@]}"; do
		up=${_DIV_AT[$(( i - 1 ))]-}; dn=${_DIV_AT[$(( i + 1 ))]-}
		[[ -n "$up$dn" ]] || continue
		case "${_RULE_AT[$i]}" in
			mid)  h=$BOX_H;  l=$BOX_ML; r=$BOX_MR
			      if [[ -n "$up" && -n "$dn" ]]; then j='╪'; elif [[ -n "$up" ]]; then j='╧'; else j='╤'; fi ;;
			thin|dash)
			      [[ "${_RULE_AT[$i]}" == thin ]] && h=$DIV_H || h=$DASH_H
			      l=$DIV_ML; r=$DIV_MR
			      if [[ -n "$up" && -n "$dn" ]]; then j='┼'; elif [[ -n "$up" ]]; then j='┴'; else j='┬'; fi ;;
			*) continue ;;
		esac
		repeat_char "$h" "$off" a
		repeat_char "$h" $(( INNER_WIDTH - off - 1 )) b
		_LINES[i]="${FG_BLUE}${l}${a}${j}${b}${r}${RESET}"
	done
}

# Emit a list of pre-built lines as a two-column grid when they fit, else one per row.
render_pairs() {   # $1 = name of an array variable holding the lines
	local -n __rp="$1"
	local n=${#__rp[@]} i
	(( n == 0 )) && return
	if (( n > 1 )) && fits_two_col "$1"; then
		for (( i=0; i<n; i+=2 )); do two_col_row "${__rp[i]}" "${__rp[i+1]-}"; done
	else
		for (( i=0; i<n; i++ )); do box_line "${__rp[i]}"; done
	fi
}

pair_or_stack() {   # two strings: side by side when both fit, else stacked
	if [[ -z "$2" ]]; then box_line "$1"; return; fi
	local -a __ps=("$1" "$2")
	if fits_two_col __ps; then two_col_row "$1" "$2"
	else box_line "$1"; box_line "$2"
	fi
}

# ── Byte / rate formatting (pure bash, no subprocesses) ───────────────────────
_FMT=''
fmt_bytes() {   # $1 = bytes, $2 = target var (default _FMT)
	local b="${1:-0}" out
	[[ "$b" =~ ^[0-9]+$ ]] || b=0
	if   (( b >= 1099511627776 )); then
		printf -v out '%d.%d TiB' $(( b / 1099511627776 )) $(( (b % 1099511627776) * 10 / 1099511627776 ))
	elif (( b >= 1073741824 )); then
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

fmt_rate() {    # $1 = bytes/sec ('' = unknown), $2 = target var (default _FMT)
	local b="${1-}" out
	if [[ ! "$b" =~ ^[0-9]+$ ]]; then out='—'
	elif (( b >= 1073741824 )); then
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

# Filled/empty bar for a 0–100 percentage.
_BAR=''
pct_bar() {     # $1 = pct, $2 = width, $3 = target var, $4 = warn %, $5 = crit %
	local pct="${1:-0}" width="${2:-20}" warn="${4:-75}" crit="${5:-90}"
	local filled=$(( pct * width / 100 ))
	(( filled > width )) && filled=$width
	(( filled < 0 )) && filled=0
	local empty=$(( width - filled ))
	local bar_col
	if   (( pct >= crit )); then bar_col="$FG_BRED"
	elif (( pct >= warn )); then bar_col="$FG_BYELLOW"
	else                         bar_col="$FG_BGREEN"
	fi
	local fs='' es=''
	(( filled > 0 )) && { printf -v fs '%*s' "$filled" ''; fs="${fs// /█}"; }
	(( empty  > 0 )) && { printf -v es '%*s' "$empty"  ''; es="${es// /░}"; }
	printf -v "${3:-_BAR}" '%s' "${bar_col}${fs}${DIM}${es}${RESET}"
}

pct_col() {     # $1 = pct, $2 = warn, $3 = crit → _PCOL
	if   (( $1 >= $3 )); then _PCOL="$FG_BRED"
	elif (( $1 >= $2 )); then _PCOL="$FG_BYELLOW"
	else                      _PCOL="$FG_BGREEN"
	fi
}

# "· SMART polled 12s ago (every 60s)" — yellow once the data is clearly stale
# (a stuck probe keeps the background poll from finishing).
_SN=''
slow_note() {   # $1 = label
	_SN=''
	[[ "$ONE_SHOT" == "true" ]] && return
	if (( _SLOW_LAST_TS == 0 )); then
		[[ -n "$_SLOW_PID" ]] && _SN="  ${DIM}· $1 polling…${RESET}"
		return
	fi
	local age=$(( _NOW - _SLOW_LAST_TS )) col="$DIM"
	(( age < 0 )) && age=0
	(( age > 2 * _SLOW_SECS + 30 )) && col="$FG_YELLOW"
	_SN="  ${col}· $1 polled ${age}s ago (every ${_SLOW_SECS}s)${RESET}"
}

# ── Service helpers ───────────────────────────────────────────────────────────

# One systemctl call per fetch for every unit.  `systemctl show` emits one
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

# ActiveEnterTimestamp survives a stop, so uptime is only meaningful while the
# unit is active — otherwise a stopped service would show a running clock.
_UPTIME=''
svc_uptime() {         # $1 = unit, $2 = target var (default _UPTIME)
	local ts="${_SVC_START[$1]-}" out
	if [[ "${_SVC_ACTIVE[$1]-}" != "active" || -z "$ts" || "$ts" == "n/a" ]] \
		|| ! ts_to_epoch "$ts"; then
		printf -v "${2:-_UPTIME}" '%s' "${DIM}n/a${RESET}"; return
	fi
	local elapsed=$(( _NOW - _EPOCH ))
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

# =============================================================================
# ── FAST FETCH — cheap sources, every interval ────────────────────────────────
# Rates are computed against a µs timestamp taken at the moment each counter
# file is read, not at the start of the frame: a frame-start timestamp mixed
# with whole-second resolution gave ±33% jitter at a 3 s interval.
# =============================================================================

fetch_zfs() {
	local f='/proc/spl/kstat/zfs/arcstats' an at av
	_ARC=()
	if [[ -r "$f" ]]; then
		while read -r an at av _; do
			case "$an" in
				size|c|c_max|l2_size|l2_asize|l2_hits|l2_misses|\
				demand_data_hits|demand_metadata_hits|\
				demand_data_misses|demand_metadata_misses)
					[[ "$av" =~ ^[0-9]+$ ]] && _ARC[$an]=$av ;;
			esac
		done 2>/dev/null < "$f"
	fi

	# Demand-only hit rates (prefetch inflates totals), both since boot and
	# over the last interval — the boot-wide figure barely moves after a day.
	local h=$(( ${_ARC[demand_data_hits]:-0} + ${_ARC[demand_metadata_hits]:-0} ))
	local m=$(( ${_ARC[demand_data_misses]:-0} + ${_ARC[demand_metadata_misses]:-0} ))
	local l2h=${_ARC[l2_hits]:-0} l2m=${_ARC[l2_misses]:-0} dh dm
	_ARC_NOW_PM=-1; _L2_NOW_PM=-1
	if (( _ARC_PREV_SET )); then
		dh=$(( h - _ARC_PREV_H )); dm=$(( m - _ARC_PREV_M ))
		(( dh >= 0 && dm >= 0 && dh + dm > 0 )) && _ARC_NOW_PM=$(( dh * 1000 / (dh + dm) ))
		dh=$(( l2h - _L2_PREV_H )); dm=$(( l2m - _L2_PREV_M ))
		(( dh >= 0 && dm >= 0 && dh + dm > 0 )) && _L2_NOW_PM=$(( dh * 1000 / (dh + dm) ))
	fi
	_ARC_PREV_H=$h; _ARC_PREV_M=$m; _L2_PREV_H=$l2h; _L2_PREV_M=$l2m; _ARC_PREV_SET=1

	_RAW_ZPOOL_LIST=$(zpool list -H -p -o name,size,alloc,free,frag,cap,health 2>/dev/null)
	_RAW_ZFS_LIST=$(zfs list -H -p -o name,used,avail,refer,usedsnap,compressratio,mountpoint 2>/dev/null)
}

fetch_mdadm() {
	slurp /proc/mdstat _RAW_MDSTAT
	_MD_MISMATCH=()
	local p v
	for p in /sys/block/md*; do
		[[ -d "$p/md" ]] || continue
		read_sysfs "$p/md/mismatch_cnt" v
		_MD_MISMATCH[${p##*/}]=$v
	done
}

fetch_drives() {
	# Whole disks have a device/ link; md arrays have md/.  Optical drives and
	# empty card-reader slots also have device/ links, so they're filtered by
	# name and by zero size.
	local -a phys=() md=()
	local p b sz
	for p in /sys/block/*; do
		b=${p##*/}
		case "$b" in sr*|loop*|ram*|zram*|nbd*|fd*) continue ;; esac
		if [[ -d "$p/md" ]]; then md+=("$b"); continue; fi
		[[ -e "$p/device" ]] || continue
		read_sysfs "$p/size" sz
		[[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 0 )) || continue
		phys+=("$b")
	done
	_DEVS=("${phys[@]}" "${md[@]}")

	local -A want=()
	for b in "${_DEVS[@]}"; do want[$b]=1; done

	# Fields: 3 name · 6 sectors read · 10 sectors written · 13 io_ticks (ms
	# with I/O in flight).  Sectors are always 512 bytes in diskstats.
	local now_us=${EPOCHREALTIME/[.,]/} dt=0 dn sr sw tk r w dr dw dk u
	(( _DISK_PREV_US > 0 )) && dt=$(( now_us - _DISK_PREV_US ))
	if [[ -r /proc/diskstats ]]; then
		while read -r _ _ dn _ _ sr _ _ _ sw _ _ tk _; do
			[[ -n "${want[$dn]-}" ]] || continue
			r=$(( sr * 512 )); w=$(( sw * 512 ))
			if (( dt > 0 )) && [[ -n "${_DISK_R[$dn]-}" ]]; then
				dr=$(( r - ${_DISK_R[$dn]} )); dw=$(( w - ${_DISK_W[$dn]} ))
				dk=$(( tk - ${_DISK_T[$dn]} ))
				(( dr < 0 )) && dr=0
				(( dw < 0 )) && dw=0
				(( dk < 0 )) && dk=0
				_DISK_RR[$dn]=$(( dr * 1000000 / dt ))
				_DISK_RW[$dn]=$(( dw * 1000000 / dt ))
				u=$(( dk * 100000 / dt ))         # ms busy / ms elapsed × 100
				(( u > 100 )) && u=100
				_DISK_UTIL[$dn]=$u
			else
				_DISK_RR[$dn]=''; _DISK_RW[$dn]=''; _DISK_UTIL[$dn]=''
			fi
			_DISK_R[$dn]=$r; _DISK_W[$dn]=$w; _DISK_T[$dn]=$tk
		done 2>/dev/null < /proc/diskstats
	fi
	_DISK_PREV_US=$now_us
}

fetch_volumes() {
	_RAW_DF=$(df -l -k --output=fstype,size,used,avail,pcent,target "${_DF_EXCL[@]}" 2>/dev/null)
}

fetch_nfs() {
	local f='/proc/net/rpc/nfsd' tag a b c d
	_NFS_STATS_OK=false
	if [[ -r "$f" ]]; then
		local now_us=${EPOCHREALTIME/[.,]/} io_r=0 io_w=0
		while read -r tag a b c d _; do
			case "$tag" in
				io)  io_r=$a; io_w=$b ;;
				net) _NFS_TCPCONN=$d ;;          # net <packets> <udp> <tcp> <tcpconn>
				rpc) _NFS_CALLS=$a; _NFS_BADCALLS=$b ;;
				th)  _NFS_THREADS=$a ;;
			esac
		done 2>/dev/null < "$f"
		[[ "$io_r" =~ ^[0-9]+$ ]] || io_r=0
		[[ "$io_w" =~ ^[0-9]+$ ]] || io_w=0
		_NFS_RR=''; _NFS_RW=''
		if (( _NFS_PREV_US > 0 && now_us > _NFS_PREV_US )); then
			local dt=$(( now_us - _NFS_PREV_US )) dr=$(( io_r - _NFS_IO_R )) dw=$(( io_w - _NFS_IO_W ))
			(( dr < 0 )) && dr=0
			(( dw < 0 )) && dw=0
			_NFS_RR=$(( dr * 1000000 / dt )); _NFS_RW=$(( dw * 1000000 / dt ))
		fi
		_NFS_IO_R=$io_r; _NFS_IO_W=$io_w; _NFS_PREV_US=$now_us
		_NFS_STATS_OK=true
	fi

	# NFSv4 clients never register with mountd, so showmount can't see them.
	# The kernel lists them under /proc/fs/nfsd/clients (root only).
	_NFS_V4=(); _NFS_V4_IDLE=0
	local ci l addr name st
	for ci in /proc/fs/nfsd/clients/*/info; do
		[[ -r "$ci" ]] || continue
		addr=''; name=''; st=''
		while IFS= read -r l; do
			case "$l" in
				address:*) l=${l#*\"}; l=${l%\"}; addr=${l%:*} ;;   # drop :port
				name:*)    l=${l#*\"}; l=${l%\"}; name=${l##* }; name=${name##*/} ;;
				status:*)  st=${l#status: } ;;
			esac
		done 2>/dev/null < "$ci"
		[[ -n "$addr" ]] || continue
		# The client chooses its own id string — keep only hostname-shaped names.
		[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && name=${name%%.*} || name=''
		sanitize "$addr"; addr=$_SAN
		if [[ "$st" == "confirmed" ]]; then _NFS_V4[$addr]=$name
		else _NFS_V4_IDLE=$(( _NFS_V4_IDLE + 1 ))
		fi
	done
}

fetch_network() {
	_IP_ADDRS=()
	if [[ "$_HAS_IP" == "true" ]]; then
		local ifn irest a out ipout
		ipout=$(ip -br addr show 2>/dev/null)
		while read -r ifn _ irest; do
			[[ -z "$ifn" ]] && continue
			ifn="${ifn%%@*}"          # veth peers appear as "veth0@if12"
			out=''
			for a in $irest; do
				[[ "$a" == fe80:* ]] && continue   # link-local is noise here
				out+="${out:+  }$a"
			done
			_IP_ADDRS["$ifn"]=$out
		done <<< "$ipout"
	fi

	local now_us=${EPOCHREALTIME/[.,]/} dt=0
	(( _NET_PREV_US > 0 )) && dt=$(( now_us - _NET_PREV_US ))
	_NET_ORDER=()
	local line iface d v u
	local -a f
	while IFS= read -r line; do
		[[ "$line" == *:* ]] || continue
		iface=${line%%:*}; iface=${iface##+([[:space:]])}
		[[ -z "$iface" || "$iface" == "lo" ]] && continue
		f=( ${line#*:} )            # numbers only — safe to word-split
		(( ${#f[@]} >= 12 )) || continue
		# rx: bytes packets errs drop fifo frame compressed multicast · tx: bytes packets errs drop …
		local rxb=${f[0]} rxe=${f[2]} rxd=${f[3]} txb=${f[8]} txe=${f[10]} txd=${f[11]}
		if (( dt > 0 )) && [[ -n "${_NET_RXB[$iface]-}" ]]; then
			local drx=$(( rxb - ${_NET_RXB[$iface]} )) dtx=$(( txb - ${_NET_TXB[$iface]} ))
			(( drx < 0 )) && drx=0
			(( dtx < 0 )) && dtx=0
			_NET_RXR[$iface]=$(( drx * 1000000 / dt ))
			_NET_TXR[$iface]=$(( dtx * 1000000 / dt ))
			_NET_ERR_NEW[$iface]=$(( rxe + txe - ${_NET_RXE[$iface]} - ${_NET_TXE[$iface]} ))
			_NET_DROP_NEW[$iface]=$(( rxd + txd - ${_NET_RXD[$iface]} - ${_NET_TXD[$iface]} ))
		else
			_NET_RXR[$iface]=''; _NET_TXR[$iface]=''
			_NET_ERR_NEW[$iface]=0; _NET_DROP_NEW[$iface]=0
		fi
		_NET_RXB[$iface]=$rxb; _NET_TXB[$iface]=$txb
		_NET_RXE[$iface]=$rxe; _NET_TXE[$iface]=$txe
		_NET_RXD[$iface]=$rxd; _NET_TXD[$iface]=$txd
		_NET_ORDER+=("$iface")

		d="/sys/class/net/$iface"
		read_sysfs "$d/operstate"       v; _NET_OPER[$iface]=$v
		read_sysfs "$d/speed"           v; _NET_SPEED[$iface]=$v
		read_sysfs "$d/duplex"          v; _NET_DUPLEX[$iface]=$v
		read_sysfs "$d/mtu"             v; _NET_MTU[$iface]=$v
		read_sysfs "$d/carrier_changes" v; _NET_CHG[$iface]=$v
		[[ -e "$d/device" ]] && _NET_PHYS[$iface]=1 || _NET_PHYS[$iface]=''

		# Master (bond/bridge): the `master` link points at one of the upper_*
		# links; -ef compares the resolved targets without forking readlink.
		_NET_MASTER[$iface]=''
		if [[ -e "$d/master" ]]; then
			for u in "$d"/upper_*; do
				[[ "$u" -ef "$d/master" ]] && { _NET_MASTER[$iface]=${u##*/upper_}; break; }
			done
		fi
		if [[ -d "$d/bonding" ]]; then
			read_sysfs "$d/bonding/mode"          v; _NET_BOND_MODE[$iface]=${v%% *}
			read_sysfs "$d/bonding/slaves"        v; _NET_BOND_SLAVES[$iface]=$v
			read_sysfs "$d/bonding/ad_aggregator" v; _NET_BOND_AGG[$iface]=$v
		else
			unset '_NET_BOND_MODE[$iface]'
		fi
		if [[ -d "$d/bonding_slave" ]]; then
			read_sysfs "$d/bonding_slave/mii_status"         v; _NET_SLAVE_MII[$iface]=$v
			read_sysfs "$d/bonding_slave/ad_aggregator_id"   v; _NET_SLAVE_AGG[$iface]=$v
			read_sysfs "$d/bonding_slave/link_failure_count" v; _NET_SLAVE_FAIL[$iface]=$v
		fi
	done 2>/dev/null < /proc/net/dev
	_NET_PREV_US=$now_us
}

fetch_fast() {
	_NOW=$EPOCHSECONDS
	svc_fetch_all
	[[ "$_ZFS_PRESENT"   == "true" ]] && fetch_zfs
	[[ "$_MDADM_PRESENT" == "true" ]] && fetch_mdadm
	fetch_drives
	fetch_volumes
	[[ "$_NFS_PRESENT"   == "true" ]] && fetch_nfs
	fetch_network
	printf -v LAST_REFRESH '%(%H:%M:%S)T' "$_NOW"
}

# After a pause, the next sample becomes a fresh baseline: a rate averaged over
# a five-minute pause would be labelled as current throughput.
reset_rate_baselines() { _DISK_PREV_US=0; _NET_PREV_US=0; _NFS_PREV_US=0; _ARC_PREV_SET=0; }

# =============================================================================
# ── SLOW POLL — background subshell, harvested when its marker appears ────────
# =============================================================================

start_slow_poll() {
	[[ -n "$_SLOW_PID" ]] && return 0
	local d="$_TMP/poll" dv pl
	local -a devs=() pools=()
	if [[ "$_SMART_AVAIL" == "true" ]]; then
		for dv in "${_DEVS[@]}"; do [[ "$dv" == md* ]] || devs+=("$dv"); done
	fi
	while IFS=$'\t' read -r pl _; do [[ -n "$pl" ]] && pools+=("$pl"); done <<< "$_RAW_ZPOOL_LIST"
	local nfs_up=false
	[[ "${_SVC_ACTIVE[nfs-server]-}" == "active" ]] && nfs_up=true
	_SLOW_START=$EPOCHSECONDS
	(
		# Without this the child would inherit nothing harmful today, but an
		# EXIT trap running restore_tty in the child would yank the parent's
		# terminal out of the alternate screen.  Be explicit.
		trap - EXIT INT TERM HUP QUIT WINCH
		rm -rf -- "$d" && mkdir -- "$d" || exit 1
		# -n standby: don't spin up sleeping drives just to read SMART.  Not
		# passed for NVMe, which has no spindle to wake.
		local -a nopt
		for dv in "${devs[@]}"; do
			nopt=(-n standby); [[ "$dv" == nvme* ]] && nopt=()
			"${_TO[@]}" smartctl "${nopt[@]}" -i -H -A "/dev/$dv" > "$d/smart.$dv"
			printf '%s' "$?" > "$d/smartrc.$dv"
		done
		(( ${#pools[@]} )) && "${_TO[@]}" zpool status > "$d/zpool"
		[[ "$_HAS_EXPORTFS" == "true" ]] && "${_TO[@]}" exportfs -v > "$d/exportfs"
		[[ "$nfs_up" == "true" && "$_HAS_SHOWMOUNT" == "true" ]] \
			&& "${_TO[@]}" showmount -a --no-headers > "$d/showmount"
		[[ "$_HAS_SMBSTATUS" == "true" && "$_SAMBA_PRESENT" == "true" ]] \
			&& "${_TO[@]}" smbstatus > "$d/smbstatus"
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

	local f dv rc
	for f in "$d"/smart.*; do
		[[ -e "$f" ]] || continue
		dv=${f##*/smart.}
		read_sysfs "$d/smartrc.$dv" rc
		[[ "$rc" =~ ^[0-9]+$ ]] || rc=255
		parse_smart "$dv" "$f" "$rc"
	done
	slurp "$d/zpool"     _RAW_ZPOOL_STATUS; parse_zpool_status
	slurp "$d/exportfs"  _RAW_EXPORTS;      parse_exports
	slurp "$d/showmount" _RAW_SHOWMOUNT
	slurp "$d/smbstatus" _RAW_SMB;          parse_smbstatus
	_SLOW_LAST_TS=$_SLOW_START
	return 0
}

# smartctl exit status is a bitmask and the authoritative health signal:
#   2 open failed / standby skip · 8 disk failing · 16 prefail attr ≤ threshold
#   32 attr ≤ threshold in the past · 64 error log has entries
#   128 self-test log has errors
# String-matching "FAILED" was fragile: the attribute table's WHEN_FAILED
# column header contains that word.
parse_smart() {   # $1 = dev, $2 = file, $3 = exit status
	local dv="$1" rc="$3" sout
	slurp "$2" sout
	if [[ "$sout" == *"STANDBY mode"* ]]; then
		_SMART_STBY[$dv]=1     # keep the last real readings; mark them as such
		return
	fi
	_SMART_STBY[$dv]=''
	if [[ -z "$sout" ]] || { (( rc & 2 )) && [[ "$sout" != *overall-health* && "$sout" != *"Health Status"* ]]; }; then
		_SMART_HS[$dv]='?'; _SMART_TC[$dv]=''; _SMART_RL[$dv]=0; _SMART_PD[$dv]=0
		_SMART_UC[$dv]=0; _SMART_CRC[$dv]=0; _SMART_WEAR[$dv]=''; _SMART_FLAGS[$dv]=''
		return
	fi

	local tc rl pd uc crc wear spare hs mdl ser cap parsed
	# \037 (unit separator) delimits fields: not IFS whitespace, so empty
	# fields survive the read, and it can't occur in a model string.
	parsed=$(awk '
		BEGIN { OFS = "\037" }
		/overall-health self-assessment test result:/ { hs = $NF }
		/^SMART Health Status:/                       { hs = $4 }
		# ATA attributes — field 10 is the raw value; avoids "34 (Min/Max 22/45)"
		$1+0==5   && NF>=10 && /Reallocated_Sector/ { rl  = $10+0 }
		$1+0==190 && NF>=10 && tc==""               { tc  = $10+0 }
		$1+0==194 && NF>=10                         { tc  = $10+0 }
		$1+0==197 && NF>=10 && /Pending/            { pd  = $10+0 }
		$1+0==198 && NF>=10 && /Uncorrect/          { uc  = $10+0 }
		$1+0==199 && NF>=10 && /CRC/                { crc = $10+0 }
		# SSD life: normalised VALUE (field 4) is percent remaining.  Matched by
		# name because the IDs are reused (WD HDDs use 202 for something else).
		/Wear_Leveling_Count|SSD_Life_Left|Media_Wearout_Indicator|Percent_Lifetime_Remain/ && NF>=10 && life=="" { life = $4+0 }
		# NVMe
		/^Temperature:[ \t]/                && tc=="" { tc = $2+0 }
		/^Percentage Used:/                           { used = $3+0 }
		/^Available Spare:/                           { spare = $3+0 }
		/^Media and Data Integrity Errors:/           { uc = $NF+0 }
		# SAS/SCSI
		/^Current Drive Temperature:/       && tc=="" { tc = $4+0 }
		/^Elements in grown defect list:/             { rl = $NF+0 }
		/^(Device Model|Model Number|Product):/ && mdl=="" {
			s = $0; sub(/^[^:]+:[ \t]*/, "", s); mdl = s
		}
		/^Serial [Nn]umber:/ && ser=="" { s = $0; sub(/^[^:]+:[ \t]*/, "", s); ser = s }
		# NVMe reports "Namespace 1 Size/Capacity" or "Total NVM Capacity".
		/^(User Capacity|Namespace 1 Size\/Capacity|Total NVM Capacity):/ && cap=="" {
			if (match($0, /\[[^\]]+\]/)) cap = substr($0, RSTART+1, RLENGTH-2)
		}
		END {
			if (used == "" && life != "") used = 100 - life
			print tc, rl+0, pd+0, uc+0, crc+0, used, spare, hs, mdl, ser, cap
		}
	' <<< "$sout")
	IFS=$'\037' read -r tc rl pd uc crc wear spare hs mdl ser cap <<< "$parsed"

	hs=${hs%!}
	[[ -z "$hs" ]] && hs='?'
	(( rc & 8 )) && hs='FAILED'

	local flags=''
	(( rc & 16 ))  && flags+="${flags:+ · }${FG_BRED}prefail attribute at threshold${RESET}"
	(( rc & 128 )) && flags+="${flags:+ · }${FG_BRED}self-test errors logged${RESET}"
	(( rc & 64 ))  && flags+="${flags:+ · }${FG_BYELLOW}error log has entries${RESET}"
	(( rc & 32 ))  && flags+="${flags:+ · }${DIM}attribute crossed threshold in the past${RESET}"
	[[ "$spare" =~ ^[0-9]+$ ]] && (( spare <= 10 )) \
		&& flags+="${flags:+ · }${FG_BRED}available spare ${spare}%${RESET}"

	sanitize "$mdl"; mdl=$_SAN
	sanitize "$ser"; ser=$_SAN
	(( ${#mdl} > 26 )) && mdl="${mdl:0:25}…"
	_SMART_HS[$dv]=$hs;      _SMART_TC[$dv]=$tc
	_SMART_RL[$dv]=${rl:-0}; _SMART_PD[$dv]=${pd:-0}; _SMART_UC[$dv]=${uc:-0}
	_SMART_CRC[$dv]=${crc:-0}; _SMART_WEAR[$dv]=$wear
	_SMART_MDL[$dv]=$mdl;    _SMART_SER[$dv]=$ser; _SMART_CAP[$dv]=$cap
	_SMART_FLAGS[$dv]=$flags
}

# One `zpool status` for every pool, split into per-pool fields here so the
# render path does no parsing beyond a few pattern matches.
parse_zpool_status() {
	_ZS_STATE=(); _ZS_STATUS=(); _ZS_SCAN=(); _ZS_ERRORS=(); _ZS_BAD=()
	_ZS_SCRUB_EPOCH=(); _ZS_SCRUB_KIND=(); _ZS_SCRUB_ERRS=()
	local line key pool='' sect='' first_row=false r w c
	local -a f
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*pool:\ (.+)$ ]]; then
			pool=${BASH_REMATCH[1]}; sect=''; continue
		fi
		[[ -n "$pool" ]] || continue
		# Section keywords are right-aligned on the colon; strip the indent.
		key=${line##+([[:space:]])}
		case "$key" in
			'state: '*)  _ZS_STATE[$pool]=${key#state: };   sect=''; continue ;;
			'status: '*) _ZS_STATUS[$pool]=${key#status: }; sect=''; continue ;;
			action:*|see:*) sect=''; continue ;;
			'scan: '*)   _ZS_SCAN[$pool]=${key#scan: };     sect='scan'; continue ;;
			config:*)    sect='config'; first_row=true; continue ;;
			'errors: '*) _ZS_ERRORS[$pool]=${key#errors: }; sect=''; continue ;;
		esac
		case "$sect" in
			scan)
				if [[ "$line" =~ ^[[:space:]]+[0-9] ]]; then _ZS_SCAN[$pool]+=$'\n'"$line"
				else sect=''
				fi ;;
			config)
				read -ra f <<< "$line"
				(( ${#f[@]} >= 2 )) || continue          # blank, "cache", "logs", "spares"
				[[ "${f[0]}" == "NAME" ]] && continue
				if [[ "$first_row" == "true" ]]; then first_row=false; continue; fi   # the pool row
				case "${f[1]}" in
					ONLINE|DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|SUSPENDED) ;;
					*) continue ;;                       # spares: AVAIL / INUSE
				esac
				# Counts may be abbreviated ("1.2K"), so compare as strings.
				r=${f[2]:-0}; w=${f[3]:-0}; c=${f[4]:-0}
				if [[ "${f[1]}" =~ ^(FAULTED|OFFLINE|UNAVAIL|REMOVED)$ || "$r" != 0 || "$w" != 0 || "$c" != 0 ]]; then
					_ZS_BAD[$pool]+="${f[0]}"$'\t'"${f[1]}"$'\t'"$r"$'\t'"$w"$'\t'"$c"$'\t'"${f[*]:5}"$'\n'
				fi ;;
		esac
	done <<< "$_RAW_ZPOOL_STATUS"

	local first
	for pool in "${!_ZS_SCAN[@]}"; do
		first=${_ZS_SCAN[$pool]%%$'\n'*}
		if [[ "$first" =~ ^(scrub\ repaired|resilvered|scrub\ canceled).*\ on\ (.+)$ ]]; then
			case "${BASH_REMATCH[1]}" in
				resilvered)     _ZS_SCRUB_KIND[$pool]=resilver ;;
				'scrub canceled') _ZS_SCRUB_KIND[$pool]=canceled ;;
				*)              _ZS_SCRUB_KIND[$pool]=scrub ;;
			esac
			ts_to_epoch "${BASH_REMATCH[2]}" && _ZS_SCRUB_EPOCH[$pool]=$_EPOCH
			[[ "$first" =~ with\ ([0-9]+)\ errors ]] && _ZS_SCRUB_ERRS[$pool]=${BASH_REMATCH[1]}
		fi
	done
}

# exportfs -v prints one line per path×client, and paths longer than 14
# characters push the client onto a continuation line:
#   /srv          192.168.1.0/24(rw,…)
#   /srv/media/library
#                 <world>(ro,…)
parse_exports() {
	_EXP=(); _EXP_ORDER=()
	local line path='' rest client opts
	while IFS= read -r line; do
		if [[ "$line" == /* ]]; then
			path=${line%%[[:space:]]*}
			rest=${line#"$path"}; rest=${rest##+([[:space:]])}
			[[ -z "$rest" ]] && continue
		elif [[ -n "$path" && "$line" == [[:space:]]* ]]; then
			rest=${line##+([[:space:]])}
		else
			continue
		fi
		client=${rest%%\(*}
		opts=${rest#*\(}; opts=${opts%)}
		[[ ",$opts," == *,ro,* ]] && client+=" (ro)"
		[[ -n "${_EXP[$path]+x}" ]] || _EXP_ORDER+=("$path")
		_EXP[$path]+="${_EXP[$path]:+, }$client"
	done <<< "$_RAW_EXPORTS"
}

# One plain `smbstatus` covers sessions, share connections and locked files.
parse_smbstatus() {
	_SMB_SESS=(); _SMB_SHARE_LIST=''; _SMB_FILES=0; _SMB_OK=false
	[[ -n "$_RAW_SMB" ]] || return
	_SMB_OK=true
	local line mode='' user mach ip proto s
	local -a f order=()
	local -A cnt=()
	while IFS= read -r line; do
		case "$line" in
			'PID '*)             mode=sess;  continue ;;
			'Service '*)         mode=share; continue ;;
			'Locked files:'*)    mode=lock;  continue ;;
			'No locked files'*)  mode='';    continue ;;
			''|-*)               continue ;;
		esac
		case "$mode" in
			sess)
				[[ "$line" == [0-9]* ]] || continue
				read -ra f <<< "$line"
				user=${f[1]-}; mach=${f[3]-}; ip=''; proto=''
				if [[ "$line" =~ \((ipv[46]):([^\)]*)\)[[:space:]]+([^[:space:]]+) ]]; then
					ip=${BASH_REMATCH[2]%:*}; proto=${BASH_REMATCH[3]}
				fi
				[[ "$mach" == "$ip" ]] && mach=''
				sanitize "$user";  user=$_SAN
				sanitize "$mach";  mach=$_SAN
				sanitize "$ip";    ip=$_SAN
				sanitize "$proto"; proto=$_SAN
				_SMB_SESS+=("$user"$'\037'"$mach"$'\037'"$ip"$'\037'"$proto") ;;
			share)
				read -ra f <<< "$line"
				s=${f[0]-}
				[[ -z "$s" || "$s" == 'IPC$' ]] && continue   # every client holds one
				[[ -n "${cnt[$s]+x}" ]] || order+=("$s")
				cnt[$s]=$(( ${cnt[$s]:-0} + 1 )) ;;
			lock)
				[[ "$line" == [0-9]* ]] && _SMB_FILES=$(( _SMB_FILES + 1 )) ;;
		esac
	done <<< "$_RAW_SMB"
	for s in "${order[@]}"; do
		sanitize "$s"
		_SMB_SHARE_LIST+="${_SMB_SHARE_LIST:+, }${_SAN} (${cnt[$s]})"
	done
}

# =============================================================================
# ── ZFS ───────────────────────────────────────────────────────────────────────
# =============================================================================
_PCOL=''
hit_col() {   # $1 = per-mille, $2 = excellent, $3 = good, $4 = cold (whole %) → _PCOL
	local p=$(( $1 / 10 ))
	if   (( $1 < 0 ));  then _PCOL="$FG_WHITE"
	elif (( p >= $2 )); then _PCOL="$FG_HGREEN"
	elif (( p >= $3 )); then _PCOL="$FG_GREEN"
	elif (( p >= $4 )); then _PCOL="$FG_WHITE"
	else                     _PCOL="$FG_CYAN"
	fi
}

render_zfs() {
	slow_note 'status'
	section_header "ZFS" "OpenZFS Pools & Cache${_SN}" "🗄"

	# ── ARC / L2ARC ───────────────────────────────────────────────────────────
	if (( ${#_ARC[@]} )); then
		local h=$(( ${_ARC[demand_data_hits]:-0} + ${_ARC[demand_metadata_hits]:-0} ))
		local m=$(( ${_ARC[demand_data_misses]:-0} + ${_ARC[demand_metadata_misses]:-0} ))
		local boot_pm=-1 now_txt boot_txt sz mx
		(( h + m > 0 )) && boot_pm=$(( h * 1000 / (h + m) ))
		# Cold <50% · Normal 50–90% · Good 90–95% · Excellent ≥95%
		hit_col "$_ARC_NOW_PM" 95 90 50
		if (( _ARC_NOW_PM >= 0 )); then printf -v now_txt '%s%d.%d%%%s' "$_PCOL" $(( _ARC_NOW_PM / 10 )) $(( _ARC_NOW_PM % 10 )) "$RESET"
		else now_txt="${DIM}idle${RESET}"
		fi
		if (( boot_pm >= 0 )); then printf -v boot_txt '%d.%d%%' $(( boot_pm / 10 )) $(( boot_pm % 10 ))
		else boot_txt='n/a'
		fi
		fmt_bytes "${_ARC[size]:-0}" sz
		fmt_bytes "${_ARC[c_max]:-${_ARC[c]:-0}}" mx
		local arc_l=" ${FG_BCYAN}ARC${RESET}    hit ${now_txt} ${DIM}now · ${boot_txt} boot${RESET}   ${DIM}size${RESET} ${FG_WHITE}${sz}${RESET} ${DIM}of${RESET} ${FG_WHITE}${mx}${RESET}"
		local arc_r=''
		if (( ${_ARC[l2_size]:-0} > 0 )); then
			local l2h=${_ARC[l2_hits]:-0} l2m=${_ARC[l2_misses]:-0} l2b=-1 l2now l2boot l2s l2a
			(( l2h + l2m > 0 )) && l2b=$(( l2h * 1000 / (l2h + l2m) ))
			# Cold <10% · Normal 10–40% · Good 40–60% · Excellent >60%
			hit_col "$_L2_NOW_PM" 61 40 10
			if (( _L2_NOW_PM >= 0 )); then printf -v l2now '%s%d.%d%%%s' "$_PCOL" $(( _L2_NOW_PM / 10 )) $(( _L2_NOW_PM % 10 )) "$RESET"
			else l2now="${DIM}idle${RESET}"
			fi
			if (( l2b >= 0 )); then printf -v l2boot '%d.%d%%' $(( l2b / 10 )) $(( l2b % 10 ))
			else l2boot='n/a'
			fi
			fmt_bytes "${_ARC[l2_size]:-0}"  l2s
			fmt_bytes "${_ARC[l2_asize]:-0}" l2a
			arc_r=" ${FG_BCYAN}L2ARC${RESET}  hit ${l2now} ${DIM}now · ${l2boot} boot${RESET}   ${DIM}size${RESET} ${FG_WHITE}${l2s}${RESET} ${DIM}(${l2a} on disk)${RESET}"
		fi
		inner_rule dash
		pair_or_stack "$arc_l" "$arc_r"
	fi

	if [[ -z "$_RAW_ZPOOL_LIST" ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  No ZFS pools imported${RESET}"
		box_blank; return
	fi

	# Bucket every dataset under its pool in one pass.
	local -A ds_by_pool=()
	local ds_name ds_used ds_avail ds_refer ds_snap ds_ratio ds_mp
	while IFS=$'\t' read -r ds_name ds_used ds_avail ds_refer ds_snap ds_ratio ds_mp; do
		[[ -z "$ds_name" ]] && continue
		ds_by_pool["${ds_name%%/*}"]+="${ds_name}"$'\t'"${ds_used}"$'\t'"${ds_avail}"$'\t'"${ds_refer}"$'\t'"${ds_snap}"$'\t'"${ds_ratio}"$'\t'"${ds_mp}"$'\n'
	done <<< "$_RAW_ZFS_LIST"

	local pool p_size p_alloc p_free p_frag p_cap p_health
	while IFS=$'\t' read -r pool p_size p_alloc p_free p_frag p_cap p_health; do
		[[ -z "$pool" ]] && continue
		inner_rule dash

		local hc
		case "$p_health" in
			ONLINE)   hc="$FG_BGREEN"  ;;
			DEGRADED) hc="$FG_BYELLOW" ;;
			*)        hc="$FG_BRED"    ;;   # FAULTED REMOVED UNAVAIL SUSPENDED OFFLINE
		esac
		box_line " ${BOLD}${FG_BWHITE}${pool}${RESET}  ${hc}${p_health:-?}${RESET}"

		# Capacity — ZFS allocation slows noticeably past ~80%, hence the bands.
		local sz al fr bar frag_txt cap_pad
		fmt_bytes "$p_size"  sz
		fmt_bytes "$p_alloc" al
		fmt_bytes "$p_free"  fr
		[[ "$p_cap" =~ ^[0-9]+$ ]] || p_cap=0
		pct_bar "$p_cap" 16 bar 80 90
		pct_col "$p_cap" 80 90
		[[ "$p_frag" =~ ^[0-9]+$ ]] && frag_txt="${p_frag}%" || frag_txt='—'
		printf -v cap_pad '%3d' "$p_cap"
		kv_line "Capacity    " "${bar} ${_PCOL}${cap_pad}%${RESET}  ${FG_BWHITE}${al}${RESET}${DIM} of ${RESET}${FG_WHITE}${sz}${RESET}${DIM}  ·  free ${RESET}${FG_BWHITE}${fr}${RESET}${DIM}  ·  frag ${frag_txt}${RESET}"

		# Scrub — shown even when clean, so a scrub schedule that has quietly
		# stopped running shows up as an ageing date.
		local scan="${_ZS_SCAN[$pool]-}" first
		first=${scan%%$'\n'*}
		if [[ -z "${_ZS_SCAN[$pool]+x}" ]]; then
			(( _SLOW_LAST_TS == 0 )) && kv_line "Scrub       " "${DIM}waiting for the first status poll…${RESET}"
		elif [[ "$first" == *"in progress"* ]]; then
			local what='scrub' pct='' eta=''
			[[ "$first" == resilver* ]] && what='resilver'
			[[ "$scan" =~ ([0-9]+\.[0-9]+)%\ done ]] && pct=${BASH_REMATCH[1]}
			[[ "$scan" =~ ,\ ([^,]+)\ to\ go ]] && eta=${BASH_REMATCH[1]}
			kv_line "Scrub       " "${FG_BYELLOW}⟳ ${what} in progress${RESET}${pct:+  ${FG_WHITE}${pct}%${RESET}}${eta:+  ${DIM}${eta} to go${RESET}}"
		elif [[ -n "${_ZS_SCRUB_EPOCH[$pool]-}" ]]; then
			local days=$(( (_NOW - ${_ZS_SCRUB_EPOCH[$pool]}) / 86400 )) kind=${_ZS_SCRUB_KIND[$pool]}
			local errs=${_ZS_SCRUB_ERRS[$pool]:-0} age_txt col
			(( days < 0 )) && days=0
			(( days == 0 )) && age_txt='today' || age_txt="${days}d ago"
			(( days > SCRUB_WARN_DAYS )) && col="$FG_BYELLOW" || col="$FG_BGREEN"
			case "$kind" in
				scrub)
					if (( errs > 0 )); then kv_line "Scrub       " "${FG_BRED}⚠ last scrub found ${errs} error(s)${RESET}  ${DIM}${age_txt}${RESET}"
					else kv_line "Scrub       " "${col}✓ last scrub ${age_txt}${RESET}  ${DIM}clean${RESET}"
					fi ;;
				canceled) kv_line "Scrub       " "${FG_BYELLOW}last scrub canceled ${age_txt}${RESET}" ;;
				resilver) kv_line "Scrub       " "${col}last resilver ${age_txt}${RESET}  ${DIM}(${errs} errors · no scrub since)${RESET}" ;;
			esac
		elif [[ "$first" == *"none requested"* ]]; then
			kv_line "Scrub       " "${FG_BYELLOW}never scrubbed${RESET}"
		elif [[ -n "$first" ]]; then
			kv_line "Scrub       " "${DIM}${first}${RESET}"
		fi

		# status: is only printed when something needs attention — except the
		# perennial "features not enabled" notice, which is dimmed.
		local zst="${_ZS_STATUS[$pool]-}"
		if [[ -n "$zst" ]]; then
			if [[ "$zst" == *features* ]]; then kv_line "Status      " "${DIM}${zst}${RESET}"
			else kv_line "Status      " "${FG_BYELLOW}${zst}${RESET}"
			fi
		fi

		# Per-device faults and error counts.  A pool stays ONLINE while a disk
		# racks up checksum errors, and DEGRADED alone doesn't say which disk.
		if [[ -n "${_ZS_BAD[$pool]-}" ]]; then
			local vn vs vr vw vc vrest vcol
			while IFS=$'\t' read -r vn vs vr vw vc vrest; do
				[[ -z "$vn" ]] && continue
				[[ "$vs" == OFFLINE ]] && vcol="$FG_BYELLOW" || vcol="$FG_BRED"
				[[ "$vs" == ONLINE ]] && vcol="$FG_BGREEN"
				box_line "     ${FG_BRED}⚠${RESET} ${FG_BWHITE}${vn}${RESET}  ${vcol}${vs}${RESET}  ${DIM}read${RESET} ${vr}  ${DIM}write${RESET} ${vw}  ${DIM}cksum${RESET} ${vc}${vrest:+  ${DIM}${vrest}${RESET}}"
			done <<< "${_ZS_BAD[$pool]}"
		fi

		local zerr="${_ZS_ERRORS[$pool]-}"
		if [[ -n "$zerr" && "$zerr" != *"No known data errors"* ]]; then
			kv_line "Data errors " "${FG_BRED}${zerr}${RESET}"
		fi

		# ── Datasets ──────────────────────────────────────────────────────────
		inner_rule dash
		local -a _ds_lines=()
		local rel w=8 bucket="${ds_by_pool[$pool]-}"
		while IFS=$'\t' read -r ds_name _; do
			[[ -z "$ds_name" ]] && continue
			rel="${ds_name#"${pool}/"}"
			(( ${#rel} > w )) && w=${#rel}
		done <<< "$bucket"
		(( w > 28 )) && w=28

		local u_h a_h r_h s_h ratio mp_str name_pad snap_txt ratio_txt
		while IFS=$'\t' read -r ds_name ds_used ds_avail ds_refer ds_snap ds_ratio ds_mp; do
			[[ -z "$ds_name" ]] && continue
			rel="${ds_name#"${pool}/"}"
			(( ${#rel} > w )) && rel="…${rel: -$(( w - 1 ))}"
			rpad "$rel" "$w" name_pad
			fmt_bytes "$ds_used"  u_h; rpad "$u_h" 9 u_h
			fmt_bytes "$ds_avail" a_h; rpad "$a_h" 9 a_h
			fmt_bytes "$ds_refer" r_h; rpad "$r_h" 9 r_h
			# Snapshots quietly eating a pool is the classic fileserver surprise.
			if [[ "$ds_snap" =~ ^[0-9]+$ ]] && (( ds_snap > 0 )); then
				fmt_bytes "$ds_snap" s_h; rpad "$s_h" 9 s_h
				snap_txt="  ${DIM}snap${RESET} ${FG_BYELLOW}${s_h}${RESET}"
			else
				snap_txt="  ${DIM}snap —        ${RESET}"
			fi
			ratio=${ds_ratio%x}
			ratio_txt=''
			[[ "$ratio" =~ ^[0-9.]+$ && "$ratio" != 1.00 ]] && ratio_txt="  ${FG_CYAN}${ratio}x${RESET}"
			mp_str=''
			[[ "$ds_mp" != "-" && "$ds_mp" != "none" && "$ds_mp" != "legacy" ]] && mp_str="  ${DIM}→ ${ds_mp}${RESET}"
			_ds_lines+=( " ${FG_WHITE}${name_pad}${RESET}  ${DIM}used${RESET} ${FG_BWHITE}${u_h}${RESET} ${DIM}avail${RESET} ${FG_WHITE}${a_h}${RESET} ${DIM}refer${RESET} ${FG_WHITE}${r_h}${RESET}${snap_txt}${ratio_txt}${mp_str}" )
		done <<< "$bucket"

		if (( ${#_ds_lines[@]} == 0 )); then
			box_line "   ${DIM}(no datasets)${RESET}"
		else
			render_pairs _ds_lines
		fi
	done <<< "$_RAW_ZPOOL_LIST"

	box_blank
}

# =============================================================================
# ── MDADM ─────────────────────────────────────────────────────────────────────
# =============================================================================
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
	# becomes "sdb1 sdc1".
	local -a _dw=()
	local w clean_devs=''
	read -r -a _dw <<< "$devs"
	for w in "${_dw[@]}"; do
		w="${w%%\[*}"
		w="${w%%(*}"
		[[ -n "$w" ]] && clean_devs+="${clean_devs:+ }$w"
	done

	local name_pad; rpad "$name" 6 name_pad
	local line=" ${FG_BWHITE}${name_pad}${RESET}  ${FG_WHITE}${level}${RESET}  ${state_str}${sdisplay}  ${FG_WHITE}${clean_devs}${RESET}"
	[[ -n "$sync_info" ]] && line+="  ${FG_BYELLOW}⟳ ${sync_info}${RESET}"
	# mismatch_cnt is set by the last check/repair; non-zero means the
	# mirrors/parity disagreed somewhere (benign on swap-backed raid1).
	local mm="${_MD_MISMATCH[$name]-}"
	[[ "$mm" =~ ^[0-9]+$ ]] && (( mm > 0 )) && line+="  ${FG_BYELLOW}mismatch ${mm}${RESET}"
	_MD_LINE="$line"
}

render_mdadm() {
	section_header "mdadm" "Linux Software RAID" "⚙"

	if [[ -z "$_RAW_MDSTAT" ]]; then
		box_line "   ${FG_YELLOW}⚠  /proc/mdstat not readable${RESET}"
		box_blank; return
	fi

	local line in_array=false arr_name='' arr_state='' arr_level='' arr_devs='' arr_status='' arr_sync=''
	local -a _arr_lines=()

	while IFS= read -r line; do
		if [[ "$line" =~ ^(md[[:alnum:]]+)[[:space:]]+:[[:space:]]+(active|inactive|read-auto)[[:space:]] ]]; then
			# Capture before flushing: the formatter runs regex tests of its own,
			# which would overwrite BASH_REMATCH for every array after the first.
			local _nm="${BASH_REMATCH[1]}" _st="${BASH_REMATCH[2]}"
			if [[ "$in_array" == "true" ]]; then
				_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync"
				_arr_lines+=( "$_MD_LINE" )
			fi
			arr_name="$_nm"
			arr_state="$_st"
			local _rest="${line#*"${arr_state}" }"
			[[ "${_rest:0:1}" == "(" ]] && _rest="${_rest#*) }"
			arr_level="${_rest%% *}"
			arr_devs="${_rest#* }"
			arr_status=''; arr_sync=''
			in_array=true

		elif [[ "$in_array" == "true" && "$line" =~ \[([U_]+)\] ]]; then
			arr_status="${BASH_REMATCH[1]}"

		elif [[ "$in_array" == "true" && "$line" =~ (resync|recovery|reshape|check)[[:space:]]*= ]]; then
			# The operation name comes from this match, not from ${line%%=*}:
			# the first '=' in the line sits inside the "[====>" progress bar.
			local _op="${BASH_REMATCH[1]}" pct=''
			[[ "$line" =~ ([0-9]+\.[0-9]+)% ]] && pct="${BASH_REMATCH[1]}"
			if [[ -n "$pct" ]]; then arr_sync="${_op} = ${pct}%"
			else arr_sync="${line##+([[:space:]])}"
			fi
		fi
	done <<< "$_RAW_MDSTAT"

	if [[ "$in_array" == "true" ]]; then
		_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync"
		_arr_lines+=( "$_MD_LINE" )
	fi

	inner_rule dash
	if (( ${#_arr_lines[@]} == 0 )); then
		box_line "   ${DIM}No mdadm arrays configured${RESET}"
	else
		render_pairs _arr_lines
	fi
	box_blank
}

# =============================================================================
# ── DRIVES ────────────────────────────────────────────────────────────────────
# Three lines per drive: health/temperature/I/O/busy · identity and totals ·
# problems (only when there are any).
# =============================================================================
render_drives() {
	local smart_lbl=''
	if [[ "$_SMART_AVAIL" == "true" ]]; then
		slow_note 'SMART'
		smart_lbl=" · SMART${_SN}"
	fi
	section_header "DRIVES" "I/O · Busy${smart_lbl}" "💾"

	if (( ${#_DEVS[@]} == 0 )); then
		inner_rule dash
		box_line "   ${DIM}No drives found${RESET}"
		box_blank; return
	fi

	local -a L1=() L2=() L3=()
	local dev rr rw ut rrs rws rcol wcol utxt uc hs hc tc temps tcol tc_lead
	local tr tw trp info wear wtxt rl pd ucr crc flags probs dev_pad hs_pad stby
	for dev in "${_DEVS[@]}"; do
		rr=${_DISK_RR[$dev]-}; rw=${_DISK_RW[$dev]-}; ut=${_DISK_UTIL[$dev]-}
		fmt_rate "$rr" rrs; fmt_rate "$rw" rws
		if [[ -n "$rr" ]]; then rcol="$FG_BGREEN"; wcol="$FG_BYELLOW"
		else rcol="$DIM"; wcol="$DIM"
		fi
		rpad "$rrs" 11 rrs; rpad "$rws" 11 rws

		# io_ticks is meaningless on md devices, so they get no busy figure.
		# On SSDs, 100% means "always something in flight", not saturated.
		utxt=''
		if [[ "$dev" != md* && -n "$ut" ]]; then
			if   (( ut >= 90 )); then uc="$FG_BRED"
			elif (( ut >= 60 )); then uc="$FG_BYELLOW"
			else                      uc="$FG_WHITE"
			fi
			printf -v utxt '  %sbusy%s %s%3d%%%s' "$DIM" "$RESET" "$uc" "$ut" "$RESET"
		fi

		hs=''; hc="$DIM"; tc=''; stby=false
		rl=0; pd=0; ucr=0; crc=0; flags=''; wear=''; info=''
		if [[ "$_SMART_AVAIL" == "true" && "$dev" != md* ]]; then
			if [[ -n "${_SMART_HS[$dev]+x}" || -n "${_SMART_STBY[$dev]-}" ]]; then
				hs=${_SMART_HS[$dev]:-?}
				case "$hs" in
					PASSED|OK) hc="$FG_BGREEN" ;;
					FAILED)    hc="$FG_BRED"   ;;
					*)         hc="$DIM"       ;;
				esac
				tc=${_SMART_TC[$dev]-}
				rl=${_SMART_RL[$dev]:-0}; pd=${_SMART_PD[$dev]:-0}
				ucr=${_SMART_UC[$dev]:-0}; crc=${_SMART_CRC[$dev]:-0}
				flags=${_SMART_FLAGS[$dev]-}; wear=${_SMART_WEAR[$dev]-}
				info=${_SMART_MDL[$dev]-}
				[[ -n "${_SMART_CAP[$dev]-}" ]] && info+="${info:+ · }${_SMART_CAP[$dev]}"
				[[ -n "${_SMART_SER[$dev]-}" ]] && info+="${info:+ · }SN ${_SMART_SER[$dev]}"
				if [[ -n "${_SMART_STBY[$dev]-}" ]]; then
					hs='STANDBY'; hc="$DIM"; stby=true
				fi
			else
				hs='…'
			fi
		fi

		temps='      '
		if [[ "$tc" =~ ^[0-9]+$ ]] && (( tc > 0 )); then
			if   [[ "$stby" == "true" ]]; then tcol="$DIM"   # last reading before spin-down
			elif (( tc >= 55 )); then tcol="$FG_BRED"
			elif (( tc >= 45 )); then tcol="$FG_BYELLOW"
			else                      tcol="$FG_BGREEN"
			fi
			case ${#tc} in 1) tc_lead='   ' ;; 2) tc_lead='  ' ;; *) tc_lead=' ' ;; esac
			temps="${tc_lead}${tcol}${tc}°C${RESET}"
		fi

		rpad "$dev" 9 dev_pad
		rpad "${hs:-—}" 7 hs_pad
		L1+=( " ${FG_BWHITE}${dev_pad}${RESET} ${hc}${hs_pad}${RESET}${temps}   ↓ ${rcol}${rrs}${RESET} ↑ ${wcol}${rws}${RESET}${utxt}" )

		fmt_bytes "${_DISK_R[$dev]:-0}" tr
		fmt_bytes "${_DISK_W[$dev]:-0}" tw
		rpad "$tr" 10 trp
		wtxt=''
		if [[ "$wear" =~ ^[0-9]+$ ]]; then
			pct_col "$wear" 70 90
			[[ "$_PCOL" == "$FG_BGREEN" ]] && _PCOL="$FG_WHITE"
			wtxt="  ${DIM}wear${RESET} ${_PCOL}${wear}%${RESET}"
		fi
		L2+=( "           ${DIM}R${RESET} ${FG_WHITE}${trp}${RESET} ${DIM}W${RESET} ${FG_WHITE}${tw}${RESET}${info:+   ${DIM}${info}${RESET}}${wtxt}" )

		probs=''
		(( rl  > 0 )) && probs+="${FG_BRED}reallocated ${rl}${RESET}   "
		(( pd  > 0 )) && probs+="${FG_BYELLOW}pending ${pd}${RESET}   "
		(( ucr > 0 )) && probs+="${FG_BRED}uncorrectable ${ucr}${RESET}   "
		(( crc > 0 )) && probs+="${FG_BYELLOW}CRC ${crc}${RESET} ${DIM}(cable/backplane)${RESET}   "
		[[ "$hs" == "FAILED" ]] && probs="${FG_BRED}SMART health FAILED${RESET}   ${probs}"
		[[ -n "$flags" ]] && probs+="$flags"
		[[ -n "$probs" ]] && L3+=( "           ⚠  ${probs}" ) || L3+=( '' )
	done

	inner_rule dash
	local -a all=("${L1[@]}" "${L2[@]}" "${L3[@]}")
	local n=${#L1[@]} i j
	if fits_two_col all; then
		# Each drive owns a block of lines that must stay together.
		for (( i=0; i<n; i+=2 )); do
			j=$(( i + 1 ))
			two_col_row "${L1[i]}" "${L1[j]-}"
			two_col_row "${L2[i]}" "${L2[j]-}"
			[[ -n "${L3[i]}" || -n "${L3[j]-}" ]] && two_col_row "${L3[i]}" "${L3[j]-}"
		done
	else
		for (( i=0; i<n; i++ )); do
			box_line "${L1[i]}"
			box_line "${L2[i]}"
			[[ -n "${L3[i]}" ]] && box_line "${L3[i]}"
		done
	fi
	box_blank
}

# =============================================================================
# ── VOLUMES ───────────────────────────────────────────────────────────────────
# =============================================================================
render_volumes() {
	section_header "VOLUMES" "Filesystem Space Usage" "📊"

	if [[ -z "$_RAW_DF" ]]; then
		box_line "   ${FG_YELLOW}⚠  df failed${RESET}"
		box_blank; return
	fi

	local -a _vols=()
	local fstype sz_k used_k avail_k pct_str mp w=12 line
	# Mount point is the last column so paths containing spaces survive.
	while read -r fstype sz_k used_k avail_k pct_str mp; do
		[[ "$fstype" == "Type" || -z "$mp" ]] && continue
		case "$mp" in /run/user/*|/snap/*|/dev/pts) continue ;; esac
		(( ${#mp} > w )) && w=${#mp}
	done <<< "$_RAW_DF"
	(( w > 28 )) && w=28

	local pct bar mp_pad fs_pad pct_pad used_h sz_h
	while read -r fstype sz_k used_k avail_k pct_str mp; do
		[[ "$fstype" == "Type" || -z "$mp" ]] && continue
		case "$mp" in /run/user/*|/snap/*|/dev/pts) continue ;; esac
		[[ "$sz_k" =~ ^[0-9]+$ && "$used_k" =~ ^[0-9]+$ ]] || continue
		pct="${pct_str//%/}"
		[[ "$pct" =~ ^[0-9]+$ ]] || pct=0
		pct_bar "$pct" 12 bar
		pct_col "$pct" 75 90
		(( ${#mp} > w )) && mp="…${mp: -$(( w - 1 ))}"
		rpad "$mp" "$w" mp_pad
		rpad "$fstype" 6 fs_pad
		printf -v pct_pad '%3d'   "$pct"
		fmt_bytes $(( used_k * 1024 )) used_h
		fmt_bytes $(( sz_k * 1024 ))   sz_h
		_vols+=( " ${FG_BWHITE}${mp_pad}${RESET}  ${DIM}${fs_pad}${RESET}  ${bar}  ${_PCOL}${pct_pad}%${RESET}  ${FG_WHITE}${used_h}${RESET}${DIM}/${RESET}${FG_WHITE}${sz_h}${RESET}" )
	done <<< "$_RAW_DF"

	inner_rule dash
	if (( ${#_vols[@]} == 0 )); then
		box_line "   ${DIM}No local filesystems found${RESET}"
	else
		render_pairs _vols
	fi
	box_blank
}

# =============================================================================
# ── NFS ───────────────────────────────────────────────────────────────────────
# =============================================================================
render_nfs() {
	slow_note 'exports'
	section_header "NFS" "NFS Kernel Server${_SN}" "📂"

	local svc='nfs-server'   # systemd unit name on Debian (pkg: nfs-kernel-server)
	local nfs_badge nfs_enabled nfs_uptime rpc_badge rpc_enabled
	svc_status_badge  "$svc"     nfs_badge
	svc_enabled_badge "$svc"     nfs_enabled
	svc_uptime        "$svc"     nfs_uptime
	svc_status_badge  'rpcbind'  rpc_badge
	svc_enabled_badge 'rpcbind'  rpc_enabled
	pair_or_stack " ${nfs_badge}  ${DIM}Boot:${RESET} ${nfs_enabled}  ${DIM}Up:${RESET} ${nfs_uptime}" \
		" ${DIM}rpcbind:${RESET}  ${rpc_badge}  ${DIM}Boot:${RESET} ${rpc_enabled}"

	# ── Exports ───────────────────────────────────────────────────────────────
	inner_rule dash
	if [[ "$_HAS_EXPORTFS" != "true" ]]; then
		kv_line "Exports     " "${DIM}exportfs not found${RESET}"
	elif (( _SLOW_LAST_TS == 0 )); then
		kv_line "Exports     " "${DIM}waiting for the first poll…${RESET}"
	elif (( ${#_EXP_ORDER[@]} == 0 )); then
		kv_line "Exports     " "${DIM}none (or exportfs requires root)${RESET}"
	else
		kv_line "Exports     " "${FG_BWHITE}${#_EXP_ORDER[@]}${RESET}  ${DIM}active${RESET}"
		local -a _exp_lines=()
		local p
		for p in "${_EXP_ORDER[@]}"; do
			_exp_lines+=( "   ${FG_BWHITE}${p}${RESET}  ${DIM}→  ${_EXP[$p]}${RESET}" )
		done
		render_pairs _exp_lines
	fi

	# ── Clients: NFSv4 from the kernel, NFSv3 from mountd ─────────────────────
	if [[ "${_SVC_ACTIVE[$svc]-}" == "active" ]]; then
		local -a names=()
		local -A seen=()
		local a h mline
		for a in "${!_NFS_V4[@]}"; do
			names+=( "${_NFS_V4[$a]:-$a}" ); seen[$a]=1
		done
		while IFS= read -r mline; do
			[[ -z "$mline" ]] && continue
			h=${mline%%:*}
			sanitize "$h"; h=$_SAN
			[[ -n "${seen[$h]-}" ]] && continue
			seen[$h]=1; names+=( "$h ${DIM}(v3)${RESET}" )
		done <<< "$_RAW_SHOWMOUNT"
		local list='' n
		for n in "${names[@]}"; do list+="${list:+, }${n}"; done
		local idle=''
		(( _NFS_V4_IDLE > 0 )) && idle="  ${DIM}+${_NFS_V4_IDLE} idle (courtesy)${RESET}"
		if (( ${#names[@]} == 0 && EUID != 0 )); then
			kv_line "Clients     " "${DIM}client list requires root${RESET}"
		else
			kv_line "Clients     " "${FG_BWHITE}${#names[@]}${RESET}  ${FG_WHITE}${list}${RESET}${idle}"
		fi
	fi

	# ── Server RPC and I/O from /proc ─────────────────────────────────────────
	if [[ "$_NFS_STATS_OK" == "true" ]]; then
		inner_rule dash
		local bad='' rrs rws trs tws
		[[ "$_NFS_BADCALLS" =~ ^[0-9]+$ ]] && (( _NFS_BADCALLS > 0 )) \
			&& bad="   ${FG_BYELLOW}bad calls ${_NFS_BADCALLS}${RESET}"
		kv_line "RPC         " "${DIM}threads${RESET} ${FG_BWHITE}${_NFS_THREADS}${RESET}   ${DIM}TCP connections${RESET} ${FG_BWHITE}${_NFS_TCPCONN:-0}${RESET}   ${DIM}calls${RESET} ${FG_WHITE}${_NFS_CALLS:-0}${RESET}${bad}"
		fmt_rate "$_NFS_RR" rrs; fmt_rate "$_NFS_RW" rws
		fmt_bytes "$_NFS_IO_R" trs; fmt_bytes "$_NFS_IO_W" tws
		rpad "$rrs" 11 rrs
		kv_line "I/O         " "${DIM}read${RESET} ${FG_BGREEN}${rrs}${RESET} ${DIM}write${RESET} ${FG_BYELLOW}${rws}${RESET}   ${DIM}total read ${trs} · written ${tws}${RESET}"
	fi

	box_blank
}

# =============================================================================
# ── SAMBA ─────────────────────────────────────────────────────────────────────
# =============================================================================
render_samba() {
	slow_note 'sessions'
	section_header "SAMBA" "SMB/CIFS File Server${_SN}" "🖧"

	local st en
	svc_status_badge  'smbd' st
	svc_enabled_badge 'smbd' en
	kv_line "smbd   " "${st}  Boot: ${en}"
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

	inner_rule dash
	if [[ "$_HAS_SMBSTATUS" != "true" ]]; then
		box_line "   ${DIM}smbstatus not found${RESET}"
	elif (( _SLOW_LAST_TS == 0 )); then
		kv_line "Sessions    " "${DIM}waiting for the first poll…${RESET}"
	elif [[ "$_SMB_OK" != "true" ]]; then
		kv_line "Sessions    " "${DIM}smbstatus returned nothing (requires root)${RESET}"
	else
		kv_line "Sessions    " "${FG_BWHITE}${#_SMB_SESS[@]}${RESET}  ${DIM}active${RESET}"
		local s user mach ip proto pcol
		for s in "${_SMB_SESS[@]}"; do
			IFS=$'\037' read -r user mach ip proto <<< "$s"
			# SMB1 (NT1) is the protocol you want to know about.
			[[ "$proto" == NT1 || "$proto" == SMB1* ]] && pcol="$FG_BRED" || pcol="$DIM"
			box_line "      ${FG_WHITE}${user}${RESET}  ${DIM}@${RESET} ${mach:+${FG_WHITE}${mach}${RESET} }${DIM}${ip}${RESET}  ${pcol}${proto}${RESET}"
		done
		kv_line "Shares      " "${_SMB_SHARE_LIST:-${DIM}none in use${RESET}}"
		kv_line "Open files  " "${FG_BWHITE}${_SMB_FILES}${RESET}"
	fi

	box_blank
}

# =============================================================================
# ── NETWORK ───────────────────────────────────────────────────────────────────
# =============================================================================
render_network() {
	section_header "NETWORK" "Interface Status & Throughput" "🌐"

	local any=false ifn
	for ifn in "${_NET_ORDER[@]}"; do
		# Physical NICs are always shown — a port that never came up is exactly
		# the failure worth seeing, and it has zero traffic since boot.  Virtual
		# devices are shown only when they carry an address or traffic.
		if [[ -z "${_NET_PHYS[$ifn]-}" && -z "${_NET_BOND_MODE[$ifn]+x}" ]]; then
			case "$ifn" in
				veth*|docker*|br-*|virbr*|vnet*|tap*|cni*|flannel*|cali*|kube-*) continue ;;
			esac
			[[ -n "${_IP_ADDRS[$ifn]-}" ]] \
				|| (( ${_NET_RXB[$ifn]:-0} + ${_NET_TXB[$ifn]:-0} > 0 )) \
				|| continue
		fi
		any=true
		inner_rule dash

		local oper=${_NET_OPER[$ifn]:-unknown} oc
		# A physical port that is down, unaddressed, unbonded and has never
		# moved a byte since boot is most likely just an unused onboard NIC.
		# A configured port that's down (address, bond slave, past traffic)
		# still gets the full red treatment below.
		if [[ "$oper" != "up" && -n "${_NET_PHYS[$ifn]-}" && -z "${_IP_ADDRS[$ifn]-}" \
			&& -z "${_NET_MASTER[$ifn]-}" ]] \
			&& (( ${_NET_RXB[$ifn]:-0} + ${_NET_TXB[$ifn]:-0} == 0 )); then
			box_line "   ${DIM}${ifn}  ${oper} · unused (no link, no address, no traffic since boot)${RESET}"
			continue
		fi
		case "$oper" in
			up)   oc="$FG_BGREEN" ;;
			down) oc="$FG_BRED"   ;;
			*)    oc="$FG_YELLOW" ;;
		esac

		# Speed: one decimal place, so 2.5 GbE reads 2.5 rather than 2.
		local sp=${_NET_SPEED[$ifn]-} sp_txt='' dup=${_NET_DUPLEX[$ifn]-}
		if [[ "$sp" =~ ^[0-9]+$ ]] && (( sp > 0 )); then
			if (( sp >= 1000 )); then
				local g=$(( sp / 1000 )) frac=$(( sp % 1000 / 100 ))
				(( frac )) && g+=".$frac"
				sp_txt="  ${FG_BWHITE}${g} Gbps${RESET}"
			else
				sp_txt="  ${FG_WHITE}${sp} Mbps${RESET}"
			fi
			case "$dup" in
				full) sp_txt+=" ${DIM}full${RESET}" ;;
				half) sp_txt+=" ${FG_BYELLOW}half-duplex${RESET}" ;;
			esac
		fi

		local mtu_txt=''
		[[ -n "${_NET_MTU[$ifn]-}" ]] && mtu_txt="  ${DIM}MTU${RESET} ${FG_WHITE}${_NET_MTU[$ifn]}${RESET}"

		local extra=''
		local master=${_NET_MASTER[$ifn]-}
		[[ -n "$master" ]] && extra+="  ${DIM}→ ${master}${RESET}"
		if [[ -n "${_NET_SLAVE_MII[$ifn]-}" && "${_NET_SLAVE_MII[$ifn]}" != up ]]; then
			extra+="  ${FG_BRED}mii ${_NET_SLAVE_MII[$ifn]}${RESET}"
		fi
		local lf=${_NET_SLAVE_FAIL[$ifn]-}
		[[ "$lf" =~ ^[0-9]+$ ]] && (( lf > 0 )) && extra+="  ${FG_BYELLOW}link failures ${lf}${RESET}"
		# carrier_changes counts every up/down transition; one or two from boot is normal.
		local chg=${_NET_CHG[$ifn]-}
		[[ "$chg" =~ ^[0-9]+$ ]] && (( chg > 2 )) && extra+="  ${FG_BYELLOW}link changes ${chg}${RESET}"

		# Bond: slaves up, and for 802.3ad whether every slave joined the
		# active aggregator.  A slave in another aggregator is up but idle —
		# the classic LACP mismatch, invisible everywhere else.
		local -a bond_warn=()
		if [[ -n "${_NET_BOND_MODE[$ifn]+x}" ]]; then
			local -a sl=()
			local s up=0 agg=${_NET_BOND_AGG[$ifn]-} sagg
			read -ra sl <<< "${_NET_BOND_SLAVES[$ifn]-}"
			for s in "${sl[@]}"; do
				if [[ "${_NET_SLAVE_MII[$s]-}" == "up" ]]; then up=$(( up + 1 ))
				else bond_warn+=( "      ${FG_BRED}⚠ ${s}: link ${_NET_SLAVE_MII[$s]:-down}${RESET}" )
				fi
				sagg=${_NET_SLAVE_AGG[$s]-}
				if [[ "${_NET_BOND_MODE[$ifn]}" == 802.3ad && -n "$agg" && -n "$sagg" && "$sagg" != "$agg" ]]; then
					bond_warn+=( "      ${FG_BYELLOW}⚠ ${s}: not in the active aggregator (${sagg} ≠ ${agg}) — up but carrying no traffic${RESET}" )
				fi
			done
			local sc="$FG_BGREEN"
			(( up < ${#sl[@]} )) && sc="$FG_BRED"
			extra+="  ${DIM}${_NET_BOND_MODE[$ifn]}${RESET}  ${sc}${up}/${#sl[@]} slaves up${RESET}"
		fi

		box_line "   ${BOLD}${FG_BWHITE}${ifn}${RESET}  ${oc}${oper}${RESET}${sp_txt}${mtu_txt}${extra}"
		local bw
		for bw in "${bond_warn[@]}"; do box_line "$bw"; done
		[[ -n "${_IP_ADDRS[$ifn]-}" ]] && box_line "      ${DIM}${_IP_ADDRS[$ifn]}${RESET}"

		local rx=${_NET_RXR[$ifn]-} tx=${_NET_TXR[$ifn]-} rxs txs trx ttx trxp
		if [[ -n "$rx" ]]; then
			fmt_rate "$rx" rxs; fmt_rate "$tx" txs
			rpad "$rxs" 13 rxs; rpad "$txs" 13 txs
			fmt_bytes "${_NET_RXB[$ifn]:-0}" trx
			fmt_bytes "${_NET_TXB[$ifn]:-0}" ttx
			rpad "$trx" 11 trxp
			box_line "      ↓ ${FG_BGREEN}${rxs}${RESET} ↑ ${FG_BYELLOW}${txs}${RESET} ${DIM}total ↓${RESET} ${FG_WHITE}${trxp}${RESET} ${DIM}↑${RESET} ${FG_WHITE}${ttx}${RESET}"
		else
			box_line "      ${DIM}↓ —   ↑ —   awaiting second sample…${RESET}"
		fi

		# Errors/drops since boot are shown dim; only growth during the last
		# interval is coloured.  rx_dropped also counts benign traffic (unknown
		# ethertypes, unconfigured VLANs), so a static count is not an alarm.
		local re=${_NET_RXE[$ifn]:-0} te=${_NET_TXE[$ifn]:-0} rd=${_NET_RXD[$ifn]:-0} td=${_NET_TXD[$ifn]:-0}
		if (( re + te + rd + td > 0 )); then
			local ne=${_NET_ERR_NEW[$ifn]:-0} nd=${_NET_DROP_NEW[$ifn]:-0} ec="$DIM" dc="$DIM" en='' dn=''
			(( ne > 0 )) && { ec="$FG_BRED";    en=" (+${ne})"; }
			(( nd > 0 )) && { dc="$FG_BYELLOW"; dn=" (+${nd})"; }
			box_line "      ${ec}errors rx ${re} tx ${te}${en}${RESET}   ${dc}drops rx ${rd} tx ${td}${dn}${RESET}   ${DIM}since boot${RESET}"
		fi
	done

	[[ "$any" == "false" ]] && { inner_rule dash; box_line "   ${DIM}No interfaces found${RESET}"; }
	box_blank
}

# =============================================================================
# ── FRAME ─────────────────────────────────────────────────────────────────────
# =============================================================================

render() {
	frame_reset
	_SLOW_SECS=$(( REFRESH_INTERVAL * SMART_INTERVAL_MULT ))
	local ts nd
	printf -v ts '%(%A %d %B %Y  %H:%M:%S %Z)T' "$_NOW"
	printf -v nd '%+d' "$NICE_VALUE"

	box_blank
	center_line "${BOLD}${FG_BCYAN}⬡  File Server — Status Dashboard${RESET}"
	center_line "${DIM}${FG_WHITE}${_HOSTNAME}   ·   ${ts}${RESET}"
	box_blank
	inner_rule mid

	if [[ "$_ZFS_PRESENT" == "true" ]];   then render_zfs;   inner_rule mid; fi
	if [[ "$_MDADM_PRESENT" == "true" ]]; then render_mdadm; inner_rule mid; fi
	render_drives;  inner_rule mid
	render_volumes; inner_rule mid
	if [[ "$_NFS_PRESENT" == "true" ]];   then render_nfs;   inner_rule mid; fi
	if [[ "$_SAMBA_PRESENT" == "true" ]]; then render_samba; inner_rule mid; fi
	render_network

	join_dividers

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
		# @@SCROLL@@ is filled by do_draw, which is where the visible window is
		# known; room is reserved for it so the key hints can shorten on
		# narrow terminals instead of being clipped by the border.
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
		box_line "   ${FG_YELLOW}⚠  Run with sudo for full access: smartctl, smbstatus, exportfs, NFSv4 clients${RESET}"
	fi

	if [[ "$SHOW_HELP" == "true" && "$_PLAIN" != "true" ]]; then
		inner_rule dash
		box_line "   ${FG_BCYAN}${BOLD}Key Bindings${RESET}"
		inner_rule dash
		box_line "   ${FG_CYAN}q / Q / Ctrl-C       ${RESET}  Quit"
		box_line "   ${FG_CYAN}p / P                ${RESET}  Pause / unpause auto-refresh"
		box_line "   ${FG_CYAN}r / R                ${RESET}  Refresh now, including SMART / zpool status / smbstatus"
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
	frame_reset
	box_blank
	center_line "${BOLD}${FG_BCYAN}⬡  File Server — Status Dashboard${RESET}"
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
# short slices and notices it within a quarter second.
trap '_RESIZED=true' WINCH

main() {
	_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fs-status.XXXXXX" 2>/dev/null) || _TMP=''

	if [[ "$ONE_SHOT" == "true" ]]; then
		_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
		[[ -t 0 ]] && read_winsize
		sync_dimensions
		fetch_fast
		[[ -n "$_TMP" ]] && start_slow_poll
		sleep 1          # second sample so rates aren't blank
		fetch_fast
		[[ -n "$_SLOW_PID" ]] && wait "$_SLOW_PID" 2>/dev/null
		harvest_slow
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
			_SLOW_SECS=$(( REFRESH_INTERVAL * SMART_INTERVAL_MULT ))
			if [[ -z "$_SLOW_PID" && -n "$_TMP" ]] \
				&& { [[ "$_FORCE_SLOW" == "true" ]] || (( _SLOW_START == 0 || EPOCHSECONDS - _SLOW_START >= _SLOW_SECS )); }; then
				_FORCE_SLOW=false
				start_slow_poll
				_DIRTY=true      # header shows "polling…"
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
			j|'ESC[B'|'ESCOB')                 scroll_by 1 ;;
			k|'ESC[A'|'ESCOA')                 scroll_by -1 ;;
			' '|'ESC[6~')                      scroll_by "$_PAGE" ;;
			b|'ESC[5~')                        scroll_by "-$_PAGE" ;;
			g|'ESC[H'|'ESCOH'|'ESC[1~'|'ESC[7~') _SCROLL=0; _DIRTY=true ;;
			G|'ESC[F'|'ESCOF'|'ESC[4~'|'ESC[8~') _SCROLL=999999; _DIRTY=true ;;
		esac
	done
}

main "$@"
