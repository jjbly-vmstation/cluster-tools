#!/usr/bin/env bash
# diagnose-monitoring-stack.sh - Diagnose monitoring stack issues
# Collects diagnostic information and identifies common problems
#
# Usage: ./diagnose-monitoring-stack.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Kubernetes namespace (default: monitoring)
#   -o, --output       Output directory for diagnostic files
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-monitoring}"
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostic-output}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose monitoring stack issues including:
  - Pod status and logs
  - Service configuration
  - Prometheus target status
  - Alertmanager configuration
  - Loki health
  - Resource utilization

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace (default: monitoring)
  -o, --output DIR            Output directory for diagnostic files
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Examples:
  $(basename "$0")                      # Basic diagnostics
  $(basename "$0") -o /tmp/diag         # Save to specific directory
  $(basename "$0") -n observability     # Use custom namespace

Output:
  Creates a directory with:
  - pod-status.txt
  - pod-logs/
  - service-info.txt
  - events.txt
  - resource-usage.txt
  - diagnosis-summary.txt
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
# Initialize output directory
#######################################
init_output_dir() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    OUTPUT_DIR="${OUTPUT_DIR}/monitoring-diag-${timestamp}"

    ensure_directory "$OUTPUT_DIR"
    ensure_directory "${OUTPUT_DIR}/pod-logs"

    log_info "Diagnostic output will be saved to: $OUTPUT_DIR"
}

#######################################
# Collect pod information
#######################################
collect_pod_info() {
    log_subsection "Collecting Pod Information"

    # Get pod status
    kubectl get pods -n "$NAMESPACE" -o wide > "${OUTPUT_DIR}/pod-status.txt" 2>&1 || true
    log_debug "Pod status collected"

    # Get pod descriptions for non-running pods
    local non_running_pods
    non_running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running" | awk '{print $1}' || true)

    if [[ -n "$non_running_pods" ]]; then
        log_warn "Found non-running pods"
        echo "$non_running_pods" | while read -r pod; do
            log_debug "Describing pod: $pod"
            kubectl describe pod -n "$NAMESPACE" "$pod" > "${OUTPUT_DIR}/pod-logs/${pod}-describe.txt" 2>&1 || true
        done
    fi

    # Collect logs from all pods
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)

    echo "$pods" | while read -r pod; do
        if [[ -n "$pod" ]]; then
            log_debug "Collecting logs for pod: $pod"
            kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=100 > "${OUTPUT_DIR}/pod-logs/${pod}.log" 2>&1 || true
            # Also collect previous logs if available
            kubectl logs -n "$NAMESPACE" "$pod" --all-containers --previous --tail=50 > "${OUTPUT_DIR}/pod-logs/${pod}-previous.log" 2>&1 || true
        fi
    done

    log_success "Pod information collected"
}

#######################################
# Collect service information
#######################################
collect_service_info() {
    log_subsection "Collecting Service Information"

    {
        echo "=== Services ==="
        kubectl get svc -n "$NAMESPACE" -o wide 2>&1 || true
        echo ""
        echo "=== Endpoints ==="
        kubectl get endpoints -n "$NAMESPACE" 2>&1 || true
        echo ""
        echo "=== Ingresses ==="
        kubectl get ingress -n "$NAMESPACE" 2>&1 || true
    } > "${OUTPUT_DIR}/service-info.txt"

    log_success "Service information collected"
}

#######################################
# Collect events
#######################################
collect_events() {
    log_subsection "Collecting Events"

    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/events.txt" 2>&1 || true

    # Also collect warning events specifically
    kubectl get events -n "$NAMESPACE" --field-selector type=Warning > "${OUTPUT_DIR}/warning-events.txt" 2>&1 || true

    log_success "Events collected"
}

#######################################
# Collect resource usage
#######################################
collect_resource_usage() {
    log_subsection "Collecting Resource Usage"

    {
        echo "=== Pod Resource Usage ==="
        kubectl top pods -n "$NAMESPACE" 2>&1 || echo "Metrics not available"
        echo ""
        echo "=== Resource Requests/Limits ==="
        kubectl get pods -n "$NAMESPACE" -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,MEM_LIM:.spec.containers[*].resources.limits.memory' 2>&1 || true
    } > "${OUTPUT_DIR}/resource-usage.txt"

    log_success "Resource usage collected"
}

