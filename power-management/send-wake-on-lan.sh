#!/usr/bin/env bash
# send-wake-on-lan.sh - Send Wake-on-LAN magic packets
# Simple tool to wake up machines using WoL
#
# Usage: ./send-wake-on-lan.sh [OPTIONS] <mac-address>
#
# Options:
#   -b, --broadcast    Broadcast address (default: 255.255.255.255)
#   -p, --port         WoL port (default: 9)
#   -i, --interface    Network interface to use
#   -c, --count        Number of packets to send (default: 3)
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
INTERFACE=""
PACKET_COUNT="${PACKET_COUNT:-3}"
MAC_ADDRESS=""

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <mac-address>

Send Wake-on-LAN magic packet to wake up a remote machine.

Arguments:
  mac-address   MAC address in format XX:XX:XX:XX:XX:XX

Options:
  -b, --broadcast ADDR   Broadcast address (default: 255.255.255.255)
  -p, --port PORT        WoL UDP port (default: 9)
  -i, --interface IFACE  Network interface to use
  -c, --count N          Number of packets to send (default: 3)
  -v, --verbose          Enable verbose output
  -h, --help             Show this help message

Examples:
  $(basename "$0") AA:BB:CC:DD:EE:FF
  $(basename "$0") -b 192.168.1.255 AA:BB:CC:DD:EE:FF
  $(basename "$0") -i eth0 -c 5 AA:BB:CC:DD:EE:FF

Environment:
  BROADCAST_ADDR   Default broadcast address
  WOL_PORT         Default WoL port
  PACKET_COUNT     Default packet count
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
            -i|--interface)
                INTERFACE="${2:?Interface required}"
                shift 2
                ;;
            -c|--count)
                PACKET_COUNT="${2:?Count required}"
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
        log_error "MAC address required"
        show_help
        exit 2
    fi
    
    # Validate MAC address
    if ! validate_mac "$MAC_ADDRESS"; then
        log_error "Invalid MAC address format: $MAC_ADDRESS"
        log_info "Expected format: XX:XX:XX:XX:XX:XX"
        exit 2
    fi
}

#######################################
# Send magic packet using various methods
#######################################
send_magic_packet() {
    local mac="$1"
    local broadcast="$2"
    local port="$3"
    
    # Normalize MAC address (uppercase, colon-separated)
    mac=$(echo "$mac" | tr '[:lower:]' '[:upper:]' | tr '-' ':')
    
    log_debug "Sending magic packet to $mac via $broadcast:$port"
    
    # Try wakeonlan first
    if command_exists wakeonlan; then
        log_debug "Using wakeonlan"
        wakeonlan -i "$broadcast" -p "$port" "$mac"
        return $?
    fi
    
    # Try wol
    if command_exists wol; then
        log_debug "Using wol"
        wol -i "$broadcast" -p "$port" "$mac"
        return $?
    fi
    
    # Try etherwake
    if command_exists etherwake && [[ -n "$INTERFACE" ]]; then
        log_debug "Using etherwake"
        etherwake -i "$INTERFACE" -b "$mac"
        return $?
    fi
    
    # Fallback to Python
    if command_exists python3; then
        log_debug "Using Python3 fallback"
        python3 << EOF
import socket
import binascii

mac = '$mac'.replace(':', '')
magic = 'ff' * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(binascii.unhexlify(magic), ('$broadcast', $port))
s.close()
print("Magic packet sent")
EOF
        return $?
    fi
    
    # Fallback to netcat if available
    if command_exists nc; then
        log_debug "Using netcat fallback"
        local magic_packet
        
        # Build magic packet hex string
        magic_packet=$(printf 'ff%.0s' {1..6})
        local mac_hex="${mac//:/}"
        for _ in {1..16}; do
            magic_packet+="$mac_hex"
        done
        
        # Send using netcat
        echo -n "$magic_packet" | xxd -r -p | nc -u -w1 "$broadcast" "$port"
        return $?
    fi
    
    log_error "No WoL tool available. Install wakeonlan, wol, etherwake, or python3"
    return 1
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    log_section "Wake-on-LAN"
    log_kv "MAC Address" "$MAC_ADDRESS"
    log_kv "Broadcast" "$BROADCAST_ADDR"
    log_kv "Port" "$WOL_PORT"
    log_kv "Packets" "$PACKET_COUNT"
    
    if [[ -n "$INTERFACE" ]]; then
        log_kv "Interface" "$INTERFACE"
    fi
    
    echo ""
    
    local success=0
    local failed=0
    
    for i in $(seq 1 "$PACKET_COUNT"); do
        log_info "Sending packet $i/$PACKET_COUNT..."
        
        if send_magic_packet "$MAC_ADDRESS" "$BROADCAST_ADDR" "$WOL_PORT"; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
        
        # Small delay between packets
        if [[ $i -lt $PACKET_COUNT ]]; then
            sleep 0.5
        fi
    done
    
    echo ""
    
    if [[ $success -gt 0 ]]; then
        log_success "Sent $success magic packet(s) to $MAC_ADDRESS"
        if [[ $failed -gt 0 ]]; then
            log_warn "$failed packet(s) failed"
        fi
        exit 0
    else
        log_error "Failed to send any magic packets"
        exit 1
    fi
}

main "$@"
