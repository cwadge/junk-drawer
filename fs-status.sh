#!/usr/bin/env bash
# =============================================================================
# fs-status — File Server Services Dashboard
# Sections:  ZFS (pools · ARC · L2ARC · datasets) · mdadm · Disk I/O · SMART
#            Volumes · NFS · Samba (if installed) · Network interfaces
# Target:   Debian 13 / Linux
# =============================================================================

shopt -s checkwinsize

# ── Defaults ──────────────────────────────────────────────────────────────────
REFRESH_INTERVAL=3
NICE_VALUE=10
ONE_SHOT=false

# ── Live state ────────────────────────────────────────────────────────────────
PAUSED=false
SHOW_HELP=false
LAST_REFRESH='—'
_NEED_REDRAW=false
INPUT_MODE=''
_FOOTER_ROW=0
_TTY_STATE=''
_HOSTNAME=''
_NOW=0

# ── Network throughput state — persist across refreshes (not in subshells) ────
declare -A _NET_PREV_RX=()
declare -A _NET_PREV_TX=()
_NET_PREV_TS=0

# ── Disk I/O throughput state — same persistence model as network ─────────────
declare -A _DISK_PREV_R=()
declare -A _DISK_PREV_W=()
_DISK_PREV_TS=0

# ── Optional-section presence — checked once at startup ──────────────────────
_ZFS_PRESENT=false
_MDADM_PRESENT=false
_NFS_PRESENT=false
_SAMBA_PRESENT=false

# ── Two-column layout support ─────────────────────────────────────────────────
_MID_COL=0   # terminal column of the center │ divider; set by rebuild_fills

# ── Config (XDG-compliant) ────────────────────────────────────────────────────
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CFG_FILE="$CFG_DIR/fs-status.conf"

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
		printf '# fs-status — saved %s\n' "$(date '+%F %T')"
		printf 'REFRESH_INTERVAL=%s\n' "$REFRESH_INTERVAL"
		printf 'NICE_VALUE=%s\n'       "$NICE_VALUE"
	} > "$CFG_FILE"
}

# ── Utility ───────────────────────────────────────────────────────────────────
clamp() {
	local v=$1
	(( v < $2 )) && v=$2
	(( v > $3 )) && v=$3
	printf '%s' "$v"
}

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

File server services status dashboard.
Always shown: DRIVES (SMART + I/O) · VOLUMES · NETWORK
Optional (shown when present): ZFS · mdadm · NFS · Samba

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

Privilege notes:
  Run as root for full access: exportfs, smbstatus, mdadm detail, smartctl.

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
	&& systemctl cat nfs-server.service &>/dev/null 2>&1 \
	&& _NFS_PRESENT=true

# Samba: smbd present, or the smbd unit file is installed
command -v smbd &>/dev/null && _SAMBA_PRESENT=true
[[ "$_SAMBA_PRESENT" == "false" ]] \
	&& systemctl list-unit-files smbd.service 2>/dev/null | grep -q 'smbd' \
	&& _SAMBA_PRESENT=true

# ── Colors ────────────────────────────────────────────────────────────────────
RESET=$'\033[0m';  BOLD=$'\033[1m';  DIM=$'\033[2m'
FG_RED=$'\033[0;31m';    FG_GREEN=$'\033[0;32m';   FG_YELLOW=$'\033[0;33m'
FG_BLUE=$'\033[0;34m';   FG_CYAN=$'\033[0;36m';    FG_WHITE=$'\033[0;37m'
FG_BWHITE=$'\033[1;37m'; FG_BCYAN=$'\033[1;36m';   FG_BGREEN=$'\033[1;32m'
FG_BRED=$'\033[1;31m';   FG_BYELLOW=$'\033[1;33m'; FG_BBLUE=$'\033[1;34m'
FG_HGREEN=$'\033[92m'  # high-intensity bright green (for "Excellent" ratings)

# ── Box-drawing ───────────────────────────────────────────────────────────────
BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'
BOX_H='═';  BOX_V='║';  BOX_ML='╠'; BOX_MR='╣'
DIV_H='─';  DIV_ML='├'; DIV_MR='┤'; DASH_H='╌'

# ── Layout ────────────────────────────────────────────────────────────────────
TERM_WIDTH=${COLUMNS:-80}
INNER_WIDTH=$(( TERM_WIDTH - 2 ))
B="${FG_BLUE}${BOX_V}${RESET}"

_FILL_MID=''
_FILL_THIN=''
_FILL_DASH=''
_FILL_OUTER=''
_LAST_WIDTH=0

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
	_MID_COL=$(( TERM_WIDTH / 2 ))   # center column for two-column sections
}

# ── Output buffer ─────────────────────────────────────────────────────────────
_BUF=''
_n() { _BUF+="$*"$'\n'; }

# ── Drawing primitives ────────────────────────────────────────────────────────

inner_rule() {
	local style="${1:-mid}"
	case "$style" in
		mid)  _n "${B}${FG_BLUE}${BOX_ML}${_FILL_MID}${BOX_MR}${RESET}${B}"  ;;
		thin) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_THIN}${DIV_MR}${RESET}${B}" ;;
		dash) _n "${B}${FG_BLUE}${DIV_ML}${_FILL_DASH}${DIV_MR}${RESET}${B}" ;;
	esac
}

box_line() {
	local content="$1" padding="${2:-1}"
	local pad; pad=$(printf '%*s' "$padding" '')
	_n "${B}${pad}${content}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
}

box_blank() { _n "${B}"$'\033[K\033'"[${TERM_WIDTH}G${B}"; }

