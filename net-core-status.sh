#!/usr/bin/env bash
# =============================================================================
# net-core-status — Network Core Services Dashboard
# Services: unbound (DNS), kea (DHCP), chrony (NTP)
# Target:   Debian 13
# =============================================================================

# ── Defaults ──────────────────────────────────────────────────────────────────
REFRESH_INTERVAL=2       # seconds between redraws
NICE_VALUE=10            # nice(1) increment applied to all stat subprocesses
ONE_SHOT=false           # true → draw once and exit (non-interactive)

# ── Live state (mutated by the key handler / SIGWINCH) ────────────────────────
PAUSED=false
SHOW_HELP=false
LAST_REFRESH='—'
_NEED_REDRAW=false       # set true by SIGWINCH handler
INPUT_MODE=''            # '' | 'interval' | 'nice'  — active prompted-input field
_FOOTER_ROW=0            # terminal row the footer status line occupies (set each draw)
_TTY_STATE=''            # tty state captured once at startup, before any read -s touches it
_HOSTNAME=''             # cached once — hostname -f can do a DNS lookup every call

# ── Config file (XDG-compliant) ───────────────────────────────────────────────
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
			REFRESH_INTERVAL) REFRESH_INTERVAL="$val" ;;
			NICE_VALUE)       NICE_VALUE="$val"       ;;
		esac
	done < "$CFG_FILE"
}

save_config() {
	mkdir -p "$CFG_DIR"
	{
		printf '# net-core-status — saved %s\n' "$(date '+%F %T')"
		printf 'REFRESH_INTERVAL=%s\n' "$REFRESH_INTERVAL"
		printf 'NICE_VALUE=%s\n'       "$NICE_VALUE"
	} > "$CFG_FILE"
}

# ── Utility ───────────────────────────────────────────────────────────────────
clamp() {   # clamp $1 to [$2..$3], print result
	local v=$1
	(( v < $2 )) && v=$2
	(( v > $3 )) && v=$3
	printf '%s' "$v"
}

# Blocking prompted input for REFRESH_INTERVAL or NICE_VALUE.
# Overwrites only the footer line in place (no service re-query, instant response).
# _TTY_STATE was captured before any read -s ran, so it reliably has echo=on and
# canonical mode — restoring it gives a clean environment for the user to type in.
prompt_input() {
	local mode="$1"
	local was_paused="$PAUSED"
	PAUSED=true
	INPUT_MODE="$mode"

	local label
	[[ "$mode" == 'interval' ]] \
		&& label="Refresh interval (1–300 s)" \
		|| label="Nice value (-20–19)"

    # Overwrite just the footer row — instant, no service re-query
    tput cup "$_FOOTER_ROW" 0
    tput el
    printf '%s   %s%s▶  %s:%s  ' "$B" "$FG_BCYAN" "$BOLD" "$label" "$RESET"

    # Restore the pre-dashboard tty state (echo on, canonical) then read.
    # After reading, suppress echo again for the rest of the main loop.
    [[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null
    tput cnorm               # show cursor

    local raw_val=''
    IFS= read -r raw_val     # canonical mode: backspace, Ctrl-U, Ctrl-W all work

    tput civis               # hide cursor
    stty -echo 2>/dev/null   # re-suppress echo for the main loop

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
# Write the footer status line directly to the terminal at _FOOTER_ROW using
# current variable values.  Called immediately after prompt_input so the new
# interval/nice value is visible before the full service re-query completes.
draw_footer_row() {
	local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"
	local content
	if [[ "$PAUSED" == "true" ]]; then
		content="   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nice_disp}   p resume · r refresh · i interval · n nice · h help · q quit${RESET}"
	else
		content="   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nice_disp}${RESET}  ${DIM}Last: ${LAST_REFRESH}   p pause · r refresh · i interval · n nice · h help · q quit${RESET}"
	fi
	tput cup "$_FOOTER_ROW" 0
	tput el
	printf '%s %s\033[%dG%s' "$B" "$content" "$TERM_WIDTH" "$B"
}
# Renice the entire script process to NICE_VALUE so bash's own CPU work
# (string loops, repeat_char, draw buffer assembly, etc.) is covered, not just
# external subprocesses.  Children inherit the parent's nice level, so
# individual nice -n wrappers on subcommands are no longer needed.
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
			--) shift; break ;;
			-*)
				printf 'Unknown option: %s\n' "$1" >&2
				usage >&2; exit 1 ;;
			*) break ;;
		esac
	done
}

