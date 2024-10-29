#!/bin/bash

# Define colors for console output
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
BOLD=$'\e[1m'
NC=$'\e[0m'  # No color

# Function to display formatted table
print_header() {
    printf "%-110s | %-12s | %-25s | %-10s\n" "GPU Name" "PCI Address" "Action" "Status"
    printf "%-110s | %-12s | %-25s | %-10s\n" "--------------------------------------------------------------------------------------------------------------" "------------" "-------------------------" "----------"
}

print_row() {
    local gpu_name=$1
    local pci_id=$2
    local action=$3
    local status=$4
    printf "%-110s | %-12s | %-25s | %-10s\n" "$gpu_name" "$pci_id" "$action" "$status"
}

# Function to extract AMD GPUs and their PCI addresses
get_amd_gpus() {
    local amd_gpus=()
    while IFS= read -r line; do
        if echo "$line" | grep -q "AMD"; then
            pci_id=$(echo "$line" | awk '{print $1}')
            amd_gpus+=("$pci_id")
        fi
    done < <(lspci | grep "VGA compatible controller")

    if [ ${#amd_gpus[@]} -eq 0 ]; then
        echo -e "${RED}No AMD GPUs found.${NC}"
        exit 1
    fi

    echo "${amd_gpus[@]}"  # Return the list of AMD GPUs
}

# Function to apply settings via amd-oc
apply_amd_oc() {
    local pci_id=$1
    local mode=$2
    local gpu_info
    local action
    gpu_info=$(lspci -s "$pci_id" | grep "VGA compatible controller" | cut -d ' ' -f 5-)

    case "$mode" in
        "energy")
            action="amd-oc energy-saving"
            if amd-oc --bus "$pci_id" --core-clock 300 --mem-clock 300 --soc-clock 300 --vdd 600 --mvdd 700 --fan 20 --pl 30 &>/dev/null; then
                status="${GREEN}Applied${NC}"
            else
                status="${RED}Failed${NC}"
            fi
            print_row "$gpu_info" "$pci_id" "$action" "$status"
            ;;
        "performance")
            action="amd-oc performance"
            if amd-oc --bus "$pci_id" --core-clock 1750 --mem-clock 1800 --soc-clock 1100 --vdd 1150 --mvdd 1350 --fan 100 --pl 225 &>/dev/null; then
                status="${GREEN}Applied${NC}"
            else
                status="${RED}Failed${NC}"
            fi
            print_row "$gpu_info" "$pci_id" "$action" "$status"
            ;;
        "default")
            action="amd-oc default"
            if amd-oc --bus "$pci_id" --core-clock 1400 --mem-clock 1750 --soc-clock 890 --vdd 950 --mvdd 1250 --fan 70 --pl 180 &>/dev/null; then
                status="${GREEN}Applied${NC}"
            else
                status="${RED}Failed${NC}"
            fi
            print_row "$gpu_info" "$pci_id" "$action" "$status"
            ;;
        "remove"|"rescan")
            action="amd-oc $mode"
            # Skip amd-oc settings when removing or rescanning
            status="${YELLOW}Skipped${NC}"
            print_row "$gpu_info" "$pci_id" "$action" "$status"
            ;;
    esac
}

