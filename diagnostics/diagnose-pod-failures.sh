#!/usr/bin/env bash
# Script: diagnose-pod-failures.sh
# Purpose: Diagnose pod failures and issues
# Usage: ./diagnose-pod-failures.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -n, --namespace Specific namespace (default: all)
#   -o, --output   Output directory for diagnostic files

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostic-output}"
NAMESPACE="${NAMESPACE:-}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose pod failures and issues including:
  - CrashLoopBackOff analysis
  - ImagePull errors
  - Pending pod investigation
  - Container restart analysis
  - Event correlation

Options:
  -n, --namespace NS  Check specific namespace (default: all)
  -o, --output DIR    Output directory for diagnostic files
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Examples:
  $(basename "$0")                   # Diagnose all namespaces
  $(basename "$0") -n monitoring     # Diagnose specific namespace
  $(basename "$0") -o /tmp/diag      # Save to specific directory

Output:
  Creates a directory with pod failure diagnostic information
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
            -o|--output)
                OUTPUT_DIR="${2:?Output directory required}"
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
# Get namespace flag for kubectl
#######################################
get_ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "--all-namespaces"
    fi
}

#######################################
# Initialize output directory
#######################################
init_output_dir() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    OUTPUT_DIR="${OUTPUT_DIR}/pod-failures-${timestamp}"

    ensure_directory "$OUTPUT_DIR"
    ensure_directory "${OUTPUT_DIR}/pod-logs"
    ensure_directory "${OUTPUT_DIR}/pod-descriptions"

    log_info "Diagnostic output will be saved to: $OUTPUT_DIR"
}

#######################################
# Collect CrashLoopBackOff pods
#######################################
collect_crashloop_pods() {
    log_subsection "Analyzing CrashLoopBackOff Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local crashloop_file="${OUTPUT_DIR}/crashloop-pods.txt"

    {
        echo "CrashLoopBackOff Pod Analysis"
        echo "=============================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
    } > "$crashloop_file"

    # shellcheck disable=SC2086
    local crashloop_pods
    crashloop_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep "CrashLoopBackOff" || true)

    if [[ -z "$crashloop_pods" ]]; then
        echo "No CrashLoopBackOff pods found" >> "$crashloop_file"
        log_success "No CrashLoopBackOff pods"
        return 0
    fi

    echo "$crashloop_pods" >> "$crashloop_file"
    echo "" >> "$crashloop_file"

    # Get details for each CrashLoopBackOff pod
    echo "$crashloop_pods" | while read -r line; do
        local ns name
        if [[ -n "$NAMESPACE" ]]; then
            ns="$NAMESPACE"
            name=$(echo "$line" | awk '{print $1}')
        else
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
        fi

        if [[ -z "$name" ]]; then
            continue
        fi

        log_debug "Collecting info for CrashLoopBackOff pod: $ns/$name"

        # Get pod description
        kubectl describe pod -n "$ns" "$name" > "${OUTPUT_DIR}/pod-descriptions/${ns}-${name}.txt" 2>&1 || true

        # Get pod logs (current and previous)
        kubectl logs -n "$ns" "$name" --all-containers --tail=100 > "${OUTPUT_DIR}/pod-logs/${ns}-${name}.log" 2>&1 || true
        kubectl logs -n "$ns" "$name" --all-containers --previous --tail=100 > "${OUTPUT_DIR}/pod-logs/${ns}-${name}-previous.log" 2>&1 || true

        {
            echo "Pod: $ns/$name"
            echo "---"
            echo "Last termination reason:"
            kubectl get pod -n "$ns" "$name" -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}' 2>/dev/null || echo "N/A"
            echo ""
            echo "Exit code:"
            kubectl get pod -n "$ns" "$name" -o jsonpath='{.status.containerStatuses[*].lastState.terminated.exitCode}' 2>/dev/null || echo "N/A"
            echo ""
            echo ""
        } >> "$crashloop_file"
    done

    log_success "CrashLoopBackOff analysis complete"
}

