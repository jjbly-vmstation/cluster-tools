#!/usr/bin/env bash
# vmstation-collect-wake-logs.sh - Collect wake event logs for VMStation
# Gathers and analyzes wake event logs for troubleshooting
#
# Usage: ./vmstation-collect-wake-logs.sh [OPTIONS]
#
# Options:
#   -o, --output       Output file or directory
#   -d, --days         Number of days of logs to collect (default: 7)
#   --analyze          Analyze logs and show statistics
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
OUTPUT="${OUTPUT:-./wake-logs}"
DAYS="${DAYS:-7}"
ANALYZE="${ANALYZE:-false}"

# Log locations
VMSTATION_LOG_DIR="${VMSTATION_LOG_DIR:-/var/log/vmstation}"
SYSTEM_LOG_DIR="/var/log"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Collect and analyze VMStation wake event logs.

Options:
  -o, --output PATH   Output file or directory (default: ./wake-logs)
  -d, --days N        Number of days of logs to collect (default: 7)
  --analyze           Analyze logs and show statistics
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Collect last 7 days of logs
  $(basename "$0") -d 30              # Collect last 30 days
  $(basename "$0") --analyze          # Collect and analyze
  $(basename "$0") -o /tmp/logs       # Custom output directory

Log Sources:
  - VMStation wake event logs
  - System power management logs
  - Network interface logs
  - Kernel wake events
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                OUTPUT="${2:?Output path required}"
                shift 2
                ;;
            -d|--days)
                DAYS="${2:?Days value required}"
                shift 2
                ;;
            --analyze)
                ANALYZE="true"
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
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
}

#######################################
# Initialize output directory
#######################################
init_output() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    OUTPUT="${OUTPUT}/wake-logs-${timestamp}"
    
    ensure_directory "$OUTPUT"
    
    log_info "Logs will be saved to: $OUTPUT"
}

#######################################
# Collect VMStation wake logs
#######################################
collect_vmstation_logs() {
    log_subsection "Collecting VMStation Logs"
    
    local wake_log="${VMSTATION_LOG_DIR}/wake-events.log"
    
    if [[ -f "$wake_log" ]]; then
        local cutoff_date
        cutoff_date=$(date -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || echo "")
        
        if [[ -n "$cutoff_date" ]]; then
            # Filter logs by date
            awk -v cutoff="$cutoff_date" '$1 >= cutoff' "$wake_log" > "${OUTPUT}/wake-events.log" 2>/dev/null || \
                cp "$wake_log" "${OUTPUT}/wake-events.log"
        else
            cp "$wake_log" "${OUTPUT}/wake-events.log"
        fi
        
        log_success "VMStation wake events collected"
    else
        log_debug "No VMStation wake log found at $wake_log"
        echo "# No VMStation wake events log found" > "${OUTPUT}/wake-events.log"
    fi
}

#######################################
# Collect system power logs
#######################################
collect_system_logs() {
    log_subsection "Collecting System Power Logs"
    
    # Collect from journald if available
    if command_exists journalctl; then
        log_debug "Collecting from journald..."
        
        # Power management events
        journalctl --since "${DAYS} days ago" -u "power*" 2>/dev/null > "${OUTPUT}/systemd-power.log" || true
        
        # Suspend/resume events
        journalctl --since "${DAYS} days ago" | grep -iE "(suspend|resume|wake|sleep|hibernate)" > "${OUTPUT}/suspend-resume.log" 2>/dev/null || true
        
        # Network interface events
        journalctl --since "${DAYS} days ago" | grep -iE "(eth|eno|enp|wlan|link)" > "${OUTPUT}/network-events.log" 2>/dev/null || true
        
        log_success "System logs collected from journald"
    fi
    
    # Collect from syslog if available
    if [[ -f "${SYSTEM_LOG_DIR}/syslog" ]]; then
        log_debug "Collecting from syslog..."
        grep -iE "(wake|wol|suspend|resume|power)" "${SYSTEM_LOG_DIR}/syslog" > "${OUTPUT}/syslog-power.log" 2>/dev/null || true
    fi
    
    # Collect from messages if available
    if [[ -f "${SYSTEM_LOG_DIR}/messages" ]]; then
        log_debug "Collecting from messages..."
        grep -iE "(wake|wol|suspend|resume|power)" "${SYSTEM_LOG_DIR}/messages" > "${OUTPUT}/messages-power.log" 2>/dev/null || true
    fi
}

#######################################
# Collect kernel wake events
#######################################
collect_kernel_logs() {
    log_subsection "Collecting Kernel Wake Events"
    
    # Collect dmesg if available
    if command_exists dmesg; then
        dmesg | grep -iE "(wake|wol|resume|suspend|power)" > "${OUTPUT}/dmesg-power.log" 2>/dev/null || true
        log_debug "Kernel messages collected"
    fi
    
    # Check wake source
    if [[ -f /sys/power/pm_wakeup_irq ]]; then
        echo "Last wake IRQ: $(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo 'N/A')" > "${OUTPUT}/wake-source.txt"
    fi
    
    # Check wakeup sources
    if [[ -d /sys/class/wakeup ]]; then
        {
            echo "Wakeup Sources:"
            echo "==============="
            for ws in /sys/class/wakeup/wakeup*; do
                if [[ -d "$ws" ]]; then
                    echo ""
                    echo "$(basename "$ws"):"
                    cat "$ws/name" 2>/dev/null && echo ""
                    echo "  Active count: $(cat "$ws/active_count" 2>/dev/null || echo 'N/A')"
                    echo "  Event count: $(cat "$ws/event_count" 2>/dev/null || echo 'N/A')"
                fi
            done
        } > "${OUTPUT}/wakeup-sources.txt"
    fi
    
    log_success "Kernel wake events collected"
}