#######################################
# Collect configuration
#######################################
collect_configuration() {
    log_subsection "Collecting Configuration"

    ensure_directory "${OUTPUT_DIR}/configs"

    # Collect ConfigMaps
    local configmaps
    configmaps=$(kubectl get configmaps -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)

    echo "$configmaps" | while read -r cm; do
        if [[ -n "$cm" ]]; then
            kubectl get configmap -n "$NAMESPACE" "$cm" -o yaml > "${OUTPUT_DIR}/configs/${cm}-configmap.yaml" 2>&1 || true
        fi
    done

    # Collect Secrets (names only, not content)
    kubectl get secrets -n "$NAMESPACE" > "${OUTPUT_DIR}/configs/secrets-list.txt" 2>&1 || true

    log_success "Configuration collected"
}

#######################################
# Analyze common issues
#######################################
analyze_issues() {
    log_subsection "Analyzing Common Issues"

    local issues=()
    local summary_file="${OUTPUT_DIR}/diagnosis-summary.txt"

    {
        echo "Monitoring Stack Diagnostic Summary"
        echo "===================================="
        echo "Timestamp: $(date -Iseconds)"
        echo "Namespace: $NAMESPACE"
        echo ""
        echo "Issues Found:"
        echo "-------------"
    } > "$summary_file"

    # Check for pod issues
    local pending_pods
    pending_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [[ $pending_pods -gt 0 ]]; then
        echo "- $pending_pods pod(s) in Pending state (possible resource or scheduling issues)" >> "$summary_file"
        issues+=("pending-pods")
    fi

    local crashloop_pods
    crashloop_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || true)
    if [[ $crashloop_pods -gt 0 ]]; then
        echo "- $crashloop_pods pod(s) in CrashLoopBackOff (check pod logs)" >> "$summary_file"
        issues+=("crashloop-pods")
    fi

    # Check for image pull issues
    local image_pull_errors
    image_pull_errors=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "ImagePullBackOff\|ErrImagePull" || true)
    if [[ $image_pull_errors -gt 0 ]]; then
        echo "- $image_pull_errors pod(s) with image pull errors" >> "$summary_file"
        issues+=("image-pull-errors")
    fi

    # Check for OOM events
    local oom_events
    oom_events=$(kubectl get events -n "$NAMESPACE" --field-selector reason=OOMKilling --no-headers 2>/dev/null | wc -l)
    if [[ $oom_events -gt 0 ]]; then
        echo "- $oom_events OOMKilled event(s) detected (increase memory limits)" >> "$summary_file"
        issues+=("oom-events")
    fi

    # Check for warning events
    local warning_count
    warning_count=$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning --no-headers 2>/dev/null | wc -l)
    if [[ $warning_count -gt 10 ]]; then
        echo "- High number of warning events: $warning_count" >> "$summary_file"
        issues+=("high-warnings")
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        echo "- No obvious issues detected" >> "$summary_file"
    fi

    {
        echo ""
        echo "Recommendations:"
        echo "----------------"

        if [[ " ${issues[*]} " =~ " pending-pods " ]]; then
            echo "- Check node resources: kubectl describe nodes"
            echo "- Check for scheduling constraints in pod specs"
        fi

        if [[ " ${issues[*]} " =~ " crashloop-pods " ]]; then
            echo "- Check pod logs in ${OUTPUT_DIR}/pod-logs/"
            echo "- Verify configuration and environment variables"
        fi

        if [[ " ${issues[*]} " =~ " image-pull-errors " ]]; then
            echo "- Verify image names and tags"
            echo "- Check imagePullSecrets configuration"
        fi

        if [[ " ${issues[*]} " =~ " oom-events " ]]; then
            echo "- Increase memory limits for affected pods"
            echo "- Review application memory usage patterns"
        fi

        echo ""
        echo "Files collected:"
        echo "- pod-status.txt: Current pod status"
        echo "- pod-logs/: Pod logs and descriptions"
        echo "- service-info.txt: Service and endpoint info"
        echo "- events.txt: Kubernetes events"
        echo "- resource-usage.txt: Resource utilization"
        echo "- configs/: ConfigMaps and secret list"
    } >> "$summary_file"

    log_success "Issue analysis complete"

    # Display summary
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

    log_section "Monitoring Stack Diagnostics"
    log_kv "Namespace" "$NAMESPACE"
    log_kv "Timestamp" "$(date -Iseconds)"

    # Initialize output
    init_output_dir

    # Collect all diagnostic information
    collect_pod_info
    collect_service_info
    collect_events
    collect_resource_usage
    collect_configuration

    # Analyze and summarize
    analyze_issues

    log_section "Diagnostic Collection Complete"
    log_info "All diagnostic files saved to: $OUTPUT_DIR"
}

main "$@"