#######################################
# Collect ImagePull error pods
#######################################
collect_imagepull_errors() {
    log_subsection "Analyzing ImagePull Errors"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local imagepull_file="${OUTPUT_DIR}/imagepull-errors.txt"

    {
        echo "ImagePull Error Analysis"
        echo "========================"
        echo "Timestamp: $(date -Iseconds)"
        echo ""
    } > "$imagepull_file"

    # shellcheck disable=SC2086
    local imagepull_pods
    imagepull_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull" || true)

    if [[ -z "$imagepull_pods" ]]; then
        echo "No ImagePull error pods found" >> "$imagepull_file"
        log_success "No ImagePull errors"
        return 0
    fi

    echo "$imagepull_pods" >> "$imagepull_file"
    echo "" >> "$imagepull_file"

    # Get details for each pod
    echo "$imagepull_pods" | while read -r line; do
        local ns name
        if [[ -n "$NAMESPACE" ]]; then
            ns="$NAMESPACE"
            name=$(echo "$line" | awk '{print $1}')
        else
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
        fi

        if [[ -z "$name" ]]; then
            continue
        fi

        {
            echo "Pod: $ns/$name"
            echo "---"
            echo "Image(s):"
            kubectl get pod -n "$ns" "$name" -o jsonpath='{.spec.containers[*].image}' 2>/dev/null || echo "N/A"
            echo ""
            echo "Events:"
            kubectl get events -n "$ns" --field-selector "involvedObject.name=$name" --no-headers 2>/dev/null | tail -5 || true
            echo ""
        } >> "$imagepull_file"

        # Get pod description
        kubectl describe pod -n "$ns" "$name" > "${OUTPUT_DIR}/pod-descriptions/${ns}-${name}.txt" 2>&1 || true
    done

    log_success "ImagePull error analysis complete"
}

#######################################
# Collect pending pods
#######################################
collect_pending_pods() {
    log_subsection "Analyzing Pending Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local pending_file="${OUTPUT_DIR}/pending-pods.txt"

    {
        echo "Pending Pod Analysis"
        echo "===================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
    } > "$pending_file"

    # shellcheck disable=SC2086
    local pending_pods
    pending_pods=$(kubectl get pods $ns_flag --field-selector=status.phase=Pending --no-headers 2>/dev/null || true)

    if [[ -z "$pending_pods" ]]; then
        echo "No pending pods found" >> "$pending_file"
        log_success "No pending pods"
        return 0
    fi

    echo "$pending_pods" >> "$pending_file"
    echo "" >> "$pending_file"

    # Get details for each pending pod
    echo "$pending_pods" | while read -r line; do
        local ns name
        if [[ -n "$NAMESPACE" ]]; then
            ns="$NAMESPACE"
            name=$(echo "$line" | awk '{print $1}')
        else
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
        fi

        if [[ -z "$name" ]]; then
            continue
        fi

        {
            echo "Pod: $ns/$name"
            echo "---"
            echo "Scheduling status:"
            kubectl get pod -n "$ns" "$name" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}: {.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || echo "N/A"
            echo ""
            echo "Recent events:"
            kubectl get events -n "$ns" --field-selector "involvedObject.name=$name" --no-headers 2>/dev/null | tail -5 || true
            echo ""
        } >> "$pending_file"

        # Get pod description
        kubectl describe pod -n "$ns" "$name" > "${OUTPUT_DIR}/pod-descriptions/${ns}-${name}.txt" 2>&1 || true
    done

    log_success "Pending pod analysis complete"
}

#######################################
# Collect failed pods
#######################################
collect_failed_pods() {
    log_subsection "Analyzing Failed Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local failed_file="${OUTPUT_DIR}/failed-pods.txt"

    {
        echo "Failed Pod Analysis"
        echo "==================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
    } > "$failed_file"

    # shellcheck disable=SC2086
    local failed_pods
    failed_pods=$(kubectl get pods $ns_flag --field-selector=status.phase=Failed --no-headers 2>/dev/null || true)

    if [[ -z "$failed_pods" ]]; then
        echo "No failed pods found" >> "$failed_file"
        log_success "No failed pods"
        return 0
    fi

    echo "$failed_pods" >> "$failed_file"
    echo "" >> "$failed_file"

    # Get details for each failed pod
    echo "$failed_pods" | while read -r line; do
        local ns name
        if [[ -n "$NAMESPACE" ]]; then
            ns="$NAMESPACE"
            name=$(echo "$line" | awk '{print $1}')
        else
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
        fi

        if [[ -z "$name" ]]; then
            continue
        fi

        # Get pod logs
        kubectl logs -n "$ns" "$name" --all-containers --tail=100 > "${OUTPUT_DIR}/pod-logs/${ns}-${name}.log" 2>&1 || true

        # Get pod description
        kubectl describe pod -n "$ns" "$name" > "${OUTPUT_DIR}/pod-descriptions/${ns}-${name}.txt" 2>&1 || true
    done

    log_success "Failed pod analysis complete"
}

