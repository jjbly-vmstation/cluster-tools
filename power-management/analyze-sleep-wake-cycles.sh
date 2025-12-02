#!/usr/bin/env bash
# Script: analyze-sleep-wake-cycles.sh
# Purpose: Analyze sleep/wake cycle patterns
# Usage: ./analyze-sleep-wake-cycles.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -d, --days     Number of days to analyze (default: 7)
#   --json         JSON output

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
DAYS="${DAYS:-7}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Log locations
VMSTATION_LOG_DIR="${VMSTATION_LOG_DIR:-/var/log/vmstation}"
WAKE_LOG="${VMSTATION_LOG_DIR}/wake-events.log"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Analyze sleep/wake cycle patterns from VMStation logs:
  - Wake event frequency
  - Success/failure rates
  - Time-of-day patterns
  - Per-host statistics

Options:
  -d, --days N    Number of days to analyze (default: 7)
  --json          Output results as JSON
  -v, --verbose   Enable verbose output
  -h, --help      Show this help message

Examples:
  $(basename "$0")            # Analyze last 7 days
  $(basename "$0") -d 30      # Analyze last 30 days
  $(basename "$0") --json     # Output as JSON

Log Location:
  Default: /var/log/vmstation/wake-events.log
  Override with VMSTATION_LOG_DIR environment variable
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--days)
                DAYS="${2:?Days value required}"
                shift 2
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
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
}

#######################################
# Check for wake log
#######################################
check_wake_log() {
    if [[ ! -f "$WAKE_LOG" ]]; then
        log_warn "Wake log not found at $WAKE_LOG"
        log_info "No wake events have been recorded"
        return 1
    fi

    if [[ ! -s "$WAKE_LOG" ]]; then
        log_warn "Wake log is empty"
        return 1
    fi

    return 0
}

#######################################
# Filter logs by date range
#######################################
get_filtered_logs() {
    local cutoff_date

    # Calculate cutoff date
    cutoff_date=$(date -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null || \
                  date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || \
                  echo "")

    if [[ -z "$cutoff_date" ]]; then
        cat "$WAKE_LOG"
    else
        awk -v cutoff="$cutoff_date" '$1 >= cutoff' "$WAKE_LOG"
    fi
}

#######################################
# Analyze wake event counts
#######################################
analyze_event_counts() {
    local logs="$1"

    local total_events
    total_events=$(echo "$logs" | wc -l)

    local wol_sent
    wol_sent=$(echo "$logs" | grep -c "WOL_SENT" || echo 0)

    local online
    online=$(echo "$logs" | grep -c "ONLINE" || echo 0)

    local timeout
    timeout=$(echo "$logs" | grep -c "TIMEOUT" || echo 0)

    local failed
    failed=$(echo "$logs" | grep -c "FAILED\|WOL_FAILED" || echo 0)

    echo "total_events=$total_events"
    echo "wol_sent=$wol_sent"
    echo "online=$online"
    echo "timeout=$timeout"
    echo "failed=$failed"
}

#######################################
# Analyze per-host statistics
#######################################
analyze_per_host() {
    local logs="$1"

    echo "Per-Host Statistics:"
    echo "===================="

    # Extract MAC addresses and count events
    echo "$logs" | awk -F'MAC=' '{print $2}' | awk '{print $1}' | sort | uniq -c | sort -rn | \
    while read -r count mac; do
        if [[ -n "$mac" ]]; then
            local host_online
            host_online=$(echo "$logs" | grep "MAC=$mac" | grep -c "ONLINE" || echo 0)

            local host_timeout
            host_timeout=$(echo "$logs" | grep "MAC=$mac" | grep -c "TIMEOUT" || echo 0)

            local success_rate=0
            if [[ $count -gt 0 ]]; then
                success_rate=$(( (host_online * 100) / count ))
            fi

            printf "  %-20s Events: %-4d Online: %-4d Timeout: %-4d Success: %d%%\n" \
                "$mac" "$count" "$host_online" "$host_timeout" "$success_rate"
        fi
    done
}

#######################################
# Analyze time-of-day patterns
#######################################
analyze_time_patterns() {
    local logs="$1"

    echo ""
    echo "Time-of-Day Distribution:"
    echo "========================="

    # Extract hours and count
    echo "$logs" | awk '{print substr($2, 1, 2)}' | sort | uniq -c | sort -k2n | \
    while read -r count hour; do
        if [[ -n "$hour" ]]; then
            local bar=""
            local bar_length=$((count / 2))
            for ((i=0; i<bar_length; i++)); do
                bar+="▓"
            done
            printf "  %02d:00 - %02d:59  [%3d] %s\n" "$hour" "$hour" "$count" "$bar"
        fi
    done
}

#######################################
# Analyze day-of-week patterns
#######################################
analyze_day_patterns() {
    local logs="$1"

    echo ""
    echo "Day-of-Week Distribution:"
    echo "========================="

    local days=("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")

    for i in {0..6}; do
        local count=0

        # Count events for each day
        echo "$logs" | awk '{print $1}' | while read -r date_str; do
            if [[ -n "$date_str" ]]; then
                local day_num
                day_num=$(date -d "$date_str" +%w 2>/dev/null || echo "")
                if [[ "$day_num" == "$i" ]]; then
                    echo "$date_str"
                fi
            fi
        done | wc -l | while read -r c; do
            local bar=""
            local bar_length=$((c / 2))
            for ((j=0; j<bar_length; j++)); do
                bar+="▓"
            done
            printf "  %-3s  [%3d] %s\n" "${days[$i]}" "$c" "$bar"
        done
    done
}

