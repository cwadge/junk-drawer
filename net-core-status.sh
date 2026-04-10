#!/usr/bin/env bash
# =============================================================================
# net-core-status — Network Core Services Dashboard
# Services: unbound (DNS), kea (DHCP), chrony (NTP)
# Target:   Debian 13
# =============================================================================

# checkwinsize keeps $COLUMNS fresh after external commands complete.
shopt -s checkwinsize

# ── Defaults ──────────────────────────────────────────────────────────────────
REFRESH_INTERVAL=2
NICE_VALUE=10
ONE_SHOT=false
SLOW_INTERVAL_MULT=20  # unbound/chrony stats polled every SLOW_INTERVAL_MULT × REFRESH_INTERVAL s
SOCAT_TIMEOUT=1        # per-call timeout for Kea control socket queries (was hardcoded 2)

# ── Live state ────────────────────────────────────────────────────────────────
PAUSED=false
SHOW_HELP=false
LAST_REFRESH='—'
_NEED_REDRAW=false
INPUT_MODE=''       # '' | 'interval' | 'nice'
_FOOTER_ROW=0       # terminal row the footer occupies; set each draw
_TTY_STATE=''       # tty state captured at startup, before any read -s
_HOSTNAME=''        # cached once — hostname -f can trigger a DNS lookup
_NOW=0              # epoch seconds, set once per draw_dashboard call

# ── Slow-cadence data cache ───────────────────────────────────────────────────
# unbound-control and chronyc output is cached here and re-polled only every
# SLOW_INTERVAL_MULT × REFRESH_INTERVAL seconds.  Kea socket queries (socat)
# stay on the fast cycle for live lease visibility but use SOCAT_TIMEOUT.
_UB_STATS_RAW=''      # unbound-control stats_noreset output
_CHR_TRACKING_RAW=''  # chronyc tracking output
_CHR_SOURCES_RAW=''   # chronyc sources output
_SLOW_LAST_TS=0        # epoch of last slow-cadence poll
_DO_SLOW=false         # true on frames that trigger a slow poll
_SLOW_SECS=0           # effective slow interval in seconds (computed each frame)

# ── Config (XDG-compliant) ────────────────────────────────────────────────────
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CFG_FILE="$CFG_DIR/net-core-status.conf"

load_config() {
	[[ -r "$CFG_FILE" ]] || return 0
	local line key val
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*#  ]] && continue
		[[ "$line" =~ ^[[:space:]]*$  ]] && continue
		key="${line%%=*}";  key="${key//[[:space:]]/}"
		val="${line#*=}";   val="${val//[[:space:]]/}"
		case "$key" in
			REFRESH_INTERVAL)  REFRESH_INTERVAL="$val"  ;;
			NICE_VALUE)        NICE_VALUE="$val"        ;;
			SLOW_INTERVAL_MULT) SLOW_INTERVAL_MULT="$val" ;;
			SOCAT_TIMEOUT)     SOCAT_TIMEOUT="$val"     ;;
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

# ── Utility ───────────────────────────────────────────────────────────────────
clamp() {
	local v=$1
	(( v < $2 )) && v=$2
	(( v > $3 )) && v=$3
	printf '%s' "$v"
}

