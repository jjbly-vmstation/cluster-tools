#!/usr/bin/env bash
# logging-utils.sh - Logging utilities for cluster-tools scripts
# Provides consistent, colorized logging with timestamps and log levels.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/logging-utils.sh"
#
# Environment Variables:
#   LOG_LEVEL - Set logging level (DEBUG, INFO, WARN, ERROR). Default: INFO
#   LOG_FILE  - Optional file path to log messages
#   NO_COLOR  - Set to disable colored output

# Prevent multiple sourcing
[[ -n "${_LOGGING_UTILS_LOADED:-}" ]] && return 0
readonly _LOGGING_UTILS_LOADED=1

# Log levels (numeric values for comparison)
declare -A _LOG_LEVELS=(
    [DEBUG]=0
    [INFO]=1
    [WARN]=2
    [ERROR]=3
)

# Default log level
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Color codes
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly _COLOR_RESET='\033[0m'
    readonly _COLOR_RED='\033[0;31m'
    readonly _COLOR_GREEN='\033[0;32m'
    readonly _COLOR_YELLOW='\033[0;33m'
    readonly _COLOR_BLUE='\033[0;34m'
    readonly _COLOR_CYAN='\033[0;36m'
    readonly _COLOR_BOLD='\033[1m'
else
    readonly _COLOR_RESET=''
    readonly _COLOR_RED=''
    readonly _COLOR_GREEN=''
    readonly _COLOR_YELLOW=''
    readonly _COLOR_BLUE=''
    readonly _COLOR_CYAN=''
    readonly _COLOR_BOLD=''
fi

#######################################
# Get current timestamp in ISO 8601 format
# Outputs:
#   Timestamp string
#######################################
_get_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

#######################################
# Check if a message should be logged at current level
# Arguments:
#   $1 - Message log level
# Returns:
#   0 if should log, 1 otherwise
#######################################
_should_log() {
    local level="${1:-INFO}"
    local current_level="${LOG_LEVEL:-INFO}"

    [[ ${_LOG_LEVELS[$level]:-1} -ge ${_LOG_LEVELS[$current_level]:-1} ]]
}

#######################################
# Internal logging function
# Arguments:
#   $1 - Log level
#   $2 - Color code
#   $3 - Message
#######################################
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp

    if ! _should_log "$level"; then
        return 0
    fi

    timestamp="$(_get_timestamp)"

    # Format: [TIMESTAMP] [LEVEL] message
    local formatted_msg="[${timestamp}] [${level}] ${message}"

    # Log to stderr for WARN and ERROR, stdout for others
    if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
        echo -e "${color}${formatted_msg}${_COLOR_RESET}" >&2
    else
        echo -e "${color}${formatted_msg}${_COLOR_RESET}"
    fi

    # Log to file if LOG_FILE is set
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "${formatted_msg}" >> "$LOG_FILE"
    fi
}

#######################################
# Log debug message
# Arguments:
#   $@ - Message to log
#######################################
log_debug() {
    _log "DEBUG" "$_COLOR_CYAN" "$*"
}

#######################################
# Log info message
# Arguments:
#   $@ - Message to log
#######################################
log_info() {
    _log "INFO" "$_COLOR_GREEN" "$*"
}

#######################################
# Log warning message
# Arguments:
#   $@ - Message to log
#######################################
log_warn() {
    _log "WARN" "$_COLOR_YELLOW" "$*"
}

#######################################
# Log error message
# Arguments:
#   $@ - Message to log
#######################################
log_error() {
    _log "ERROR" "$_COLOR_RED" "$*"
}

