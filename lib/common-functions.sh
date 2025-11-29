#!/usr/bin/env bash
# common-functions.sh - Common functions for cluster-tools scripts
# This library provides shared utility functions used across all tools.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common-functions.sh"

# Prevent multiple sourcing
[[ -n "${_COMMON_FUNCTIONS_LOADED:-}" ]] && return 0
readonly _COMMON_FUNCTIONS_LOADED=1

# shellcheck source=./logging-utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging-utils.sh"

#######################################
# Check if a command exists
# Arguments:
#   $1 - Command name to check
# Returns:
#   0 if command exists, 1 otherwise
#######################################
command_exists() {
    local cmd="${1:?Command name required}"
    command -v "$cmd" >/dev/null 2>&1
}

#######################################
# Require a command to exist, exit if not
# Arguments:
#   $1 - Command name to require
#   $2 - Optional: package name to install
# Returns:
#   0 if command exists, exits with error otherwise
#######################################
require_command() {
    local cmd="${1:?Command name required}"
    local package="${2:-$cmd}"
    
    if ! command_exists "$cmd"; then
        log_error "Required command '$cmd' not found. Please install '$package'."
        exit 1
    fi
}

#######################################
# Check if running as root
# Returns:
#   0 if running as root, 1 otherwise
#######################################
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

#######################################
# Require root privileges, exit if not root
#######################################
require_root() {
    if ! is_root; then
        log_error "This script requires root privileges. Please run with sudo."
        exit 1
    fi
}

#######################################
# Validate that a variable is set and non-empty
# Arguments:
#   $1 - Variable name
#   $2 - Variable value
# Returns:
#   0 if valid, exits with error otherwise
#######################################
require_var() {
    local name="${1:?Variable name required}"
    local value="${2:-}"
    
    if [[ -z "$value" ]]; then
        log_error "Required variable '$name' is not set or empty."
        exit 1
    fi
}

#######################################
# Validate that a file exists
# Arguments:
#   $1 - File path
# Returns:
#   0 if file exists, exits with error otherwise
#######################################
require_file() {
    local file="${1:?File path required}"
    
    if [[ ! -f "$file" ]]; then
        log_error "Required file not found: $file"
        exit 1
    fi
}

#######################################
# Validate that a directory exists
# Arguments:
#   $1 - Directory path
# Returns:
#   0 if directory exists, exits with error otherwise
#######################################
require_directory() {
    local dir="${1:?Directory path required}"
    
    if [[ ! -d "$dir" ]]; then
        log_error "Required directory not found: $dir"
        exit 1
    fi
}

#######################################
# Create a directory if it doesn't exist
# Arguments:
#   $1 - Directory path
# Returns:
#   0 on success, exits with error otherwise
#######################################
ensure_directory() {
    local dir="${1:?Directory path required}"
    
    if [[ ! -d "$dir" ]]; then
        if ! mkdir -p "$dir"; then
            log_error "Failed to create directory: $dir"
            exit 1
        fi
        log_debug "Created directory: $dir"
    fi
}