# Overwrite only the footer row so the rest of the frame stays visible.
# Restoring _TTY_STATE gives echo-on canonical mode for comfortable editing.
prompt_input() {
	local mode="$1"
	local was_paused="$PAUSED"
	PAUSED=true
	INPUT_MODE="$mode"

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

	if [[ "$raw_val" =~ ^-?[0-9]+$ ]]; then
		if [[ "$mode" == 'interval' ]]; then
			REFRESH_INTERVAL=$(clamp "$raw_val" 1 300)
		else
			NICE_VALUE=$(clamp "$raw_val" -20 19)
			apply_nice
		fi
		save_config
	fi

	INPUT_MODE=''
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

# Renice the whole process; children inherit it, so no per-command wrappers needed.
apply_nice() {
	local current delta
	current=$(ps -o nice= -p $$ 2>/dev/null | tr -d '[:space:]') || current=0
	[[ "$current" =~ ^-?[0-9]+$ ]] || current=0
	delta=$(( NICE_VALUE - current ))
	(( delta == 0 )) && return 0
	renice -n "$delta" -p $$ >/dev/null 2>&1 || true
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Network core services status dashboard — unbound · kea · chrony.

Options:
  -i, --interval SECS  Auto-refresh interval, seconds  (1–300,  default: $REFRESH_INTERVAL)
  -n, --nice     N     Nice value for stat subprocesses (-20–19, default: $NICE_VALUE)
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
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-i|--interval)
				[[ -z "${2-}" ]] && { printf 'Error: %s requires a value\n' "$1" >&2; exit 1; }
				REFRESH_INTERVAL=$(clamp "$2" 1 300); shift 2 ;;
			-n|--nice)
				[[ -z "${2-}" ]] && { printf 'Error: %s requires a value\n' "$1" >&2; exit 1; }
				NICE_VALUE=$(clamp "$2" -20 19); shift 2 ;;
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
FG_RED=$'\033[0;31m';    FG_GREEN=$'\033[0;32m';   FG_YELLOW=$'\033[0;33m'
FG_BLUE=$'\033[0;34m';   FG_CYAN=$'\033[0;36m';    FG_WHITE=$'\033[0;37m'
FG_BWHITE=$'\033[1;37m'; FG_BCYAN=$'\033[1;36m';   FG_BGREEN=$'\033[1;32m'
FG_BRED=$'\033[1;31m';   FG_BYELLOW=$'\033[1;33m'; FG_BBLUE=$'\033[1;34m'

# ── Box-drawing ───────────────────────────────────────────────────────────────
BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'
BOX_H='═';  BOX_V='║';  BOX_ML='╠'; BOX_MR='╣'
DIV_H='─';  DIV_ML='├'; DIV_MR='┤'; DASH_H='╌'

# ── Layout ────────────────────────────────────────────────────────────────────
TERM_WIDTH=${COLUMNS:-80}
INNER_WIDTH=$(( TERM_WIDTH - 2 ))
B="${FG_BLUE}${BOX_V}${RESET}"

# Cached fill strings for rule/border lines — rebuilt only on resize, not every frame.
_FILL_MID=''   # BOX_H  × (INNER_WIDTH-2)  used by inner_rule mid
_FILL_THIN=''  # DIV_H  × (INNER_WIDTH-2)  used by inner_rule thin
_FILL_DASH=''  # DASH_H × (INNER_WIDTH-2)  used by inner_rule dash
_FILL_OUTER='' # BOX_H  × INNER_WIDTH      used by outer_top / outer_bottom
_LAST_WIDTH=0  # tracks when a rebuild is needed

# Fill a string of $count spaces then substitute every space with $char.
# Two builtins; no loop, no subprocess.
repeat_char() {
	local char="$1" count="$2" out
	printf -v out "%${count}s" ''
	printf '%s' "${out// /$char}"
}

rebuild_fills() {
	local fill=$(( INNER_WIDTH - 2 ))
	_FILL_MID=$(repeat_char   "$BOX_H"  "$fill")
	_FILL_THIN=$(repeat_char  "$DIV_H"  "$fill")
	_FILL_DASH=$(repeat_char  "$DASH_H" "$fill")
	_FILL_OUTER=$(repeat_char "$BOX_H"  "$INNER_WIDTH")
	_LAST_WIDTH=$INNER_WIDTH
}

# ── Output buffer ─────────────────────────────────────────────────────────────
_BUF=''
_n() { _BUF+="$*"$'\n'; }

# ── Drawing primitives ────────────────────────────────────────────────────────

inner_rule() {   # mid(╠═╣)  thin(├─┤)  dash(├╌┤)
	local style="${1:-mid}"
	case "$style" in
		mid)  _n "${B}${FG_BLUE}${BOX_ML}${_FILL_MID}${BOX_MR}${RESET}${B}"  ;;
		thin) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_THIN}${DIV_MR}${RESET}${B}" ;;
		dash) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_DASH}${DIV_MR}${RESET}${B}" ;;
	esac
}

