#!/usr/bin/env bash
# network-utils.sh - Network utilities for cluster-tools scripts
# Provides functions for network operations, connectivity testing, and Wake-on-LAN.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/network-utils.sh"

# Prevent multiple sourcing
[[ -n "${_NETWORK_UTILS_LOADED:-}" ]] && return 0
readonly _NETWORK_UTILS_LOADED=1

# shellcheck source=./logging-utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging-utils.sh"
# shellcheck source=./common-functions.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-functions.sh"

#######################################
# Check if a host is reachable via ping
# Arguments:
#   $1 - Host (IP or hostname)
#   $2 - Optional: timeout in seconds (default: 5)
# Returns:
#   0 if reachable, 1 otherwise
#######################################
ping_host() {
    local host="${1:?Host required}"
    local timeout="${2:-5}"
    
    ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
}

#######################################
# Check if a TCP port is open
# Arguments:
#   $1 - Host (IP or hostname)
#   $2 - Port number
#   $3 - Optional: timeout in seconds (default: 5)
# Returns:
#   0 if port is open, 1 otherwise
#######################################
check_port() {
    local host="${1:?Host required}"
    local port="${2:?Port required}"
    local timeout="${3:-5}"
    
    if command_exists nc; then
        nc -z -w "$timeout" "$host" "$port" 2>/dev/null
    elif command_exists timeout; then
        timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
    else
        bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
    fi
}

#######################################
# Wait for a host to become reachable
# Arguments:
#   $1 - Host (IP or hostname)
#   $2 - Optional: timeout in seconds (default: 60)
#   $3 - Optional: check interval in seconds (default: 5)
# Returns:
#   0 if host becomes reachable, 1 if timeout
#######################################
wait_for_host() {
    local host="${1:?Host required}"
    local timeout="${2:-60}"
    local interval="${3:-5}"
    
    log_info "Waiting for host $host to become reachable..."
    
    if wait_for "$timeout" "$interval" ping_host "$host"; then
        log_success "Host $host is reachable"
        return 0
    else
        log_error "Timeout waiting for host $host"
        return 1
    fi
}

#######################################
# Wait for a port to become available
# Arguments:
#   $1 - Host (IP or hostname)
#   $2 - Port number
#   $3 - Optional: timeout in seconds (default: 60)
#   $4 - Optional: check interval in seconds (default: 5)
# Returns:
#   0 if port becomes available, 1 if timeout
#######################################
wait_for_port() {
    local host="${1:?Host required}"
    local port="${2:?Port required}"
    local timeout="${3:-60}"
    local interval="${4:-5}"
    
    log_info "Waiting for $host:$port to become available..."
    
    if wait_for "$timeout" "$interval" check_port "$host" "$port"; then
        log_success "Port $host:$port is available"
        return 0
    else
        log_error "Timeout waiting for port $host:$port"
        return 1
    fi
}

#######################################
# Send Wake-on-LAN magic packet
# Arguments:
#   $1 - MAC address (format: XX:XX:XX:XX:XX:XX)
#   $2 - Optional: broadcast address (default: 255.255.255.255)
#   $3 - Optional: port (default: 9)
# Returns:
#   0 on success, 1 on failure
#######################################
send_wol() {
    local mac="${1:?MAC address required}"
    local broadcast="${2:-255.255.255.255}"
    local port="${3:-9}"
    
    # Validate MAC address
    if ! validate_mac "$mac"; then
        log_error "Invalid MAC address format: $mac"
        return 1
    fi
    
    log_info "Sending Wake-on-LAN packet to $mac via $broadcast:$port"
    
    # Send using different methods based on available tools
    if command_exists wakeonlan; then
        wakeonlan -i "$broadcast" -p "$port" "$mac"
    elif command_exists wol; then
        wol -i "$broadcast" -p "$port" "$mac"
    elif command_exists etherwake; then
        etherwake -b "$mac"
    elif command_exists python3; then
        python3 -c "
import socket
import binascii
mac = '$mac'.replace(':', '')
magic = 'ff' * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(binascii.unhexlify(magic), ('$broadcast', $port))
s.close()
"
    else
        log_error "No Wake-on-LAN tool available (wakeonlan, wol, etherwake, or python3)"
        return 1
    fi
    
    log_success "Wake-on-LAN packet sent to $mac"
}

#######################################
# Get the IP address of a network interface
# Arguments:
#   $1 - Interface name
# Outputs:
#   IP address of the interface
# Returns:
#   0 on success, 1 on failure
#######################################
get_interface_ip() {
    local interface="${1:?Interface name required}"
    
    if command_exists ip; then
        ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
    elif command_exists ifconfig; then
        ifconfig "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
    else
        log_error "Neither 'ip' nor 'ifconfig' command available"
        return 1
    fi
}

