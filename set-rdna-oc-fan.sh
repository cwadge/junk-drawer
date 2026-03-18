#!/bin/bash
set -euo pipefail

# Configuration file path
CONFIG_FILE="/etc/set-rdna-oc-fan.conf"
SYSFS_TIMEOUT=5
MAX_WAIT=30
WAIT_INTERVAL=1

# Known RDNA GPU PCI IDs
# RDNA1/2: sourced from kernel amdgpu_drv.c pciidlist (explicit CHIP_* entries)
# RDNA3/4: sourced from /usr/share/libdrm/amdgpu.ids and hardware probes
#           (kernel uses IP Discovery wildcard matching for these generations)
RDNA1_IDS=(
	# Navi 10: RX 5700 XT/5700/5600 XT/5600/5500 XT/5500/5300 and workstation variants
	"1002:7310" "1002:7312" "1002:7318" "1002:7319" "1002:731A" "1002:731B" "1002:731E" "1002:731F"
	# Navi 14: RX 5500 XT/5500/5300 XT/5300 and workstation variants
	"1002:7340" "1002:7341" "1002:7347" "1002:734F"
	# Navi 12: RX 5600M and Pro 5600M
	"1002:7360" "1002:7362"
)
RDNA2_IDS=(
	# Navi 21: RX 6900 XT/6800 XT/6800, Pro W6900X/W6800/W6800X/W6800X Duo and variants
	"1002:73A0" "1002:73A1" "1002:73A2" "1002:73A3" "1002:73A5" "1002:73A8" "1002:73A9"
	"1002:73AB" "1002:73AC" "1002:73AD" "1002:73AE" "1002:73AF" "1002:73BF"
	# Navi 22: RX 6700 XT/6700/6750 XT and Pro variants
	"1002:73C0" "1002:73C1" "1002:73C3"
	# Navi 22 (cont.): Navy Flounder mobile/OEM variants
	"1002:73DA" "1002:73DB" "1002:73DC" "1002:73DD" "1002:73DE" "1002:73DF"
	# Navi 23: RX 6600 XT/6600/6650 XT and Pro W6600 variants
	"1002:73E0" "1002:73E1" "1002:73E3"
	# Navi 23 (cont.): Dimgrey Cavefish mobile/OEM variants
	"1002:73E8" "1002:73E9" "1002:73EA" "1002:73EB" "1002:73EC" "1002:73ED" "1002:73EF" "1002:73FF"
	# Navi 24: RX 6500 XT/6400 and Pro W6400 variants
	"1002:7420" "1002:7421" "1002:7422" "1002:7423" "1002:7424" "1002:743F"
)
RDNA3_IDS=(
	# Navi 31: RX 7900 XTX/XT/GRE, Pro W7900, Pro W7900 Dual Slot
	"1002:7448" "1002:744A" "1002:744C" "1002:745E"
	# Navi 32: RX 7900M, RX 7800 XT, RX 7700 XT, RX 7700, Pro W7700
	"1002:7460" "1002:7461" "1002:7470" "1002:747E"
	# Navi 33: Pro W7600/RX 7600 XT/7600/7700S/7600S/7600M XT (7480, multi-SKU via revision byte),
	#          RX 7600M (7483), Pro W7500 (7489)
	"1002:7480" "1002:7483" "1002:7489"
)
RDNA4_IDS=(
	# Navi 48: RX 9070 XT (7550), RX 9070 (7578); remaining IDs are tentative
	"1002:7550"
	"1002:7572" "1002:7573" "1002:7578" "1002:7579" "1002:7590"
)

# Modes
DEBUG_MODE=0
DRY_RUN_MODE=0
RESET_MODE=0
CREATE_CONFIG_MODE=0
CREATE_CONFIG_INTERACTIVE_MODE=0
STATUS_MODE=0
CARD_INDEX=0

# Color codes
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# Info/status output goes to stdout; errors go to stderr.
color_echo() {
	local color="$1"
	shift
	if [[ -t 1 ]]; then
		echo -e "${color}$*${COLOR_RESET}"
	else
		echo "$*"
	fi
}

error_echo() {
	local color="$1"
	shift
	if [[ -t 2 ]]; then
		echo -e "${color}$*${COLOR_RESET}" >&2
	else
		echo "$*" >&2
	fi
}

# Check if a sysfs path is writable
check_writable() {
	local path="$1"
	[[ -w "$path" ]] || { error_echo "$COLOR_RED" "Error: $path not writable"; exit 1; }
}

# Display usage information and available options
print_help() {
	color_echo "$COLOR_CYAN" "Usage: $0 [OPTIONS]"
	color_echo "$COLOR_CYAN" "Options:"
	color_echo "$COLOR_CYAN" "  -h, --help                   Display this help message"
	color_echo "$COLOR_CYAN" "  --card N                     Target the Nth AMDGPU card (default: 0)"
	color_echo "$COLOR_CYAN" "  --debug                      Enable verbose shell tracing"
	color_echo "$COLOR_CYAN" "  --dry-run                    Print settings without applying them"
	color_echo "$COLOR_CYAN" "  --reset                      Reset GPU to default settings"
	color_echo "$COLOR_CYAN" "  --create-config              Create config file with hardware defaults"
	color_echo "$COLOR_CYAN" "  --create-config-interactive  Interactively create config file with hardware defaults"
	color_echo "$COLOR_CYAN" "  --status                     Display current GPU settings from hardware"
	color_echo "$COLOR_CYAN" "Config file: $CONFIG_FILE"
	exit 0
}

# Parse command-line arguments to set operational modes
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) print_help ;;
		--card)
			[[ -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: --card requires a non-negative integer"; exit 1; }
			CARD_INDEX="$2"; shift ;;
		--debug) DEBUG_MODE=1 ;;
		--dry-run) DRY_RUN_MODE=1 ;;
		--reset) RESET_MODE=1 ;;
		--create-config) CREATE_CONFIG_MODE=1 ;;
		--create-config-interactive) CREATE_CONFIG_INTERACTIVE_MODE=1 ;;
		--status) STATUS_MODE=1 ;;
		*) error_echo "$COLOR_RED" "Unknown option: $1"; print_help ;;
	esac
	shift
done

[[ "$DEBUG_MODE" -eq 1 ]] && set -x

# Check if the script is running interactively (connected to a terminal)
is_interactive() {
	[[ -t 0 && -t 1 ]]
}

# Restore power profile to auto on unexpected exit to avoid leaving GPU in manual mode
_POWER_PROFILE_PATH_FOR_TRAP=""
cleanup_trap() {
	local exit_code=$?
	if [[ $exit_code -ne 0 && -n "$_POWER_PROFILE_PATH_FOR_TRAP" && -w "$_POWER_PROFILE_PATH_FOR_TRAP" ]]; then
		echo "auto" > "$_POWER_PROFILE_PATH_FOR_TRAP" 2>/dev/null || true
	fi
}
trap cleanup_trap EXIT

# Locate AMD GPU sysfs paths for hardware control and verify mandatory path availability.
# Fan OD paths (fan_curve, fan_zero_rpm_enable) are located here but not required;
# check_fan_paths() verifies and gates them after RDNA generation is known.
find_card_paths() {
	CARD_PATH=""
	local found=0
	for card in /sys/class/drm/card*/device; do
		[[ -d "$card" ]] || continue
		[[ -f "$card/uevent" ]] || continue
		timeout "$SYSFS_TIMEOUT" grep -qi "DRIVER=amdgpu" "$card/uevent" || continue
		if [[ "$found" -eq "$CARD_INDEX" ]]; then
			CARD_PATH="$card"
			break
		fi
		found=$((found + 1))
	done
	[[ -z "$CARD_PATH" ]] && { error_echo "$COLOR_RED" "Error: No AMDGPU card found at index $CARD_INDEX"; exit 1; }

	HWMON_PATH=""
	for dir in "${CARD_PATH}/hwmon/hwmon"*/; do
		if [[ -f "$dir/name" ]] && [[ "$(timeout "$SYSFS_TIMEOUT" cat "$dir/name" 2>/dev/null)" == "amdgpu" ]]; then
			HWMON_PATH="${dir%/}"
			break
		fi
	done
	[[ -z "$HWMON_PATH" ]] && { error_echo "$COLOR_RED" "Error: No hwmon path found"; exit 1; }

	FAN_CURVE_PATH="${CARD_PATH}/gpu_od/fan_ctrl/fan_curve"
	ZERO_RPM_PATH="${CARD_PATH}/gpu_od/fan_ctrl/fan_zero_rpm_enable"
	PP_OD_PATH="${CARD_PATH}/pp_od_clk_voltage"
	POWER_CAP_PATH="${HWMON_PATH}/power1_cap"
	POWER_CAP_MAX_PATH="${HWMON_PATH}/power1_cap_max"
	POWER_CAP_DEFAULT_PATH="${HWMON_PATH}/power1_cap_default"
	POWER_PROFILE_PATH="${CARD_PATH}/power_dpm_force_performance_level"
	# Arm the exit trap once the path is known
	_POWER_PROFILE_PATH_FOR_TRAP="$POWER_PROFILE_PATH"

	# Wait for and verify mandatory sysfs paths
	local elapsed=0
	local mandatory_paths=("$PP_OD_PATH" "$POWER_CAP_PATH" "$POWER_PROFILE_PATH" "$POWER_CAP_DEFAULT_PATH")
	while [[ $elapsed -lt $MAX_WAIT ]]; do
		local all_present=true
		for f in "${mandatory_paths[@]}"; do
			[[ ! -f "$f" ]] && all_present=false && break
		done
		[[ "$all_present" == true ]] && break
		color_echo "$COLOR_YELLOW" "Waiting for sysfs paths to be available... ($elapsed/$MAX_WAIT seconds)"
		sleep "$WAIT_INTERVAL"
		elapsed=$((elapsed + WAIT_INTERVAL))
	done
	for f in "${mandatory_paths[@]}"; do
		if [[ ! -f "$f" ]]; then
			error_echo "$COLOR_RED" "Error: $f not found after ${MAX_WAIT}s"
			exit 1
		fi
	done

	# Verify writable mandatory paths (POWER_CAP_DEFAULT_PATH is read-only by design)
	for f in "$PP_OD_PATH" "$POWER_CAP_PATH" "$POWER_PROFILE_PATH"; do
		check_writable "$f"
	done
}