# CHA (\033[NG) snaps the right border to column TERM_WIDTH, bypassing
# Unicode/ANSI byte-width accounting entirely.
box_line() {
	local content="$1" padding="${2:-1}"
	local pad; pad=$(printf '%*s' "$padding" '')
	_n "${B}${pad}${content}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
}

box_blank() { _n "${B}"$'\033[K\033'"[${TERM_WIDTH}G${B}"; }

outer_top()    { printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_TL" "$_FILL_OUTER" "${BOX_TR}${RESET}"; }
outer_bottom() { printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_BL" "$_FILL_OUTER" "${BOX_BR}${RESET}"; }

# ── Service helpers ───────────────────────────────────────────────────────────

# One systemctl call per service; results go into globals read by the badge/uptime
# helpers below.  Those helpers are called inside $() subshells (as kv_line
# arguments) — subshells inherit globals for reading, just can't write back.
svc_fetch() {
	local raw
	raw=$(systemctl show "$1" \
		--property=ActiveState,UnitFileState,ActiveEnterTimestamp 2>/dev/null)
			_SVC_ACTIVE='' _SVC_ENABLED='' _SVC_ENTER=''
			# IFS='=' splits on the first '=' only; val gets the full remainder,
			# which matters for the timestamp (contains spaces and colons).
			local key val
			while IFS='=' read -r key val; do
				case "$key" in
					ActiveState)          _SVC_ACTIVE="$val"  ;;
					UnitFileState)        _SVC_ENABLED="$val" ;;
					ActiveEnterTimestamp) _SVC_ENTER="$val"   ;;
				esac
			done <<< "$raw"
		}

		svc_status_badge() {   # reads _SVC_ACTIVE, _SVC_ENABLED (set by svc_fetch)
			case "$_SVC_ACTIVE" in
				active)   printf '%s● Active  %s' "$FG_BGREEN" "$RESET" ;;
				inactive)
					# Dim when deliberately disabled/masked; red only when enabled but not running.
					if [[ "$_SVC_ENABLED" == "disabled" || "$_SVC_ENABLED" == "masked" ]]; then
						printf '%s✖ Inactive%s' "$DIM"     "$RESET"
					else
						printf '%s✖ Inactive%s' "$FG_BRED" "$RESET"
						fi ;;
					failed)   printf '%s✖ Failed  %s' "$FG_BRED"   "$RESET" ;;
					*)        printf '%s%-10s%s'       "$FG_YELLOW" "? ${_SVC_ACTIVE:-unknown}" "$RESET" ;;
				esac
			}

			svc_enabled_badge() {   # reads _SVC_ENABLED (set by svc_fetch)
				case "$_SVC_ENABLED" in
					enabled)  printf '%sEnabled %s' "$FG_BGREEN" "$RESET" ;;
					disabled) printf '%sDisabled%s' "$FG_YELLOW" "$RESET" ;;
					masked)   printf '%sMasked  %s' "$FG_BRED"   "$RESET" ;;
					*)        printf '%s%-8s%s'      "$FG_WHITE"  "${_SVC_ENABLED:-unknown}" "$RESET" ;;
				esac
			}