#######################################
# Get the MAC address of a network interface
# Arguments:
#   $1 - Interface name
# Outputs:
#   MAC address of the interface
# Returns:
#   0 on success, 1 on failure
#######################################
get_interface_mac() {
    local interface="${1:?Interface name required}"
    
    if command_exists ip; then
        ip link show "$interface" 2>/dev/null | grep -oP '(?<=link/ether\s)[0-9a-f:]{17}'
    elif [[ -f "/sys/class/net/$interface/address" ]]; then
        cat "/sys/class/net/$interface/address"
    else
        log_error "Cannot determine MAC address for interface: $interface"
        return 1
    fi
}

#######################################
# List all network interfaces
# Outputs:
#   List of interface names
#######################################
list_interfaces() {
    if command_exists ip; then
        ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
    elif [[ -d /sys/class/net ]]; then
        # Using find instead of ls for shellcheck compliance
        find /sys/class/net -maxdepth 1 -type l -exec basename {} \; 2>/dev/null | grep -v '^lo$'
    else
        log_error "Cannot list network interfaces"
        return 1
    fi
}

#######################################
# Check DNS resolution
# Arguments:
#   $1 - Hostname to resolve
#   $2 - Optional: DNS server to use
# Returns:
#   0 if resolution succeeds, 1 otherwise
#######################################
check_dns() {
    local hostname="${1:?Hostname required}"
    local dns_server="${2:-}"
    
    if command_exists dig; then
        if [[ -n "$dns_server" ]]; then
            dig +short "@$dns_server" "$hostname" >/dev/null 2>&1
        else
            dig +short "$hostname" >/dev/null 2>&1
        fi
    elif command_exists nslookup; then
        if [[ -n "$dns_server" ]]; then
            nslookup "$hostname" "$dns_server" >/dev/null 2>&1
        else
            nslookup "$hostname" >/dev/null 2>&1
        fi
    elif command_exists host; then
        if [[ -n "$dns_server" ]]; then
            host "$hostname" "$dns_server" >/dev/null 2>&1
        else
            host "$hostname" >/dev/null 2>&1
        fi
    else
        # Fallback: try to resolve using getent
        getent hosts "$hostname" >/dev/null 2>&1
    fi
}

#######################################
# Check HTTP/HTTPS endpoint
# Arguments:
#   $1 - URL to check
#   $2 - Optional: expected status code (default: 200)
#   $3 - Optional: timeout in seconds (default: 10)
# Returns:
#   0 if endpoint returns expected status, 1 otherwise
#######################################
check_http() {
    local url="${1:?URL required}"
    local expected_status="${2:-200}"
    local timeout="${3:-10}"
    local actual_status
    
    if ! command_exists curl; then
        log_error "curl is required for HTTP checks"
        return 1
    fi
    
    actual_status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$timeout" "$url" 2>/dev/null)
    
    [[ "$actual_status" == "$expected_status" ]]
}

#######################################
# Get public IP address
# Outputs:
#   Public IP address
# Returns:
#   0 on success, 1 on failure
#######################################
get_public_ip() {
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
    )
    
    for service in "${services[@]}"; do
        local ip
        ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null)
        if validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    
    log_error "Could not determine public IP address"
    return 1
}

#######################################
# Check if running inside a container
# Returns:
#   0 if in container, 1 otherwise
#######################################
is_in_container() {
    [[ -f /.dockerenv ]] || grep -q 'docker\|lxc\|containerd' /proc/1/cgroup 2>/dev/null
}

#######################################
# Get the default gateway
# Outputs:
#   Default gateway IP address
# Returns:
#   0 on success, 1 on failure
#######################################
get_default_gateway() {
    if command_exists ip; then
        ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1
    elif command_exists route; then
        route -n 2>/dev/null | awk '/^0.0.0.0/ {print $2}' | head -n1
    else
        log_error "Cannot determine default gateway"
        return 1
    fi
}

#######################################
# Check network connectivity to multiple hosts
# Arguments:
#   $@ - Hosts to check
# Outputs:
#   Status for each host
# Returns:
#   0 if all reachable, 1 if any unreachable
#######################################
check_connectivity() {
    local hosts=("$@")
    local all_ok=true
    
    for host in "${hosts[@]}"; do
        if ping_host "$host" 2; then
            log_success "$host is reachable"
        else
            log_failure "$host is unreachable"
            all_ok=false
        fi
    done
    
    $all_ok
}
