#!/usr/bin/env bash
# diagnose-cluster-issues.sh - Diagnose general cluster issues
# Collects comprehensive cluster diagnostics
#
# Usage: ./diagnose-cluster-issues.sh [OPTIONS]
#
# Options:
#   -o, --output       Output directory for diagnostic files
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostic-output}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose general Kubernetes cluster issues including:
  - Node health and status
  - Pod status across all namespaces
  - System component health
  - Resource utilization
  - Recent events
  - Network configuration

Options:
  -o, --output DIR   Output directory for diagnostic files
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message

Examples:
  $(basename "$0")                  # Basic diagnostics
  $(basename "$0") -o /tmp/diag     # Save to specific directory

Output:
  Creates a comprehensive diagnostic bundle
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    OUTPUT_DIR="${OUTPUT_DIR}/cluster-diag-${timestamp}"

    ensure_directory "$OUTPUT_DIR"
    ensure_directory "${OUTPUT_DIR}/nodes"
    ensure_directory "${OUTPUT_DIR}/namespaces"
    ensure_directory "${OUTPUT_DIR}/system"

    log_info "Diagnostic output will be saved to: $OUTPUT_DIR"
}

#######################################
# Collect cluster information
#######################################
collect_cluster_info() {
    log_subsection "Collecting Cluster Information"

    {
        echo "=== Cluster Info ==="
        kubectl cluster-info 2>&1 || true
        echo ""
        echo "=== Kubernetes Version ==="
        kubectl version 2>&1 || true
        echo ""
        echo "=== Current Context ==="
        kubectl config current-context 2>&1 || true
    } > "${OUTPUT_DIR}/cluster-info.txt"

    log_success "Cluster information collected"
}

#######################################
# Collect node information
#######################################
collect_node_info() {
    log_subsection "Collecting Node Information"

    # Get node list
    kubectl get nodes -o wide > "${OUTPUT_DIR}/nodes/node-list.txt" 2>&1 || true

    # Get node details
    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' || true)

    echo "$nodes" | while read -r node; do
        if [[ -n "$node" ]]; then
            log_debug "Collecting info for node: $node"
            kubectl describe node "$node" > "${OUTPUT_DIR}/nodes/${node}-describe.txt" 2>&1 || true
        fi
    done

    # Get node resource usage
    kubectl top nodes > "${OUTPUT_DIR}/nodes/node-resources.txt" 2>&1 || echo "Metrics not available" > "${OUTPUT_DIR}/nodes/node-resources.txt"

    log_success "Node information collected"
}

#######################################
# Collect namespace information
#######################################
collect_namespace_info() {
    log_subsection "Collecting Namespace Information"

    # Get all namespaces
    kubectl get namespaces > "${OUTPUT_DIR}/namespaces/namespace-list.txt" 2>&1 || true

    # Get pods in all namespaces
    kubectl get pods --all-namespaces -o wide > "${OUTPUT_DIR}/namespaces/all-pods.txt" 2>&1 || true

    # Get deployments in all namespaces
    kubectl get deployments --all-namespaces > "${OUTPUT_DIR}/namespaces/all-deployments.txt" 2>&1 || true

    # Get services in all namespaces
    kubectl get services --all-namespaces > "${OUTPUT_DIR}/namespaces/all-services.txt" 2>&1 || true

    # Get non-running pods
    kubectl get pods --all-namespaces --field-selector='status.phase!=Running,status.phase!=Succeeded' > "${OUTPUT_DIR}/namespaces/non-running-pods.txt" 2>&1 || true

    log_success "Namespace information collected"
}

#######################################
# Collect system component information
#######################################
collect_system_info() {
    log_subsection "Collecting System Component Information"

    # Get kube-system pods
    kubectl get pods -n kube-system -o wide > "${OUTPUT_DIR}/system/kube-system-pods.txt" 2>&1 || true

    # Get component statuses (deprecated but still useful)
    kubectl get componentstatuses > "${OUTPUT_DIR}/system/component-status.txt" 2>&1 || echo "Component status not available" > "${OUTPUT_DIR}/system/component-status.txt"

    # Get API server health
    {
        echo "=== API Server Health ==="
        kubectl get --raw='/healthz' 2>&1 || true
        echo ""
        echo "=== Readiness ==="
        kubectl get --raw='/readyz' 2>&1 || true
    } > "${OUTPUT_DIR}/system/api-health.txt"

    log_success "System information collected"
}