# $1 = epoch seconds from draw_dashboard (_NOW); reads _SVC_ENTER (set by svc_fetch).
svc_uptime() {
	local now="$1"
	if [[ -z "$_SVC_ENTER" || "$_SVC_ENTER" == "n/a" ]]; then
		printf '%sn/a%s' "$DIM" "$RESET"; return
	fi
	local epoch_start
	epoch_start=$(date -d "$_SVC_ENTER" +%s 2>/dev/null) \
		|| { printf '%sn/a%s' "$DIM" "$RESET"; return; }
			local elapsed=$(( now - epoch_start ))
			local d=$(( elapsed/86400 )) h=$(( (elapsed%86400)/3600 ))
			local m=$(( (elapsed%3600)/60 )) s=$(( elapsed%60 ))
			if   (( d > 0 )); then printf '%s%dd %dh %dm%s'  "$FG_BWHITE" "$d" "$h" "$m" "$RESET"
			elif (( h > 0 )); then printf '%s%dh %dm %ds%s'  "$FG_BWHITE" "$h" "$m" "$s" "$RESET"
			elif (( m > 0 )); then printf '%s%dm %ds%s'      "$FG_BWHITE" "$m" "$s" "$RESET"
			else                   printf '%s%ds%s'           "$FG_BWHITE" "$s" "$RESET"
			fi
		}

		kv_line() {
			local key="$1" val="$2" indent="${3:-3}"
			box_line "$(printf '%*s' "$indent" '')${FG_CYAN}${key}:${RESET}  ${val}"
		}

		section_header() {   # title subtitle icon
			box_blank
			box_line "${3}  ${BOLD}${FG_BWHITE}${1}${RESET}${FG_BLUE} — ${RESET}${FG_WHITE}${2}${RESET}" 2
			inner_rule thin
		}

# =============================================================================
# ── UNBOUND ───────────────────────────────────────────────────────────────────
# =============================================================================
section_unbound() {
	local svc='unbound'

	# Slow-poll note for header (shown once cache is primed)
	local _ub_note=''
	if (( _SLOW_LAST_TS > 0 )); then
		local _ub_age=$(( _NOW - _SLOW_LAST_TS ))
		_ub_note="  ${DIM}· stats polled ${_ub_age}s ago (every ${_SLOW_SECS}s)${RESET}"
	fi
	section_header "UNBOUND" "Recursive DNS Resolver${_ub_note}" "🔍"

	# Fast path: service status changes matter immediately
	svc_fetch "$svc"
	kv_line "Status " "$(svc_status_badge)  Boot: $(svc_enabled_badge)"
	kv_line "Uptime " "$(svc_uptime "$_NOW")"

	if command -v unbound-control &>/dev/null; then
		# Slow path: unbound-control stats — accumulate over seconds/minutes;
		# running every 2s adds subprocess cost for data that won't meaningfully differ.
		if [[ "$_DO_SLOW" == "true" ]]; then
			_UB_STATS_RAW=$(unbound-control stats_noreset 2>/dev/null)
		fi
		if [[ -n "$_UB_STATS_RAW" ]]; then
			local total_q cache_hits cache_miss prefetch avg_ms rec_ms msg_cache rrset_cache cache_pct=''
			eval "$(awk -F= '
			/^total\.num\.queries=/            { total=$2+0;     printf "total_q=\"%'"'"'d\"\n",    $2+0 }
			/^total\.num\.cachehits=/          { hits=$2+0;      printf "cache_hits=\"%'"'"'d\"\n", $2+0 }
			/^total\.num\.cachemiss=/          {                 printf "cache_miss=\"%'"'"'d\"\n", $2+0 }
			/^total\.num\.prefetch=/           {                 printf "prefetch=\"%'"'"'d\"\n",   $2+0 }
			/^total\.recursion\.time\.avg=/    {                 printf "avg_ms=\"%.2f ms\"\n",     $2*1000 }
			/^total\.recursion\.time\.median=/ {                 printf "rec_ms=\"%.2f ms\"\n",     $2*1000 }
			/^mem\.cache\.message=/            {                 printf "msg_cache=\"%.1f MiB\"\n", $2/1048576 }
			/^mem\.cache\.rrset=/              {                 printf "rrset_cache=\"%.1f MiB\"\n",$2/1048576 }
			END { if (total>0) printf "cache_pct=\"%.1f%%\"\n", hits/total*100 }
			' <<< "$_UB_STATS_RAW")"
			inner_rule dash
			kv_line "Queries (total)" "${FG_BWHITE}${total_q:-n/a}${RESET}"
			kv_line "Cache hits     " "${FG_BGREEN}$(printf '%-12s' "${cache_hits:-n/a}")${RESET}misses:  ${FG_YELLOW}${cache_miss:-n/a}${RESET}${cache_pct:+   ${FG_BCYAN}(${cache_pct} hit rate)${RESET}}"
			kv_line "Prefetches     " "${FG_WHITE}${prefetch:-n/a}${RESET}"
			kv_line "Avg recursion  " "${FG_WHITE}$(printf '%-12s' "${avg_ms:-n/a}")${RESET}median:  ${FG_WHITE}${rec_ms:-n/a}${RESET}"
			kv_line "Msg cache      " "${FG_WHITE}$(printf '%-12s' "${msg_cache:-n/a}")${RESET}RRset:   ${FG_WHITE}${rrset_cache:-n/a}${RESET}"
		else
			inner_rule dash
			box_line "   ${FG_YELLOW}⚠  unbound-control unavailable or remote-control not configured${RESET}"
		fi
	else
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  unbound-control not found${RESET}"
	fi
	box_blank
}