outer_top()    { printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_TL" "$_FILL_OUTER" "${BOX_TR}${RESET}"; }
outer_bottom() { printf '%s%s%s%s\n' "$FG_BLUE" "$BOX_BL" "$_FILL_OUTER" "${BOX_BR}${RESET}"; }

# ── Service helpers ───────────────────────────────────────────────────────────

svc_fetch() {
	local raw
	raw=$(systemctl show "$1" \
		--property=ActiveState,UnitFileState,ActiveEnterTimestamp 2>/dev/null)
			_SVC_ACTIVE='' _SVC_ENABLED='' _SVC_ENTER=''
			local key val
			while IFS='=' read -r key val; do
				case "$key" in
					ActiveState)          _SVC_ACTIVE="$val"  ;;
					UnitFileState)        _SVC_ENABLED="$val" ;;
					ActiveEnterTimestamp) _SVC_ENTER="$val"   ;;
				esac
			done <<< "$raw"
		}

		svc_status_badge() {
			case "$_SVC_ACTIVE" in
				active)   printf '%s● Active  %s' "$FG_BGREEN" "$RESET" ;;
				inactive) printf '%s✖ Inactive%s' "$FG_BRED"   "$RESET" ;;
				failed)   printf '%s✖ Failed  %s' "$FG_BRED"   "$RESET" ;;
				*)        printf '%s%-10s%s'       "$FG_YELLOW" "? ${_SVC_ACTIVE:-unknown}" "$RESET" ;;
			esac
		}

		svc_enabled_badge() {
			case "$_SVC_ENABLED" in
				enabled)  printf '%sEnabled %s' "$FG_BGREEN" "$RESET" ;;
				disabled) printf '%sDisabled%s' "$FG_YELLOW" "$RESET" ;;
				masked)   printf '%sMasked  %s' "$FG_BRED"   "$RESET" ;;
				*)        printf '%s%-8s%s'      "$FG_WHITE"  "${_SVC_ENABLED:-unknown}" "$RESET" ;;
			esac
		}

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
							box_line "${3}  ${BOLD}${FG_BWHITE}${1}${RESET}${FG_BLUE} — ${RESET}${FG_WHITE}${2}${RESET}" 2
							inner_rule thin
						}

# Render one line with content in two columns separated by a │ at _MID_COL.
# Left and right are arbitrary colored strings; CHA handles ANSI-safe positioning.
# Falls back to showing only left content when _MID_COL is 0 (shouldn't happen
# after the first rebuild_fills call, but guards against early-startup edge cases).
two_col_row() {
	local left="$1" right="${2:-}"
	if (( _MID_COL > 0 )); then
		_n "${B}${left}${RESET}"$'\033'"[${_MID_COL}G${FG_BLUE}│${RESET}${right}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	else
		_n "${B}${left}${RESET}"$'\033[K\033'"[${TERM_WIDTH}G${B}"
	fi
}

# ── Byte / rate formatting (pure bash, no subprocesses) ───────────────────────

fmt_bytes() {
	local b="${1:-0}"
	if   (( b >= 1073741824 )); then
		printf '%d.%d GiB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
	elif (( b >= 1048576 )); then
		printf '%d.%d MiB' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
	elif (( b >= 1024 )); then
		printf '%d.%d KiB' $(( b / 1024 )) $(( (b % 1024) * 10 / 1024 ))
	else
		printf '%d B' "$b"
	fi
}

fmt_rate() {
	local b="${1:-0}"
	if   (( b >= 1073741824 )); then
		printf '%d.%d GiB/s' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
	elif (( b >= 1048576 )); then
		printf '%d.%d MiB/s' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
	elif (( b >= 1024 )); then
		printf '%d.%d KiB/s' $(( b / 1024 )) $(( (b % 1024) * 10 / 1024 ))
	else
		printf '%d B/s' "$b"
	fi
}