#######################################
# Collect network interface info
#######################################
collect_network_info() {
    log_subsection "Collecting Network Interface Info"
    
    {
        echo "Network Interfaces Wake-on-LAN Status"
        echo "======================================"
        echo ""
        
        # Check each interface
        for iface in /sys/class/net/*; do
            local name
            name=$(basename "$iface")
            
            # Skip loopback and virtual interfaces
            [[ "$name" == "lo" ]] && continue
            [[ "$name" == veth* ]] && continue
            [[ "$name" == docker* ]] && continue
            [[ "$name" == br-* ]] && continue
            
            echo "Interface: $name"
            
            # Get MAC address
            if [[ -f "$iface/address" ]]; then
                echo "  MAC: $(cat "$iface/address")"
            fi
            
            # Get link status
            if [[ -f "$iface/operstate" ]]; then
                echo "  State: $(cat "$iface/operstate")"
            fi
            
            # Get WoL status using ethtool
            if command_exists ethtool; then
                local wol_status
                wol_status=$(ethtool "$name" 2>/dev/null | grep -A1 "Wake-on" || echo "N/A")
                echo "  WoL: $wol_status"
            fi
            
            echo ""
        done
    } > "${OUTPUT}/network-interfaces.txt"
    
    log_success "Network interface info collected"
}

#######################################
# Analyze logs
#######################################
analyze_logs() {
    log_subsection "Analyzing Logs"
    
    local analysis_file="${OUTPUT}/analysis.txt"
    
    {
        echo "Wake Event Analysis"
        echo "==================="
        echo "Generated: $(date -Iseconds)"
        echo "Period: Last $DAYS days"
        echo ""
        
        # Analyze wake events
        if [[ -f "${OUTPUT}/wake-events.log" ]] && [[ -s "${OUTPUT}/wake-events.log" ]]; then
            echo "VMStation Wake Events:"
            echo "-----------------------"
            
            local total_events
            total_events=$(wc -l < "${OUTPUT}/wake-events.log")
            echo "Total events: $total_events"
            
            local successful
            successful=$(grep -c "ONLINE" "${OUTPUT}/wake-events.log" 2>/dev/null || echo 0)
            echo "Successful wakes: $successful"
            
            local timeout
            timeout=$(grep -c "TIMEOUT" "${OUTPUT}/wake-events.log" 2>/dev/null || echo 0)
            echo "Timeouts: $timeout"
            
            local failed
            failed=$(grep -c "FAILED" "${OUTPUT}/wake-events.log" 2>/dev/null || echo 0)
            echo "Failed: $failed"
            
            echo ""
            echo "Events by MAC address:"
            awk -F'MAC=' '{print $2}' "${OUTPUT}/wake-events.log" 2>/dev/null | \
                awk '{print $1}' | sort | uniq -c | sort -rn || true
            
            echo ""
        fi
        
        # Analyze suspend/resume events
        if [[ -f "${OUTPUT}/suspend-resume.log" ]] && [[ -s "${OUTPUT}/suspend-resume.log" ]]; then
            echo "Suspend/Resume Events:"
            echo "----------------------"
            
            local suspend_count
            suspend_count=$(grep -ci "suspend" "${OUTPUT}/suspend-resume.log" 2>/dev/null || echo 0)
            echo "Suspend events: $suspend_count"
            
            local resume_count
            resume_count=$(grep -ci "resume" "${OUTPUT}/suspend-resume.log" 2>/dev/null || echo 0)
            echo "Resume events: $resume_count"
            
            echo ""
        fi
        
        echo "Summary:"
        echo "--------"
        echo "Log files collected:"
        find "$OUTPUT" -type f -name "*.log" -o -name "*.txt" | while read -r f; do
            echo "  - $(basename "$f"): $(wc -l < "$f") lines"
        done
        
    } > "$analysis_file"
    
    # Display analysis
    cat "$analysis_file"
}

#######################################
# Generate summary
#######################################
generate_summary() {
    local summary_file="${OUTPUT}/collection-summary.txt"
    
    {
        echo "Wake Log Collection Summary"
        echo "==========================="
        echo "Timestamp: $(date -Iseconds)"
        echo "Days: $DAYS"
        echo ""
        echo "Files collected:"
        find "$OUTPUT" -type f | while read -r f; do
            echo "  - $(basename "$f")"
        done
    } > "$summary_file"
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    log_section "VMStation Wake Log Collection"
    log_kv "Days" "$DAYS"
    log_kv "Output" "$OUTPUT"
    
    # Initialize output
    init_output
    
    # Collect logs
    collect_vmstation_logs
    collect_system_logs
    collect_kernel_logs
    collect_network_info
    
    # Generate summary
    generate_summary
    
    # Analyze if requested
    if [[ "$ANALYZE" == "true" ]]; then
        analyze_logs
    fi
    
    log_section "Collection Complete"
    log_info "Logs saved to: $OUTPUT"
}

main "$@"