#######################################
# Collect events
#######################################
collect_events() {
    log_subsection "Collecting Events"

    # Get all events
    kubectl get events --all-namespaces --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/all-events.txt" 2>&1 || true

    # Get warning events
    kubectl get events --all-namespaces --field-selector type=Warning > "${OUTPUT_DIR}/warning-events.txt" 2>&1 || true

    log_success "Events collected"
}

#######################################
# Collect resource quotas and limits
#######################################
collect_resource_info() {
    log_subsection "Collecting Resource Information"

    {
        echo "=== Resource Quotas ==="
        kubectl get resourcequotas --all-namespaces 2>&1 || true
        echo ""
        echo "=== Limit Ranges ==="
        kubectl get limitranges --all-namespaces 2>&1 || true
        echo ""
        echo "=== PersistentVolumes ==="
        kubectl get pv 2>&1 || true
        echo ""
        echo "=== PersistentVolumeClaims ==="
        kubectl get pvc --all-namespaces 2>&1 || true
    } > "${OUTPUT_DIR}/resource-info.txt"

    log_success "Resource information collected"
}

#######################################
# Collect network information
#######################################
collect_network_info() {
    log_subsection "Collecting Network Information"

    {
        echo "=== Network Policies ==="
        kubectl get networkpolicies --all-namespaces 2>&1 || true
        echo ""
        echo "=== Ingresses ==="
        kubectl get ingress --all-namespaces 2>&1 || true
        echo ""
        echo "=== Endpoints ==="
        kubectl get endpoints --all-namespaces 2>&1 || true
    } > "${OUTPUT_DIR}/network-info.txt"

    log_success "Network information collected"
}

#######################################
# Analyze and generate summary
#######################################
generate_summary() {
    log_subsection "Generating Summary"

    local summary_file="${OUTPUT_DIR}/diagnosis-summary.txt"

    {
        echo "Cluster Diagnostic Summary"
        echo "=========================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""

        echo "Cluster Overview:"
        echo "-----------------"
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        echo "- Total nodes: $node_count"

        local ready_nodes
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
        echo "- Ready nodes: $ready_nodes"

        local namespace_count
        namespace_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)
        echo "- Namespaces: $namespace_count"

        local pod_count
        pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
        echo "- Total pods: $pod_count"

        echo ""
        echo "Issues Detected:"
        echo "----------------"

        # Check for not ready nodes
        local not_ready
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready" || true)
        if [[ $not_ready -gt 0 ]]; then
            echo "- WARNING: $not_ready node(s) not in Ready state"
        fi

        # Check for pod issues
        local failed_pods
        failed_pods=$(kubectl get pods --all-namespaces --field-selector='status.phase=Failed' --no-headers 2>/dev/null | wc -l)
        if [[ $failed_pods -gt 0 ]]; then
            echo "- WARNING: $failed_pods failed pod(s)"
        fi

        local pending_pods
        pending_pods=$(kubectl get pods --all-namespaces --field-selector='status.phase=Pending' --no-headers 2>/dev/null | wc -l)
        if [[ $pending_pods -gt 0 ]]; then
            echo "- INFO: $pending_pods pending pod(s)"
        fi

        # Check for warning events
        local warning_events
        warning_events=$(kubectl get events --all-namespaces --field-selector type=Warning --no-headers 2>/dev/null | wc -l)
        if [[ $warning_events -gt 20 ]]; then
            echo "- INFO: High number of warning events: $warning_events"
        fi

        echo ""
        echo "Files Collected:"
        echo "----------------"
        echo "- cluster-info.txt: Cluster version and context"
        echo "- nodes/: Node status and descriptions"
        echo "- namespaces/: Pod and service information"
        echo "- system/: System component status"
        echo "- all-events.txt: All Kubernetes events"
        echo "- resource-info.txt: Resource quotas and storage"
        echo "- network-info.txt: Network policies and ingresses"
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

    log_section "Cluster Diagnostics"
    log_kv "Timestamp" "$(date -Iseconds)"

    # Initialize output
    init_output_dir

    # Collect all diagnostic information
    collect_cluster_info
    collect_node_info
    collect_namespace_info
    collect_system_info
    collect_events
    collect_resource_info
    collect_network_info

    # Generate summary
    generate_summary

    log_section "Diagnostic Collection Complete"
    log_info "All diagnostic files saved to: $OUTPUT_DIR"
}

main "$@"