# Load saved config first, then let CLI args override, then apply niceness
load_config
parse_args "$@"
apply_nice

# ── Colours ($'...' → real ESC bytes) ─────────────────────────────────────────
RESET=$'\033[0m';  BOLD=$'\033[1m';  DIM=$'\033[2m'
FG_RED=$'\033[0;31m';    FG_GREEN=$'\033[0;32m';   FG_YELLOW=$'\033[0;33m'
FG_BLUE=$'\033[0;34m';   FG_CYAN=$'\033[0;36m';    FG_WHITE=$'\033[0;37m'
FG_BWHITE=$'\033[1;37m'; FG_BCYAN=$'\033[1;36m';   FG_BGREEN=$'\033[1;32m'
FG_BRED=$'\033[1;31m';   FG_BYELLOW=$'\033[1;33m'; FG_BBLUE=$'\033[1;34m'

# ── Box-drawing ────────────────────────────────────────────────────────────────
BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'
BOX_H='═';  BOX_V='║';  BOX_ML='╠'; BOX_MR='╣'
DIV_H='─';  DIV_ML='├'; DIV_MR='┤'; DASH_H='╌'

# ── Layout (recalculated every frame + on SIGWINCH) ───────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
INNER_WIDTH=$(( TERM_WIDTH - 2 ))
B="${FG_BLUE}${BOX_V}${RESET}"      # coloured side-border character

# ── Output buffer ─────────────────────────────────────────────────────────────
_BUF=''
_n() { _BUF+="$*"$'\n'; }

# ── Drawing primitives ────────────────────────────────────────────────────────
repeat_char() {
	local char="$1" count="$2" i out=''
	for (( i=0; i<count; i++ )); do out+="$char"; done
	printf '%s' "$out"
}

inner_rule() {                        # mid(╠═╣)  thin(├─┤)  dash(├╌┤)
	local style="${1:-mid}" fill=$(( INNER_WIDTH - 2 ))
	case "$style" in
		mid)  _n "${B}${FG_BLUE}${BOX_ML}$(repeat_char "$BOX_H"  "$fill")${BOX_MR}${RESET}${B}" ;;
		thin) _n "${B}${FG_BLUE}${DIV_ML}$(repeat_char "$DIV_H"  "$fill")${DIV_MR}${RESET}${B}" ;;
		dash) _n "${B}${FG_BLUE}${DIV_ML}$(repeat_char "$DASH_H" "$fill")${DIV_MR}${RESET}${B}" ;;
	esac
}

# CHA escape snaps the right border to column TERM_WIDTH, bypassing all
# Unicode / ANSI-sequence byte-width accounting.
box_line() {
	local content="$1" padding="${2:-1}"
	local pad; pad=$(printf '%*s' "$padding" '')
	_n "${B}${pad}${content}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
}

box_blank() { _n "${B}"$'\033[K\033'"[${TERM_WIDTH}G${B}"; }

outer_top() {
	printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_TL" \
		"$(repeat_char "$BOX_H" "$INNER_WIDTH")" "${BOX_TR}${RESET}"
	}
	outer_bottom() {
		printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_BL" \
			"$(repeat_char "$BOX_H" "$INNER_WIDTH")" "${BOX_BR}${RESET}"
		}

# ── Service status badge helpers ──────────────────────────────────────────────
# Fixed visible widths: status=10 ("✖ Inactive"), boot=8 ("Disabled")

svc_status_badge() {
	local state
	state=$(systemctl is-active "$1" 2>/dev/null)
	case "$state" in
		active)   printf '%s● Active  %s' "$FG_BGREEN" "$RESET" ;;
		inactive) printf '%s✖ Inactive%s' "$FG_BRED"   "$RESET" ;;
		failed)   printf '%s✖ Failed  %s' "$FG_BRED"   "$RESET" ;;
		*)        printf '%s%-10s%s'       "$FG_YELLOW" "? ${state:-unknown}" "$RESET" ;;
	esac
}