# =============================================================================
# ── KEA ───────────────────────────────────────────────────────────────────────
# =============================================================================
section_kea() {
	section_header "KEA" "ISC DHCP Server (DHCPv4 / DHCPv6 / DDNS)" "📡"

	local services=('kea-dhcp4-server' 'kea-dhcp6-server' 'kea-dhcp-ddns-server')
	local labels=('DHCPv4' 'DHCPv6' 'DDNS  ')
	local i _kea4_active='' _kea6_active=''
	for i in "${!services[@]}"; do
		svc_fetch "${services[$i]}"
		kv_line "${labels[$i]} status" \
			"$(svc_status_badge)  Boot: $(svc_enabled_badge)  Up: $(svc_uptime "$_NOW")"
					# Capture before next svc_fetch overwrites _SVC_ACTIVE.
					[[ $i -eq 0 ]] && _kea4_active="$_SVC_ACTIVE"
					[[ $i -eq 1 ]] && _kea6_active="$_SVC_ACTIVE"
				done

				inner_rule dash

				local sock4='/run/kea/kea4-ctrl-socket'
				local sock6='/run/kea/kea6-ctrl-socket'
				local has_socat=false
				command -v socat &>/dev/null && has_socat=true

	# ── DHCPv4 leases ─────────────────────────────────────────────────────────
	if [[ "$_kea4_active" == "active" ]]; then
		local leases4_line=''
		if [[ "$has_socat" == true && -S "$sock4" ]]; then
			local raw4
			raw4=$(printf '{"command":"stat-lease4-get","service":["dhcp4"]}' \
				| socat -t${SOCAT_TIMEOUT} - UNIX-CONNECT:"$sock4" 2>/dev/null)
							# Kea returns "result": 1/2 if stat_cmds hook is missing or command fails;
							# treat anything other than result:0 as a socket failure and fall back to CSV.
							if [[ "$raw4" == *'"result": 0'* || "$raw4" == *'"result":0'* ]]; then
								local tot4 asgn4 decl4
								# stat-lease4-get rows: [subnet-id, total-addresses, cumulative-assigned-addresses, assigned-addresses, declined-addresses]
								# Kea may emit "rows": [ with a space; /, */ handles space after comma in each row.
								read -r tot4 asgn4 decl4 < <(awk '
								{ if (match($0, /"rows": *\[/)) {
									s = substr($0, RSTART + RLENGTH)
									while (match(s, /\[ *[0-9, ]+\]/)) {
										row = substr(s, RSTART+1, RLENGTH-2)
										n = split(row, a, /, */)
										if (n >= 5) { tot+=a[2]+0; asgn+=a[4]+0; decl+=a[5]+0 }
											s = substr(s, RSTART + RLENGTH)
										}
									} }
									END { printf "%d %d %d\n", tot+0, asgn+0, decl+0 }
									' <<< "$raw4")
									# Kea has no explicit expired count; remainder of pool = expired/available.
									local exp4=$(( tot4 - asgn4 - decl4 ))
									(( exp4 < 0 )) && exp4=0
									leases4_line="Total: ${FG_BWHITE}$(printf '%4d' "$tot4")${RESET}   Active: ${FG_BGREEN}$(printf '%4d' "$asgn4")${RESET}   Expired: ${FG_YELLOW}$(printf '%4d' "$exp4")${RESET}   Declined: ${FG_BRED}$(printf '%4d' "$decl4")${RESET}"
							fi
		fi
		if [[ -z "$leases4_line" ]]; then
			local lease4='/var/lib/kea/kea-leases4.csv'
			if [[ -r "$lease4" ]]; then
				local t4 a4 e4 d4
				# Kea appends a row on every renewal; dedupe by address keeping the
				# highest expire per IP, then classify — static leases not reflected.
				read -r t4 a4 e4 d4 < <(awk -F, -v now="$_NOW" '
				NR>1 {
				addr=$1; expire=$5+0; state=$10+0
				if (expire > best_expire[addr]) {
					best_expire[addr] = expire
					best_state[addr]  = state
				}
			}
			END {
			for (addr in best_expire) {
				t++
				s = best_state[addr]; e = best_expire[addr]
				if      (s == 1)           d++
				else if (s == 2 || e <= now) ex++
				else                         a++
				}
				printf "%d %d %d %d\n", t+0, a+0, ex+0, d+0
			}
			' "$lease4")
			leases4_line="Total: ${FG_BWHITE}$(printf '%4d' "$t4")${RESET}   Active: ${FG_BGREEN}$(printf '%4d' "$a4")${RESET}   Expired: ${FG_YELLOW}$(printf '%4d' "$e4")${RESET}   Declined: ${FG_BRED}$(printf '%4d' "$d4")${RESET}  ${DIM}(≈ csv)${RESET}"
		else
			leases4_line="${FG_YELLOW}socket unavailable · lease file not readable${RESET}"
			fi
		fi
		kv_line "DHCPv4 leases" "$leases4_line"
	fi # _kea4_active

	# ── DHCPv6 leases ─────────────────────────────────────────────────────────
	if [[ "$_kea6_active" == "active" ]]; then
		local leases6_line=''
		if [[ "$has_socat" == true && -S "$sock6" ]]; then
			local raw6
			raw6=$(printf '{"command":"stat-lease6-get","service":["dhcp6"]}' \
				| socat -t${SOCAT_TIMEOUT} - UNIX-CONNECT:"$sock6" 2>/dev/null)
							# Same result:0 guard as v4.
							if [[ "$raw6" == *'"result": 0'* || "$raw6" == *'"result":0'* ]]; then
								local tna ana dna tpd apd
								# stat-lease6-get rows: [subnet-id, total-nas, assigned-nas, declined-nas, total-pds, assigned-pds]
								# >= 6 guards against extra cumulative columns; /, */ handles spaces after commas.
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
									leases6_line="NA — Total: ${FG_BWHITE}$(printf '%3d' "$tna")${RESET}  Active: ${FG_BGREEN}$(printf '%3d' "$ana")${RESET}  Expired: ${FG_YELLOW}$(printf '%3d' "$exp_na")${RESET}  Declined: ${FG_BRED}$(printf '%3d' "$dna")${RESET}   PD: ${FG_BGREEN}$(printf '%3d' "$apd")${RESET}${DIM}/${RESET}${FG_BWHITE}$(printf '%3d' "$tpd")${RESET}"
							fi
		fi
		if [[ -z "$leases6_line" ]]; then
			local lease6='/var/lib/kea/kea-leases6.csv'
			if [[ -r "$lease6" ]]; then
				local t6 a6 e6 d6
				# v6 CSV: $3=expire, $9=state — column position may vary across Kea versions.
				read -r t6 a6 e6 d6 < <(awk -F, -v now="$_NOW" '
				NR>1 {
				addr=$1; expire=$3+0; state=$9+0
				if (expire > best_expire[addr]) {
					best_expire[addr] = expire
					best_state[addr]  = state
				}
			}
			END {
			for (addr in best_expire) {
				t++
				s = best_state[addr]; e = best_expire[addr]
				if      (s == 1)           d++
				else if (s == 2 || e <= now) ex++
				else                         a++
				}
				printf "%d %d %d %d\n", t+0, a+0, ex+0, d+0
			}
			' "$lease6")
			leases6_line="Total: ${FG_BWHITE}$(printf '%4d' "$t6")${RESET}   Active: ${FG_BGREEN}$(printf '%4d' "$a6")${RESET}   Expired: ${FG_YELLOW}$(printf '%4d' "$e6")${RESET}   Declined: ${FG_BRED}$(printf '%4d' "$d6")${RESET}  ${DIM}(≈ csv)${RESET}"
		else
			leases6_line="${FG_YELLOW}socket unavailable · lease file not readable${RESET}"
			fi
		fi
		kv_line "DHCPv6 leases" "$leases6_line"
	fi # _kea6_active

	# ── DHCPv4 packet counters ─────────────────────────────────────────────────
	if [[ "$has_socat" == true && -S "$sock4" ]]; then
		local raw rcv sent drop
		raw=$(printf '{"command":"statistic-get-all","service":["dhcp4"]}' \
			| socat -t${SOCAT_TIMEOUT} - UNIX-CONNECT:"$sock4" 2>/dev/null)
					if [[ -n "$raw" ]]; then
						# RS="," gives one field per record; getval() seeks past the "[ [" value
						# marker (space-tolerant) to avoid matching digits in key names like "pkt4".
						read -r rcv sent drop < <(awk 'BEGIN{RS=","}
						function getval(s,  i,t) {
						match(s,/\[ *\[/); t=substr(s,RSTART+RLENGTH)
						match(t,/[0-9]+/); return substr(t,RSTART,RLENGTH)+0
					}
					/"pkt4-received":/     { rcv=getval($0) }
					/"pkt4-sent":/         { sent=getval($0) }
					/"pkt4-receive-drop":/ { drop=getval($0) }
					END { printf "%d %d %d\n", rcv+0, sent+0, drop+0 }
					' <<< "$raw")
					kv_line "DHCPv4 pkts  " \
						"Rcvd : ${FG_BWHITE}$(printf '%4d' "${rcv:-0}")${RESET}   Sent  : ${FG_BGREEN}$(printf '%4d' "${sent:-0}")${RESET}   Dropped: ${FG_BRED}$(printf '%4d' "${drop:-0}")${RESET}"
					fi
	fi

	box_blank
}

# =============================================================================
# ── CHRONY ────────────────────────────────────────────────────────────────────
# =============================================================================
section_chrony() {
	local svc='chrony'

	# Slow-poll note for header (shown once cache is primed)
	local _chr_note=''
	if (( _SLOW_LAST_TS > 0 )); then
		local _chr_age=$(( _NOW - _SLOW_LAST_TS ))
		_chr_note="  ${DIM}· stats polled ${_chr_age}s ago (every ${_SLOW_SECS}s)${RESET}"
	fi
	section_header "CHRONY" "NTP Time Synchronization${_chr_note}" "🕐"

	# Fast path: service status changes matter immediately
	svc_fetch "$svc"
	kv_line "Status " "$(svc_status_badge)  Boot: $(svc_enabled_badge)"
	kv_line "Uptime " "$(svc_uptime "$_NOW")"

	if ! command -v chronyc &>/dev/null; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  chronyc not found${RESET}"
		box_blank; return
	fi

	# Slow path: chronyc output — NTP convergence plays out over minutes,
	# and source selection rarely changes; no value in polling every 2s.
	if [[ "$_DO_SLOW" == "true" ]]; then
		_CHR_TRACKING_RAW=$(chronyc tracking 2>/dev/null)
		_CHR_SOURCES_RAW=$(chronyc sources 2>/dev/null)
	fi

	if [[ -n "$_CHR_TRACKING_RAW" ]]; then
		inner_rule dash

		local ref_id stratum sys_time rms_offset freq_err leap offset_key
		# Single awk pass; emits offset_key (good/warn/bad) so bash can choose a
		# color without spawning another awk just for the float comparison.
		eval "$(awk -F': ' '
		/^Reference ID/ { printf "ref_id=\"%s\"\n",      $2 }
		/^Stratum/       { printf "stratum=\"%s\"\n",     $2 }
		/^System time/   { printf "sys_time=\"%s\"\n",    $2
		match($2, /[0-9]+\.[0-9]+/)
		v = substr($2, RSTART, RLENGTH) + 0
		if      (v < 0.001) print "offset_key=good"
		else if (v < 0.010) print "offset_key=warn"
		else                print "offset_key=bad" }
			/^RMS offset/    { printf "rms_offset=\"%s\"\n",  $2 }
			/^Frequency/     { printf "freq_err=\"%s\"\n",    $2 }
			/^Leap status/   { printf "leap=\"%s\"\n",         $2 }
			' <<< "$_CHR_TRACKING_RAW")"

			local offset_col leap_col
			case "${offset_key:-bad}" in
				good) offset_col="$FG_BGREEN"  ;;
				warn) offset_col="$FG_BYELLOW" ;;
				*)    offset_col="$FG_BRED"    ;;
			esac
			[[ "${leap:-}" == "Normal" ]] && leap_col="$FG_BGREEN" || leap_col="$FG_BYELLOW"

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

		# Color by selection state character at index 1 (0-based):
		#   * current best  + combined  - not combined
		#   ? unreachable   x falseticker   ~ too variable
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local sc
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
		done < <(grep -E '^[\^=#][*+?x~-]' <<< "$_CHR_SOURCES_RAW")
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
			read -r _NOW ts < <(date '+%s %A %d %B %Y  %H:%M:%S %Z')   # one fork for both epoch and display time

			# Slow-frame decision — shared by section_unbound and section_chrony
			_SLOW_SECS=$(( REFRESH_INTERVAL * SLOW_INTERVAL_MULT ))
			_DO_SLOW=false
			(( _SLOW_LAST_TS == 0 || _NOW - _SLOW_LAST_TS >= _SLOW_SECS )) && _DO_SLOW=true
			local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"

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

															# Update slow-cadence timestamp after all sections have rendered
															[[ "$_DO_SLOW" == "true" ]] && _SLOW_LAST_TS=$_NOW

															inner_rule thin

	# Count newlines already in _BUF to find the row the footer will land on.
	# outer_top prints one line before _BUF, hence +1.
	local _nl="${_BUF//[^$'\n']/}"
	_FOOTER_ROW=$(( 1 + ${#_nl} ))

	if [[ "$PAUSED" == "true" ]]; then
		box_line "   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nice_disp}   p resume · r refresh · i interval · n nice · h help · q quit${RESET}"
	else
		box_line "   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nice_disp}${RESET}  ${DIM}Last: ${LAST_REFRESH}   p pause · r refresh · i interval · n nice · h help · q quit${RESET}"
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

cleanup() {
	printf '\033[?25h\033[?1049l'
	[[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null || stty echo 2>/dev/null
	exit 0
}
trap cleanup INT TERM

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
	# B is composed of constants set at startup; no need to reassign here.
	(( INNER_WIDTH != _LAST_WIDTH )) && rebuild_fills
}

main() {
	if [[ "$ONE_SHOT" == "true" ]]; then
		_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
		sync_dimensions
		printf -v LAST_REFRESH '%(%H:%M:%S)T' -1   # bash strftime builtin — no fork
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
			[[ -n "$_BUF" ]] && { printf '\033[H'; outer_top; printf '%s' "$_BUF"; outer_bottom; printf '\033[J'; }

			[[ "$PAUSED" == "false" || "$force_refresh" == "true" ]] \
				&& printf -v LAST_REFRESH '%(%H:%M:%S)T' -1   # bash strftime builtin — no fork
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
			q|Q) cleanup ;;

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