# Function to apply settings via direct device path for AMD GPUs only
apply_device_settings() {
    local card_index=$1
    local mode=$2
    local pci_id=$3

    device="/sys/class/drm/card${card_index}/device"
    if [[ -d "$device" && -f "$device/vendor" ]]; then
        vendor=$(cat "$device/vendor")
        if [[ "$vendor" == "0x1002" ]]; then
            local gpu_name=$(lspci -s "$pci_id" | grep "VGA compatible controller" | cut -d ' ' -f 5-)
            if [[ -f "$device/power_dpm_state" && -f "$device/power_dpm_force_performance_level" ]]; then
                local action
                case "$mode" in
                    "energy")
                        action="power_dpm energy-saving"
                        echo "battery" > "$device/power_dpm_state" 2>/dev/null
                        echo "low" > "$device/power_dpm_force_performance_level" 2>/dev/null
                        status="${GREEN}Applied${NC}"
                        ;;
                    "performance")
                        action="power_dpm performance"
                        echo "performance" > "$device/power_dpm_state" 2>/dev/null
                        echo "high" > "$device/power_dpm_force_performance_level" 2>/dev/null
                        status="${GREEN}Applied${NC}"
                        ;;
                    "default")
                        action="power_dpm default"
                        echo "balanced" > "$device/power_dpm_state" 2>/dev/null
                        echo "auto" > "$device/power_dpm_force_performance_level" 2>/dev/null
                        status="${GREEN}Applied${NC}"
                        ;;
                    "remove"|"rescan")
                        action="power_dpm $mode"
                        status="${YELLOW}Skipped${NC}"
                        ;;
                esac
            else
                action="power_dpm $mode"
                status="${RED}Skipped${NC} (No power management files)"
            fi
            print_row "$gpu_name" "$pci_id" "$action" "$status"
        fi
    fi
}

# Function to remove the GPU from the system
remove_gpu() {
    local pci_id=$1
    local gpu_info
    local action="remove GPU"
    gpu_info=$(lspci -s "$pci_id" | grep "VGA compatible controller" | cut -d ' ' -f 5-)

    if [ -w "/sys/bus/pci/devices/0000:${pci_id}/remove" ]; then
        echo "1" > "/sys/bus/pci/devices/0000:${pci_id}/remove" 2>/dev/null
        status="${GREEN}Removed${NC}"
    else
        status="${RED}Failed${NC} (Permission denied)"
    fi
    print_row "$gpu_info" "$pci_id" "$action" "$status"
}

# Function to rescan the PCI bus
rescan_pci_bus() {
    local action="PCI Bus Rescan"
    if [ -w "/sys/bus/pci/rescan" ]; then
        echo "1" > /sys/bus/pci/rescan
        status="${GREEN}Rescanned${NC}"
    else
        status="${RED}Failed${NC} (Permission denied)"
    fi
    # Since rescanning affects the whole bus, we can print a single line
    printf "%-110s | %-12s | %-25s | %-10s\n" "-" "-" "$action" "$status"
}

# Main unified function to apply all settings for each card
apply_settings() {
    local mode=$1

    if [[ "$mode" == "rescan" ]]; then
        # Rescan the PCI bus
        print_header
        rescan_pci_bus
        echo -e "${GREEN}PCI bus rescan completed.${NC}"
    else
        # Retrieve AMD GPUs
        local amd_gpus=($(get_amd_gpus))
        echo -e "${YELLOW}Detected ${#amd_gpus[@]} AMD GPU(s).${NC}"

        # Print table header
        print_header

        # Assign a simple sequential index (starting from 0) to each card
        local index=0
        for pci_id in "${amd_gpus[@]}"; do
            # Apply settings for each card
            if [[ "$mode" == "remove" ]]; then
                remove_gpu "$pci_id"
            else
                apply_amd_oc "$pci_id" "$mode"
                apply_device_settings "$index" "$mode" "$pci_id"
            fi
            index=$((index + 1))  # Increment index for each card
        done

        echo -e "${GREEN}All settings applied to ${#amd_gpus[@]} GPU(s).${NC}"
    fi
}

# Main script logic
case "$1" in
    "energy")
        echo -e "${YELLOW}Applying energy-saving settings...${NC}"
        apply_settings "energy"
        ;;
    "performance")
        echo -e "${YELLOW}Applying performance settings...${NC}"
        apply_settings "performance"
        ;;
    "default")
        echo -e "${YELLOW}Reverting settings to default...${NC}"
        apply_settings "default"
        ;;
    "remove")
        echo -e "${YELLOW}Removing GPUs from the system...${NC}"
        apply_settings "remove"
        ;;
    "rescan")
        echo -e "${YELLOW}Rescanning the PCI bus...${NC}"
        apply_settings "rescan"
        ;;
    *)
        echo -e "${RED}Usage: $0 [energy|performance|default|remove|rescan]${NC}"
        exit 1
        ;;
esac