#######################################
# Log a section header
# Arguments:
#   $@ - Section title
#######################################
log_section() {
    local title="$*"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))
    local line

    printf -v line '%*s' "$width" ''
    line="${line// /=}"

    echo ""
    echo -e "${_COLOR_BOLD}${_COLOR_BLUE}${line}${_COLOR_RESET}"
    echo -e "${_COLOR_BOLD}${_COLOR_BLUE}$(printf '%*s' $padding '')= ${title} =$(printf '%*s' $padding '')${_COLOR_RESET}"
    echo -e "${_COLOR_BOLD}${_COLOR_BLUE}${line}${_COLOR_RESET}"
    echo ""
}

#######################################
# Log a subsection header
# Arguments:
#   $@ - Subsection title
#######################################
log_subsection() {
    local title="$*"
    echo ""
    echo -e "${_COLOR_BOLD}--- ${title} ---${_COLOR_RESET}"
    echo ""
}

#######################################
# Log success message with checkmark
# Arguments:
#   $@ - Message to log
#######################################
log_success() {
    echo -e "${_COLOR_GREEN}✓ $*${_COLOR_RESET}"
}

#######################################
# Log failure message with X
# Arguments:
#   $@ - Message to log
#######################################
log_failure() {
    echo -e "${_COLOR_RED}✗ $*${_COLOR_RESET}" >&2
}

#######################################
# Log a key-value pair
# Arguments:
#   $1 - Key
#   $2 - Value
#######################################
log_kv() {
    local key="${1:?Key required}"
    local value="${2:-}"
    printf "  %-25s : %s\n" "$key" "$value"
}

#######################################
# Display a progress indicator
# Arguments:
#   $1 - Current step
#   $2 - Total steps
#   $3 - Message
#######################################
log_progress() {
    local current="${1:?Current step required}"
    local total="${2:?Total steps required}"
    local message="${3:-Processing...}"

    local percent=$(( (current * 100) / total ))
    local bar_width=30
    local filled=$(( (percent * bar_width) / 100 ))
    local empty=$(( bar_width - filled ))

    local bar
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    local empty_bar
    printf -v empty_bar '%*s' "$empty" ''
    empty_bar="${empty_bar// /-}"

    printf "\r[%s%s] %3d%% %s" "$bar" "$empty_bar" "$percent" "$message"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

#######################################
# Log the start of a timed operation
# Arguments:
#   $1 - Operation name
# Outputs:
#   Start time for use with log_end_timer
#######################################
log_start_timer() {
    local operation="${1:?Operation name required}"
    log_info "Starting: $operation"
    date +%s
}

#######################################
# Log the end of a timed operation
# Arguments:
#   $1 - Operation name
#   $2 - Start time from log_start_timer
#######################################
log_end_timer() {
    local operation="${1:?Operation name required}"
    local start_time="${2:?Start time required}"
    local end_time
    local duration

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    log_info "Completed: $operation (${duration}s)"
}

#######################################
# Initialize logging to a file
# Arguments:
#   $1 - Log file path
#######################################
init_log_file() {
    local log_file="${1:?Log file path required}"

    # Ensure directory exists
    local log_dir
    log_dir="$(dirname "$log_file")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" || {
            log_error "Failed to create log directory: $log_dir"
            return 1
        }
    fi

    # Set global LOG_FILE
    export LOG_FILE="$log_file"

    # Write header to log file
    {
        echo "============================================"
        echo "Log started at: $(_get_timestamp)"
        echo "Script: ${BASH_SOURCE[2]:-unknown}"
        echo "============================================"
        echo ""
    } >> "$LOG_FILE"

    log_debug "Logging to file: $LOG_FILE"
}

#######################################
# Set the logging level
# Arguments:
#   $1 - Log level (DEBUG, INFO, WARN, ERROR)
#######################################
set_log_level() {
    local level="${1:?Log level required}"
    level="${level^^}"  # Convert to uppercase

    if [[ -z "${_LOG_LEVELS[$level]:-}" ]]; then
        log_error "Invalid log level: $level. Must be one of: DEBUG, INFO, WARN, ERROR"
        return 1
    fi

    export LOG_LEVEL="$level"
    log_debug "Log level set to: $LOG_LEVEL"
}
