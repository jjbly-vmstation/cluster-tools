#!/usr/bin/env bash
# check-power-state.sh - Check power state of VMStation nodes
# Verifies power state and reachability of cluster nodes
#
# Usage: ./check-power-state.sh [OPTIONS] [hostname|ip...]
#
# Options:
#   -c, --config       Path to hosts config file
#   -a, --all          Check all hosts in config
#   --json             Output as JSON
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"
# shellcheck source=../lib/network-utils.sh
source "${SCRIPT_DIR}/../lib/network-utils.sh"

# Default configuration
CONFIG_FILE="${VMSTATION_CONFIG:-/etc/vmstation/hosts.conf}"
CHECK_ALL="${CHECK_ALL:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Hosts to check
declare -a HOSTS_TO_CHECK

# Results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [hostname|ip...]

Check power state and reachability of VMStation nodes.

Arguments:
  hostname|ip   Hostnames or IP addresses to check (optional)

Options:
  -c, --config FILE   Path to hosts config file
  -a, --all           Check all hosts in config file
  --json              Output results as JSON
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Examples:
  $(basename "$0") vmstation-node1                # Check single host
  $(basename "$0") 192.168.1.10 192.168.1.11      # Check by IP
  $(basename "$0") -a                             # Check all configured hosts
  $(basename "$0") --json node1 node2             # JSON output

Config File Format:
  hostname mac_address ip_address
  vmstation-node1 AA:BB:CC:DD:EE:FF 192.168.1.10

Environment:
  VMSTATION_CONFIG   Path to hosts config file (default: /etc/vmstation/hosts.conf)
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="${2:?Config file required}"
                shift 2
                ;;
            -a|--all)
                CHECK_ALL="true"
                shift
                ;;
            --json)
                JSON_OUTPUT="true"
                shift
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
            *)
                HOSTS_TO_CHECK+=("$1")
                shift
                ;;
        esac
    done
}

#######################################
# Load hosts from config file
#######################################
load_hosts_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 2
    fi

    log_debug "Loading hosts from $CONFIG_FILE"

    while read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        local hostname ip
        hostname=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $3}')

        if [[ -n "$ip" ]]; then
            HOSTS_TO_CHECK+=("$ip")
            log_debug "Added host: $hostname ($ip)"
        fi
    done < "$CONFIG_FILE"
}

#######################################
# Check single host
#######################################
check_host() {
    local host="$1"
    local status="offline"
    local latency="N/A"
    local ssh_status="N/A"

    log_debug "Checking host: $host"

    # Check ping
    if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
        status="online"

        # Get latency
        latency=$(ping -c 1 -W 2 "$host" 2>/dev/null | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1 ms/' || echo "N/A")

        # Check SSH port (optional)
        if check_port "$host" 22 2; then
            ssh_status="open"
        else
            ssh_status="closed"
        fi
    fi

    RESULTS["$host"]="$status|$latency|$ssh_status"
}

#######################################
# Output results as text
#######################################
output_text() {
    log_section "Power State Check Results"

    printf "%-30s %-10s %-15s %-10s\n" "HOST" "STATUS" "LATENCY" "SSH"
    printf "%-30s %-10s %-15s %-10s\n" "----" "------" "-------" "---"

    local online=0
    local offline=0

    for host in "${!RESULTS[@]}"; do
        local result="${RESULTS[$host]}"
        local status="${result%%|*}"
        local rest="${result#*|}"
        local latency="${rest%%|*}"
        local ssh="${rest#*|}"

        if [[ "$status" == "online" ]]; then
            printf "%-30s \033[0;32m%-10s\033[0m %-15s %-10s\n" "$host" "$status" "$latency" "$ssh"
            ((online++)) || true
        else
            printf "%-30s \033[0;31m%-10s\033[0m %-15s %-10s\n" "$host" "$status" "$latency" "$ssh"
            ((offline++)) || true
        fi
    done

    echo ""
    log_kv "Online" "$online"
    log_kv "Offline" "$offline"
    log_kv "Total" "$((online + offline))"
}

#######################################
# Output results as JSON
#######################################
output_json() {
    local online=0
    local offline=0

    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    echo '  "hosts": {'

    local first=true
    for host in "${!RESULTS[@]}"; do
        local result="${RESULTS[$host]}"
        local status="${result%%|*}"
        local rest="${result#*|}"
        local latency="${rest%%|*}"
        local ssh="${rest#*|}"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo -n '    "'"$host"'": {"status": "'"$status"'", "latency": "'"$latency"'", "ssh": "'"$ssh"'"}'

        if [[ "$status" == "online" ]]; then
            ((online++)) || true
        else
            ((offline++)) || true
        fi
    done

    echo ""
    echo "  },"
    echo '  "summary": {"online": '$online', "offline": '$offline', "total": '$((online + offline))'}'
    echo "}"
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"

    # Load hosts if --all specified
    if [[ "$CHECK_ALL" == "true" ]]; then
        load_hosts_from_config
    fi

    # Check if we have hosts to check
    if [[ ${#HOSTS_TO_CHECK[@]} -eq 0 ]]; then
        log_error "No hosts specified"
        log_info "Use -a to check all hosts in config, or specify hosts as arguments"
        exit 2
    fi

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_info "Checking ${#HOSTS_TO_CHECK[@]} host(s)..."
    fi

    # Check each host
    for host in "${HOSTS_TO_CHECK[@]}"; do
        check_host "$host"
    done

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_text
    fi

    # Return non-zero if any hosts are offline
    local offline=0
    for host in "${!RESULTS[@]}"; do
        local result="${RESULTS[$host]}"
        local status="${result%%|*}"
        if [[ "$status" == "offline" ]]; then
            ((offline++)) || true
        fi
    done

    [[ $offline -eq 0 ]]
}

main "$@"