#######################################
# Collect high restart pods
#######################################
collect_high_restart_pods() {
    log_subsection "Analyzing High Restart Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local restart_file="${OUTPUT_DIR}/high-restart-pods.txt"

    {
        echo "High Restart Pod Analysis"
        echo "========================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        echo "Pods with > 5 restarts:"
        echo ""
    } > "$restart_file"

    # Get pods with high restart counts
    # shellcheck disable=SC2086
    kubectl get pods $ns_flag -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null | \
    while IFS= read -r line; do
        local restarts
        restarts=$(echo "$line" | awk '{print $NF}')

        # Handle comma-separated restart counts
        local total=0
        IFS=',' read -ra restart_arr <<< "$restarts"
        for r in "${restart_arr[@]}"; do
            if [[ "$r" =~ ^[0-9]+$ ]]; then
                total=$((total + r))
            fi
        done

        if [[ $total -gt 5 ]]; then
            echo "$line (total: $total)" >> "$restart_file"
        fi
    done

    log_success "High restart pod analysis complete"
}

#######################################
# Collect OOM killed pods
#######################################
collect_oom_killed_pods() {
    log_subsection "Analyzing OOMKilled Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local oom_file="${OUTPUT_DIR}/oom-killed-pods.txt"

    {
        echo "OOMKilled Pod Analysis"
        echo "======================"
        echo "Timestamp: $(date -Iseconds)"
        echo ""
    } > "$oom_file"

    # Get OOMKilled events
    # shellcheck disable=SC2086
    local oom_events
    oom_events=$(kubectl get events $ns_flag --field-selector reason=OOMKilling --no-headers 2>/dev/null || true)

    if [[ -z "$oom_events" ]]; then
        echo "No OOMKilled events found" >> "$oom_file"
    else
        echo "Recent OOMKilled events:" >> "$oom_file"
        echo "$oom_events" >> "$oom_file"
    fi

    log_success "OOMKilled analysis complete"
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_subsection "Generating Summary"

    local summary_file="${OUTPUT_DIR}/diagnosis-summary.txt"
    local ns_flag
    ns_flag=$(get_ns_flag)

    {
        echo "Pod Failure Diagnostic Summary"
        echo "=============================="
        echo "Timestamp: $(date -Iseconds)"
        echo "Namespace: ${NAMESPACE:-all}"
        echo ""

        echo "Pod Status Summary:"
        echo "-------------------"
        # shellcheck disable=SC2086
        local crashloop
        crashloop=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)
        echo "- CrashLoopBackOff: $crashloop"

        # shellcheck disable=SC2086
        local imagepull
        imagepull=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -cE "ImagePullBackOff|ErrImagePull" || echo 0)
        echo "- ImagePull errors: $imagepull"

        # shellcheck disable=SC2086
        local pending
        pending=$(kubectl get pods $ns_flag --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
        echo "- Pending: $pending"

        # shellcheck disable=SC2086
        local failed
        failed=$(kubectl get pods $ns_flag --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
        echo "- Failed: $failed"

        echo ""
        echo "Files Collected:"
        echo "----------------"
        echo "- crashloop-pods.txt"
        echo "- imagepull-errors.txt"
        echo "- pending-pods.txt"
        echo "- failed-pods.txt"
        echo "- high-restart-pods.txt"
        echo "- oom-killed-pods.txt"
        echo "- pod-logs/ (individual pod logs)"
        echo "- pod-descriptions/ (pod descriptions)"
    } > "$summary_file"

    log_success "Summary generated"
    cat "$summary_file"
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

    log_section "Pod Failure Diagnostics"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Timestamp" "$(date -Iseconds)"

    # Initialize output
    init_output_dir

    # Collect all diagnostic information
    collect_crashloop_pods
    collect_imagepull_errors
    collect_pending_pods
    collect_failed_pods
    collect_high_restart_pods
    collect_oom_killed_pods

    # Generate summary
    generate_summary

    log_section "Diagnostic Collection Complete"
    log_info "All diagnostic files saved to: $OUTPUT_DIR"
}

main "$@"
