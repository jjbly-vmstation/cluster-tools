#!/usr/bin/env bash
# vmstation-event-wake.sh - Wake-on-LAN event handler for VMStation
# Handles wake events and brings up VMStation nodes
#
# Usage: ./vmstation-event-wake.sh [OPTIONS] <mac-address>
#
# Options:
#   -b, --broadcast    Broadcast address (default: 255.255.255.255)
#   -p, --port         WoL port (default: 9)
#   -w, --wait         Wait for host to come online
#   -t, --timeout      Timeout for waiting (default: 300 seconds)
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
BROADCAST_ADDR="${BROADCAST_ADDR:-255.255.255.255}"
WOL_PORT="${WOL_PORT:-9}"
WAIT_FOR_HOST="${WAIT_FOR_HOST:-false}"
TIMEOUT="${TIMEOUT:-300}"
MAC_ADDRESS=""
TARGET_HOST=""

# VMStation configuration
VMSTATION_CONFIG="${VMSTATION_CONFIG:-/etc/vmstation/hosts.conf}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <mac-address|hostname>

Send Wake-on-LAN packet to wake up a VMStation node.

Arguments:
  mac-address   MAC address (format: XX:XX:XX:XX:XX:XX)
  hostname      Hostname from VMStation config file

Options:
  -b, --broadcast ADDR   Broadcast address (default: 255.255.255.255)
  -p, --port PORT        WoL port (default: 9)
  -w, --wait             Wait for host to come online after WoL
  -t, --timeout SEC      Timeout for waiting (default: 300 seconds)
  -v, --verbose          Enable verbose output
  -h, --help             Show this help message

Examples:
  $(basename "$0") AA:BB:CC:DD:EE:FF           # Wake by MAC
  $(basename "$0") vmstation-node1             # Wake by hostname
  $(basename "$0") -w AA:BB:CC:DD:EE:FF        # Wake and wait
  $(basename "$0") -b 192.168.1.255 AA:BB:...  # Custom broadcast

Environment:
  VMSTATION_CONFIG   Path to hosts config file (default: /etc/vmstation/hosts.conf)
  BROADCAST_ADDR     Default broadcast address
  WOL_PORT           Default WoL port
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--broadcast)
                BROADCAST_ADDR="${2:?Broadcast address required}"
                shift 2
                ;;
            -p|--port)
                WOL_PORT="${2:?Port required}"
                shift 2
                ;;
            -w|--wait)
                WAIT_FOR_HOST="true"
                shift
                ;;
            -t|--timeout)
                TIMEOUT="${2:?Timeout required}"
                shift 2
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
                if [[ -z "$MAC_ADDRESS" ]]; then
                    MAC_ADDRESS="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 2
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$MAC_ADDRESS" ]]; then
        log_error "MAC address or hostname required"
        show_help
        exit 2
    fi
}

#######################################
# Look up MAC address from hostname
#######################################
lookup_host() {
    local host="$1"
    
    if [[ -f "$VMSTATION_CONFIG" ]]; then
        # Config format: hostname mac_address ip_address
        local entry
        entry=$(grep -E "^${host}\s+" "$VMSTATION_CONFIG" 2>/dev/null | head -1 || true)
        
        if [[ -n "$entry" ]]; then
            MAC_ADDRESS=$(echo "$entry" | awk '{print $2}')
            TARGET_HOST=$(echo "$entry" | awk '{print $3}')
            log_debug "Found host $host: MAC=$MAC_ADDRESS, IP=$TARGET_HOST"
            return 0
        fi
    fi
    
    log_error "Host '$host' not found in $VMSTATION_CONFIG"
    return 1
}

#######################################
# Resolve target (MAC or hostname)
#######################################
resolve_target() {
    # Check if input looks like a MAC address
    if validate_mac "$MAC_ADDRESS"; then
        log_debug "Input is a valid MAC address"
        return 0
    fi
    
    # Try to look up as hostname
    log_debug "Looking up hostname: $MAC_ADDRESS"
    local hostname="$MAC_ADDRESS"
    
    if lookup_host "$hostname"; then
        return 0
    fi
    
    log_error "Invalid MAC address format and hostname not found: $MAC_ADDRESS"
    exit 2
}

#######################################
# Log wake event
#######################################
log_wake_event() {
    local status="$1"
    local log_file="${VMSTATION_LOG_DIR:-/var/log/vmstation}/wake-events.log"
    
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$log_file")
    if [[ -d "$log_dir" ]] && [[ -w "$log_dir" ]]; then
        echo "$(date -Iseconds) $status MAC=$MAC_ADDRESS HOST=$TARGET_HOST" >> "$log_file"
    fi
}

#######################################
# Wait for host to come online
#######################################
wait_for_online() {
    if [[ -z "$TARGET_HOST" ]]; then
        log_warn "No IP address known for host, cannot wait for online status"
        return 0
    fi
    
    log_info "Waiting for host to come online (timeout: ${TIMEOUT}s)..."
    
    if wait_for_host "$TARGET_HOST" "$TIMEOUT" 10; then
        log_success "Host $TARGET_HOST is online!"
        log_wake_event "ONLINE"
        return 0
    else
        log_error "Host did not come online within ${TIMEOUT}s"
        log_wake_event "TIMEOUT"
        return 1
    fi
}

#######################################
# Send wake packet
#######################################
send_wake_packet() {
    log_info "Sending Wake-on-LAN packet..."
    log_kv "MAC Address" "$MAC_ADDRESS"
    log_kv "Broadcast" "$BROADCAST_ADDR"
    log_kv "Port" "$WOL_PORT"
    
    if send_wol "$MAC_ADDRESS" "$BROADCAST_ADDR" "$WOL_PORT"; then
        log_wake_event "WOL_SENT"
        return 0
    else
        log_wake_event "WOL_FAILED"
        return 1
    fi
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    log_section "VMStation Wake Event"
    
    # Resolve target
    resolve_target
    
    # Send wake packet
    if ! send_wake_packet; then
        log_error "Failed to send Wake-on-LAN packet"
        exit 1
    fi
    
    # Wait for host if requested
    if [[ "$WAIT_FOR_HOST" == "true" ]]; then
        if ! wait_for_online; then
            exit 1
        fi
    fi
    
    log_success "Wake event completed successfully"
}

main "$@"
