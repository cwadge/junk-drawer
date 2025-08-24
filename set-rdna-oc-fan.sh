#!/bin/bash

# Configuration file path
CONFIG_FILE="/etc/set-rdna-oc-fan.conf"
SYSFS_TIMEOUT=5
MAX_WAIT=30
WAIT_INTERVAL=1

# Known RDNA GPU PCI IDs
RDNA1_IDS=("1002:731F" "1002:7360" "1002:7362" "1002:7340" "1002:7341" "1002:7347" "1002:734F" "1002:7312" "1002:7310" "1002:731A" "1002:731B")
RDNA2_IDS=("1002:73BF" "1002:73A0" "1002:73A1" "1002:73A2" "1002:73A3" "1002:73A5" "1002:73A8" "1002:73A9" "1002:73AB" "1002:73AD" "1002:73AE" "1002:73AF" "1002:73DF" "1002:73E0" "1002:73E1" "1002:73E3" "1002:73EF" "1002:7408" "1002:740C" "1002:740F" "1002:7410")
RDNA3_IDS=("1002:747E" "1002:7480" "1002:744C" "1002:743F" "1002:74A0" "1002:74A1" "1002:7448" "1002:745E" "1002:7460" "1002:7461" "1002:7470")
RDNA4_IDS=("1002:7572" "1002:7573" "1002:7578" "1002:7579" "1002:7590")

# Modes
DEBUG_MODE=0
DRY_RUN_MODE=0
RESET_MODE=0
CREATE_CONFIG_MODE=0
CREATE_CONFIG_INTERACTIVE_MODE=0
STATUS_MODE=0

# Color codes
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# Colorized echo function for consistent output formatting
color_echo() {
    local color="$1"
    shift
    if [[ -t 1 ]]; then
        echo -e "${color}$*${COLOR_RESET}" >&2
    else
        echo "$*" >&2
    fi
}

# Check if a sysfs path is writable
check_writable() {
    local path="$1"
    [[ -w "$path" ]] || { color_echo "$COLOR_RED" "Error: $path not writable"; exit 1; }
}

# Display usage information and available options
print_help() {
    color_echo "$COLOR_CYAN" "Usage: $0 [OPTIONS]"
    color_echo "$COLOR_CYAN" "Options:"
    color_echo "$COLOR_CYAN" "  -h, --help                Display this help message"
    color_echo "$COLOR_CYAN" "  --debug                   Enable verbose shell tracing"
    color_echo "$COLOR_CYAN" "  --dry-run                 Print settings without applying them"
    color_echo "$COLOR_CYAN" "  --reset                   Reset GPU to default settings"
    color_echo "$COLOR_CYAN" "  --create-config           Create config file with safe defaults"
    color_echo "$COLOR_CYAN" "  --create-config-interactive  Interactively create config file with hardware defaults"
    color_echo "$COLOR_CYAN" "  --status                  Display current GPU settings from hardware"
    color_echo "$COLOR_CYAN" "Config file: $CONFIG_FILE"
    exit 0
}

# Parse command-line arguments to set operational modes
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) print_help ;;
        --debug) DEBUG_MODE=1 ;;
        --dry-run) DRY_RUN_MODE=1 ;;
        --reset) RESET_MODE=1 ;;
        --create-config) CREATE_CONFIG_MODE=1 ;;
        --create-config-interactive) CREATE_CONFIG_INTERACTIVE_MODE=1 ;;
        --status) STATUS_MODE=1 ;;
        *) color_echo "$COLOR_RED" "Unknown option: $1"; print_help ;;
    esac
    shift
done

# Enable debug mode with verbose output if requested
[[ "$DEBUG_MODE" -eq 1 ]] && set -x

# Check if the script is running interactively (connected to a terminal)
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Locate AMD GPU sysfs paths for hardware control and verify availability
find_card_paths() {
    CARD_PATH=""
    for card in /sys/class/drm/card*/device; do
        [[ -d "$card" ]] && [[ -f "$card/uevent" ]] && timeout "$SYSFS_TIMEOUT" grep -qi "DRIVER=amdgpu" "$card/uevent" && CARD_PATH="$card" && break
    done
    [[ -z "$CARD_PATH" ]] && { color_echo "$COLOR_RED" "Error: No AMDGPU card found"; exit 1; }

    HWMON_PATH=""
    for dir in "${CARD_PATH}/hwmon/hwmon"*/; do
        [[ -f "$dir/name" ]] && [[ "$(timeout "$SYSFS_TIMEOUT" cat "$dir/name" 2>/dev/null)" == "amdgpu" ]] && HWMON_PATH="${dir%/}" && break
    done
    [[ -z "$HWMON_PATH" ]] && { color_echo "$COLOR_RED" "Error: No hwmon path found"; exit 1; }

    FAN_CURVE_PATH="${CARD_PATH}/gpu_od/fan_ctrl/fan_curve"
    ZERO_RPM_PATH="${CARD_PATH}/gpu_od/fan_ctrl/fan_zero_rpm_enable"
    PP_OD_PATH="${CARD_PATH}/pp_od_clk_voltage"
    POWER_CAP_PATH="${HWMON_PATH}/power1_cap"
    POWER_CAP_MAX_PATH="${HWMON_PATH}/power1_cap_max"
    POWER_CAP_DEFAULT_PATH="${HWMON_PATH}/power1_cap_default"
    POWER_PROFILE_PATH="${CARD_PATH}/power_dpm_force_performance_level"

    # Wait for sysfs paths to be available
    local elapsed=0
    while [[ $elapsed -lt $MAX_WAIT ]]; do
        if [[ -f "${FAN_CURVE_PATH}" && -f "${ZERO_RPM_PATH}" && -f "${PP_OD_PATH}" && -f "${POWER_CAP_PATH}" && -f "${POWER_PROFILE_PATH}" && -f "${POWER_CAP_DEFAULT_PATH}" ]]; then
            break
        fi
        color_echo "$COLOR_YELLOW" "Waiting for sysfs paths to be available... ($elapsed/$MAX_WAIT seconds)"
        sleep "$WAIT_INTERVAL"
        ((elapsed+=WAIT_INTERVAL))
    done

    # Verify all required files exist and are writable
    for file in "${FAN_CURVE_PATH}" "${ZERO_RPM_PATH}" "${PP_OD_PATH}" "${POWER_CAP_PATH}" "${POWER_PROFILE_PATH}" "${POWER_CAP_DEFAULT_PATH}"; do
        if [[ ! -f "$file" ]]; then
            color_echo "$COLOR_RED" "Error: File $file not found after waiting"
            exit 1
        fi
        check_writable "$file"
    done
}