# Verify overdrive is actually enabled by confirming pp_od_clk_voltage contains OD data.
# The file is always present and writable regardless of ppfeaturemask; writes silently
# do nothing if the overdrive feature bit is not set.
check_overdrive() {
	check_writable "$PP_OD_PATH"
	local od_content
	od_content=$(timeout "$SYSFS_TIMEOUT" cat "$PP_OD_PATH" 2>/dev/null | tr -d '\0' || true)
	if [[ -z "$od_content" ]] || ! grep -qiE "OD_SCLK|OD_RANGE|OD_SCLK_OFFSET" <<< "$od_content"; then
		error_echo "$COLOR_RED" "Error: pp_od_clk_voltage is writable but contains no OD data."
		error_echo "$COLOR_RED" "Ensure overdrive is enabled in amdgpu.ppfeaturemask (e.g. amdgpu.ppfeaturemask=0xfffd7fff)."
		exit 1
	fi
}

# Detect RDNA generation based on PCI ID.
# PSTATE_MAX is only meaningful for RDNA1 (8 pstates, 0-7).
# RDNA2/3 use it only as a grep context line count; RDNA4 does not use it.
detect_rdna_gen() {
	PCI_ID=$(timeout "$SYSFS_TIMEOUT" grep PCI_ID "$CARD_PATH/uevent" | cut -d'=' -f2)
	SUPPORTS_VOLTAGE_OFFSET=0
	PSTATE_MAX=0
	if [[ " ${RDNA1_IDS[*]} " == *" $PCI_ID "* ]]; then
		RDNA_GEN=1
		PSTATE_MAX=7
		SUPPORTS_VOLTAGE_OFFSET=0
	elif [[ " ${RDNA2_IDS[*]} " == *" $PCI_ID "* ]]; then
		RDNA_GEN=2
		PSTATE_MAX=2
		SUPPORTS_VOLTAGE_OFFSET=1
	elif [[ " ${RDNA3_IDS[*]} " == *" $PCI_ID "* ]]; then
		RDNA_GEN=3
		PSTATE_MAX=2
		SUPPORTS_VOLTAGE_OFFSET=1
	elif [[ " ${RDNA4_IDS[*]} " == *" $PCI_ID "* ]]; then
		RDNA_GEN=4
		SUPPORTS_VOLTAGE_OFFSET=1
	else
		error_echo "$COLOR_RED" "Error: Unknown AMD GPU (PCI ID: $PCI_ID)"
		exit 1
	fi
	local volt_str="Not available (RDNA1)"
	[[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]] && volt_str="Available"
	color_echo "$COLOR_GREEN" "Detected RDNA${RDNA_GEN} (PCI ID: $PCI_ID, voltage offset: $volt_str)"
}

# Verify fan OD sysfs paths and set FAN_OD_AVAILABLE.
# Called after detect_rdna_gen so RDNA_GEN is known.
# For RDNA4, fan OD may not yet be exposed by the driver; treated as a warning, not a fatal error.
# For all other generations, missing fan paths are fatal.
check_fan_paths() {
	FAN_OD_AVAILABLE=0
	# RDNA4 driver support for fan OD is still maturing; use a short wait
	local fan_wait=$MAX_WAIT
	[[ "$RDNA_GEN" == "4" ]] && fan_wait=5

	local elapsed=0
	while [[ $elapsed -lt $fan_wait ]]; do
		[[ -f "$FAN_CURVE_PATH" && -f "$ZERO_RPM_PATH" ]] && break
		color_echo "$COLOR_YELLOW" "Waiting for fan OD sysfs paths... ($elapsed/${fan_wait}s)"
		sleep "$WAIT_INTERVAL"
		elapsed=$((elapsed + WAIT_INTERVAL))
	done

	if [[ -f "$FAN_CURVE_PATH" && -f "$ZERO_RPM_PATH" ]]; then
		if [[ -w "$FAN_CURVE_PATH" && -w "$ZERO_RPM_PATH" ]]; then
			FAN_OD_AVAILABLE=1
			color_echo "$COLOR_GREEN" "Fan OD control available"
		else
			color_echo "$COLOR_YELLOW" "Warning: Fan OD paths exist but are not writable; fan control disabled"
		fi
	else
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_YELLOW" "Warning: Fan OD sysfs paths not found for RDNA4 after ${fan_wait}s; fan control unavailable (driver support may be incomplete)"
		else
			error_echo "$COLOR_RED" "Error: Fan OD sysfs paths not found after ${MAX_WAIT}s"
			exit 1
		fi
	fi
}