#######################################
# Prompt user for confirmation
# Arguments:
#   $1 - Prompt message
#   $2 - Optional: default value (y/n)
# Returns:
#   0 if user confirms, 1 otherwise
#######################################
confirm() {
    local prompt="${1:?Prompt message required}"
    local default="${2:-n}"
    local response
    
    # In non-interactive mode, use default
    if [[ ! -t 0 ]]; then
        [[ "$default" == "y" || "$default" == "Y" ]]
        return $?
    fi
    
    if [[ "$default" == "y" || "$default" == "Y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -r -p "$prompt" response
    response="${response:-$default}"
    
    [[ "$response" =~ ^[Yy] ]]
}

#######################################
# Execute a command with optional dry-run support
# Globals:
#   DRY_RUN - If set to "true", only print the command
# Arguments:
#   $@ - Command and arguments to execute
# Returns:
#   Command exit code, or 0 for dry-run
#######################################
run_cmd() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    
    log_debug "Executing: $*"
    "$@"
}

#######################################
# Wait for a condition with timeout
# Arguments:
#   $1 - Timeout in seconds
#   $2 - Interval between checks in seconds
#   $@ - Command to check (should return 0 when condition is met)
# Returns:
#   0 if condition met, 1 if timeout
#######################################
wait_for() {
    local timeout="${1:?Timeout required}"
    local interval="${2:?Interval required}"
    shift 2
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

#######################################
# Generate a temporary file with automatic cleanup
# Arguments:
#   $1 - Optional: prefix for the temp file
# Outputs:
#   Path to the temporary file
#######################################
create_temp_file() {
    local prefix="${1:-cluster-tools}"
    local temp_file
    
    temp_file=$(mktemp "/tmp/${prefix}.XXXXXX") || {
        log_error "Failed to create temporary file"
        exit 1
    }
    
    # Register cleanup on script exit
    # shellcheck disable=SC2064
    trap "rm -f '$temp_file'" EXIT
    
    echo "$temp_file"
}

#######################################
# Parse common command line options
# Globals:
#   VERBOSE - Set to true if -v/--verbose passed
#   DEBUG - Set to true if --debug passed
#   DRY_RUN - Set to true if -n/--dry-run passed
#   QUIET - Set to true if -q/--quiet passed
# Arguments:
#   $@ - Command line arguments
# Returns:
#   Remaining arguments after options processed
#######################################
parse_common_options() {
    VERBOSE="${VERBOSE:-false}"
    DEBUG="${DEBUG:-false}"
    DRY_RUN="${DRY_RUN:-false}"
    QUIET="${QUIET:-false}"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE="true"
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            --debug)
                DEBUG="true"
                VERBOSE="true"
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -q|--quiet)
                QUIET="true"
                export LOG_LEVEL="ERROR"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Return remaining arguments
    echo "$@"
}

#######################################
# Get script directory
# Outputs:
#   Absolute path to the directory containing the script
#######################################
get_script_dir() {
    local source="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    local dir
    
    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    
    cd -P "$(dirname "$source")" && pwd
}

#######################################
# Get the repository root directory
# Outputs:
#   Absolute path to the repository root
#######################################
get_repo_root() {
    local script_dir
    script_dir="$(get_script_dir)"
    
    # Navigate up from lib/ to repo root
    dirname "$script_dir"
}

#######################################
# Check if kubectl is available and configured
# Returns:
#   0 if kubectl is working, 1 otherwise
#######################################
kubectl_ready() {
    if ! command_exists kubectl; then
        return 1
    fi
    
    kubectl cluster-info >/dev/null 2>&1
}

#######################################
# Retry a command with exponential backoff
# Arguments:
#   $1 - Maximum retries
#   $2 - Initial delay in seconds
#   $@ - Command to retry
# Returns:
#   Command exit code
#######################################
retry_with_backoff() {
    local max_retries="${1:?Max retries required}"
    local delay="${2:?Initial delay required}"
    shift 2
    
    local attempt=1
    local exit_code=0
    
    while [[ $attempt -le $max_retries ]]; do
        if "$@"; then
            return 0
        fi
        exit_code=$?
        
        if [[ $attempt -lt $max_retries ]]; then
            log_warn "Command failed (attempt $attempt/$max_retries). Retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_error "Command failed after $max_retries attempts"
    return $exit_code
}

#######################################
# Validate an IP address
# Arguments:
#   $1 - IP address to validate
# Returns:
#   0 if valid, 1 otherwise
#######################################
validate_ip() {
    local ip="${1:?IP address required}"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! "$ip" =~ $regex ]]; then
        return 1
    fi
    
    local IFS='.'
    read -ra octets <<< "$ip"
    
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done
    
    return 0
}

#######################################
# Validate a MAC address
# Arguments:
#   $1 - MAC address to validate
# Returns:
#   0 if valid, 1 otherwise
#######################################
validate_mac() {
    local mac="${1:?MAC address required}"
    local regex='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
    
    [[ "$mac" =~ $regex ]]
}