#######################################
# Analyze trends
#######################################
analyze_trends() {
    local logs="$1"

    echo ""
    echo "Trend Analysis:"
    echo "==============="

    # Calculate daily averages
    local unique_days
    unique_days=$(echo "$logs" | awk '{print $1}' | sort -u | wc -l)

    local total_events
    total_events=$(echo "$logs" | wc -l)

    if [[ $unique_days -gt 0 ]]; then
        local avg_per_day=$((total_events / unique_days))
        echo "  Average events per day: $avg_per_day"
    fi

    # Find most active day
    local most_active_day
    most_active_day=$(echo "$logs" | awk '{print $1}' | sort | uniq -c | sort -rn | head -1)
    if [[ -n "$most_active_day" ]]; then
        echo "  Most active day: $most_active_day"
    fi

    # Calculate overall success rate
    local online
    online=$(echo "$logs" | grep -c "ONLINE" || echo 0)

    local wol_sent
    wol_sent=$(echo "$logs" | grep -c "WOL_SENT" || echo 0)

    if [[ $wol_sent -gt 0 ]]; then
        local success_rate=$(( (online * 100) / wol_sent ))
        echo "  Overall success rate: $success_rate%"
    fi
}

#######################################
# Output as JSON
#######################################
output_json() {
    local logs="$1"

    # Get counts
    local total_events
    total_events=$(echo "$logs" | wc -l)

    local wol_sent
    wol_sent=$(echo "$logs" | grep -c "WOL_SENT" || echo 0)

    local online
    online=$(echo "$logs" | grep -c "ONLINE" || echo 0)

    local timeout
    timeout=$(echo "$logs" | grep -c "TIMEOUT" || echo 0)

    local failed
    failed=$(echo "$logs" | grep -c "FAILED\|WOL_FAILED" || echo 0)

    local success_rate=0
    if [[ $wol_sent -gt 0 ]]; then
        success_rate=$(( (online * 100) / wol_sent ))
    fi

    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    echo '  "period_days": '"$DAYS"','
    echo '  "summary": {'
    echo '    "total_events": '"$total_events"','
    echo '    "wol_sent": '"$wol_sent"','
    echo '    "online": '"$online"','
    echo '    "timeout": '"$timeout"','
    echo '    "failed": '"$failed"','
    echo '    "success_rate": '"$success_rate"
    echo '  },'

    # Per-host statistics
    echo '  "hosts": {'
    local first=true
    echo "$logs" | awk -F'MAC=' '{print $2}' | awk '{print $1}' | sort -u | while read -r mac; do
        if [[ -n "$mac" ]]; then
            local host_events
            host_events=$(echo "$logs" | grep -c "MAC=$mac" || echo 0)

            local host_online
            host_online=$(echo "$logs" | grep "MAC=$mac" | grep -c "ONLINE" || echo 0)

            local host_timeout
            host_timeout=$(echo "$logs" | grep "MAC=$mac" | grep -c "TIMEOUT" || echo 0)

            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi

            echo -n '    "'"$mac"'": {"events": '"$host_events"', "online": '"$host_online"', "timeout": '"$host_timeout"'}'
        fi
    done
    echo ""
    echo "  }"
    echo "}"
}

#######################################
# Output text report
#######################################
output_text() {
    local logs="$1"

    log_section "Sleep/Wake Cycle Analysis"
    log_kv "Period" "Last $DAYS days"
    log_kv "Log File" "$WAKE_LOG"
    log_kv "Timestamp" "$(date -Iseconds)"

    echo ""
    echo "Event Summary:"
    echo "=============="

    local total_events
    total_events=$(echo "$logs" | wc -l)
    echo "  Total events: $total_events"

    local wol_sent
    wol_sent=$(echo "$logs" | grep -c "WOL_SENT" || echo 0)
    echo "  WoL packets sent: $wol_sent"

    local online
    online=$(echo "$logs" | grep -c "ONLINE" || echo 0)
    echo "  Successful wakes: $online"

    local timeout
    timeout=$(echo "$logs" | grep -c "TIMEOUT" || echo 0)
    echo "  Timeouts: $timeout"

    local failed
    failed=$(echo "$logs" | grep -c "FAILED\|WOL_FAILED" || echo 0)
    echo "  Failures: $failed"

    if [[ $wol_sent -gt 0 ]]; then
        local success_rate=$(( (online * 100) / wol_sent ))
        echo "  Success rate: $success_rate%"
    fi

    echo ""
    analyze_per_host "$logs"
    analyze_time_patterns "$logs"
    analyze_trends "$logs"
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_info "Analyzing sleep/wake cycles for the last $DAYS days..."
    fi

    # Check for wake log
    if ! check_wake_log; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"error": "No wake log found", "log_path": "'"$WAKE_LOG"'"}'
        fi
        exit 0
    fi

    # Get filtered logs
    local logs
    logs=$(get_filtered_logs)

    if [[ -z "$logs" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            echo '{"error": "No events in date range", "days": '"$DAYS"'}'
        else
            log_info "No wake events found in the last $DAYS days"
        fi
        exit 0
    fi

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json "$logs"
    else
        output_text "$logs"
    fi
}

main "$@"