svc_enabled_badge() {
	local state
	state=$(systemctl is-enabled "$1" 2>/dev/null)
	case "$state" in
		enabled)  printf '%sEnabled %s' "$FG_BGREEN" "$RESET" ;;
		disabled) printf '%sDisabled%s' "$FG_YELLOW" "$RESET" ;;
		masked)   printf '%sMasked  %s' "$FG_BRED"   "$RESET" ;;
		*)        printf '%s%-8s%s'      "$FG_WHITE"  "${state:-unknown}" "$RESET" ;;
	esac
}

svc_uptime() {
	local ts
	ts=$(systemctl show "$1" \
		--property=ActiveEnterTimestamp --value 2>/dev/null)
			if [[ -z "$ts" || "$ts" == "n/a" ]]; then
				printf '%sn/a%s' "$DIM" "$RESET"; return
			fi
			local epoch_start
			epoch_start=$(date -d "$ts" +%s 2>/dev/null) \
				|| { printf '%sn/a%s' "$DIM" "$RESET"; return; }
							local elapsed=$(( $(date +%s) - epoch_start ))
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
	section_header "UNBOUND" "Recursive DNS Resolver" "🔍"
	kv_line "Status " "$(svc_status_badge "$svc")  Boot: $(svc_enabled_badge "$svc")"
	kv_line "Uptime " "$(svc_uptime "$svc")"

	if command -v unbound-control &>/dev/null \
		&& unbound-control status &>/dev/null 2>&1; then

	local stats
	stats=$(unbound-control stats_noreset 2>/dev/null)

	local total_q cache_hits cache_miss prefetch avg_ms rec_ms msg_cache rrset_cache cache_pct=''
	# Single awk pass over $stats — avoids spawning 10 separate processes
	eval "$(awk -F= '
	/^total\.num\.queries=/            { total=$2+0;      printf "total_q=\"%'"'"'d\"\n",   $2+0 }
	/^total\.num\.cachehits=/          { hits=$2+0;       printf "cache_hits=\"%'"'"'d\"\n", $2+0 }
	/^total\.num\.cachemiss=/          {                  printf "cache_miss=\"%'"'"'d\"\n", $2+0 }
	/^total\.num\.prefetch=/           {                  printf "prefetch=\"%'"'"'d\"\n",   $2+0 }
	/^total\.recursion\.time\.avg=/    {                  printf "avg_ms=\"%.2f ms\"\n",     $2*1000 }
	/^total\.recursion\.time\.median=/ {                  printf "rec_ms=\"%.2f ms\"\n",     $2*1000 }
	/^mem\.cache\.message=/            {                  printf "msg_cache=\"%.1f MiB\"\n", $2/1048576 }
	/^mem\.cache\.rrset=/              {                  printf "rrset_cache=\"%.1f MiB\"\n",$2/1048576 }
	END { if (total>0) printf "cache_pct=\"%.1f%%\"\n", hits/total*100 }
	' <<< "$stats")"

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
	box_blank
}

