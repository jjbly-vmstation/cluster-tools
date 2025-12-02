#!/usr/bin/env bash
# Script: validate-pod-health.sh
# Purpose: Validate pod status across namespaces
# Usage: ./validate-pod-health.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -q, --quiet    Quiet mode
#   --json         JSON output
#   -n, --namespace Specific namespace (default: all)

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"
NAMESPACE="${NAMESPACE:-}"
MAX_POD_RESTART_COUNT="${MAX_POD_RESTART_COUNT:-5}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate Kubernetes pod health including:
  - Pod running status
  - Container restart counts
  - CrashLoopBackOff detection
  - ImagePull errors
  - Pod scheduling issues

Options:
  -n, --namespace NS  Check specific namespace (default: all)
  -v, --verbose       Enable verbose output
  -q, --quiet         Suppress non-error output
  --json              Output results as JSON
  -h, --help          Show this help message

Environment:
  MAX_POD_RESTART_COUNT  Maximum allowed restarts (default: 5)

Examples:
  $(basename "$0")                   # Validate all namespaces
  $(basename "$0") -n monitoring     # Validate specific namespace
  $(basename "$0") --json            # Output results as JSON

Exit Codes:
  0 - All validations passed
  1 - One or more validations failed
  2 - Script error (missing dependencies, etc.)
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
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -q|--quiet)
                export LOG_LEVEL="ERROR"
                shift
                ;;
            --json)
                JSON_OUTPUT="true"
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
# Record validation result
#######################################
record_result() {
    local check="$1"
    local status="$2"
    local message="$3"

    RESULTS["$check"]="$status|$message"

    if [[ "$status" == "pass" ]]; then
        log_success "$check: $message"
    else
        log_failure "$check: $message"
    fi
}

#######################################
# Get namespace flag for kubectl
# Returns a string to be used as kubectl namespace argument.
# IMPORTANT: This string should NOT be quoted when used
# because it may contain multiple words (-n namespace or --all-namespaces)
# and we intentionally want word splitting.
# Usage: local ns_flag; ns_flag=$(get_ns_flag)
#        # shellcheck disable=SC2086
#        kubectl get pods $ns_flag
#######################################
get_ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "--all-namespaces"
    fi
}

#######################################
# Check running pods
#######################################
check_running_pods() {
    log_subsection "Pod Running Status"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local total_pods
    # shellcheck disable=SC2086
    total_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | wc -l)

    if [[ $total_pods -eq 0 ]]; then
        log_debug "No pods found"
        return 0
    fi

    local running_pods
    # shellcheck disable=SC2086
    running_pods=$(kubectl get pods $ns_flag --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    local completed_pods
    # shellcheck disable=SC2086
    completed_pods=$(kubectl get pods $ns_flag --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l)

    local healthy=$((running_pods + completed_pods))

    if [[ $healthy -eq $total_pods ]]; then
        record_result "pods-running" "pass" "$running_pods Running, $completed_pods Completed of $total_pods total"
    else
        local unhealthy=$((total_pods - healthy))
        record_result "pods-running" "fail" "$unhealthy pods not in Running/Completed state"
    fi
}

#######################################
# Check for CrashLoopBackOff
#######################################
check_crashloop_pods() {
    log_subsection "CrashLoopBackOff Detection"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local crashloop_count
    # shellcheck disable=SC2086
    crashloop_count=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)

    if [[ $crashloop_count -eq 0 ]]; then
        record_result "crashloop-pods" "pass" "No CrashLoopBackOff pods"
    else
        record_result "crashloop-pods" "fail" "$crashloop_count pod(s) in CrashLoopBackOff"

        # List CrashLoopBackOff pods
        log_debug "CrashLoopBackOff pods:"
        # shellcheck disable=SC2086
        kubectl get pods $ns_flag --no-headers 2>/dev/null | grep "CrashLoopBackOff" | while read -r line; do
            log_debug "  $line"
        done
    fi
}

#######################################
# Check for ImagePull errors
#######################################
check_imagepull_errors() {
    log_subsection "ImagePull Error Detection"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local imagepull_count
    # shellcheck disable=SC2086
    imagepull_count=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -cE "ImagePullBackOff|ErrImagePull" || echo 0)

    if [[ $imagepull_count -eq 0 ]]; then
        record_result "imagepull-errors" "pass" "No ImagePull errors"
    else
        record_result "imagepull-errors" "fail" "$imagepull_count pod(s) with ImagePull errors"

        # List pods with ImagePull errors
        log_debug "Pods with ImagePull errors:"
        # shellcheck disable=SC2086
        kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull" | while read -r line; do
            log_debug "  $line"
        done
    fi
}