# Validate PCI ID against config file, with mode-specific behavior
check_pci_id() {
	local mode="$1"
	if [[ -f "$CONFIG_FILE" ]]; then
		# Only extract EXPECTED_PCI_ID to avoid clobbering globals before load_config
		local config_pci_id
		config_pci_id=$(grep -oP '^EXPECTED_PCI_ID="\K[^"]+' "$CONFIG_FILE" 2>/dev/null || true)
		if [[ -n "$config_pci_id" && "$config_pci_id" != "$PCI_ID" ]]; then
			if [[ "$mode" == "apply" && ! -t 0 ]]; then
				error_echo "$COLOR_RED" "Error: PCI ID mismatch (Config: $config_pci_id, Detected: $PCI_ID) in non-interactive mode"
				exit 1
			elif [[ "$mode" == "apply" ]]; then
				color_echo "$COLOR_YELLOW" "Warning: PCI ID mismatch (Config: $config_pci_id, Detected: $PCI_ID). Proceeding with interactive confirmation."
				read -rp "Continue with detected GPU? [y/N]: " confirm
				[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { error_echo "$COLOR_RED" "Aborted due to PCI ID mismatch"; exit 1; }
			elif [[ "$mode" == "reset" || "$mode" == "status" ]]; then
				color_echo "$COLOR_YELLOW" "Warning: PCI ID mismatch (Config: $config_pci_id, Detected: $PCI_ID; not applying profile)."
			fi
		fi
	fi
}

# Read hardware default settings directly from sysfs.
# On RDNA4 the OD subsystem is unified: echo "r" > pp_od_clk_voltage resets ALL OD
# staging including fan_curve and fan_zero_rpm_enable. We therefore snapshot the current
# committed state of all three files BEFORE the reset, and expose those snapshots as
# globals so print_status can read current values without re-reading stale staging.
read_hardware_defaults() {
	# Snapshot current committed OD state before the staging reset wipes it
	PP_OD_SNAPSHOT=$(timeout "$SYSFS_TIMEOUT" cat "${PP_OD_PATH}" 2>/dev/null | tr -d '\0' || true)
	FAN_CURVE_SNAPSHOT=""
	ZERO_RPM_SNAPSHOT=""
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		FAN_CURVE_SNAPSHOT=$(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' || true)
		ZERO_RPM_SNAPSHOT=$(timeout "$SYSFS_TIMEOUT" cat "${ZERO_RPM_PATH}" 2>/dev/null | tr -d '\0' || true)
	fi

	if [[ -w "$PP_OD_PATH" ]]; then
		echo "r" > "$PP_OD_PATH" 2>/dev/null || color_echo "$COLOR_YELLOW" "Warning: Failed to reset pp_od_clk_voltage staging area"
	fi
	local pp_od_data=""
	pp_od_data=$(timeout "$SYSFS_TIMEOUT" cat "${PP_OD_PATH}" 2>/dev/null | tr -d '\0' || true)
	if [[ "$DEBUG_MODE" -eq 1 ]]; then
		color_echo "$COLOR_CYAN" "Raw pp_od_clk_voltage content (factory defaults):"
		echo "$pp_od_data"
	fi

	# Initialize variables for GPU settings
	SCLK_DEFAULT=0
	SCLK_OFFSET_DEFAULT=0
	MCLK_DEFAULT=0
	SCLK_MIN=0
	SCLK_MAX=0
	MCLK_MIN=0
	MCLK_MAX=0
	VDDGFX_OFFSET_DEFAULT=0
	VDDGFX_OFFSET_MIN=0
	VDDGFX_OFFSET_MAX=0
	SCLK_PSTATES=()
	POWER_CAP_MAX=0
	POWER_CAP_DEFAULT=0
	ZERO_RPM_DEFAULT=0
	FAN_CURVE=()
	TEMP_MIN=25
	TEMP_MAX=110
	SPEED_MIN=15
	SPEED_MAX=100

	# Parse clock settings based on RDNA generation
	if [[ -n "$pp_od_data" ]]; then
		if [[ "$RDNA_GEN" == "4" ]]; then
			# GFX12 uses an offset-based SCLK OD API rather than absolute pstate frequencies.
			# MCLK OD availability on RDNA4/GDDR6 is unverified; parsed the same way as RDNA2/3
			# and a high fallback is used to avoid silently writing a destructively low value.
			SCLK_OFFSET_DEFAULT=$(echo "$pp_od_data" | awk '/OD_SCLK_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Hh][zZ]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || true)
			SCLK_OFFSET_DEFAULT=${SCLK_OFFSET_DEFAULT:-0}
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed SCLK_OFFSET_DEFAULT=$SCLK_OFFSET_DEFAULT"
			SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK_OFFSET:.*[Mm][Hh][zZ]" | grep -o "[0-9-]\+" | head -n 1 || true)
			SCLK_MIN=${SCLK_MIN:--500}
			SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK_OFFSET:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
			SCLK_MAX=${SCLK_MAX:-1000}
			MCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
			if [[ -z "$MCLK_DEFAULT" ]]; then
				# RDNA4 GDDR6 runs ~2800 MHz; a low fallback could cause a destructive clock write
				color_echo "$COLOR_YELLOW" "Warning: Failed to parse MCLK_DEFAULT from pp_od_clk_voltage; using fallback 2800 MHz"
				MCLK_DEFAULT=2800
			fi
			MCLK_MIN=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || true)
			MCLK_MIN=${MCLK_MIN:-97}
			MCLK_MAX=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
			MCLK_MAX=${MCLK_MAX:-$MCLK_DEFAULT}
		else
			if [[ "$RDNA_GEN" == "1" ]]; then
				local i
				for ((i=0; i<=PSTATE_MAX; i++)); do
					local pstate_val
					pstate_val=$(echo "$pp_od_data" | grep -A$((PSTATE_MAX+1)) "OD_SCLK" | grep -i "$i:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
					pstate_val=${pstate_val:-0}
					SCLK_PSTATES+=("$pstate_val")
					[[ "$i" -eq 1 ]] && SCLK_DEFAULT="$pstate_val"
				done
				SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || true)
				SCLK_MIN=${SCLK_MIN:-255}
				SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
				SCLK_MAX=${SCLK_MAX:-3000}
			else
				SCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_SCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
				SCLK_DEFAULT=${SCLK_DEFAULT:-3000}
				SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || true)
				SCLK_MIN=${SCLK_MIN:-255}
				SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
				SCLK_MAX=${SCLK_MAX:-3000}
				SCLK_PSTATES=(0 "$SCLK_DEFAULT")
			fi
			MCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
			MCLK_DEFAULT=${MCLK_DEFAULT:-1200}
			MCLK_MIN=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || true)
			MCLK_MIN=${MCLK_MIN:-97}
			MCLK_MAX=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || true)
			MCLK_MAX=${MCLK_MAX:-1200}
		fi

		# Parse voltage offset settings for RDNA2+ if supported
		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
			VDDGFX_OFFSET_DEFAULT=$(echo "$pp_od_data" | awk '/OD_VDDGFX_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Vv]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || true)
			VDDGFX_OFFSET_DEFAULT=${VDDGFX_OFFSET_DEFAULT:-0}
			VDDGFX_OFFSET_MIN=$(echo "$pp_od_data" | grep -i "VDDGFX_OFFSET:.*[Mm][Vv]" | grep -o "[0-9-]\+" | head -n 1 || true)
			VDDGFX_OFFSET_MIN=${VDDGFX_OFFSET_MIN:--200}
			VDDGFX_OFFSET_MAX=$(echo "$pp_od_data" | grep -i "VDDGFX_OFFSET:.*[Mm][Vv]" | grep -o "[0-9]\+" | tail -n 1 || true)
			VDDGFX_OFFSET_MAX=${VDDGFX_OFFSET_MAX:-200}
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed VDDGFX_OFFSET_DEFAULT=$VDDGFX_OFFSET_DEFAULT (range: $VDDGFX_OFFSET_MIN to $VDDGFX_OFFSET_MAX mV)"
		fi
	else
		color_echo "$COLOR_YELLOW" "pp_od_clk_voltage is empty or unreadable, using fallback defaults"
	fi

	# Read power cap settings from hardware
	if [[ -f "${POWER_CAP_MAX_PATH}" ]]; then
		POWER_CAP_MAX=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_MAX_PATH}" 2>/dev/null | tr -d '\0' || true)
		POWER_CAP_MAX=${POWER_CAP_MAX:-0}
	fi
	if [[ -f "${POWER_CAP_DEFAULT_PATH}" ]]; then
		POWER_CAP_DEFAULT=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_DEFAULT_PATH}" 2>/dev/null | tr -d '\0' || true)
		POWER_CAP_DEFAULT=${POWER_CAP_DEFAULT:-$POWER_CAP_MAX}
	else
		POWER_CAP_DEFAULT="$POWER_CAP_MAX"
	fi
	POWER_CAP=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_PATH}" 2>/dev/null | tr -d '\0' || true)
	POWER_CAP=${POWER_CAP:-$POWER_CAP_DEFAULT}

	# fan_zero_rpm_enable is a plain integer file (0 or 1), not a structured header file
	ZERO_RPM_DEFAULT=0
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		# fan_zero_rpm_enable is a structured OD file with header + value on separate lines:
		#   FAN_ZERO_RPM_ENABLE:\n1\nOD_RANGE:\nZERO_RPM_ENABLE: 0 1
		# Use the pre-reset snapshot: the pp_od reset also wipes zero_rpm staging on RDNA4.
		local zero_rpm_raw
		zero_rpm_raw=$(awk '/^FAN_ZERO_RPM_ENABLE:/{getline; print; exit}' <<< "$ZERO_RPM_SNAPSHOT" | tr -d '[:space:]' || true)
		if [[ "$zero_rpm_raw" =~ ^[01]$ ]]; then
			ZERO_RPM_DEFAULT="$zero_rpm_raw"
		else
			color_echo "$COLOR_YELLOW" "Warning: Could not read fan_zero_rpm_enable, defaulting to 0"
		fi
	fi
	# Default to disabling zero RPM for consistent fan curve behavior
	ZERO_RPM=0

	# Read fan curve settings based on junction temperature from hardware
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		# Use the pre-reset snapshot: after echo "r" > pp_od_clk_voltage the fan_curve
		# staging is also wiped on RDNA4, so re-reading the file here gives all zeros.
		local fan_curve_data="$FAN_CURVE_SNAPSHOT"
		FAN_CURVE=()
		local invalid_curve=false has_valid_points=false
		while IFS= read -r line; do
			if [[ "$line" =~ ^[0-4]:[[:space:]]*([0-9]+)C[[:space:]]*([0-9]+)% ]]; then
				local point temp speed
				point=${line%%:*}
				temp=${BASH_REMATCH[1]}
				speed=${BASH_REMATCH[2]}
				FAN_CURVE+=("$point $temp $speed")
				has_valid_points=true
				[[ "$temp" -eq 0 || "$speed" -eq 0 ]] && invalid_curve=true
				[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed fan curve point: $point $temp $speed"
			fi
		done <<< "$fan_curve_data"
		# Parse temperature/speed range from kernel-emitted range header if present;
		# fall back to safe constants if the format varies across driver versions
		TEMP_MIN=$(echo "$fan_curve_data" | grep -i "FAN_CURVE(hotspot temp):" | grep -o "[0-9]\+" | head -n 1 || true)
		TEMP_MIN=${TEMP_MIN:-25}
		TEMP_MAX=$(echo "$fan_curve_data" | grep -i "FAN_CURVE(hotspot temp):" | grep -o "[0-9]\+" | tail -n 1 || true)
		TEMP_MAX=${TEMP_MAX:-110}
		SPEED_MIN=$(echo "$fan_curve_data" | grep -i "FAN_CURVE(fan speed):" | grep -o "[0-9]\+" | head -n 1 || true)
		SPEED_MIN=${SPEED_MIN:-15}
		SPEED_MAX=$(echo "$fan_curve_data" | grep -i "FAN_CURVE(fan speed):" | grep -o "[0-9]\+" | tail -n 1 || true)
		SPEED_MAX=${SPEED_MAX:-100}
		if [[ "$has_valid_points" == true && ${#FAN_CURVE[@]} -eq 5 && "$invalid_curve" == false ]]; then
			color_echo "$COLOR_GREEN" "Valid junction fan curve detected with ${#FAN_CURVE[@]} points"
		else
			color_echo "$COLOR_YELLOW" "No valid junction fan curve found or invalid points detected, using fallback curve"
			FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
		fi
	else
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_YELLOW" "Fan OD not available; using fallback junction curve"
		else
			color_echo "$COLOR_YELLOW" "fan_curve sysfs path not found, using fallback junction curve"
		fi
		FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
	fi
	FAN_CURVE_DEFAULT=("${FAN_CURVE[@]}")
	EXPECTED_PCI_ID=${PCI_ID:-"1002:FFFF"}
}

# Display current GPU settings directly from hardware.
# Config values are read via grep/subshell rather than sourcing the config file,
# so this function does not clobber the hardware globals set by read_hardware_defaults.
print_status() {
	local skip_config_comparison="$1"
	color_echo "$COLOR_CYAN" "=== GPU Status (PCI ID: $PCI_ID, RDNA Generation: $RDNA_GEN) ==="

	if [[ "$skip_config_comparison" != "1" ]]; then
		check_pci_id "status"
	fi

	# Use pre-reset snapshots captured by read_hardware_defaults.
	# On RDNA4 the OD subsystem is unified: re-reading pp_od_clk_voltage, fan_curve, or
	# fan_zero_rpm_enable after the staging reset would return factory defaults, not the
	# currently committed values.
	local current_sclk="" current_sclk_offset="" current_mclk="" current_power_cap="" current_zero_rpm="" current_vddgfx_offset=""
	local pp_od_data="$PP_OD_SNAPSHOT"
	if [[ "$RDNA_GEN" == "4" ]]; then
		if [[ -n "$pp_od_data" ]]; then
			current_sclk_offset=$(echo "$pp_od_data" | awk '/OD_SCLK_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Hh][zZ]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || true)
			current_sclk_offset=${current_sclk_offset:-N/A}
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Current SCLK_OFFSET parsed as: $current_sclk_offset"
		else
			current_sclk_offset="N/A"
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: pp_od_clk_voltage snapshot is empty or unreadable"
		fi
	else
		current_sclk=$(echo "$pp_od_data" | grep -A$((PSTATE_MAX+1)) "OD_SCLK" | grep -i "1:.*[Mm][Hh][zZ]" | awk '{print $2}' | grep -o "[0-9]\+" || true)
		current_sclk=${current_sclk:-N/A}
	fi
	current_mclk=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | awk '{print $2}' | grep -o "[0-9]\+" || true)
	current_mclk=${current_mclk:-N/A}

	if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
		current_vddgfx_offset=$(echo "$pp_od_data" | awk '/OD_VDDGFX_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Vv]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || true)
		current_vddgfx_offset=${current_vddgfx_offset:-N/A}
		[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Current VDDGFX_OFFSET parsed as: $current_vddgfx_offset"
	fi

	current_power_cap=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_PATH}" 2>/dev/null | tr -d '\0' || true)
	current_power_cap=${current_power_cap:-N/A}

	# Parse zero_rpm and fan curve from pre-reset snapshots
	current_zero_rpm="N/A"
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		local zero_rpm_raw
		zero_rpm_raw=$(awk '/^FAN_ZERO_RPM_ENABLE:/{getline; print; exit}' <<< "$ZERO_RPM_SNAPSHOT" | tr -d '[:space:]' || true)
		[[ "$zero_rpm_raw" =~ ^[01]$ ]] && current_zero_rpm="$zero_rpm_raw"
	fi

	local -a current_fan_curve=()
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		while IFS= read -r line; do
			if [[ "$line" =~ ^[0-4]:[[:space:]]*([0-9]+)C[[:space:]]*([0-9]+)% ]]; then
				local point temp speed
				point=${line%%:*}
				temp=${BASH_REMATCH[1]}
				speed=${BASH_REMATCH[2]}
				current_fan_curve+=("$point $temp $speed")
			fi
		done <<< "$FAN_CURVE_SNAPSHOT"
	fi

	if [[ "$skip_config_comparison" == "1" ]]; then
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_CYAN" "SCLK_OFFSET (MHz):"
			color_echo "$COLOR_GREEN" "  Current: $current_sclk_offset"
		else
			color_echo "$COLOR_CYAN" "SCLK (MHz):"
			color_echo "$COLOR_GREEN" "  Current: $current_sclk"
		fi
		color_echo "$COLOR_CYAN" "MCLK (MHz):"
		color_echo "$COLOR_GREEN" "  Current: $current_mclk"
		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
			color_echo "$COLOR_CYAN" "VDDGFX_OFFSET (mV):"
			color_echo "$COLOR_GREEN" "  Current: $current_vddgfx_offset"
		fi
		color_echo "$COLOR_CYAN" "Power Cap (W):"
		if [[ "$current_power_cap" != "N/A" ]]; then
			color_echo "$COLOR_GREEN" "  Current: $((current_power_cap / 1000000))"
		else
			color_echo "$COLOR_GREEN" "  Current: N/A"
		fi
		color_echo "$COLOR_CYAN" "Zero RPM:"
		color_echo "$COLOR_GREEN" "  Current: $current_zero_rpm"
		color_echo "$COLOR_CYAN" "Junction Fan Curve:"
		if [[ ${#current_fan_curve[@]} -eq 0 ]]; then
			color_echo "$COLOR_YELLOW" "  No valid junction fan curve points detected"
		else
			local i
			for i in "${!current_fan_curve[@]}"; do
				color_echo "$COLOR_GREEN" "  Point $i: ${current_fan_curve[i]}"
			done
		fi
	else
		# Read intended settings from config without sourcing into globals.
		# Sourcing would clobber the hardware globals set by read_hardware_defaults.
		local intended_sclk="$SCLK_DEFAULT"
		local intended_sclk_offset="$SCLK_OFFSET_DEFAULT"
		local intended_mclk="$MCLK_DEFAULT"
		local intended_power_cap="$POWER_CAP_DEFAULT"
		local intended_zero_rpm="$ZERO_RPM_DEFAULT"
		local intended_vddgfx_offset="$VDDGFX_OFFSET_DEFAULT"
		local -a intended_fan_curve=("${FAN_CURVE_DEFAULT[@]}")

		if [[ -f "$CONFIG_FILE" ]]; then
			local v
			if [[ "$RDNA_GEN" == "4" ]]; then
				v=$(grep -oP '^SCLK_OFFSET=\K-?[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)
				[[ -n "$v" ]] && intended_sclk_offset="$v"
			else
				v=$(grep -oP '^SCLK=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)
				[[ -n "$v" ]] && intended_sclk="$v"
			fi
			v=$(grep -oP '^MCLK=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)
			[[ -n "$v" ]] && intended_mclk="$v"
			v=$(grep -oP '^POWER_CAP=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)
			[[ -n "$v" ]] && intended_power_cap="$v"
			v=$(grep -oP '^ZERO_RPM=\K[01]' "$CONFIG_FILE" 2>/dev/null || true)
			[[ -n "$v" ]] && intended_zero_rpm="$v"
			if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
				v=$(grep -oP '^VDDGFX_OFFSET=\K-?[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)
				[[ -n "$v" ]] && intended_vddgfx_offset="$v"
			fi
			# FAN_CURVE is a bash array; read it in a subshell to avoid clobbering globals
			local fan_curve_raw
			fan_curve_raw=$(bash -c "source \"$CONFIG_FILE\" 2>/dev/null; printf '%s\n' \"\${FAN_CURVE[@]:-}\"" 2>/dev/null || true)
			if [[ -n "$fan_curve_raw" ]]; then
				mapfile -t intended_fan_curve <<< "$fan_curve_raw"
			fi
		fi

		# Compare hardware settings with intended settings
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_CYAN" "SCLK_OFFSET (MHz):"
			if [[ -z "$current_sclk_offset" || "$current_sclk_offset" == "N/A" ]]; then
				color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $intended_sclk_offset (Cannot verify)"
			elif [[ "$current_sclk_offset" == "$intended_sclk_offset" ]]; then
				color_echo "$COLOR_GREEN" "  Current: $current_sclk_offset, Intended: $intended_sclk_offset (Match)"
			else
				color_echo "$COLOR_YELLOW" "  Current: $current_sclk_offset, Intended: $intended_sclk_offset (Mismatch)"
			fi
		else
			color_echo "$COLOR_CYAN" "SCLK (MHz):"
			if [[ -z "$current_sclk" || "$current_sclk" == "N/A" ]]; then
				color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $intended_sclk (Cannot verify)"
			elif [[ "$current_sclk" == "$intended_sclk" ]]; then
				color_echo "$COLOR_GREEN" "  Current: $current_sclk, Intended: $intended_sclk (Match)"
			else
				color_echo "$COLOR_YELLOW" "  Current: $current_sclk, Intended: $intended_sclk (Mismatch)"
			fi
		fi
		color_echo "$COLOR_CYAN" "MCLK (MHz):"
		if [[ -z "$current_mclk" || "$current_mclk" == "N/A" ]]; then
			color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $intended_mclk (Cannot verify)"
		elif [[ "$current_mclk" == "$intended_mclk" ]]; then
			color_echo "$COLOR_GREEN" "  Current: $current_mclk, Intended: $intended_mclk (Match)"
		else
			color_echo "$COLOR_YELLOW" "  Current: $current_mclk, Intended: $intended_mclk (Mismatch)"
		fi
		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
			color_echo "$COLOR_CYAN" "VDDGFX_OFFSET (mV):"
			if [[ -z "$current_vddgfx_offset" || "$current_vddgfx_offset" == "N/A" ]]; then
				color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $intended_vddgfx_offset (Cannot verify)"
			elif [[ "$current_vddgfx_offset" == "$intended_vddgfx_offset" ]]; then
				color_echo "$COLOR_GREEN" "  Current: $current_vddgfx_offset, Intended: $intended_vddgfx_offset (Match)"
			else
				color_echo "$COLOR_YELLOW" "  Current: $current_vddgfx_offset, Intended: $intended_vddgfx_offset (Mismatch)"
			fi
		fi
		color_echo "$COLOR_CYAN" "Power Cap (W):"
		if [[ -z "$current_power_cap" || "$current_power_cap" == "N/A" ]]; then
			color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $((intended_power_cap / 1000000)) (Cannot verify)"
		elif [[ "$current_power_cap" == "$intended_power_cap" ]]; then
			color_echo "$COLOR_GREEN" "  Current: $((current_power_cap / 1000000)), Intended: $((intended_power_cap / 1000000)) (Match)"
		else
			color_echo "$COLOR_YELLOW" "  Current: $((current_power_cap / 1000000)), Intended: $((intended_power_cap / 1000000)) (Mismatch)"
		fi
		color_echo "$COLOR_CYAN" "Zero RPM:"
		if [[ -z "$current_zero_rpm" || "$current_zero_rpm" == "N/A" ]]; then
			color_echo "$COLOR_YELLOW" "  Current: Unreadable, Intended: $intended_zero_rpm (Cannot verify)"
		elif [[ "$current_zero_rpm" == "$intended_zero_rpm" ]]; then
			color_echo "$COLOR_GREEN" "  Current: $current_zero_rpm, Intended: $intended_zero_rpm (Match)"
		else
			color_echo "$COLOR_YELLOW" "  Current: $current_zero_rpm, Intended: $intended_zero_rpm (Mismatch)"
		fi
		color_echo "$COLOR_CYAN" "Junction Fan Curve:"
		if [[ "$FAN_OD_AVAILABLE" -eq 0 ]]; then
			color_echo "$COLOR_YELLOW" "  Fan OD not available; cannot compare"
		else
			local match=true i
			for i in "${!intended_fan_curve[@]}"; do
				if [[ "${current_fan_curve[i]:-}" == "${intended_fan_curve[i]}" ]]; then
					color_echo "$COLOR_GREEN" "  Point $i: ${current_fan_curve[i]} (Match)"
				else
					color_echo "$COLOR_YELLOW" "  Point $i: Current: ${current_fan_curve[i]:-N/A}, Intended: ${intended_fan_curve[i]} (Mismatch)"
					match=false
				fi
			done
			if [[ "$match" == true && ${#current_fan_curve[@]} -eq ${#intended_fan_curve[@]} ]]; then
				color_echo "$COLOR_GREEN" "  Junction fan curve fully matches intended settings"
			else
				color_echo "$COLOR_YELLOW" "  Junction fan curve does not fully match intended settings"
			fi
		fi
	fi
}

# Load and validate configuration settings from file
load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		if is_interactive; then
			color_echo "$COLOR_YELLOW" "Warning: Config file $CONFIG_FILE not found, launching interactive config creation"
			create_config 1
		else
			error_echo "$COLOR_RED" "Error: Config file $CONFIG_FILE not found in non-interactive mode, not applying profile"
			exit 1
		fi
	fi
	# shellcheck disable=SC1090
	source "$CONFIG_FILE"

	# Validate configuration parameters
	[[ -z "${EXPECTED_PCI_ID:-}" ]] && { error_echo "$COLOR_RED" "Error: EXPECTED_PCI_ID not set in config"; exit 1; }
	if [[ "$RDNA_GEN" == "4" ]]; then
		[[ -z "${SCLK_OFFSET:-}" ]] && { error_echo "$COLOR_RED" "Error: SCLK_OFFSET not set in config"; exit 1; }
		[[ ! "$SCLK_OFFSET" =~ ^-?[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid SCLK_OFFSET: $SCLK_OFFSET"; exit 1; }
		[[ "$SCLK_OFFSET" -lt "$SCLK_MIN" ]] && { error_echo "$COLOR_RED" "Error: SCLK_OFFSET $SCLK_OFFSET below minimum $SCLK_MIN"; exit 1; }
		[[ "$SCLK_OFFSET" -gt "$SCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: SCLK_OFFSET $SCLK_OFFSET above maximum $SCLK_MAX"; exit 1; }
		[[ -z "${MCLK:-}" ]] && { error_echo "$COLOR_RED" "Error: MCLK not set in config"; exit 1; }
		[[ ! "$MCLK" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid MCLK: $MCLK"; exit 1; }
		[[ "$MCLK" -lt "$MCLK_MIN" ]] && { error_echo "$COLOR_RED" "Error: MCLK $MCLK below minimum $MCLK_MIN"; exit 1; }
		[[ "$MCLK" -gt "$MCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: MCLK $MCLK above maximum $MCLK_MAX"; exit 1; }
	else
		[[ -z "${SCLK:-}" ]] && { error_echo "$COLOR_RED" "Error: SCLK not set in config"; exit 1; }
		[[ ! "$SCLK" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid SCLK: $SCLK"; exit 1; }
		[[ "$SCLK" -lt "$SCLK_MIN" ]] && { error_echo "$COLOR_RED" "Error: SCLK $SCLK below minimum $SCLK_MIN"; exit 1; }
		[[ "$SCLK" -gt "$SCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: SCLK $SCLK above maximum $SCLK_MAX"; exit 1; }
		[[ -z "${MCLK:-}" ]] && { error_echo "$COLOR_RED" "Error: MCLK not set in config"; exit 1; }
		[[ ! "$MCLK" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid MCLK: $MCLK"; exit 1; }
		[[ "$MCLK" -lt "$MCLK_MIN" ]] && { error_echo "$COLOR_RED" "Error: MCLK $MCLK below minimum $MCLK_MIN"; exit 1; }
		[[ "$MCLK" -gt "$MCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: MCLK $MCLK above maximum $MCLK_MAX"; exit 1; }
	fi

	# Validate voltage offset for RDNA2+ if specified in config
	if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "${VDDGFX_OFFSET:-}" ]]; then
		[[ ! "$VDDGFX_OFFSET" =~ ^-?[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid VDDGFX_OFFSET: $VDDGFX_OFFSET"; exit 1; }
		[[ "$VDDGFX_OFFSET" -lt "$VDDGFX_OFFSET_MIN" ]] && { error_echo "$COLOR_RED" "Error: VDDGFX_OFFSET $VDDGFX_OFFSET below minimum $VDDGFX_OFFSET_MIN"; exit 1; }
		[[ "$VDDGFX_OFFSET" -gt "$VDDGFX_OFFSET_MAX" ]] && { error_echo "$COLOR_RED" "Error: VDDGFX_OFFSET $VDDGFX_OFFSET above maximum $VDDGFX_OFFSET_MAX"; exit 1; }
	elif [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 0 && -n "${VDDGFX_OFFSET:-}" ]]; then
		color_echo "$COLOR_YELLOW" "Warning: VDDGFX_OFFSET specified but not supported on RDNA1, ignoring"
		VDDGFX_OFFSET=""
	fi

	[[ -z "${POWER_CAP:-}" ]] && { error_echo "$COLOR_RED" "Error: POWER_CAP not set in config"; exit 1; }
	[[ ! "$POWER_CAP" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid POWER_CAP: $POWER_CAP"; exit 1; }
	[[ "$POWER_CAP" -gt "$POWER_CAP_MAX" ]] && { error_echo "$COLOR_RED" "Error: POWER_CAP $POWER_CAP above maximum $POWER_CAP_MAX"; exit 1; }
	[[ -z "${ZERO_RPM:-}" ]] && { error_echo "$COLOR_RED" "Error: ZERO_RPM not set in config"; exit 1; }
	[[ ! "$ZERO_RPM" =~ ^[0-1]$ ]] && { error_echo "$COLOR_RED" "Error: Invalid ZERO_RPM: $ZERO_RPM"; exit 1; }
	if [[ ${#FAN_CURVE[@]} -eq 0 ]]; then
		color_echo "$COLOR_CYAN" "No FAN_CURVE in config, using fallback junction curve"
		FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
	fi
	if [[ ${#FAN_CURVE[@]} -ne 5 ]]; then
		error_echo "$COLOR_RED" "Error: FAN_CURVE must have exactly 5 points, found ${#FAN_CURVE[@]}"
		exit 1
	fi
	local point idx temp speed
	for point in "${FAN_CURVE[@]}"; do
		[[ ! "$point" =~ ^[0-4][[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid FAN_CURVE point: $point"; exit 1; }
		read -r idx temp speed <<< "$point"
		[[ "$temp" -lt "$TEMP_MIN" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx temperature $temp below minimum $TEMP_MIN"; exit 1; }
		[[ "$temp" -gt "$TEMP_MAX" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx temperature $temp above maximum $TEMP_MAX"; exit 1; }
		[[ "$speed" -lt "$SPEED_MIN" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx speed $speed below minimum $SPEED_MIN"; exit 1; }
		[[ "$speed" -gt "$SPEED_MAX" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx speed $speed above maximum $SPEED_MAX"; exit 1; }
	done

	# Validate fan curve monotonicity (each point must have temp >= previous and speed >= previous)
	local prev_temp=-1 prev_speed=-1
	for point in "${FAN_CURVE[@]}"; do
		read -r idx temp speed <<< "$point"
		if [[ "$prev_temp" -ge 0 ]]; then
			[[ "$temp" -lt "$prev_temp" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx temperature $temp is lower than previous ($prev_temp); curve must be monotonically increasing"; exit 1; }
			[[ "$speed" -lt "$prev_speed" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point $idx speed $speed is lower than previous ($prev_speed); curve must be monotonically increasing"; exit 1; }
		fi
		prev_temp="$temp"
		prev_speed="$speed"
	done
}

# Apply GPU settings based on configuration.
# Commits are issued as individual writes per sysfs file; tee-to-multiple-files
# is not a valid mechanism since each driver interface processes writes independently.
apply_settings() {
	if [[ "$DRY_RUN_MODE" -eq 1 ]]; then
		color_echo "$COLOR_YELLOW" "=== Dry-run mode: The following settings would be applied ==="
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_CYAN" "  SCLK_OFFSET: $SCLK_OFFSET MHz"
		else
			color_echo "$COLOR_CYAN" "  SCLK: $SCLK MHz"
		fi
		color_echo "$COLOR_CYAN" "  MCLK: $MCLK MHz"
		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "${VDDGFX_OFFSET:-}" ]]; then
			color_echo "$COLOR_CYAN" "  VDDGFX_OFFSET: $VDDGFX_OFFSET mV"
		fi
		color_echo "$COLOR_CYAN" "  POWER_CAP: $((POWER_CAP / 1000000)) W ($POWER_CAP uW)"
		color_echo "$COLOR_CYAN" "  ZERO_RPM: $ZERO_RPM"
		if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
			color_echo "$COLOR_CYAN" "  Junction Fan Curve:"
			local point idx temp speed
			for point in "${FAN_CURVE[@]}"; do
				read -r idx temp speed <<< "$point"
				color_echo "$COLOR_CYAN" "    Point $idx: ${temp}C ${speed}%"
			done
		else
			color_echo "$COLOR_YELLOW" "  Fan curve: Not applied (fan OD unavailable)"
		fi
		color_echo "$COLOR_YELLOW" "=== No changes were made ==="
		exit 0
	fi

	# Set power profile to manual
	check_writable "$POWER_PROFILE_PATH"
	echo "manual" > "$POWER_PROFILE_PATH" || { error_echo "$COLOR_RED" "Error: Failed to set manual power profile"; exit 1; }

	# Apply power cap
	check_writable "$POWER_CAP_PATH"
	echo "$POWER_CAP" > "$POWER_CAP_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write to power1_cap"; exit 1; }

	# Apply OD clock settings and commit
	if [[ "$RDNA_GEN" == "4" ]]; then
		# GFX12/RDNA4 clock and voltage OD write paths are not yet functional in the
		# amdgpu driver as of kernel 6.x. Specifically:
		#   - "s <offset>" is misrouted to the RDNA1/2/3 pstate-frequency parser,
		#     corrupting pstate 0 rather than setting an SCLK offset.
		#   - "m 1 <freq>" stages without error but the commit never rebuilds the
		#     pstate table; pp_dpm_mclk remains unchanged.
		#   - "vo <mv>" stages but effect on hardware is unverified.
		# All three token/commit issues share the same root cause: the GFX12 SMU OD
		# commit path in amdgpu is not implemented at this driver maturity level.
		# Clock/voltage writes are intentionally skipped to avoid corrupting hardware
		# state. Power cap (hwmon) and fan curve (gpu_od) are applied normally.
		color_echo "$COLOR_YELLOW" "Note: RDNA4 clock/voltage OD (SCLK_OFFSET, MCLK, VDDGFX_OFFSET) is not yet"
		color_echo "$COLOR_YELLOW" "      functional in the amdgpu driver. These settings will be skipped."
		color_echo "$COLOR_CYAN"   "Applying settings: POWER_CAP=$((POWER_CAP / 1000000)) W, ZERO_RPM=$ZERO_RPM (fan curve below)"

		if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
			check_writable "$ZERO_RPM_PATH"
			check_writable "$FAN_CURVE_PATH"
			check_writable "$PP_OD_PATH"
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing ZERO_RPM=$ZERO_RPM to $ZERO_RPM_PATH"
			echo "$ZERO_RPM" > "$ZERO_RPM_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write to fan_zero_rpm_enable"; exit 1; }
			local point idx temp speed
			for point in "${FAN_CURVE[@]}"; do
				read -r idx temp speed <<< "$point"
				[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing fan curve point $idx $temp $speed to $FAN_CURVE_PATH"
				echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write to fan_curve"; exit 1; }
			done
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Committing fan OD settings via $PP_OD_PATH"
			echo "c" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to commit fan OD settings"; exit 1; }
		else
			color_echo "$COLOR_YELLOW" "Fan OD not available; skipping fan curve and zero RPM settings"
		fi
	else
		local settings_str="SCLK=$SCLK MHz, MCLK=$MCLK MHz"
		[[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "${VDDGFX_OFFSET:-}" ]] && settings_str+=", VDDGFX_OFFSET=$VDDGFX_OFFSET mV"
		settings_str+=", POWER_CAP=$((POWER_CAP / 1000000)) W, ZERO_RPM=$ZERO_RPM"
		color_echo "$COLOR_CYAN" "Applying settings: $settings_str"

		check_writable "$PP_OD_PATH"
		if [[ "$RDNA_GEN" == "1" ]]; then
			local i
			for ((i=0; i<=PSTATE_MAX; i++)); do
				local sclk_val="${SCLK_PSTATES[i]:-$SCLK}"
				[[ "$i" -eq 1 ]] && sclk_val="$SCLK"
				[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing SCLK PSTATE $i=$sclk_val to $PP_OD_PATH"
				echo "s $i $sclk_val" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write SCLK PSTATE $i to pp_od_clk_voltage"; exit 1; }
			done
		else
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing SCLK=$SCLK to $PP_OD_PATH"
			echo "s 1 $SCLK" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write SCLK to pp_od_clk_voltage"; exit 1; }
		fi
		[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing MCLK=$MCLK to $PP_OD_PATH"
		echo "m 1 $MCLK" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write MCLK to pp_od_clk_voltage"; exit 1; }

		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "${VDDGFX_OFFSET:-}" ]]; then
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing VDDGFX_OFFSET=$VDDGFX_OFFSET to $PP_OD_PATH"
			echo "vo $VDDGFX_OFFSET" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write VDDGFX_OFFSET to pp_od_clk_voltage"; exit 1; }
		fi

		[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Committing OD settings to $PP_OD_PATH"
		echo "c" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to commit pp_od_clk_voltage"; exit 1; }

		check_writable "$FAN_CURVE_PATH"
		check_writable "$ZERO_RPM_PATH"
		[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing ZERO_RPM=$ZERO_RPM to $ZERO_RPM_PATH"
		echo "$ZERO_RPM" > "$ZERO_RPM_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write to fan_zero_rpm_enable"; exit 1; }
		local point idx temp speed
		for point in "${FAN_CURVE[@]}"; do
			read -r idx temp speed <<< "$point"
			[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing fan curve point $idx $temp $speed to $FAN_CURVE_PATH"
			echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write to fan_curve"; exit 1; }
		done
		# Fan OD settings (fan_curve, zero_rpm) commit through pp_od_clk_voltage,
		# not through the individual fan files; writing "c" to those files resets them.
		[[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Committing fan OD settings via $PP_OD_PATH"
		echo "c" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to commit fan OD settings"; exit 1; }
	fi

	verify_od_applied
}

# Verify OD settings actually took effect by checking the live pstate tables.
# For RDNA1/2/3: pp_dpm_sclk and pp_dpm_mclk reflect the hardware pstate table after commit.
# For RDNA4: clock/voltage OD writes are skipped entirely (driver not yet functional);
# only power cap and fan curve are applied, so no pstate verification is needed.
verify_od_applied() {
	if [[ "$RDNA_GEN" == "4" ]]; then
		color_echo "$COLOR_GREEN" "Power cap and fan curve applied successfully"
		color_echo "$COLOR_YELLOW" "Note: SCLK_OFFSET, MCLK, and VDDGFX_OFFSET were not applied (GFX12 OD not yet functional in driver)"
		return
	fi

	local pp_dpm_sclk_path="${CARD_PATH}/pp_dpm_sclk"
	local pp_dpm_mclk_path="${CARD_PATH}/pp_dpm_mclk"
	local od_applied=true

	if [[ -f "$pp_dpm_mclk_path" && "${MCLK:-0}" -gt 0 ]]; then
		local max_mclk
		max_mclk=$(grep -o "[0-9]\+Mhz" "$pp_dpm_mclk_path" 2>/dev/null | grep -o "[0-9]\+" | sort -n | tail -n 1 || true)
		if [[ -n "$max_mclk" && "$max_mclk" != "$MCLK" ]]; then
			color_echo "$COLOR_YELLOW" "Warning: MCLK OD may not have taken effect (requested: ${MCLK} MHz, pstate max: ${max_mclk} MHz)"
			od_applied=false
		fi
	fi
	if [[ -f "$pp_dpm_sclk_path" && "${SCLK:-0}" -gt 0 ]]; then
		local max_sclk
		max_sclk=$(grep -o "[0-9]\+Mhz" "$pp_dpm_sclk_path" 2>/dev/null | grep -o "[0-9]\+" | sort -n | tail -n 1 || true)
		if [[ -n "$max_sclk" && "$max_sclk" != "$SCLK" ]]; then
			color_echo "$COLOR_YELLOW" "Warning: SCLK OD may not have taken effect (requested: ${SCLK} MHz, pstate max: ${max_sclk} MHz)"
			od_applied=false
		fi
	fi

	if [[ "$od_applied" == true ]]; then
		color_echo "$COLOR_GREEN" "Settings applied successfully"
	else
		color_echo "$COLOR_YELLOW" "Some OD settings may not be active (see warnings above); power cap and fan curve are unaffected"
	fi
}

# Create configuration file, either interactively or with hardware defaults.
# Non-interactive mode writes hardware defaults as a safe starting point.
create_config() {
	local interactive="$1"
	color_echo "$COLOR_CYAN" "Creating configuration file: $CONFIG_FILE"
	[[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" && color_echo "$COLOR_YELLOW" "Backed up existing config to ${CONFIG_FILE}.bak"
	local sclk="" sclk_offset="" mclk="" power_cap="" zero_rpm="" vddgfx_offset=""
	local sclk_proposed="" sclk_offset_proposed="" mclk_proposed="" power_cap_proposed="" zero_rpm_proposed="" vddgfx_offset_proposed=""
	local -a fan_curve=() fan_curve_proposed=()

	if [[ "$interactive" -eq 1 ]]; then
		color_echo "$COLOR_GREEN" "==> Enter a value or simply hit ENTER to use the proposed value"
		if [[ "$RDNA_GEN" == "4" ]]; then
			color_echo "$COLOR_CYAN" "Enter SCLK_OFFSET (MHz, range $SCLK_MIN-$SCLK_MAX, hardware default $SCLK_OFFSET_DEFAULT, proposed 0):"
			read -r sclk_offset
			sclk_offset=${sclk_offset:-0}
			[[ ! "$sclk_offset" =~ ^-?[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid SCLK_OFFSET"; exit 1; }
			[[ "$sclk_offset" -lt "$SCLK_MIN" || "$sclk_offset" -gt "$SCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: SCLK_OFFSET out of range"; exit 1; }
		else
			color_echo "$COLOR_CYAN" "Enter SCLK (MHz, range $SCLK_MIN-$SCLK_MAX, hardware default $SCLK_DEFAULT, proposed $SCLK_DEFAULT):"
			read -r sclk
			sclk=${sclk:-$SCLK_DEFAULT}
			[[ ! "$sclk" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid SCLK"; exit 1; }
			[[ "$sclk" -lt "$SCLK_MIN" || "$sclk" -gt "$SCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: SCLK out of range"; exit 1; }
		fi

		color_echo "$COLOR_CYAN" "Enter MCLK (MHz, range $MCLK_MIN-$MCLK_MAX, hardware default $MCLK_DEFAULT, proposed $MCLK_DEFAULT):"
		read -r mclk
		mclk=${mclk:-$MCLK_DEFAULT}
		[[ ! "$mclk" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid MCLK"; exit 1; }
		[[ "$mclk" -lt "$MCLK_MIN" || "$mclk" -gt "$MCLK_MAX" ]] && { error_echo "$COLOR_RED" "Error: MCLK out of range"; exit 1; }

		if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
			color_echo "$COLOR_YELLOW" "Note: Voltage offset can improve stability or allow higher clocks. Use negative values to undervolt."
			color_echo "$COLOR_CYAN" "Enter VDDGFX_OFFSET (mV, range $VDDGFX_OFFSET_MIN-$VDDGFX_OFFSET_MAX, hardware default $VDDGFX_OFFSET_DEFAULT, proposed 0):"
			read -r vddgfx_offset
			vddgfx_offset=${vddgfx_offset:-0}
			[[ ! "$vddgfx_offset" =~ ^-?[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid VDDGFX_OFFSET"; exit 1; }
			[[ "$vddgfx_offset" -lt "$VDDGFX_OFFSET_MIN" || "$vddgfx_offset" -gt "$VDDGFX_OFFSET_MAX" ]] && { error_echo "$COLOR_RED" "Error: VDDGFX_OFFSET out of range"; exit 1; }
		fi

		color_echo "$COLOR_CYAN" "Enter POWER_CAP (Watts, range 0-$((POWER_CAP_MAX / 1000000)), hardware default $((POWER_CAP_DEFAULT / 1000000)), proposed $((POWER_CAP_DEFAULT / 1000000))):"
		read -r power_cap
		power_cap=${power_cap:-$((POWER_CAP_DEFAULT / 1000000))}
		[[ ! "$power_cap" =~ ^[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid POWER_CAP"; exit 1; }
		power_cap=$((power_cap * 1000000))
		[[ "$power_cap" -lt 0 || "$power_cap" -gt "$POWER_CAP_MAX" ]] && { error_echo "$COLOR_RED" "Error: POWER_CAP out of range"; exit 1; }

		color_echo "$COLOR_YELLOW" "Note: If enabled, zero RPM (complete fan spindown) may interfere with custom fan curve behavior."
		color_echo "$COLOR_CYAN" "Enter ZERO_RPM (0 or 1, hardware default $ZERO_RPM_DEFAULT, proposed 0):"
		read -r zero_rpm
		zero_rpm=${zero_rpm:-0}
		[[ ! "$zero_rpm" =~ ^[0-1]$ ]] && { error_echo "$COLOR_RED" "Error: Invalid ZERO_RPM"; exit 1; }

		color_echo "$COLOR_CYAN" "Enter FAN_CURVE (5 points: idx temp speed, e.g., '0 45 30') for junction temperature:"
		local -a fan_curve_input=()
		local i
		for i in {0..4}; do
			color_echo "$COLOR_CYAN" "Point $i (temp range $TEMP_MIN-$TEMP_MAX C, speed range $SPEED_MIN-$SPEED_MAX %, hardware default ${FAN_CURVE_DEFAULT[i]}, proposed ${FAN_CURVE_DEFAULT[i]}):"
			local point
			read -r point
			point=${point:-${FAN_CURVE_DEFAULT[i]}}
			[[ ! "$point" =~ ^[0-4][[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] && { error_echo "$COLOR_RED" "Error: Invalid junction fan curve point"; exit 1; }
			local idx temp speed
			read -r idx temp speed <<< "$point"
			[[ "$idx" -ne "$i" ]] && { error_echo "$COLOR_RED" "Error: Fan curve point index must be $i"; exit 1; }
			[[ "$temp" -lt "$TEMP_MIN" || "$temp" -gt "$TEMP_MAX" ]] && { error_echo "$COLOR_RED" "Error: Junction temperature out of range"; exit 1; }
			[[ "$speed" -lt "$SPEED_MIN" || "$speed" -gt "$SPEED_MAX" ]] && { error_echo "$COLOR_RED" "Error: Speed out of range"; exit 1; }
			fan_curve_input+=("$point")
		done
		fan_curve=("${fan_curve_input[@]}")

		# Set proposed values to what the user entered (used in config file comments)
		if [[ "$RDNA_GEN" == "4" ]]; then
			sclk_offset_proposed="$sclk_offset"
		else
			sclk_proposed="$sclk"
		fi
		mclk_proposed="$mclk"
		power_cap_proposed="$power_cap"
		zero_rpm_proposed="$zero_rpm"
		vddgfx_offset_proposed="${vddgfx_offset:-0}"
		fan_curve_proposed=("${fan_curve[@]}")
	else
		# Non-interactive: use hardware defaults as the safe starting point
		if [[ "$RDNA_GEN" == "1" ]]; then
			sclk="$SCLK_DEFAULT"
			sclk_proposed="$SCLK_DEFAULT"
		elif [[ "$RDNA_GEN" == "4" ]]; then
			sclk_offset="$SCLK_OFFSET_DEFAULT"
			sclk_offset_proposed="$SCLK_OFFSET_DEFAULT"
		else
			sclk="$SCLK_DEFAULT"
			sclk_proposed="$SCLK_DEFAULT"
		fi
		mclk="$MCLK_DEFAULT"
		mclk_proposed="$MCLK_DEFAULT"
		power_cap="$POWER_CAP_DEFAULT"
		power_cap_proposed="$POWER_CAP_DEFAULT"
		zero_rpm=0
		zero_rpm_proposed=0
		fan_curve=("${FAN_CURVE_DEFAULT[@]}")
		fan_curve_proposed=("${FAN_CURVE_DEFAULT[@]}")
		if [[ "$RDNA_GEN" != "1" ]]; then
			vddgfx_offset="$VDDGFX_OFFSET_DEFAULT"
			vddgfx_offset_proposed="0"
		fi
	fi

	# Generate FAN_CURVE array string for config file
	local fan_curve_str=""
	local point
	for point in "${fan_curve[@]}"; do
		fan_curve_str+=$(printf '"%s" ' "$point")
	done

	# Generate FAN_CURVE proposed string for config comments
	local fan_curve_proposed_str=""
	for point in "${fan_curve_proposed[@]:-${FAN_CURVE_DEFAULT[@]}}"; do
		fan_curve_proposed_str+=$(printf "\n#     Point %s" "$point")
	done

	# Write configuration file with commentary
	if [[ "$RDNA_GEN" == "4" ]]; then
		cat << EOF > "$CONFIG_FILE"
# AMD RDNA GPU Overclocking and Fan Curve Configuration
# PCI ID of the target GPU
EXPECTED_PCI_ID="$PCI_ID"

# Core clock offset (MHz)
SCLK_OFFSET=$sclk_offset
# Range: $SCLK_MIN to $SCLK_MAX MHz
# Hardware default: $SCLK_OFFSET_DEFAULT MHz
# Proposed default: ${sclk_offset_proposed:-0} MHz

# Memory clock (MHz)
MCLK=$mclk
# Range: $MCLK_MIN to $MCLK_MAX MHz
# Hardware default: $MCLK_DEFAULT MHz
# Proposed default: ${mclk_proposed:-$MCLK_DEFAULT} MHz

EOF
else
	cat << EOF > "$CONFIG_FILE"
# AMD RDNA GPU Overclocking and Fan Curve Configuration
# PCI ID of the target GPU
EXPECTED_PCI_ID="$PCI_ID"

# Core clock (MHz)
SCLK=$sclk
# Range: $SCLK_MIN to $SCLK_MAX MHz
# Hardware default: $SCLK_DEFAULT MHz
# Proposed default: ${sclk_proposed:-$SCLK_DEFAULT} MHz

# Memory clock (MHz)
MCLK=$mclk
# Range: $MCLK_MIN to $MCLK_MAX MHz
# Hardware default: $MCLK_DEFAULT MHz
# Proposed default: ${mclk_proposed:-$MCLK_DEFAULT} MHz

EOF
	fi

	# Add voltage offset section if supported
	if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
		cat << EOF >> "$CONFIG_FILE"
# GPU voltage offset (milliVolts)
# Negative values undervolt, positive values overvolt
# Use with caution - improper voltage settings can cause instability
VDDGFX_OFFSET=${vddgfx_offset:-$VDDGFX_OFFSET_DEFAULT}
# Range: $VDDGFX_OFFSET_MIN to $VDDGFX_OFFSET_MAX mV
# Hardware default: $VDDGFX_OFFSET_DEFAULT mV
# Proposed default: ${vddgfx_offset_proposed:-0} mV

EOF
	fi

	cat << EOF >> "$CONFIG_FILE"
# Power cap (microWatts)
POWER_CAP=$power_cap
# Range: 0 to $POWER_CAP_MAX microWatts ($((POWER_CAP_MAX / 1000000)) W)
# Hardware default: $((POWER_CAP_DEFAULT / 1000000)) W
# Proposed default: ${power_cap_proposed:-$POWER_CAP_DEFAULT} microWatts ($((${power_cap_proposed:-$POWER_CAP_DEFAULT} / 1000000)) W)

# Zero RPM fan mode (0 = disabled, 1 = enabled)
# Note: If enabled, zero RPM may interfere with custom fan curve behavior
ZERO_RPM=$zero_rpm
# Range: 0 to 1
# Hardware default: $ZERO_RPM_DEFAULT
# Proposed default: ${zero_rpm_proposed:-0}

# Junction temperature fan curve (5 points: index temp speed)
FAN_CURVE=($fan_curve_str)
# Temperature range: $TEMP_MIN to $TEMP_MAX C
# Speed range: $SPEED_MIN to $SPEED_MAX %
# Example: ("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
EOF

chmod 644 "$CONFIG_FILE"
color_echo "$COLOR_GREEN" "Configuration file created: $CONFIG_FILE"
}

# Reset GPU to default settings.
# pp_od_clk_voltage is reset and committed immediately before any fan manipulation
# to avoid inadvertently re-committing a stale staging area later in the function.
reset_gpu() {
	color_echo "$COLOR_YELLOW" "Resetting GPU to default settings..."

	# Reset and immediately commit pp_od_clk_voltage
	check_writable "$PP_OD_PATH"
	echo "r" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to reset pp_od_clk_voltage staging area"; exit 1; }
	echo "c" > "$PP_OD_PATH" || { error_echo "$COLOR_RED" "Error: Failed to commit pp_od_clk_voltage reset"; exit 1; }

	# Reset power cap to hardware default
	if [[ -w "$POWER_CAP_PATH" && -f "$POWER_CAP_DEFAULT_PATH" ]]; then
		cat "$POWER_CAP_DEFAULT_PATH" > "$POWER_CAP_PATH" || { error_echo "$COLOR_RED" "Error: Failed to reset power1_cap"; exit 1; }
	fi

	# Reset fan OD settings if available
	if [[ "$FAN_OD_AVAILABLE" -eq 1 ]]; then
		echo "$ZERO_RPM_DEFAULT" > "$ZERO_RPM_PATH" || color_echo "$COLOR_YELLOW" "Warning: Failed to reset fan_zero_rpm_enable"
		echo "r" > "$FAN_CURVE_PATH" 2>/dev/null || true
		if ! grep -qE '[1-9][0-9]*C [1-9][0-9]*%' "$FAN_CURVE_PATH"; then
			color_echo "$COLOR_YELLOW" "Warning: fan_curve reset returned invalid data, applying fallback junction curve"
			local default_fan_curve=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
			local point idx temp speed
			for point in "${default_fan_curve[@]}"; do
				read -r idx temp speed <<< "$point"
				echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { error_echo "$COLOR_RED" "Error: Failed to write fallback fan_curve point $idx"; exit 1; }
			done
		fi
		# Fan OD settings commit through pp_od_clk_voltage, not the individual fan files
		echo "c" > "$PP_OD_PATH" || color_echo "$COLOR_YELLOW" "Warning: Failed to commit fan OD reset"
	else
		color_echo "$COLOR_YELLOW" "Fan OD not available; skipping fan curve and zero RPM reset"
	fi

	echo "auto" > "$POWER_PROFILE_PATH" || { error_echo "$COLOR_RED" "Error: Failed to reset power_dpm_force_performance_level"; exit 1; }
	color_echo "$COLOR_GREEN" "GPU settings reset successfully"
}

# Main execution
find_card_paths
check_overdrive
detect_rdna_gen
check_fan_paths
read_hardware_defaults

if [[ "$RESET_MODE" -eq 1 ]]; then
	check_pci_id "reset"
	reset_gpu
	print_status 1
	exit 0
fi

if [[ "$CREATE_CONFIG_MODE" -eq 1 ]]; then
	create_config 0
	exit 0
elif [[ "$CREATE_CONFIG_INTERACTIVE_MODE" -eq 1 ]]; then
	create_config 1
	exit 0
elif [[ "$STATUS_MODE" -eq 1 ]]; then
	print_status 0
	exit 0
fi

check_pci_id "apply"
load_config
apply_settings