# =============================================================================
# ── KEA ───────────────────────────────────────────────────────────────────────
# =============================================================================
section_kea() {
	section_header "KEA" "ISC DHCP Server (DHCPv4 / DHCPv6 / DDNS)" "📡"

    # Helpers are fixed-width; columns align naturally across all three rows
    local services=('kea-dhcp4-server' 'kea-dhcp6-server' 'kea-dhcp-ddns-server')
    local labels=('DHCPv4' 'DHCPv6' 'DDNS  ')
    local i
    for i in "${!services[@]}"; do
	    local svc="${services[$i]}"
	    kv_line "${labels[$i]} status" \
		    "$(svc_status_badge "$svc")  Boot: $(svc_enabled_badge "$svc")  Up: $(svc_uptime "$svc")"
	    done

	    inner_rule dash

	    local lease4='/var/lib/kea/kea-leases4.csv'
	    if [[ -r "$lease4" ]]; then
		    local t4 a4 e4 d4
		    # Single awk pass: count total (skip header), active ($10==0), expired ($10==2), declined ($10==1)
		    read -r t4 a4 e4 d4 < <(awk -F, '
		    NR>1 { t++; if($10==0) a++; else if($10==2) e++; else if($10==1) d++ }
		    END  { printf "%d %d %d %d\n", t+0, a+0, e+0, d+0 }
		    ' "$lease4")
		    kv_line "DHCPv4 leases" \
			    "Total: ${FG_BWHITE}$(printf '%4d' "$t4")${RESET}   Active: ${FG_BGREEN}$(printf '%4d' "$a4")${RESET}   Expired: ${FG_YELLOW}$(printf '%4d' "$e4")${RESET}   Declined: ${FG_BRED}$(printf '%4d' "$d4")${RESET}"
					else
						kv_line "DHCPv4 leases" "${FG_YELLOW}lease file not readable (${lease4})${RESET}"
	    fi

	    local lease6='/var/lib/kea/kea-leases6.csv'
	    if [[ -r "$lease6" ]]; then
		    local t6 a6 e6 d6
		    read -r t6 a6 e6 d6 < <(awk -F, '
		    NR>1 { t++; if($9==0) a++; else if($9==2) e++; else if($9==1) d++ }
		    END  { printf "%d %d %d %d\n", t+0, a+0, e+0, d+0 }
		    ' "$lease6")
		    kv_line "DHCPv6 leases" \
			    "Total: ${FG_BWHITE}$(printf '%4d' "$t6")${RESET}   Active: ${FG_BGREEN}$(printf '%4d' "$a6")${RESET}   Expired: ${FG_YELLOW}$(printf '%4d' "$e6")${RESET}   Declined: ${FG_BRED}$(printf '%4d' "$d6")${RESET}"
					else
						kv_line "DHCPv6 leases" "${FG_YELLOW}lease file not readable (${lease6})${RESET}"
	    fi

	    local ctl_sock='/run/kea/kea4-ctrl-socket'
	    if command -v socat &>/dev/null && [[ -S "$ctl_sock" ]]; then
		    local raw rcv sent drop
		    raw=$(printf '{"command":"statistic-get-all","service":["dhcp4"]}' \
			    | socat - UNIX-CONNECT:"$ctl_sock" 2>/dev/null)
						if [[ -n "$raw" ]]; then
							rcv=$(  grep -o '"pkt4-received":\s*\[\s*\[[^]]*\]'     <<< "$raw" | grep -o '[0-9]\+' | head -1)
							sent=$( grep -o '"pkt4-sent":\s*\[\s*\[[^]]*\]'         <<< "$raw" | grep -o '[0-9]\+' | head -1)
							drop=$( grep -o '"pkt4-receive-drop":\s*\[\s*\[[^]]*\]' <<< "$raw" | grep -o '[0-9]\+' | head -1)
							kv_line "DHCPv4 packets" \
								"Rcvd: ${FG_BWHITE}$(printf '%7d' "${rcv:-0}")${RESET}   Sent: ${FG_BGREEN}$(printf '%7d' "${sent:-0}")${RESET}   Dropped: ${FG_BRED}$(printf '%7d' "${drop:-0}")${RESET}"
						fi
	    fi

	    box_blank
    }

# =============================================================================
# ── CHRONY ────────────────────────────────────────────────────────────────────
# =============================================================================
section_chrony() {
	local svc='chrony'
	section_header "CHRONY" "NTP Time Synchronisation" "🕐"
	kv_line "Status " "$(svc_status_badge "$svc")  Boot: $(svc_enabled_badge "$svc")"
	kv_line "Uptime " "$(svc_uptime "$svc")"

	if ! command -v chronyc &>/dev/null; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  chronyc not found${RESET}"
		box_blank; return
	fi

	local tracking
	tracking=$(chronyc tracking 2>/dev/null)
	if [[ -n "$tracking" ]]; then
		inner_rule dash
		local ref_id stratum sys_time rms_offset freq_err leap
		ref_id=$(    awk -F': ' '/^Reference ID/{print $2}'  <<< "$tracking")
		stratum=$(   awk -F': ' '/^Stratum/{print $2}'       <<< "$tracking")
		sys_time=$(  awk -F': ' '/^System time/{print $2}'   <<< "$tracking")
		rms_offset=$(awk -F': ' '/^RMS offset/{print $2}'    <<< "$tracking")
		freq_err=$(  awk -F': ' '/^Frequency/{print $2}'     <<< "$tracking")
		leap=$(      awk -F': ' '/^Leap status/{print $2}'   <<< "$tracking")

		local sys_raw offset_col
		sys_raw=$(awk '/^System time/{print $4}' <<< "$tracking")
		if   awk "BEGIN{exit !($sys_raw < 0.001)}" 2>/dev/null; then offset_col="$FG_BGREEN"
		elif awk "BEGIN{exit !($sys_raw < 0.010)}" 2>/dev/null; then offset_col="$FG_BYELLOW"
		else                                                          offset_col="$FG_BRED"
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

    # ── NTP sources table ──────────────────────────────────────────────────────
    local src_output
    src_output=$(chronyc sources 2>/dev/null)
    if [[ -n "$src_output" ]]; then
	    inner_rule dash
	    box_line "   ${FG_BCYAN}NTP Sources${RESET}"

	# Hardcoded header — matches chronyc's own fixed-width column layout
	# exactly, so it always aligns with the data rows below regardless of
	# chrony version.  Column key:
	#   M = reference mode (^ server, = peer, # local ref)
	#   S = selection state (* best, + combined, - not combined,
	#                        ? unreachable, x falseticker, ~ too variable)
	local NTP_HDR='MS Name/IP address         Stratum Poll Reach LastRx Last sample'
	box_line "   ${DIM}${NTP_HDR}${RESET}"
	inner_rule dash

	# Colour-code by state character (index 1, 0-based):
	#   Mode (index 0): ^ = server, = = peer, # = local clock
	#   State (index 1): * current best, + combined, - not combined,
	#                    ? unreachable, x may be wrong, ~ too variable
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local sc
		case "${line:1:1}" in
			'*') sc="$FG_BGREEN"  ;;   # selected / current best
			'+') sc="$FG_BWHITE"  ;;   # combined candidate
			'-') sc="$FG_YELLOW"  ;;   # not combined
			'?') sc="$FG_YELLOW"  ;;   # unreachable
			'x') sc="$FG_BRED"    ;;   # time may be in error
			'~') sc="$FG_YELLOW"  ;;   # time too variable
			*)   sc="$FG_WHITE"   ;;
		esac
		box_line "   ${sc}${line}${RESET}"
	done <<< "$(grep -E '^[\^=#][*+?x~-]' <<< "$src_output")"
    fi

    box_blank
}