# Render a filled/empty bar string for a 0–100 percentage value.
# Pure bash: printf -v avoids spawning repeat_char subshells.
pct_bar() {
	local pct="${1:-0}" width="${2:-20}"
	local filled=$(( pct * width / 100 ))
	(( filled > width )) && filled=$width
	local empty=$(( width - filled ))
	local bar_col
	if   (( pct >= 90 )); then bar_col="$FG_BRED"
	elif (( pct >= 75 )); then bar_col="$FG_BYELLOW"
	else                       bar_col="$FG_BGREEN"
	fi
	local fs es
	printf -v fs '%*s' "$filled" ''; fs="${fs// /█}"
	printf -v es '%*s' "$empty"  ''; es="${es// /░}"
	printf '%s%s%s%s%s' "$bar_col" "$fs" "$DIM" "$es" "$RESET"
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
	local arcstats='/proc/spl/kstat/zfs/arcstats'
	if [[ -r "$arcstats" ]]; then
		local arc_size arc_max arc_hit_pct arc_hits arc_misses
		local l2arc_present l2arc_size l2arc_asize l2arc_hit_pct l2arc_hits l2arc_misses
		eval "$(awk '
		function fmtb(b) {
		if (b >= 1073741824) return sprintf("%.1f GiB", b/1073741824)
			if (b >= 1048576)   return sprintf("%.1f MiB", b/1048576)
				if (b >= 1024)      return sprintf("%.1f KiB", b/1024)
					return sprintf("%d B", b)
				}
				NR>2 { v[$1]=$3+0 }
				END {
				printf "arc_size=\"%s\"\n",  fmtb(v["size"]+0)
				printf "arc_max=\"%s\"\n",   fmtb(v["c"]+0)
				# demand-only hits: excludes prefetch, which inflates totals
				h = v["demand_data_hits"]+v["demand_metadata_hits"]
				m = v["demand_data_misses"]+v["demand_metadata_misses"]
				tot = h + m
				printf "arc_hits=\"%d\"\n",   h
				printf "arc_misses=\"%d\"\n", m
				if (tot > 0) printf "arc_hit_pct=\"%.1f\"\n",  h/tot*100
				else         printf "arc_hit_pct=\"\"\n"
					l2s = v["l2_size"]+0
					if (l2s > 0) {
						printf "l2arc_present=true\n"
						printf "l2arc_size=\"%s\"\n",  fmtb(l2s)
						printf "l2arc_asize=\"%s\"\n", fmtb(v["l2_asize"]+0)
						l2h = v["l2_hits"]+0; l2m = v["l2_misses"]+0; l2t = l2h + l2m
						printf "l2arc_hits=\"%d\"\n",   l2h
						printf "l2arc_misses=\"%d\"\n", l2m
						if (l2t > 0) printf "l2arc_hit_pct=\"%.1f\"\n", l2h/l2t*100
						else         printf "l2arc_hit_pct=\"\"\n"
						} else {
						printf "l2arc_present=false\n"
					}
				}' "$arcstats")"

				local arc_col l2_col
				# Cold <50% · Poor 50–75% · Normal 75–90% · Good 90–95% · Excellent >95%
				if   [[ -z "$arc_hit_pct" ]];               then arc_col="$FG_WHITE"
				elif (( ${arc_hit_pct%%.*} >= 95 ));         then arc_col="$FG_HGREEN"
				elif (( ${arc_hit_pct%%.*} >= 90 ));         then arc_col="$FG_GREEN"
				elif (( ${arc_hit_pct%%.*} >= 75 ));         then arc_col="$FG_WHITE"
				elif (( ${arc_hit_pct%%.*} >= 50 ));         then arc_col="$FG_WHITE"
				else                                              arc_col="$FG_CYAN"
				fi
				local arc_hit_str
				[[ -n "$arc_hit_pct" ]] \
					&& arc_hit_str="${arc_col}${arc_hit_pct}%${RESET}" \
					|| arc_hit_str="${DIM}n/a${RESET}"

				local arc_right=''
				if [[ "$l2arc_present" == "true" ]]; then
					# Cold <10% · Poor 10–20% · Normal 20–40% · Good 40–60% · Excellent >60%
					if   [[ -z "$l2arc_hit_pct" ]];               then l2_col="$FG_WHITE"
					elif (( ${l2arc_hit_pct%%.*} > 60 ));          then l2_col="$FG_HGREEN"
					elif (( ${l2arc_hit_pct%%.*} >= 40 ));         then l2_col="$FG_GREEN"
					elif (( ${l2arc_hit_pct%%.*} >= 20 ));         then l2_col="$FG_WHITE"
					elif (( ${l2arc_hit_pct%%.*} >= 10 ));         then l2_col="$FG_WHITE"
					else                                                l2_col="$FG_CYAN"
					fi
					local l2_hit_str
					[[ -n "$l2arc_hit_pct" ]] \
						&& l2_hit_str="${l2_col}${l2arc_hit_pct}%${RESET}" \
						|| l2_hit_str="${DIM}n/a${RESET}"
											arc_right=" ${FG_BCYAN}L2ARC${RESET}  ${l2_hit_str}  ${DIM}size:${RESET} ${FG_WHITE}${l2arc_size}${RESET}  ${DIM}on-disk:${RESET} ${FG_WHITE}${l2arc_asize}${RESET}  ${DIM}hits: ${l2arc_hits}  misses: ${l2arc_misses}${RESET}"
				fi

				inner_rule dash
				two_col_row " ${FG_BCYAN}ARC${RESET}  ${arc_hit_str}  ${DIM}size:${RESET} ${FG_WHITE}${arc_size}${RESET}  ${DIM}of${RESET} ${FG_WHITE}${arc_max}${RESET}  ${DIM}hits: ${arc_hits}  misses: ${arc_misses}${RESET}" "$arc_right"
	fi

	# ── Per-pool status ───────────────────────────────────────────────────────
	local pool_list
	pool_list=$(zpool list -H -o name 2>/dev/null) || pool_list=''

	if [[ -z "$pool_list" ]]; then
		inner_rule dash
		box_line "   ${FG_YELLOW}⚠  No ZFS pools imported${RESET}"
		box_blank; return
	fi

	local pool
	while IFS= read -r pool; do
		[[ -z "$pool" ]] && continue
		inner_rule dash

		# zpool list: size alloc free frag cap health
		local p_size p_alloc p_free p_frag p_cap p_health
		IFS=$'\t' read -r p_size p_alloc p_free p_frag p_cap p_health < <(
		zpool list -H -p -o size,alloc,free,frag,cap,health "$pool" 2>/dev/null
	)

		# -p gives raw bytes; compute human-readable with fmt_bytes and integer cap/frag
		local p_size_h p_alloc_h p_free_h
		p_size_h=$(fmt_bytes "${p_size:-0}")
		p_alloc_h=$(fmt_bytes "${p_alloc:-0}")
		p_free_h=$(fmt_bytes "${p_free:-0}")

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

		# Scrub and error info from zpool status
		local zs_out
		zs_out=$(zpool status "$pool" 2>/dev/null)
		if [[ -n "$zs_out" ]]; then
			# Grab scan: line plus any immediately following detail lines
			local scan_text
			scan_text=$(awk '
			/scan:/ { found=1; sub(/.*scan:[[:space:]]*/,""); print; next }
			found && /^[[:space:]]+[0-9]/ { print; next }
			found { exit }
			' <<< "$zs_out")

			if [[ "$scan_text" == *"scrub in progress"* ]]; then
				local pct_done
				pct_done=$(grep -oP '[0-9]+\.[0-9]+(?=% done)' <<< "$scan_text" | head -1)
				kv_line "Scrub       " "${FG_BYELLOW}⟳ In progress${RESET}${pct_done:+  ${FG_WHITE}${pct_done}% done${RESET}}"
			elif [[ "$scan_text" == *"resilver in progress"* ]]; then
				kv_line "Scrub       " "${FG_BYELLOW}⟳ Resilver in progress${RESET}"
			elif [[ "$scan_text" == *"scrub repaired"* ]]; then
				local s_errs
				s_errs=$(grep -oP '[0-9]+(?= error)' <<< "$scan_text" | head -1)
				if [[ "${s_errs:-0}" != "0" ]]; then
					local s_date; s_date=$(grep -oP '(?<=on ).*' <<< "$scan_text" | head -1)
					kv_line "Scrub       " "${FG_BRED}⚠ ${s_errs} error(s)${RESET}${s_date:+  ${DIM}${s_date}${RESET}}"
				fi
				# Clean scrubs (0 errors) are not shown — pool line already shows ONLINE
			fi

			# Data errors — only show the row when there's something to report
			local err_line
			err_line=$(grep 'errors:' <<< "$zs_out" | head -1)
			if [[ -n "$err_line" && "$err_line" != *"No known data errors"* ]]; then
				kv_line "Data errors " "${FG_BRED}${err_line##*errors: }${RESET}"
			fi
		fi

		# ── Per-dataset space usage ───────────────────────────────────────────
		# -H: no header  -p: raw bytes  -r: recurse under this pool
		inner_rule dash
		local -a _ds_lines=()
		while IFS=$'\t' read -r ds_name ds_used ds_avail ds_refer ds_mp; do
			[[ -z "$ds_name" ]] && continue

			local ds_rel="${ds_name#${pool}/}"
			[[ "$ds_rel" == "$ds_name" ]] && ds_rel="${ds_name##*/}"

			local ds_used_h ds_avail_h ds_refer_h
			ds_used_h=$(fmt_bytes "$ds_used")
			ds_avail_h=$(fmt_bytes "$ds_avail")
			ds_refer_h=$(fmt_bytes "$ds_refer")

			local mp_str=''
			[[ "$ds_mp" != "-" && "$ds_mp" != "none" && "$ds_mp" != "legacy" ]] \
				&& mp_str="  ${DIM}→ ${ds_mp}${RESET}"

			_ds_lines+=( " ${FG_WHITE}$(printf '%-18s' "$ds_rel")${RESET}  ${DIM}used:${RESET} ${FG_BWHITE}${ds_used_h}${RESET}  ${DIM}avail:${RESET} ${FG_WHITE}${ds_avail_h}${RESET}  ${DIM}refer:${RESET} ${FG_WHITE}${ds_refer_h}${RESET}${mp_str}" )
		done < <(zfs list -H -p -r -o name,used,avail,refer,mountpoint "$pool" 2>/dev/null)

		local _nds=${#_ds_lines[@]}
		if (( _nds == 0 )); then
			box_line "   ${DIM}(no datasets)${RESET}"
		elif (( INNER_WIDTH >= 140 )); then
			local _di=0
			while (( _di < _nds )); do
				local _dj=$(( _di + 1 ))
				two_col_row "${_ds_lines[$_di]}" "${_ds_lines[$_dj]:-}"
				_di=$(( _di + 2 ))
			done
		else
			local _dl
			for _dl in "${_ds_lines[@]}"; do box_line "$_dl"; done
		fi

	done <<< "$pool_list"

	box_blank
}

# =============================================================================
# ── MDADM ─────────────────────────────────────────────────────────────────────
# =============================================================================

# Returns a compact one-line summary of one mdadm array.  Called in $()
# context; outputs to stdout and the caller captures into an array.
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

		local clean_devs
		clean_devs=$(sed 's/\[[0-9]*\]//g; s/([^)]*)//g; s/[[:space:]]\{2,\}/ /g' <<< "$devs" \
			| sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

		local line=" ${FG_BWHITE}$(printf '%-6s' "$name")${RESET}  ${FG_WHITE}${level}${RESET}  ${state_str}${sdisplay}  ${FG_WHITE}${clean_devs}${RESET}"
		[[ -n "$sync_info" ]] && line+="  ${FG_BYELLOW}⟳ ${sync_info}${RESET}"
		printf '%s' "$line"
	}

	section_mdadm() {
		section_header "mdadm" "Linux Software RAID" "⚙"

		if [[ ! -r /proc/mdstat ]]; then
			box_line "   ${FG_YELLOW}⚠  /proc/mdstat not readable${RESET}"
			box_blank; return
		fi

		local md_found=false
		local in_array=false arr_name='' arr_state='' arr_level='' arr_devs='' arr_status='' arr_sync=''
		local -a _arr_lines=()

		while IFS= read -r line; do
			if [[ "$line" =~ ^(md[[:alnum:]]+)[[:space:]]+:[[:space:]]+(active|inactive|read-auto)[[:space:]] ]]; then
				# Flush previous array before starting a new one
				if [[ "$in_array" == "true" ]]; then
					_arr_lines+=( "$(_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync")" )
				fi
				arr_name="${BASH_REMATCH[1]}"
				arr_state="${BASH_REMATCH[2]}"
				local _rest="${line#*${arr_state} }"
				[[ "${_rest:0:1}" == "(" ]] && _rest="${_rest#*) }"
				arr_level="${_rest%% *}"
				arr_devs="${_rest#* }"
				arr_status=''; arr_sync=''
				in_array=true; md_found=true

			elif [[ "$in_array" == "true" && "$line" =~ \[([U_]+)\] ]]; then
				arr_status="${BASH_REMATCH[1]}"

			elif [[ "$in_array" == "true" && "$line" =~ (resync|recovery|reshape|check)[[:space:]]*= ]]; then
				local pct
				pct=$(grep -oP '[0-9]+\.[0-9]+(?=%)' <<< "$line" | head -1)
				arr_sync=$(sed 's/^[[:space:]]*//' <<< "$line")
				[[ -n "$pct" ]] && arr_sync="${line%%=*}= ${pct}%"
				arr_sync=$(sed 's/^[[:space:]]*//' <<< "$arr_sync")
			fi
		done < /proc/mdstat

	# Flush the last array
	[[ "$in_array" == "true" ]] \
		&& _arr_lines+=( "$(_mdadm_format_array "$arr_name" "$arr_state" "$arr_level" "$arr_devs" "$arr_status" "$arr_sync")" )

	local n=${#_arr_lines[@]}
	inner_rule dash

	if [[ "$md_found" == "false" || $n -eq 0 ]]; then
		box_line "   ${DIM}No mdadm arrays configured${RESET}"
	elif (( INNER_WIDTH >= 140 )); then
		local i=0
		while (( i < n )); do
			local j=$(( i + 1 ))
			local l="${_arr_lines[$i]}" r=''
			(( j < n )) && r="${_arr_lines[$j]}"
			two_col_row "$l" "$r"
			i=$(( i + 2 ))
		done
	else
		local al
		for al in "${_arr_lines[@]}"; do box_line "$al"; done
	fi

	box_blank
}

# =============================================================================
# ── DRIVES ────────────────────────────────────────────────────────────────────
# Combined SMART health + I/O throughput in a two-column grid (one row per
# drive pair) when the terminal is wide enough; single-column otherwise.
# =============================================================================
section_drives() {
	local smart_avail=false
	command -v smartctl &>/dev/null && smart_avail=true
	section_header "DRIVES" "I/O Throughput${smart_avail:+ · SMART Health}" "💾"

	# ── Pre-parse diskstats into lookup tables ────────────────────────────────
	local elapsed=0
	(( _DISK_PREV_TS > 0 && _NOW > _DISK_PREV_TS )) && elapsed=$(( _NOW - _DISK_PREV_TS ))

	declare -A _ds_r=() _ds_w=()
	if [[ -r /proc/diskstats ]]; then
		while IFS= read -r dline; do
			local _dn _dr _dw
			read -r _ _ _dn _ _ _dr _ _ _ _dw _ <<< "$dline"
			[[ -n "$_dn" ]] && {
				_ds_r[$_dn]=$(( _dr * 512 ))
							_ds_w[$_dn]=$(( _dw * 512 ))
						}
					done < /proc/diskstats
	fi

	# ── Device enumeration: physical (lsblk) + software RAID (md*) ───────────
	local dev_list=''
	if command -v lsblk &>/dev/null; then
		dev_list=$(lsblk -d -o NAME,TYPE --noheadings 2>/dev/null \
			| awk '$2=="disk"{print $1}')
				else
					dev_list=$(for d in /sys/block/*/device; do
					[[ -e "$d" ]] || continue
					local _b="${d%/device}"; _b="${_b##*/}"; printf '%s\n' "$_b"
				done)
	fi
	local md_list=''
	[[ -r /proc/diskstats ]] \
		&& md_list=$(awk '$3~/^md[0-9]+$/{print $3}' /proc/diskstats | sort -u)
			local all_devs="${dev_list}${dev_list:+${md_list:+$'\n'}}${md_list}"

			if [[ -z "$all_devs" ]]; then
				inner_rule dash
				box_line "   ${DIM}No drives found${RESET}"
				box_blank; return
			fi

	# ── Collect per-drive data into parallel arrays before rendering ──────────
	# All smartctl calls happen here so the two-column pairing is clean.
	local -a _line1=() _line2=()

	while IFS= read -r devname; do
		[[ -z "$devname" ]] && continue

		# I/O throughput from diskstats
		local bytes_r="${_ds_r[$devname]:-0}"
		local bytes_w="${_ds_w[$devname]:-0}"
		local rrc="$FG_BGREEN" rwc="$FG_BYELLOW" rrs rws
		if (( elapsed > 0 )); then
			local pr="${_DISK_PREV_R[$devname]:-0}" pw="${_DISK_PREV_W[$devname]:-0}"
			local dr=$(( bytes_r - pr )) dw=$(( bytes_w - pw ))
			(( dr < 0 )) && dr=0; (( dw < 0 )) && dw=0
			rrs=$(fmt_rate $(( dr / elapsed )))
			rws=$(fmt_rate $(( dw / elapsed )))
		else
			rrs='—'; rws='—'; rrc="$DIM"; rwc="$DIM"
		fi
		_DISK_PREV_R[$devname]="$bytes_r"
		_DISK_PREV_W[$devname]="$bytes_w"

		local io_col=" ↓ ${rrc}$(printf '%-12s' "$rrs")${RESET}  ↑ ${rwc}$(printf '%-12s' "$rws")${RESET}  ${DIM}R:${RESET} ${FG_WHITE}$(printf '%-10s' "$(fmt_bytes "$bytes_r")")${RESET}  ${DIM}W:${RESET} ${FG_WHITE}$(fmt_bytes "$bytes_w")${RESET}"

		# SMART health (md* arrays are skipped; requires root for block devices)
		local hs='n/a' hc="$DIM" temps='      ' mdls='' errs=''
		if [[ "$smart_avail" == "true" && "$devname" != md* ]]; then
			local sout
			sout=$(smartctl -i -H -A "/dev/${devname}" 2>/dev/null)
			if [[ -n "$sout" ]]; then
				if   [[ "$sout" == *"PASSED"* ]]; then hs='PASSED'; hc="$FG_BGREEN"
				elif [[ "$sout" == *": OK"*   ]]; then hs='OK';     hc="$FG_BGREEN"
				elif [[ "$sout" == *"FAILED"* ]]; then hs='FAILED'; hc="$FG_BRED"
				else                                   hs='?';      hc="$FG_YELLOW"
				fi

				local tc='' rl='' pd='' uc=''
				eval "$(awk '
				# Attribute table: field 10 is the raw value first token.
				# Using $10 (not $NF) avoids mis-parsing "34 (Min/Max 22/45)" → would give 22.
				$1+0==5   && NF>=10 && /Reallocated/ { printf "rl=\"%d\"\n", $10+0 }
				$1+0==190 && NF>=10                  { if(!tc) printf "tc=\"%d\"\n", $10+0 }
				$1+0==194 && NF>=10                  { printf "tc=\"%d\"\n", $10+0 }
				$1+0==197 && NF>=10 && /Pending/     { printf "pd=\"%d\"\n", $10+0 }
				$1+0==198 && NF>=10 && /Uncorrect/   { printf "uc=\"%d\"\n", $10+0 }
				# Generic temperature lines (NVMe + some SATA/SAS)
				/^Temperature:[[:space:]]/ && NF>=2       { if(!tc) printf "tc=\"%d\"\n", $2+0 }
				/^Temperature Sensor 1:[[:space:]]/ && NF>=4 { if(!tc) printf "tc=\"%d\"\n", $4+0 }
				/^Current Drive Temperature:[[:space:]]/ && NF>=4 { if(!tc) printf "tc=\"%d\"\n", $4+0 }
				' <<< "$sout")"

				if [[ -n "$tc" && "$tc" =~ ^[0-9]+$ && "$tc" -gt 0 ]]; then
					local tcol
					if   (( tc >= 55 )); then tcol="$FG_BRED"
					elif (( tc >= 45 )); then tcol="$FG_BYELLOW"
					else                      tcol="$FG_BGREEN"
					fi
					# Fixed 6 visual-char slot regardless of digit count:
					# 1-dig → "   9°C", 2-dig → "  34°C", 3-dig → " 100°C"
					local tc_lead
					case ${#tc} in
						1) tc_lead="   " ;;
						2) tc_lead="  "  ;;
						*) tc_lead=" "   ;;
					esac
					temps="${tc_lead}${tcol}${tc}°C${RESET}"
				fi

				local mdl cap
				mdl=$(awk '/^(Device Model|Model Number|Model Family|Product):/{
				sub(/^[^:]+:[[:space:]]*/,""); print; exit}' <<< "$sout")
				cap=$(awk '/^(User Capacity|Namespace 1 Size):/{
				match($0,/\[[^\]]+\]/); if(RSTART){print substr($0,RSTART+1,RLENGTH-2); exit}
				match($0,/[0-9.]+ [KMGT]iB/); if(RSTART){print substr($0,RSTART,RLENGTH); exit}
			}' <<< "$sout")
			if [[ -n "$mdl" ]]; then
				[[ ${#mdl} -gt 30 ]] && mdl="${mdl:0:27}…"
				mdls="  ${DIM}${mdl}${cap:+  (${cap})}${RESET}"
			fi

			if [[ "${rl:-0}" != "0" || "${pd:-0}" != "0" || \
				"${uc:-0}" != "0" || "$hs" == "FAILED" ]]; then
							local rc pc ucc
							[[ "${rl:-0}" != "0" ]] && rc="$FG_BRED"    || rc="$DIM"
							[[ "${pd:-0}" != "0" ]] && pc="$FG_BYELLOW" || pc="$DIM"
							[[ "${uc:-0}" != "0" ]] && ucc="$FG_BRED"   || ucc="$DIM"
							errs=" $(printf '%-10s' '')  ⚠  ${rc}Reallocated: ${rl:-0}${RESET}   ${pc}Pending: ${pd:-0}${RESET}   ${ucc}Uncorrectable: ${uc:-0}${RESET}"
			fi
		else
			hs='?'; hc="$DIM"   # no output — likely not root
			fi
		fi

		_line1+=( " ${FG_BWHITE}$(printf '%-10s' "$devname")${RESET}  ${hc}$(printf '%-8s' "$hs")${RESET}${temps}${io_col}${mdls}" )
		_line2+=( "$errs" )

	done <<< "$all_devs"

	_DISK_PREV_TS="$_NOW"

	# ── Render ────────────────────────────────────────────────────────────────
	local n=${#_line1[@]}
	inner_rule dash

	if (( n == 0 )); then
		box_line "   ${DIM}No drives found${RESET}"
	elif (( INNER_WIDTH >= 140 )); then
		# Two-column grid: drives paired left/right, one band per pair
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

	while IFS= read -r line; do
		[[ "$line" =~ ^Mounted ]] && continue

		local mp sz_k used_k avail_k pct_str fstype
		read -r mp sz_k used_k avail_k pct_str fstype <<< "$line"

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

			local bar; bar=$(pct_bar "$pct" 12)

			_vols+=( " ${FG_BWHITE}$(printf '%-20s' "$mp")${RESET}  ${DIM}$(printf '%-6s' "$fstype")${RESET}  ${bar}  ${pct_col}$(printf '%3d' "$pct")%${RESET}  ${FG_WHITE}$(fmt_bytes "$used_b")${RESET}${DIM}/${RESET}${FG_WHITE}$(fmt_bytes "$sz_b")${RESET}" )

		done <<< "$df_out"

		inner_rule dash
		local n=${#_vols[@]}

		if (( n == 0 )); then
			box_line "   ${DIM}No real filesystems found${RESET}"
		elif (( INNER_WIDTH >= 140 )); then
			local i=0
			while (( i < n )); do
				local j=$(( i + 1 ))
				local l="${_vols[$i]}" r=''
				(( j < n )) && r="${_vols[$j]}"
				two_col_row "$l" "$r"
				i=$(( i + 2 ))
			done
		else
			local v
			for v in "${_vols[@]}"; do box_line "$v"; done
		fi

		box_blank
	}

# =============================================================================
# ── NFS ───────────────────────────────────────────────────────────────────────
# =============================================================================
section_nfs() {
	section_header "NFS" "NFS Kernel Server" "📂"

	local svc='nfs-server'   # systemd unit name on Debian (pkg: nfs-kernel-server)
	svc_fetch "$svc"
	local nfs_active="$_SVC_ACTIVE"
	local nfs_badge nfs_enabled nfs_uptime
	nfs_badge=$(svc_status_badge)
	nfs_enabled=$(svc_enabled_badge)
	nfs_uptime=$(svc_uptime "$_NOW")

	svc_fetch 'rpcbind'
	local rpc_badge rpc_enabled
	rpc_badge=$(svc_status_badge)
	rpc_enabled=$(svc_enabled_badge)

	two_col_row " ${nfs_badge}  ${DIM}Boot:${RESET} ${nfs_enabled}  ${DIM}Up:${RESET} ${nfs_uptime}" " ${DIM}rpcbind:${RESET}  ${rpc_badge}  ${DIM}Boot:${RESET} ${rpc_enabled}"

	# ── Exports ───────────────────────────────────────────────────────────────
	inner_rule dash
	if command -v exportfs &>/dev/null; then
		local exports_raw
		exports_raw=$(exportfs -v 2>/dev/null)
		if [[ -n "$exports_raw" ]]; then
			local export_count
			export_count=$(grep -c '^/' <<< "$exports_raw" 2>/dev/null || printf '0')
			kv_line "Exports     " "${FG_BWHITE}${export_count}${RESET}  ${DIM}active${RESET}"
			local _xre='^(/[^[:space:]]+)[[:space:]]+([^(]+)'
			local -a _exp_lines=()
			while IFS= read -r xline; do
				[[ "$xline" =~ $_xre ]] || continue
				local xpath="${BASH_REMATCH[1]}"
				local xclient="${BASH_REMATCH[2]%% }"   # trim trailing space
				_exp_lines+=( " ${FG_BWHITE}${xpath}${RESET}  ${DIM}→  ${xclient}${RESET}" )
			done < <(grep '^/' <<< "$exports_raw")
			local _ne=${#_exp_lines[@]}
			if (( INNER_WIDTH >= 140 && _ne > 0 )); then
				local _ei=0
				while (( _ei < _ne )); do
					two_col_row "${_exp_lines[$_ei]}" "${_exp_lines[$((_ei+1))]:-}"
					_ei=$(( _ei + 2 ))
				done
			else
				local _el
				for _el in "${_exp_lines[@]}"; do box_line "$_el"; done
			fi
		else
			kv_line "Exports     " "${DIM}none (or exportfs requires root)${RESET}"
		fi
	else
		kv_line "Exports     " "${DIM}exportfs not found${RESET}"
	fi

	# ── Active client mounts ──────────────────────────────────────────────────
	if command -v showmount &>/dev/null && [[ "$nfs_active" == "active" ]]; then
		local mounts_raw
		mounts_raw=$(showmount -a --no-headers 2>/dev/null)
		if [[ -n "$mounts_raw" ]]; then
			local client_count
			client_count=$(awk -F: '{print $1}' <<< "$mounts_raw" | sort -u | wc -l)
			kv_line "Clients     " "${FG_BWHITE}${client_count}${RESET}  ${DIM}unique host(s) with active mounts${RESET}"
		fi
	fi

	# ── Server I/O and RPC stats from /proc ───────────────────────────────────
	local nfsd_rpc='/proc/net/rpc/nfsd'
	if [[ -r "$nfsd_rpc" ]]; then
		inner_rule dash
		local io_r io_w net_tcp rpc_calls th_count
		eval "$(awk '
		/^io /  { printf "io_r=\"%s\"\nio_w=\"%s\"\n",     $2, $3 }
		/^net / { printf "net_tcp=\"%s\"\n",                $4 }
		/^rpc / { printf "rpc_calls=\"%s\"\n",              $2 }
		/^th /  { printf "th_count=\"%s\"\n",               $2 }
		' "$nfsd_rpc")"

		kv_line "RPC calls   " "${FG_BWHITE}${rpc_calls:-0}${RESET}  ${DIM}threads: ${th_count:-?}   TCP conn: ${net_tcp:-0}${RESET}"
		kv_line "I/O (total) " "Read: ${FG_BWHITE}$(fmt_bytes "${io_r:-0}")${RESET}   Write: ${FG_BWHITE}$(fmt_bytes "${io_w:-0}")${RESET}  ${DIM}since mount${RESET}"
	fi

	box_blank
}

# =============================================================================
# ── SAMBA ─────────────────────────────────────────────────────────────────────
# =============================================================================
section_samba() {
	section_header "SAMBA" "SMB/CIFS File Server" "🖧"

	svc_fetch 'smbd'
	kv_line "smbd   " "$(svc_status_badge)  Boot: $(svc_enabled_badge)"

	# nmbd and winbind are optional — only show if the unit file exists
	if systemctl cat nmbd.service &>/dev/null 2>&1; then
		svc_fetch 'nmbd'
		kv_line "nmbd   " "$(svc_status_badge)  Boot: $(svc_enabled_badge)"
	fi
	if systemctl cat winbind.service &>/dev/null 2>&1; then
		svc_fetch 'winbind'
		kv_line "winbind" "$(svc_status_badge)  Boot: $(svc_enabled_badge)"
	fi

	# ── Active sessions ───────────────────────────────────────────────────────
	inner_rule dash
	if command -v smbstatus &>/dev/null; then
		local smb_brief
		smb_brief=$(smbstatus --brief 2>/dev/null)
		if [[ -n "$smb_brief" ]]; then
			# Session lines begin with a PID (digit)
			local session_count
			session_count=$(awk '/^[0-9]/{c++} END{print c+0}' <<< "$smb_brief")
			kv_line "Sessions    " "${FG_BWHITE}${session_count}${RESET}  ${DIM}active${RESET}"
			if (( session_count > 0 )); then
				while IFS= read -r sline; do
					[[ "$sline" =~ ^[0-9] ]] || continue
					local s_user s_machine s_ip
					# columns: pid username group machine(ip)
					read -r _ s_user _ s_machine _ <<< "$sline"
					# strip trailing parenthesized IP from machine field if present
					s_ip=$(grep -oP '\d+\.\d+\.\d+\.\d+' <<< "$sline" | head -1)
					box_line "      ${FG_WHITE}${s_user}${RESET}  ${DIM}@  ${s_machine%%(*}${s_ip:+(${s_ip})}${RESET}"
				done <<< "$smb_brief"
			fi
		else
			kv_line "Sessions    " "${DIM}smbstatus requires root${RESET}"
		fi

		# Open share connections
		local smb_shares
		smb_shares=$(smbstatus --shares 2>/dev/null)
		if [[ -n "$smb_shares" ]]; then
			local share_count
			share_count=$(awk '/^[[:alnum:]]/ && !/^Service/{c++} END{print c+0}' <<< "$smb_shares")
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

	local any_shown=false

	# /proc/net/dev columns: rx: bytes packets errors drop fifo frame compressed multicast
	#                        tx: bytes packets errors drop ...
	local _net_re='^([^:]+):[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)'
	while IFS= read -r line; do
		# Strip leading whitespace; skip header lines and loopback
		line="${line#"${line%%[![:space:]]*}"}"
		[[ "$line" =~ ^lo: ]] && continue
		[[ "$line" =~ $_net_re ]] || continue

		local iface="${BASH_REMATCH[1]}"
		local rx_bytes="${BASH_REMATCH[2]}"  rx_pkts="${BASH_REMATCH[3]}"
		local rx_err="${BASH_REMATCH[4]}"    rx_drop="${BASH_REMATCH[5]}"
		local tx_bytes="${BASH_REMATCH[6]}"  tx_pkts="${BASH_REMATCH[7]}"
		local tx_err="${BASH_REMATCH[8]}"    tx_drop="${BASH_REMATCH[9]}"

		# Read operstate from sysfs
		local operstate link_col
		operstate=$(< "/sys/class/net/${iface}/operstate" 2>/dev/null) || operstate='unknown'
		case "$operstate" in
			up)      link_col="$FG_BGREEN"  ;;
			down)    link_col="$FG_BRED"    ;;
			*)       link_col="$FG_YELLOW"  ;;
		esac

		# Skip completely idle interfaces — zero I/O in both directions since boot
		# means the port is unused. Active ports always accumulate at least ARP traffic.
		[[ "$rx_bytes" == "0" && "$tx_bytes" == "0" ]] && continue

		inner_rule dash
		any_shown=true

		# Speed / duplex
		local speed duplex speed_str=''
		speed=$(< "/sys/class/net/${iface}/speed" 2>/dev/null) || speed=''
		duplex=$(< "/sys/class/net/${iface}/duplex" 2>/dev/null) || duplex=''
		if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then
			if (( speed >= 1000 )); then
				speed_str="  ${FG_BWHITE}$(( speed / 1000 )) Gbps${RESET}${duplex:+  ${DIM}${duplex}${RESET}}"
			else
				speed_str="  ${FG_WHITE}${speed} Mbps${RESET}${duplex:+  ${DIM}${duplex}${RESET}}"
			fi
		fi

		# IP addresses (brief format: state + addresses)
		local ip_str
		ip_str=$(ip -br addr show dev "$iface" 2>/dev/null \
			| awk '{for(i=3;i<=NF;i++) printf "%s  ",$i}' \
			| sed 's/[[:space:]]*$//')

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
			local rrx rtx
			rrx=$(fmt_rate $(( delta_rx / elapsed )))
			rtx=$(fmt_rate $(( delta_tx / elapsed )))
			box_line "      ↓ ${FG_BGREEN}$(printf '%-14s' "$rrx")${RESET}  ↑ ${FG_BYELLOW}$(printf '%-14s' "$rtx")${RESET}  ${DIM}tot ↓${RESET} ${FG_WHITE}$(printf '%-12s' "$(fmt_bytes "$rx_bytes")")${RESET}  ${DIM}↑${RESET} ${FG_WHITE}$(fmt_bytes "$tx_bytes")${RESET}  ${DIM}since boot${RESET}"
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

	done < <(tail -n +3 "$net_dev")

	# Advance timestamp after processing all interfaces
	_NET_PREV_TS="$_NOW"

	[[ "$any_shown" == "false" ]] && { inner_rule dash; box_line "   ${DIM}No active interfaces found${RESET}"; }

	box_blank
}

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================

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
			_BUF=''
		}

		draw_dashboard() {
			_BUF=''
			local ts
			read -r _NOW ts < <(date '+%s %A %d %B %Y  %H:%M:%S %Z')
			local nice_disp; printf -v nice_disp '%+d' "$NICE_VALUE"

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

															local _nl="${_BUF//[^$'\n']/}"
															_FOOTER_ROW=$(( 1 + ${#_nl} ))

															if [[ "$PAUSED" == "true" ]]; then
																box_line "   ${FG_YELLOW}${BOLD}⏸  PAUSED${RESET}  ${DIM}Last: ${LAST_REFRESH}   Nice: ${nice_disp}   p resume · r refresh · i interval · n nice · h help · q quit${RESET}"
															else
																box_line "   ${DIM}Refresh: ${RESET}${FG_BWHITE}${REFRESH_INTERVAL}s${RESET}  ${DIM}Nice: ${RESET}${FG_BWHITE}${nice_disp}${RESET}  ${DIM}Last: ${LAST_REFRESH}   p pause · r refresh · i interval · n nice · h help · q quit${RESET}"
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

														cleanup() {
															printf '\033[?25h\033[?1049l'
															[[ -n "$_TTY_STATE" ]] && stty "$_TTY_STATE" 2>/dev/null || stty echo 2>/dev/null
															exit 0
														}
														trap cleanup INT TERM

														trap '_NEED_REDRAW=true
														TERM_WIDTH=$(tput cols 2>/dev/null || printf "%s" "${COLUMNS:-80}")
														INNER_WIDTH=$(( TERM_WIDTH - 2 ))
														rebuild_fills' WINCH

														do_draw() {
															printf '\033[H'
															outer_top
															printf '%s' "$_BUF"
															outer_bottom
															printf '\033[J'
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

															printf '\033[?1049h\033[?25l'

															_TTY_STATE=$(stty -g 2>/dev/null)
															stty -echo 2>/dev/null

															sync_dimensions
															draw_loading

															_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')

															local force_refresh=true
															local key=''

															while true; do
																sync_dimensions

																if [[ "$PAUSED" == "false" || "$force_refresh" == "true" || "$_NEED_REDRAW" == "true" ]]; then
																	[[ -n "$_BUF" ]] && { printf '\033[H'; outer_top; printf '%s' "$_BUF"; outer_bottom; printf '\033[J'; }

																	[[ "$PAUSED" == "false" || "$force_refresh" == "true" ]] \
																		&& printf -v LAST_REFRESH '%(%H:%M:%S)T' -1
																																			force_refresh=false
																																			_NEED_REDRAW=false
																																			draw_dashboard
																																			do_draw
																fi

																key=''
																if [[ "$PAUSED" == "true" ]]; then
																	IFS= read -r -s -n 1 key 2>/dev/null || true
																else
																	IFS= read -r -s -n 1 -t "$REFRESH_INTERVAL" key 2>/dev/null || true
																fi

																if [[ "$key" == $'\033' ]]; then
																	local _seq=''
																	IFS= read -r -s -n 4 -t 0.05 _seq 2>/dev/null || true
																fi

																case "$key" in
																	$'\003'|q|Q) cleanup ;;   # Ctrl+C or q

																	p|P)
																		[[ "$PAUSED" == "true" ]] && PAUSED=false || PAUSED=true
																		force_refresh=true ;;

																	r|R)
																		PAUSED=false; force_refresh=true ;;

																	i|I)
																		prompt_input 'interval'
																		draw_footer_row
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