# Verify Overdrive support by checking pp_od_clk_voltage writability
check_overdrive() {
    check_writable "$PP_OD_PATH"
}

# Detect RDNA generation based on PCI ID and set appropriate pstate maximum
detect_rdna_gen() {
    PCI_ID=$(timeout "$SYSFS_TIMEOUT" grep PCI_ID "$CARD_PATH/uevent" | cut -d'=' -f2)
    SUPPORTS_VOLTAGE_OFFSET=0
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
        PSTATE_MAX=1
        SUPPORTS_VOLTAGE_OFFSET=1
    else
        color_echo "$COLOR_RED" "Error: Unknown AMD GPU (PCI ID: $PCI_ID)"
        exit 1
    fi
    color_echo "$COLOR_GREEN" "Detected RDNA Generation: $RDNA_GEN, PSTATE_MAX: $PSTATE_MAX, PCI_ID: $PCI_ID"
    [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]] && color_echo "$COLOR_GREEN" "Voltage offset support: Available" || color_echo "$COLOR_YELLOW" "Voltage offset support: Not available (RDNA1)"
}

# Validate PCI ID against config file, with mode-specific behavior
check_pci_id() {
    local mode="$1"
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        if [[ -n "$EXPECTED_PCI_ID" && "$EXPECTED_PCI_ID" != "$PCI_ID" ]]; then
            if [[ "$mode" == "apply" && ! -t 0 ]]; then
                color_echo "$COLOR_RED" "Error: PCI ID mismatch (Config: $EXPECTED_PCI_ID, Detected: $PCI_ID) in non-interactive mode"
                exit 1
            elif [[ "$mode" == "apply" ]]; then
                color_echo "$COLOR_YELLOW" "Warning: PCI ID mismatch (Config: $EXPECTED_PCI_ID, Detected: $PCI_ID). Proceeding with interactive confirmation."
                read -p "Continue with detected GPU? [y/N]: " confirm
                [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { color_echo "$COLOR_RED" "Aborted due to PCI ID mismatch"; exit 1; }
            elif [[ "$mode" == "reset" || "$mode" == "status" ]]; then
                color_echo "$COLOR_YELLOW" "Warning: PCI ID mismatch (Config: $EXPECTED_PCI_ID, Detected: $PCI_ID; Not applying profile)."
            fi
        fi
    fi
}

# Read hardware default settings directly from sysfs
read_hardware_defaults() {
    color_echo "$COLOR_CYAN" "Raw pp_od_clk_voltage content:"
    local pp_od_data
    if ! pp_od_data=$(timeout "$SYSFS_TIMEOUT" cat "${PP_OD_PATH}" 2>/dev/null | tr -d '\0'); then
        color_echo "$COLOR_RED" "Error: Failed to read pp_od_clk_voltage"
    else
        echo "$pp_od_data" >&2
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
    MCLK_PSTATES=()
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
            # Fixed parsing for SCLK_OFFSET
            SCLK_OFFSET_DEFAULT=$(echo "$pp_od_data" | awk '/OD_SCLK_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Hh][zZ]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || echo "0")
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed SCLK_OFFSET_DEFAULT=$SCLK_OFFSET_DEFAULT"
            SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK_OFFSET:.*[Mm][Hh][zZ]" | grep -o "[0-9-]\+" | head -n 1 || echo "-500")
            SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK_OFFSET:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "1000")
            MCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "1500")
            MCLK_MIN=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || echo "97")
            MCLK_MAX=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "1500")
            MCLK_PSTATES=(0 "$MCLK_DEFAULT")
        else
            if [[ "$RDNA_GEN" == "1" ]]; then
                for ((i=0; i<=PSTATE_MAX; i++)); do
                    pstate_val=$(echo "$pp_od_data" | grep -A$((PSTATE_MAX+1)) "OD_SCLK" | grep -i "$i:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "0")
                    SCLK_PSTATES+=("$pstate_val")
                    [[ "$i" -eq 1 ]] && SCLK_DEFAULT="$pstate_val"
                done
                SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || echo "255")
                SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "3000")
            else
                SCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_SCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "3000")
                SCLK_MIN=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || echo "255")
                SCLK_MAX=$(echo "$pp_od_data" | grep -i "SCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "3000")
                SCLK_PSTATES=(0 "$SCLK_DEFAULT")
            fi
            MCLK_DEFAULT=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "1200")
            MCLK_MIN=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | head -n 1 || echo "97")
            MCLK_MAX=$(echo "$pp_od_data" | grep -i "MCLK:.*[Mm][Hh][zZ]" | grep -o "[0-9]\+" | tail -n 1 || echo "1200")
            MCLK_PSTATES=(0 "$MCLK_DEFAULT")
        fi

        # Parse voltage offset settings for RDNA2+ if supported
        if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
            VDDGFX_OFFSET_DEFAULT=$(echo "$pp_od_data" | awk '/OD_VDDGFX_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Vv]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || echo "0")
            VDDGFX_OFFSET_MIN=$(echo "$pp_od_data" | grep -i "VDDGFX_OFFSET:.*[Mm][Vv]" | grep -o "[0-9-]\+" | head -n 1 || echo "-200")
            VDDGFX_OFFSET_MAX=$(echo "$pp_od_data" | grep -i "VDDGFX_OFFSET:.*[Mm][Vv]" | grep -o "[0-9]\+" | tail -n 1 || echo "200")
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed VDDGFX_OFFSET_DEFAULT=$VDDGFX_OFFSET_DEFAULT (range: $VDDGFX_OFFSET_MIN to $VDDGFX_OFFSET_MAX mV)"
        fi
    else
        color_echo "$COLOR_YELLOW" "pp_od_clk_voltage is empty or unreadable, using fallback defaults"
    fi

    # Read power cap settings from hardware
    if [[ -f "${POWER_CAP_MAX_PATH}" ]]; then
        POWER_CAP_MAX=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_MAX_PATH}" 2>/dev/null | tr -d '\0' || echo "0")
    fi
    if [[ -f "${POWER_CAP_DEFAULT_PATH}" ]]; then
        POWER_CAP_DEFAULT=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_DEFAULT_PATH}" 2>/dev/null | tr -d '\0' || echo "$POWER_CAP_MAX")
    else
        POWER_CAP_DEFAULT="$POWER_CAP_MAX"
    fi
    POWER_CAP=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_PATH}" 2>/dev/null | tr -d '\0' || echo "$POWER_CAP_DEFAULT")
    POWER_CAP=${POWER_CAP:-0}
    POWER_CAP_MAX_DEFAULT="$POWER_CAP_DEFAULT"

    # Read zero RPM setting from hardware
    ZERO_RPM_DEFAULT=$(timeout "$SYSFS_TIMEOUT" cat "${ZERO_RPM_PATH}" 2>/dev/null | tr -d '\0' | grep -A1 -i "^FAN_ZERO_RPM_ENABLE:" | grep -o "[0-1]" | head -n 1 || echo "0")
    # Default to disabling zero RPM for consistent fan curve behavior
    ZERO_RPM=0

    # Read fan curve settings based on junction temperature from hardware
    if [[ -f "${FAN_CURVE_PATH}" ]]; then
        FAN_CURVE=()
        local invalid_curve=false
        local has_valid_points=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^[0-4]:[[:space:]]*([0-9]+)C[[:space:]]*([0-9]+)% ]]; then
                point=${line%%:*}
                temp=${BASH_REMATCH[1]}
                speed=${BASH_REMATCH[2]}
                FAN_CURVE+=("$point $temp $speed")
                has_valid_points=true
                [[ "$temp" -eq 0 || "$speed" -eq 0 ]] && invalid_curve=true
                [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Parsed fan curve point: $point $temp $speed"
            fi
        done < <(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' || echo "")
        TEMP_MIN=$(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' | grep -i "FAN_CURVE(hotspot temp):" | grep -o "[0-9]\+" | head -n 1 || echo "25")
        TEMP_MAX=$(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' | grep -i "FAN_CURVE(hotspot temp):" | grep -o "[0-9]\+" | tail -n 1 || echo "110")
        SPEED_MIN=$(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' | grep -i "FAN_CURVE(fan speed):" | grep -o "[0-9]\+" | head -n 1 || echo "15")
        SPEED_MAX=$(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' | grep -i "FAN_CURVE(fan speed):" | grep -o "[0-9]\+" | tail -n 1 || echo "100")
        if [[ "$has_valid_points" == true && ${#FAN_CURVE[@]} -eq 5 && "$invalid_curve" == false ]]; then
            color_echo "$COLOR_GREEN" "Valid junction fan curve detected with ${#FAN_CURVE[@]} points"
        else
            color_echo "$COLOR_YELLOW" "No valid junction fan curve found or invalid points detected, using fallback curve (RDNA GPUs typically use temperature targets)"
            FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
        fi
    else
        color_echo "$COLOR_YELLOW" "fan_curve sysfs path not found, using fallback junction curve (RDNA GPUs typically use temperature targets)"
        FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
    fi
    TEMP_MIN=${TEMP_MIN:-25}
    TEMP_MAX=${TEMP_MAX:-110}
    SPEED_MIN=${SPEED_MIN:-15}
    SPEED_MAX=${SPEED_MAX:-100}
    FAN_CURVE_DEFAULT=("${FAN_CURVE[@]}")
    EXPECTED_PCI_ID=${PCI_ID:-"1002:FFFF"}
}

# Display current GPU settings directly from hardware
print_status() {
    local skip_config_comparison="$1"
    color_echo "$COLOR_CYAN" "=== GPU Status (PCI ID: $PCI_ID, RDNA Generation: $RDNA_GEN) ==="

    # Check for PCI ID mismatch if config comparison is enabled
    if [[ "$skip_config_comparison" != "1" ]]; then
        check_pci_id "status"
    fi

    # Read current settings directly from sysfs
    local current_sclk current_sclk_offset current_mclk current_power_cap current_zero_rpm current_vddgfx_offset
    local pp_od_data
    pp_od_data=$(timeout "$SYSFS_TIMEOUT" cat "${PP_OD_PATH}" 2>/dev/null | tr -d '\0')
    if [[ "$RDNA_GEN" == "4" ]]; then
        if [[ -n "$pp_od_data" ]]; then
            # Fixed parsing for SCLK_OFFSET
            current_sclk_offset=$(echo "$pp_od_data" | awk '/OD_SCLK_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Hh][zZ]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || echo "N/A")
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Current SCLK_OFFSET parsed as: $current_sclk_offset"
        else
            current_sclk_offset="N/A"
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: pp_od_clk_voltage is empty or unreadable"
        fi
    else
        current_sclk=$(echo "$pp_od_data" | grep -A$((PSTATE_MAX+1)) "OD_SCLK" | grep -i "1:.*[Mm][Hh][zZ]" | awk '{print $2}' | grep -o "[0-9]\+" || echo "N/A")
    fi
    current_mclk=$(echo "$pp_od_data" | grep -A2 "OD_MCLK" | grep -i "1:.*[Mm][Hh][zZ]" | awk '{print $2}' | grep -o "[0-9]\+" || echo "N/A")
    
    # Parse voltage offset for RDNA2+
    if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
        current_vddgfx_offset=$(echo "$pp_od_data" | awk '/OD_VDDGFX_OFFSET:/{getline; if ($0 ~ /[0-9-]+\s*[Mm][Vv]/) print $0}' | grep -o "[0-9-]\+" | head -n 1 || echo "N/A")
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Current VDDGFX_OFFSET parsed as: $current_vddgfx_offset"
    fi

    current_power_cap=$(timeout "$SYSFS_TIMEOUT" cat "${POWER_CAP_PATH}" 2>/dev/null | tr -d '\0' || echo "N/A")
    current_zero_rpm=$(timeout "$SYSFS_TIMEOUT" cat "${ZERO_RPM_PATH}" 2>/dev/null | tr -d '\0' | grep -A1 -i "^FAN_ZERO_RPM_ENABLE:" | grep -o "[0-1]" | head -n 1 || echo "N/A")
    local -a current_fan_curve=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-4]:[[:space:]]*([0-9]+)C[[:space:]]*([0-9]+)% ]]; then
            point=${line%%:*}
            temp=${BASH_REMATCH[1]}
            speed=${BASH_REMATCH[2]}
            current_fan_curve+=("$point $temp $speed")
        fi
    done < <(timeout "$SYSFS_TIMEOUT" cat "${FAN_CURVE_PATH}" 2>/dev/null | tr -d '\0' || echo "")

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
        color_echo "$COLOR_GREEN" "  Current: $((current_power_cap / 1000000))"
        color_echo "$COLOR_CYAN" "Zero RPM:"
        color_echo "$COLOR_GREEN" "  Current: $current_zero_rpm"
        color_echo "$COLOR_CYAN" "Junction Fan Curve:"
        if [[ ${#current_fan_curve[@]} -eq 0 ]]; then
            color_echo "$COLOR_YELLOW" "  No valid junction fan curve points detected"
        else
            for i in "${!current_fan_curve[@]}"; do
                color_echo "$COLOR_GREEN" "  Point $i: ${current_fan_curve[i]}"
            done
        fi
    else
        # Load intended settings from config or hardware defaults
        local intended_sclk="$SCLK_DEFAULT" intended_sclk_offset="$SCLK_OFFSET_DEFAULT" intended_mclk="$MCLK_DEFAULT" intended_power_cap="$POWER_CAP_DEFAULT" intended_zero_rpm="$ZERO_RPM" intended_vddgfx_offset="$VDDGFX_OFFSET_DEFAULT"
        local -a intended_fan_curve=("${FAN_CURVE_DEFAULT[@]}")
        if [[ -f "$CONFIG_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$CONFIG_FILE"
            if [[ "$RDNA_GEN" == "4" ]]; then
                intended_sclk_offset="$SCLK_OFFSET"
            else
                intended_sclk="$SCLK"
            fi
            intended_mclk="$MCLK"
            intended_power_cap="$POWER_CAP"
            intended_zero_rpm="$ZERO_RPM"
            if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]]; then
                intended_vddgfx_offset="$VDDGFX_OFFSET"
            fi
            intended_fan_curve=("${FAN_CURVE[@]}")
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
        local match=true
        for i in "${!intended_fan_curve[@]}"; do
            if [[ "${current_fan_curve[i]}" == "${intended_fan_curve[i]}" ]]; then
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
}

# Load and validate configuration settings from file
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if is_interactive; then
            color_echo "$COLOR_YELLOW" "Warning: Config file $CONFIG_FILE not found, launching interactive config creation"
            create_config 1
        else
            color_echo "$COLOR_RED" "Error: Config file $CONFIG_FILE not found in non-interactive mode, not applying profile"
            exit 1
        fi
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Validate configuration parameters
    [[ -z "$EXPECTED_PCI_ID" ]] && { color_echo "$COLOR_RED" "Error: EXPECTED_PCI_ID not set in config"; exit 1; }
    if [[ "$RDNA_GEN" == "4" ]]; then
        [[ -z "$SCLK_OFFSET" ]] && { color_echo "$COLOR_RED" "Error: SCLK_OFFSET not set in config"; exit 1; }
        [[ ! "$SCLK_OFFSET" =~ ^-?[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid SCLK_OFFSET: $SCLK_OFFSET"; exit 1; }
        [[ "$SCLK_OFFSET" -lt "$SCLK_MIN" ]] && { color_echo "$COLOR_RED" "Error: SCLK_OFFSET $SCLK_OFFSET below minimum $SCLK_MIN"; exit 1; }
        [[ "$SCLK_OFFSET" -gt "$SCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: SCLK_OFFSET $SCLK_OFFSET above maximum $SCLK_MAX"; exit 1; }
        [[ -z "$MCLK" ]] && { color_echo "$COLOR_RED" "Error: MCLK not set in config"; exit 1; }
        [[ ! "$MCLK" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid MCLK: $MCLK"; exit 1; }
        [[ "$MCLK" -lt "$MCLK_MIN" ]] && { color_echo "$COLOR_RED" "Error: MCLK $MCLK below minimum $MCLK_MIN"; exit 1; }
        [[ "$MCLK" -gt "$MCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: MCLK $MCLK above maximum $MCLK_MAX"; exit 1; }
    else
        [[ -z "$SCLK" ]] && { color_echo "$COLOR_RED" "Error: SCLK not set in config"; exit 1; }
        [[ ! "$SCLK" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid SCLK: $SCLK"; exit 1; }
        [[ "$SCLK" -lt "$SCLK_MIN" ]] && { color_echo "$COLOR_RED" "Error: SCLK $SCLK below minimum $SCLK_MIN"; exit 1; }
        [[ "$SCLK" -gt "$SCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: SCLK $SCLK above maximum $SCLK_MAX"; exit 1; }
        [[ -z "$MCLK" ]] && { color_echo "$COLOR_RED" "Error: MCLK not set in config"; exit 1; }
        [[ ! "$MCLK" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid MCLK: $MCLK"; exit 1; }
        [[ "$MCLK" -lt "$MCLK_MIN" ]] && { color_echo "$COLOR_RED" "Error: MCLK $MCLK below minimum $MCLK_MIN"; exit 1; }
        [[ "$MCLK" -gt "$MCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: MCLK $MCLK above maximum $MCLK_MAX"; exit 1; }
    fi

    # Validate voltage offset for RDNA2+ if specified in config
    if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]]; then
        [[ ! "$VDDGFX_OFFSET" =~ ^-?[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid VDDGFX_OFFSET: $VDDGFX_OFFSET"; exit 1; }
        [[ "$VDDGFX_OFFSET" -lt "$VDDGFX_OFFSET_MIN" ]] && { color_echo "$COLOR_RED" "Error: VDDGFX_OFFSET $VDDGFX_OFFSET below minimum $VDDGFX_OFFSET_MIN"; exit 1; }
        [[ "$VDDGFX_OFFSET" -gt "$VDDGFX_OFFSET_MAX" ]] && { color_echo "$COLOR_RED" "Error: VDDGFX_OFFSET $VDDGFX_OFFSET above maximum $VDDGFX_OFFSET_MAX"; exit 1; }
    elif [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 0 && -n "$VDDGFX_OFFSET" ]]; then
        color_echo "$COLOR_YELLOW" "Warning: VDDGFX_OFFSET specified but not supported on RDNA1, ignoring"
        VDDGFX_OFFSET=""
    fi

    [[ -z "$POWER_CAP" ]] && { color_echo "$COLOR_RED" "Error: POWER_CAP not set in config"; exit 1; }
    [[ ! "$POWER_CAP" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid POWER_CAP: $POWER_CAP"; exit 1; }
    [[ "$POWER_CAP" -lt 0 ]] && { color_echo "$COLOR_RED" "Error: POWER_CAP $POWER_CAP below minimum 0"; exit 1; }
    [[ "$POWER_CAP" -gt "$POWER_CAP_MAX" ]] && { color_echo "$COLOR_RED" "Error: POWER_CAP $POWER_CAP above maximum $POWER_CAP_MAX"; exit 1; }
    [[ -z "$ZERO_RPM" ]] && { color_echo "$COLOR_RED" "Error: ZERO_RPM not set in config"; exit 1; }
    [[ ! "$ZERO_RPM" =~ ^[0-1]$ ]] && { color_echo "$COLOR_RED" "Error: Invalid ZERO_RPM: $ZERO_RPM"; exit 1; }
    if [[ ${#FAN_CURVE[@]} -eq 0 ]]; then
        color_echo "$COLOR_CYAN" "No existing FAN_CURVE found, using fallback junction curve"
        FAN_CURVE=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
    fi
    if [[ ${#FAN_CURVE[@]} -ne 5 ]]; then
        color_echo "$COLOR_RED" "Error: FAN_CURVE must have exactly 5 points, found ${#FAN_CURVE[@]}"
        exit 1
    fi
    for point in "${FAN_CURVE[@]}"; do
        [[ ! "$point" =~ ^[0-4][[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid FAN_CURVE point: $point"; exit 1; }
        read -r idx temp speed <<< "$point"
        [[ "$temp" -lt "$TEMP_MIN" ]] && { color_echo "$COLOR_RED" "Error: Fan curve point $idx temperature $temp below minimum $TEMP_MIN"; exit 1; }
        [[ "$temp" -gt "$TEMP_MAX" ]] && { color_echo "$COLOR_RED" "Error: Fan curve point $idx temperature $temp above maximum $TEMP_MAX"; exit 1; }
        [[ "$speed" -lt "$SPEED_MIN" ]] && { color_echo "$COLOR_RED" "Error: Fan curve point $idx speed $speed below minimum $SPEED_MIN"; exit 1; }
        [[ "$speed" -gt "$SPEED_MAX" ]] && { color_echo "$COLOR_RED" "Error: Fan curve point $idx speed $speed above maximum $SPEED_MAX"; exit 1; }
    done
}

# Apply GPU settings based on configuration with simultaneous commit
apply_settings() {
    [[ "$DRY_RUN_MODE" -eq 1 ]] && { color_echo "$COLOR_YELLOW" "Dry-run mode: Settings not applied"; exit 0; }

    # Set power profile to manual
    check_writable "$POWER_PROFILE_PATH"
    echo "manual" > "$POWER_PROFILE_PATH" || { color_echo "$COLOR_RED" "Error: Failed to set manual power profile"; exit 1; }

    # Apply power cap
    check_writable "$POWER_CAP_PATH"
    echo "$POWER_CAP" > "$POWER_CAP_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write to power1_cap"; exit 1; }

    # Apply settings for simultaneous commit
    if [[ "$RDNA_GEN" == "4" ]]; then
        local settings_str="SCLK_OFFSET=$SCLK_OFFSET MHz, MCLK=$MCLK MHz"
        [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]] && settings_str+=", VDDGFX_OFFSET=$VDDGFX_OFFSET mV"
        settings_str+=", POWER_CAP=$((POWER_CAP / 1000000)) W, ZERO_RPM=$ZERO_RPM"
        color_echo "$COLOR_CYAN" "Applying settings: $settings_str"
        
        check_writable "$PP_OD_PATH"
        check_writable "$FAN_CURVE_PATH"
        check_writable "$ZERO_RPM_PATH"
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing SCLK_OFFSET=$SCLK_OFFSET to $PP_OD_PATH"
        echo "s $SCLK_OFFSET" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write SCLK_OFFSET to pp_od_clk_voltage"; exit 1; }
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing MCLK=$MCLK to $PP_OD_PATH"
        echo "m 1 $MCLK" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write MCLK to pp_od_clk_voltage"; exit 1; }
        
        # Apply voltage offset if supported and specified
        if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]]; then
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing VDDGFX_OFFSET=$VDDGFX_OFFSET to $PP_OD_PATH"
            echo "vo $VDDGFX_OFFSET" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write VDDGFX_OFFSET to pp_od_clk_voltage"; exit 1; }
        fi
        
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing ZERO_RPM=$ZERO_RPM to $ZERO_RPM_PATH"
        echo "$ZERO_RPM" > "$ZERO_RPM_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write to fan_zero_rpm_enable"; exit 1; }
        for point in "${FAN_CURVE[@]}"; do
            read -r idx temp speed <<< "$point"
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing fan curve point $idx $temp $speed to $FAN_CURVE_PATH"
            echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write to fan_curve"; exit 1; }
        done
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Committing settings to $PP_OD_PATH, $FAN_CURVE_PATH, $ZERO_RPM_PATH"
        if ! echo "c" | tee "$PP_OD_PATH" "$FAN_CURVE_PATH" "$ZERO_RPM_PATH" >/dev/null; then
            color_echo "$COLOR_RED" "Error: Failed to commit settings"
            exit 1
        fi
    else
        local settings_str="SCLK=$SCLK MHz, MCLK=$MCLK MHz"
        [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]] && settings_str+=", VDDGFX_OFFSET=$VDDGFX_OFFSET mV"
        settings_str+=", POWER_CAP=$((POWER_CAP / 1000000)) W, ZERO_RPM=$ZERO_RPM"
        color_echo "$COLOR_CYAN" "Applying settings: $settings_str"
        
        check_writable "$PP_OD_PATH"
        check_writable "$FAN_CURVE_PATH"
        check_writable "$ZERO_RPM_PATH"
        if [[ "$RDNA_GEN" == "1" ]]; then
            for ((i=0; i<=PSTATE_MAX; i++)); do
                local sclk_val="${SCLK_PSTATES[i]:-$SCLK}"
                [[ "$i" -eq 1 ]] && sclk_val="$SCLK"
                [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing SCLK PSTATE $i=$sclk_val to $PP_OD_PATH"
                echo "s $i $sclk_val" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write SCLK PSTATE $i to pp_od_clk_voltage"; exit 1; }
            done
        else
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing SCLK=$SCLK to $PP_OD_PATH"
            echo "s 1 $SCLK" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write SCLK to pp_od_clk_voltage"; exit 1; }
        fi
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing MCLK=$MCLK to $PP_OD_PATH"
        echo "m 1 $MCLK" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write MCLK to pp_od_clk_voltage"; exit 1; }
        
        # Apply voltage offset if supported and specified
        if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 && -n "$VDDGFX_OFFSET" ]]; then
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing VDDGFX_OFFSET=$VDDGFX_OFFSET to $PP_OD_PATH"
            echo "vo $VDDGFX_OFFSET" > "$PP_OD_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write VDDGFX_OFFSET to pp_od_clk_voltage"; exit 1; }
        fi
        
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing ZERO_RPM=$ZERO_RPM to $ZERO_RPM_PATH"
        echo "$ZERO_RPM" > "$ZERO_RPM_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write to fan_zero_rpm_enable"; exit 1; }
        for point in "${FAN_CURVE[@]}"; do
            read -r idx temp speed <<< "$point"
            [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Writing fan curve point $idx $temp $speed to $FAN_CURVE_PATH"
            echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { color_echo "$COLOR_RED" "Error: Failed to write to fan_curve"; exit 1; }
        done
        [[ "$DEBUG_MODE" -eq 1 ]] && color_echo "$COLOR_YELLOW" "Debug: Committing settings to $PP_OD_PATH, $FAN_CURVE_PATH, $ZERO_RPM_PATH"
        if ! echo "c" | tee "$PP_OD_PATH" "$FAN_CURVE_PATH" "$ZERO_RPM_PATH" >/dev/null; then
            color_echo "$COLOR_RED" "Error: Failed to commit settings"
            exit 1
        fi
    fi

    color_echo "$COLOR_GREEN" "Settings applied successfully"
}

# Create configuration file, either interactively or with safe defaults
create_config() {
    local interactive="$1"
    color_echo "$COLOR_CYAN" "Creating configuration file: $CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" && color_echo "$COLOR_YELLOW" "Backed up existing config to ${CONFIG_FILE}.bak"
    local sclk_proposed mclk_proposed power_cap_proposed zero_rpm_proposed vddgfx_offset_proposed
    local -a fan_curve_proposed
    if [[ "$interactive" -eq 1 ]]; then
        color_echo "$COLOR_GREEN" "==> Enter a value or simply hit ENTER to use the proposed value"
        if [[ "$RDNA_GEN" == "4" ]]; then
            color_echo "$COLOR_CYAN" "Enter SCLK_OFFSET (MHz, range $SCLK_MIN-$SCLK_MAX, hardware default $SCLK_OFFSET_DEFAULT, proposed 0):"
            read -r sclk_offset
            sclk_offset=${sclk_offset:-$SCLK_OFFSET_DEFAULT}
            [[ ! "$sclk_offset" =~ ^-?[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid SCLK_OFFSET"; exit 1; }
            [[ "$sclk_offset" -lt "$SCLK_MIN" || "$sclk_offset" -gt "$SCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: SCLK_OFFSET out of range"; exit 1; }
        else
            color_echo "$COLOR_CYAN" "Enter SCLK (MHz, range $SCLK_MIN-$SCLK_MAX, hardware default $SCLK_DEFAULT, proposed $SCLK_MAX):"
            read -r sclk
            sclk=${sclk:-$SCLK_DEFAULT}
            [[ ! "$sclk" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid SCLK"; exit 1; }
            [[ "$sclk" -lt "$SCLK_MIN" || "$sclk" -gt "$SCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: SCLK out of range"; exit 1; }
        fi

        color_echo "$COLOR_CYAN" "Enter MCLK (MHz, range $MCLK_MIN-$MCLK_MAX, hardware default $MCLK_DEFAULT, proposed $MCLK_DEFAULT):"
        read -r mclk
        mclk=${mclk:-$MCLK_DEFAULT}
        [[ ! "$mclk" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid MCLK"; exit 1; }
        [[ "$mclk" -lt "$MCLK_MIN" || "$mclk" -gt "$MCLK_MAX" ]] && { color_echo "$COLOR_RED" "Error: MCLK out of range"; exit 1; }

        # Ask for voltage offset if supported
        if [[ "$SUPPORTS_VOLTAGE_OFFSET" -eq 1 ]]; then
            color_echo "$COLOR_YELLOW" "Note: Voltage offset can improve stability or allow higher clocks. Use negative values to undervolt."
            color_echo "$COLOR_CYAN" "Enter VDDGFX_OFFSET (mV, range $VDDGFX_OFFSET_MIN-$VDDGFX_OFFSET_MAX, hardware default $VDDGFX_OFFSET_DEFAULT, proposed 0):"
            read -r vddgfx_offset
            vddgfx_offset=${vddgfx_offset:-0}
            [[ ! "$vddgfx_offset" =~ ^-?[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid VDDGFX_OFFSET"; exit 1; }
            [[ "$vddgfx_offset" -lt "$VDDGFX_OFFSET_MIN" || "$vddgfx_offset" -gt "$VDDGFX_OFFSET_MAX" ]] && { color_echo "$COLOR_RED" "Error: VDDGFX_OFFSET out of range"; exit 1; }
        fi

        color_echo "$COLOR_CYAN" "Enter POWER_CAP (Watts, range 0-$((POWER_CAP_MAX / 1000000)), hardware default $((POWER_CAP_DEFAULT / 1000000)), proposed $((POWER_CAP_MAX / 1000000))):"
        read -r power_cap
        power_cap=${power_cap:-$((POWER_CAP_DEFAULT / 1000000))}
        [[ ! "$power_cap" =~ ^[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid POWER_CAP"; exit 1; }
        power_cap=$((power_cap * 1000000))
        [[ "$power_cap" -lt 0 || "$power_cap" -gt "$POWER_CAP_MAX" ]] && { color_echo "$COLOR_RED" "Error: POWER_CAP out of range"; exit 1; }

        color_echo "$COLOR_YELLOW" "Note: If enabled, zero RPM (complete fan spindown) may interfere with custom fan curve behavior."
        color_echo "$COLOR_CYAN" "Enter ZERO_RPM (0 or 1, hardware default $ZERO_RPM_DEFAULT, proposed 0):"
        read -r zero_rpm
        zero_rpm=${zero_rpm:-0}
        [[ ! "$zero_rpm" =~ ^[0-1]$ ]] && { color_echo "$COLOR_RED" "Error: Invalid ZERO_RPM"; exit 1; }

        color_echo "$COLOR_CYAN" "Enter FAN_CURVE (5 points: idx temp speed, e.g., '0 45 30') for junction temperature:"
        local -a fan_curve
        for i in {0..4}; do
            color_echo "$COLOR_CYAN" "Point $i (temp range $TEMP_MIN-$TEMP_MAX C, speed range $SPEED_MIN-$SPEED_MAX %, hardware default ${FAN_CURVE_DEFAULT[i]}, proposed ${FAN_CURVE_DEFAULT[i]}):"
            read -r point
            point=${point:-${FAN_CURVE_DEFAULT[i]}}
            [[ ! "$point" =~ ^[0-4][[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] && { color_echo "$COLOR_RED" "Error: Invalid junction fan curve point"; exit 1; }
            read -r idx temp speed <<< "$point"
            [[ "$idx" -ne "$i" ]] && { color_echo "$COLOR_RED" "Error: Fan curve point index must be $i"; exit 1; }
            [[ "$temp" -lt "$TEMP_MIN" || "$temp" -gt "$TEMP_MAX" ]] && { color_echo "$COLOR_RED" "Error: Junction temperature out of range"; exit 1; }
            [[ "$speed" -lt "$SPEED_MIN" || "$speed" -gt "$SPEED_MAX" ]] && { color_echo "$COLOR_RED" "Error: Speed out of range"; exit 1; }
            fan_curve+=("$point")
        done
    else
        if [[ "$RDNA_GEN" == "1" ]]; then
            sclk="$SCLK_DEFAULT"
            sclk_proposed="$SCLK_DEFAULT"
            mclk="$MCLK_DEFAULT"
            mclk_proposed="$MCLK_DEFAULT"
            power_cap="$POWER_CAP_MAX"
            power_cap_proposed="$POWER_CAP_MAX"
            zero_rpm=0
            zero_rpm_proposed=0
            fan_curve=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
            fan_curve_proposed=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
            # RDNA1 doesn't support voltage offset
            vddgfx_offset=""
            vddgfx_offset_proposed=""
        else
            if [[ "$RDNA_GEN" == "4" ]]; then
                sclk_offset="$SCLK_OFFSET_DEFAULT"
                sclk_offset_proposed="$SCLK_OFFSET_DEFAULT"
            else
                sclk="$SCLK_MAX"
                sclk_proposed="$SCLK_MAX"
            fi
            mclk="$MCLK_DEFAULT"
            mclk_proposed="$MCLK_DEFAULT"
            power_cap="$POWER_CAP_MAX"
            power_cap_proposed="$POWER_CAP_MAX"
            zero_rpm=0
            zero_rpm_proposed=0
            fan_curve=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
            fan_curve_proposed=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
            # RDNA2+ supports voltage offset, default to 0 (no offset)
            vddgfx_offset="$VDDGFX_OFFSET_DEFAULT"
            vddgfx_offset_proposed="0"
        fi
    fi

    # Generate FAN_CURVE array string for config file
    local fan_curve_str=""
    for point in "${fan_curve[@]}"; do
        fan_curve_str+=$(printf '"%s" ' "$point")
    done

    # Generate FAN_CURVE proposed string for config comments
    local fan_curve_proposed_str=""
    for point in "${fan_curve_proposed[@]:-${FAN_CURVE_DEFAULT[@]}}"; do
        fan_curve_proposed_str+=$(printf "\n#     Point %s" "$point")
    done

    # Write configuration file with improved comments
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
# Proposed default: ${power_cap_proposed:-$POWER_CAP_MAX} microWatts ($((power_cap_proposed / 1000000)) W)

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
    else
        cat << EOF > "$CONFIG_FILE"
# AMD RDNA GPU Overclocking and Fan Curve Configuration
# PCI ID of the target GPU
EXPECTED_PCI_ID="$PCI_ID"

# Core clock (MHz)
SCLK=$sclk
# Range: $SCLK_MIN to $SCLK_MAX MHz
# Hardware default: $SCLK_DEFAULT MHz
# Proposed default: ${sclk_proposed:-$SCLK_MAX} MHz

# Memory clock (MHz)
MCLK=$mclk
# Range: $MCLK_MIN to $MCLK_MAX MHz
# Hardware default: $MCLK_DEFAULT MHz
# Proposed default: ${mclk_proposed:-$MCLK_DEFAULT} MHz

EOF
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
# Proposed default: ${power_cap_proposed:-$POWER_CAP_MAX} microWatts ($((power_cap_proposed / 1000000)) W)

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
    fi
    chmod 644 "$CONFIG_FILE"
    color_echo "$COLOR_GREEN" "Configuration file created: $CONFIG_FILE"
}

# Reset GPU to default settings
reset_gpu() {
    color_echo "$COLOR_YELLOW" "Resetting GPU to default settings..."
    check_writable "$PP_OD_PATH"
    if ! echo "r" > "$PP_OD_PATH" 2>/dev/null; then
        color_echo "$COLOR_RED" "Error: Failed to reset GPU settings"
        exit 1
    fi
    if [[ -w "$POWER_CAP_PATH" && -f "$POWER_CAP_DEFAULT_PATH" ]]; then
        check_writable "$POWER_CAP_PATH"
        cat "$POWER_CAP_DEFAULT_PATH" > "$POWER_CAP_PATH" || { color_echo "$COLOR_RED" "Error: Failed to reset power1_cap"; exit 1; }
    fi
    if [[ -w "$ZERO_RPM_PATH" ]]; then
        check_writable "$ZERO_RPM_PATH"
        echo "0" > "$ZERO_RPM_PATH" || { color_echo "$COLOR_RED" "Error: Failed to reset fan_zero_rpm_enable"; exit 1; }
    fi
    if [[ -w "$FAN_CURVE_PATH" ]]; then
        check_writable "$FAN_CURVE_PATH"
        if ! echo "r" > "$FAN_CURVE_PATH" 2>/dev/null || ! grep -qE '[1-9][0-9]*C [1-9][0-9]*%' "$FAN_CURVE_PATH"; then
            color_echo "$COLOR_YELLOW" "Warning: Failed to reset fan_curve or invalid curve returned, applying fallback junction curve"
            local default_fan_curve=("0 45 30" "1 55 40" "2 65 50" "3 75 70" "4 85 100")
            for point in "${default_fan_curve[@]}"; do
                read -r idx temp speed <<< "$point"
                echo "$idx $temp $speed" > "$FAN_CURVE_PATH" || { color_echo "$COLOR_RED" "Error: Failed to apply fallback junction fan_curve"; exit 1; }
            done
            if ! echo "c" | tee "$PP_OD_PATH" "$FAN_CURVE_PATH" "$ZERO_RPM_PATH" >/dev/null; then
                color_echo "$COLOR_RED" "Error: Failed to commit fallback settings"
                exit 1
            fi
        fi
    fi
    check_writable "$POWER_PROFILE_PATH"
    echo "auto" > "$POWER_PROFILE_PATH" || { color_echo "$COLOR_RED" "Error: Failed to reset power_dpm_force_performance_level"; exit 1; }
    color_echo "$COLOR_GREEN" "GPU settings reset successfully"
}

# Main execution logic
find_card_paths
check_overdrive
detect_rdna_gen
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