# Renders a minimal placeholder frame immediately after smcup so the alternate
# screen is never blank.  Called once before any service queries run.
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
			tput cup 0 0
			outer_top
			printf '%s' "$_BUF"
			outer_bottom
			tput ed
			_BUF=''   # reset so the pre-flush guard skips on the real first draw
		}


		draw_dashboard() {
			_BUF=''
			local ts
			ts=$(date '+%A %d %B %Y  %H:%M:%S %Z')

    # nice_disp shows sign explicitly: +10 or -5
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

    # ── Footer ────────────────────────────────────────────────────────────────
    inner_rule thin

    # Capture the row this line will occupy so prompt_input() can overwrite it
    # in place instantly without re-querying any services.
    # outer_top prints one line before _BUF, hence the +1 offset.
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

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================
cleanup() {
	tput cnorm; tput rmcup
	# Restore the terminal to exactly the state it was in before the dashboard ran
	[[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null || stty echo 2>/dev/null
	exit 0
}
trap cleanup INT TERM

# SIGWINCH: flag a redraw and update dimensions so the interrupted read
# causes an immediate redraw at the new terminal size.
trap '_NEED_REDRAW=true
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
INNER_WIDTH=$(( TERM_WIDTH - 2 ))' WINCH

do_draw() {
	tput cup 0 0
	outer_top
	printf '%s' "$_BUF"
	outer_bottom
	tput ed     # erase any stale lines below the dashboard (e.g. after help is toggled off)
}

main() {
	# ── One-shot mode: draw once to stdout and exit ────────────────────────────
	if [[ "$ONE_SHOT" == "true" ]]; then
		_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
		TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
		INNER_WIDTH=$(( TERM_WIDTH - 2 ))
		B="${FG_BLUE}${BOX_V}${RESET}"
		LAST_REFRESH=$(date '+%H:%M:%S')
		draw_dashboard
		outer_top
		printf '%s' "$_BUF"
		outer_bottom
		return
	fi

    # Switch to alternate screen and suppress echo immediately — the user sees the
    # dashboard frame at once rather than a frozen terminal during setup.
    tput smcup
    tput civis

    # Capture the tty state NOW, before any read -s call modifies it.
    _TTY_STATE=$(stty -g 2>/dev/null)
    stty -echo 2>/dev/null

    # Measure terminal and draw a loading placeholder immediately — the alternate
    # screen must never be blank while hostname / service queries run.
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    INNER_WIDTH=$(( TERM_WIDTH - 2 ))
    B="${FG_BLUE}${BOX_V}${RESET}"
    draw_loading

    # hostname -f may do a DNS lookup; runs after the screen is already drawn.
    _HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')

    local force_refresh=true   # ensure a draw on the very first iteration
    local key=''               # declared once here; reset to '' at the top of each read

    while true; do
	    # Remeasure on every iteration — catches resize even without SIGWINCH
	    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
	    INNER_WIDTH=$(( TERM_WIDTH - 2 ))
	    B="${FG_BLUE}${BOX_V}${RESET}"

	# Draw when: running normally, explicitly forced, or after a resize
	if [[ "$PAUSED" == "false" || "$force_refresh" == "true" || "$_NEED_REDRAW" == "true" ]]; then
		# If we have a previous frame, flush it first so the user sees
		# something immediately while service queries run.
		[[ -n "$_BUF" ]] && { tput cup 0 0; outer_top; printf '%s' "$_BUF"; outer_bottom; tput ed; }

	    # Only stamp a new time when data is actually being fetched
	    [[ "$PAUSED" == "false" || "$force_refresh" == "true" ]] \
		    && LAST_REFRESH=$(date '+%H:%M:%S')
				force_refresh=false
				_NEED_REDRAW=false
				draw_dashboard
				do_draw
	fi

	# Wait for keypress.
	# • Paused → block indefinitely (no timeout)
	# • Normal → timeout at the refresh interval
	key=''
	if [[ "$PAUSED" == "true" ]]; then
		IFS= read -r -s -n 1 key 2>/dev/null || true
	else
		IFS= read -r -s -n 1 -t "$REFRESH_INTERVAL" key 2>/dev/null || true
	fi

	# Drain any multi-byte escape sequence (arrow keys, F-keys, etc.)
	# so stray bytes don't pollute the next read.
	if [[ "$key" == $'\033' ]]; then
		local _seq=''
		IFS= read -r -s -n 4 -t 0.05 _seq 2>/dev/null || true
	fi

	# ── Key dispatch ──────────────────────────────────────────────────────
	case "$key" in
		q|Q) cleanup ;;

		p|P)
			[[ "$PAUSED" == "true" ]] && PAUSED=false || PAUSED=true
			force_refresh=true ;;

		r|R)
			PAUSED=false; force_refresh=true ;;

		i|I)
			prompt_input 'interval'
			draw_footer_row   # show new interval immediately, before re-query
			force_refresh=true ;;

		n|N)
			prompt_input 'nice'
			draw_footer_row   # show new nice value immediately, before re-query
			force_refresh=true ;;

		'h'|'?')
			[[ "$SHOW_HELP" == "true" ]] && SHOW_HELP=false || SHOW_HELP=true
			force_refresh=true ;;
	esac
done
}

main "$@"
