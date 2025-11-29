#!/usr/bin/env bash
# collect-logs.sh - Collect logs from cluster components
# Gathers logs from pods, nodes, and system components
#
# Usage: ./collect-logs.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Kubernetes namespace (default: all namespaces)
#   -l, --labels       Label selector for pods
#   -o, --output       Output directory for logs
#   --since            Only logs newer than this duration (e.g., 1h, 30m)
#   --tail             Number of lines from end of logs (default: 1000)
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-}"
LABEL_SELECTOR="${LABEL_SELECTOR:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./logs}"
SINCE="${SINCE:-}"
TAIL_LINES="${TAIL_LINES:-1000}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Collect logs from Kubernetes pods and components.

Options:
  -n, --namespace NS    Kubernetes namespace (default: all namespaces)
  -l, --labels LABELS   Label selector for pods (e.g., app=nginx)
  -o, --output DIR      Output directory for logs (default: ./logs)
  --since DURATION      Only logs newer than this duration (e.g., 1h, 30m)
  --tail N              Number of lines from end of logs (default: 1000)
  -v, --verbose         Enable verbose output
  -h, --help            Show this help message

Examples:
  $(basename "$0")                              # Collect all logs
  $(basename "$0") -n monitoring                # Logs from monitoring namespace
  $(basename "$0") -l app=prometheus --since 1h # Prometheus logs, last hour
  $(basename "$0") --tail 500 -o /tmp/logs      # Last 500 lines to /tmp/logs

Output:
  Creates a directory structure with logs organized by namespace and pod
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace)
                NAMESPACE="${2:?Namespace value required}"
                shift 2
                ;;
            -l|--labels)
                LABEL_SELECTOR="${2:?Label selector required}"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="${2:?Output directory required}"
                shift 2
                ;;
            --since)
                SINCE="${2:?Duration value required}"
                shift 2
                ;;
            --tail)
                TAIL_LINES="${2:?Number of lines required}"
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
init_output_dir() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    OUTPUT_DIR="${OUTPUT_DIR}/logs-${timestamp}"
    
    ensure_directory "$OUTPUT_DIR"
    
    log_info "Logs will be saved to: $OUTPUT_DIR"
}

#######################################
# Build kubectl command arguments
#######################################
build_kubectl_args() {
    local args=()
    
    if [[ -n "$NAMESPACE" ]]; then
        args+=("-n" "$NAMESPACE")
    else
        args+=("--all-namespaces")
    fi
    
    if [[ -n "$LABEL_SELECTOR" ]]; then
        args+=("-l" "$LABEL_SELECTOR")
    fi
    
    echo "${args[*]}"
}

#######################################
# Build log command arguments
#######################################
build_log_args() {
    local args=()
    
    args+=("--tail=$TAIL_LINES")
    
    if [[ -n "$SINCE" ]]; then
        args+=("--since=$SINCE")
    fi
    
    args+=("--all-containers=true")
    
    echo "${args[*]}"
}

#######################################
# Collect pod logs
#######################################
collect_pod_logs() {
    log_subsection "Collecting Pod Logs"
    
    local kubectl_args
    kubectl_args=$(build_kubectl_args)
    
    local log_args
    log_args=$(build_log_args)
    
    # Get list of pods
    local pods
    # shellcheck disable=SC2086
    pods=$(kubectl get pods $kubectl_args --no-headers -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name' 2>/dev/null || true)
    
    if [[ -z "$pods" ]]; then
        log_warn "No pods found matching criteria"
        return 0
    fi
    
    local count=0
    local total
    total=$(echo "$pods" | wc -l)
    
    echo "$pods" | while read -r ns pod; do
        if [[ -n "$pod" ]]; then
            ((count++)) || true
            log_progress "$count" "$total" "Collecting logs: $pod"
            
            local ns_dir="${OUTPUT_DIR}/${ns}"
            ensure_directory "$ns_dir"
            
            # Collect current logs
            # shellcheck disable=SC2086
            kubectl logs -n "$ns" "$pod" $log_args > "${ns_dir}/${pod}.log" 2>&1 || true
            
            # Try to collect previous logs
            # shellcheck disable=SC2086
            kubectl logs -n "$ns" "$pod" $log_args --previous > "${ns_dir}/${pod}-previous.log" 2>&1 || true
            
            # Remove empty previous log files
            if [[ ! -s "${ns_dir}/${pod}-previous.log" ]]; then
                rm -f "${ns_dir}/${pod}-previous.log"
            fi
        fi
    done
    
    echo ""  # New line after progress
    log_success "Pod logs collected"
}

#######################################
# Collect container information
#######################################
collect_container_info() {
    log_subsection "Collecting Container Information"
    
    local kubectl_args
    kubectl_args=$(build_kubectl_args)
    
    # Get pod details including container info
    # shellcheck disable=SC2086
    kubectl get pods $kubectl_args -o wide > "${OUTPUT_DIR}/pod-summary.txt" 2>&1 || true
    
    # Get container statuses
    # shellcheck disable=SC2086
    kubectl get pods $kubectl_args -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,CONTAINERS:.spec.containers[*].name,STATUS:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' > "${OUTPUT_DIR}/container-status.txt" 2>&1 || true
    
    log_success "Container information collected"
}

#######################################
# Collect events related to pods
#######################################
collect_related_events() {
    log_subsection "Collecting Related Events"
    
    if [[ -n "$NAMESPACE" ]]; then
        kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/events.txt" 2>&1 || true
    else
        kubectl get events --all-namespaces --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/events.txt" 2>&1 || true
    fi
    
    log_success "Events collected"
}

#######################################
# Generate collection summary
#######################################
generate_summary() {
    log_subsection "Generating Summary"
    
    local summary_file="${OUTPUT_DIR}/collection-summary.txt"
    
    {
        echo "Log Collection Summary"
        echo "======================"
        echo "Timestamp: $(date -Iseconds)"
        echo "Namespace: ${NAMESPACE:-all}"
        echo "Label selector: ${LABEL_SELECTOR:-none}"
        echo "Since: ${SINCE:-all time}"
        echo "Tail lines: $TAIL_LINES"
        echo ""
        echo "Files collected:"
        find "$OUTPUT_DIR" -type f -name "*.log" | wc -l | xargs echo "- Log files:"
        echo ""
        echo "Directory structure:"
        find "$OUTPUT_DIR" -type d | sort | sed 's/^/  /'
    } > "$summary_file"
    
    log_success "Summary generated"
}

#######################################
# Create compressed archive
#######################################
create_archive() {
    log_subsection "Creating Archive"
    
    local archive_name
    archive_name="$(dirname "$OUTPUT_DIR")/$(basename "$OUTPUT_DIR").tar.gz"
    
    tar -czf "$archive_name" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null || {
        log_warn "Could not create compressed archive"
        return 0
    }
    
    log_success "Archive created: $archive_name"
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    # Check prerequisites
    require_command kubectl
    
    if ! kubectl_ready; then
        log_error "kubectl is not configured or cluster is not reachable"
        exit 2
    fi
    
    log_section "Log Collection"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Labels" "${LABEL_SELECTOR:-none}"
    log_kv "Since" "${SINCE:-all time}"
    log_kv "Tail lines" "$TAIL_LINES"
    
    # Initialize output
    init_output_dir
    
    # Collect logs
    collect_pod_logs
    collect_container_info
    collect_related_events
    
    # Generate summary and archive
    generate_summary
    create_archive
    
    log_section "Log Collection Complete"
    log_info "Logs saved to: $OUTPUT_DIR"
}

main "$@"