#######################################
# Check pending pods
#######################################
check_pending_pods() {
    log_subsection "Pending Pod Detection"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local pending_count
    # shellcheck disable=SC2086
    pending_count=$(kubectl get pods $ns_flag --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)

    if [[ $pending_count -eq 0 ]]; then
        record_result "pending-pods" "pass" "No pending pods"
    else
        record_result "pending-pods" "fail" "$pending_count pod(s) in Pending state"

        # List pending pods
        log_debug "Pending pods:"
        # shellcheck disable=SC2086
        kubectl get pods $ns_flag --field-selector=status.phase=Pending --no-headers 2>/dev/null | while read -r line; do
            log_debug "  $line"
        done
    fi
}

#######################################
# Check failed pods
#######################################
check_failed_pods() {
    log_subsection "Failed Pod Detection"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local failed_count
    # shellcheck disable=SC2086
    failed_count=$(kubectl get pods $ns_flag --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)

    if [[ $failed_count -eq 0 ]]; then
        record_result "failed-pods" "pass" "No failed pods"
    else
        record_result "failed-pods" "fail" "$failed_count pod(s) in Failed state"
    fi
}

#######################################
# Check container restarts
#######################################
check_container_restarts() {
    log_subsection "Container Restart Check"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local high_restart_pods=0

    # Get pods with restart counts
    local pods_with_restarts
    # shellcheck disable=SC2086
    pods_with_restarts=$(kubectl get pods $ns_flag -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null || true)

    echo "$pods_with_restarts" | while read -r ns name restarts; do
        if [[ -z "$name" ]]; then
            continue
        fi

        # Sum restarts (may be comma-separated for multiple containers)
        local total_restarts=0
        IFS=',' read -ra restart_arr <<< "$restarts"
        for r in "${restart_arr[@]}"; do
            if [[ "$r" =~ ^[0-9]+$ ]]; then
                total_restarts=$((total_restarts + r))
            fi
        done

        if [[ $total_restarts -gt $MAX_POD_RESTART_COUNT ]]; then
            log_debug "High restarts: $ns/$name ($total_restarts restarts)"
            ((high_restart_pods++)) || true
        fi
    done

    if [[ $high_restart_pods -eq 0 ]]; then
        record_result "container-restarts" "pass" "No pods with excessive restarts (> $MAX_POD_RESTART_COUNT)"
    else
        record_result "container-restarts" "fail" "$high_restart_pods pod(s) with restarts > $MAX_POD_RESTART_COUNT"
    fi
}

#######################################
# Check pods by namespace summary
#######################################
check_namespace_summary() {
    log_subsection "Namespace Summary"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Get pod count by namespace
    log_debug "Pod counts by namespace:"
    # shellcheck disable=SC2086
    kubectl get pods $ns_flag --no-headers 2>/dev/null | awk '{ns[$1]++} END {for (n in ns) print "  "n": "ns[n]" pods"}' | sort || true
}

#######################################
# Check pod resource usage
#######################################
check_pod_resources() {
    log_subsection "Pod Resource Usage"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Check if metrics are available
    # shellcheck disable=SC2086
    local top_output
    top_output=$(kubectl top pods $ns_flag --no-headers 2>/dev/null | head -5 || true)

    if [[ -n "$top_output" ]]; then
        log_debug "Top 5 resource-consuming pods:"
        echo "$top_output" | while read -r line; do
            log_debug "  $line"
        done
        record_result "pod-metrics" "pass" "Pod metrics available"
    else
        log_debug "Pod metrics not available (metrics-server may not be installed)"
    fi
}

#######################################
# Output results as JSON
#######################################
output_json() {
    local passed=0
    local failed=0

    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    if [[ -n "$NAMESPACE" ]]; then
        echo '  "namespace": "'"$NAMESPACE"'",'
    fi
    echo '  "checks": {'

    local first=true
    for check in "${!RESULTS[@]}"; do
        local result="${RESULTS[$check]}"
        local status="${result%%|*}"
        local message="${result#*|}"

        if [[ "$status" == "pass" ]]; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo -n '    "'"$check"'": {"status": "'"$status"'", "message": "'"$message"'"}'
    done

    echo ""
    echo "  },"
    echo '  "summary": {"passed": '$passed', "failed": '$failed', "total": '$((passed + failed))'}'
    echo "}"
}

#######################################
# Output summary
#######################################
output_summary() {
    local passed=0
    local failed=0

    for check in "${!RESULTS[@]}"; do
        local result="${RESULTS[$check]}"
        local status="${result%%|*}"
        if [[ "$status" == "pass" ]]; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi
    done

    log_section "Pod Health Summary"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All pod health validations passed!"
        return 0
    else
        echo ""
        log_failure "Some pod health validations failed"
        return 1
    fi
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

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_section "Pod Health Validation"
        log_kv "Namespace" "${NAMESPACE:-all}"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_running_pods
    check_crashloop_pods
    check_imagepull_errors
    check_pending_pods
    check_failed_pods
    check_container_restarts
    check_namespace_summary
    check_pod_resources

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
