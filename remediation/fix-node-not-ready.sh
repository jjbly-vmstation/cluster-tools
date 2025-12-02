#!/usr/bin/env bash
# Script: fix-node-not-ready.sh
# Purpose: Diagnose and fix nodes in NotReady state
# Usage: ./fix-node-not-ready.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   --dry-run      Show what would be done without making changes

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
DRY_RUN="${DRY_RUN:-false}"
NODE_NAME="${NODE_NAME:-}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [node-name]

Diagnose and fix nodes in NotReady state including:
  - Analyze node conditions
  - Check kubelet status
  - Identify common issues
  - Suggest remediation steps

Arguments:
  node-name    Specific node to fix (optional, default: all NotReady nodes)

Options:
  --dry-run     Show what would be done without making changes
  -v, --verbose Enable verbose output
  -h, --help    Show this help message

Examples:
  $(basename "$0")                    # Fix all NotReady nodes
  $(basename "$0") worker-1           # Fix specific node
  $(basename "$0") --dry-run          # Preview actions

Note: Some fixes may require SSH access to nodes.
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="true"
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
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
            *)
                if [[ -z "$NODE_NAME" ]]; then
                    NODE_NAME="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 2
                fi
                shift
                ;;
        esac
    done
}

#######################################
# Record action taken
#######################################
record_action() {
    local action="$1"
    ACTIONS_TAKEN+=("$action")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would: $action"
    else
        log_info "Action: $action"
    fi
}

#######################################
# Get NotReady nodes
#######################################
get_not_ready_nodes() {
    if [[ -n "$NODE_NAME" ]]; then
        # Check if specified node is NotReady
        local status
        status=$(kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | awk '{print $2}')

        if [[ "$status" != "Ready" ]]; then
            echo "$NODE_NAME"
        fi
    else
        # Get all NotReady nodes
        kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | awk '{print $1}'
    fi
}

#######################################
# Diagnose node issues
#######################################
diagnose_node() {
    local node="$1"

    log_subsection "Diagnosing Node: $node"

    # Get node conditions
    log_debug "Node conditions:"
    local conditions
    conditions=$(kubectl get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}' 2>/dev/null)
    echo "$conditions" | while read -r line; do
        log_debug "  $line"
    done

    # Check for common issues
    local issues=()

    # Check Ready condition
    local ready_status
    ready_status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

    local ready_reason
    ready_reason=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)

    local ready_message
    ready_message=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)

    log_warn "Ready condition: $ready_status"
    log_warn "Reason: $ready_reason"
    log_warn "Message: $ready_message"

    # Check DiskPressure
    local disk_pressure
    disk_pressure=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null)

    if [[ "$disk_pressure" == "True" ]]; then
        issues+=("DiskPressure: Node has low disk space")
    fi

    # Check MemoryPressure
    local memory_pressure
    memory_pressure=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null)

    if [[ "$memory_pressure" == "True" ]]; then
        issues+=("MemoryPressure: Node has low memory")
    fi

    # Check PIDPressure
    local pid_pressure
    pid_pressure=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="PIDPressure")].status}' 2>/dev/null)

    if [[ "$pid_pressure" == "True" ]]; then
        issues+=("PIDPressure: Node has too many processes")
    fi

    # Check NetworkUnavailable
    local network_unavailable
    network_unavailable=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="NetworkUnavailable")].status}' 2>/dev/null)

    if [[ "$network_unavailable" == "True" ]]; then
        issues+=("NetworkUnavailable: Node network is not configured")
    fi

    # Check node taints
    local unschedulable
    unschedulable=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)

    if [[ "$unschedulable" == "true" ]]; then
        issues+=("Cordoned: Node is marked unschedulable")
    fi

    # Report issues
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_warn "Issues detected:"
        for issue in "${issues[@]}"; do
            log_warn "  - $issue"
        done
    fi

    # Return issues for remediation
    echo "${issues[*]:-}"
}

#######################################
# Fix DiskPressure
#######################################
fix_disk_pressure() {
    local node="$1"

    record_action "Node $node: Clean up old resources to free disk space"

    log_info "Recommendations for disk pressure:"
    log_info "  1. SSH to node and run: docker system prune -a"
    log_info "  2. Clean up unused images: crictl rmi --prune"
    log_info "  3. Check /var/log for large log files"
    log_info "  4. Check PersistentVolumes for full volumes"
}

#######################################
# Fix MemoryPressure
#######################################
fix_memory_pressure() {
    local node="$1"

    record_action "Node $node: Evict non-essential pods to free memory"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Get pods on the node sorted by memory usage
        log_info "Top memory-consuming pods on $node:"
        kubectl get pods --all-namespaces --field-selector="spec.nodeName=$node" -o json 2>/dev/null | \
            jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' 2>/dev/null | head -5 || true
    fi

    log_info "Recommendations for memory pressure:"
    log_info "  1. Review resource limits for pods on this node"
    log_info "  2. Consider adding more nodes to the cluster"
    log_info "  3. Evict non-critical pods if necessary"
}

#######################################
# Fix NetworkUnavailable
#######################################
fix_network_unavailable() {
    local node="$1"

    record_action "Node $node: Check CNI plugin status"

    log_info "Recommendations for network issues:"
    log_info "  1. Check CNI pods: kubectl get pods -n kube-system -l k8s-app=calico-node"
    log_info "  2. Check flannel: kubectl get pods -n kube-system -l app=flannel"
    log_info "  3. SSH to node and check: systemctl status kubelet"
    log_info "  4. Check node network interfaces and routes"
}

#######################################
# Uncordon node
#######################################
uncordon_node() {
    local node="$1"

    # Check if node is cordoned
    local unschedulable
    unschedulable=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)

    if [[ "$unschedulable" == "true" ]]; then
        record_action "Uncordon node: $node"

        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl uncordon "$node" 2>/dev/null || {
                log_warn "Failed to uncordon node: $node"
            }
        fi
    fi
}

#######################################
# Apply fixes for node
#######################################
apply_fixes() {
    local node="$1"
    local issues_str="$2"

    log_subsection "Applying Fixes for: $node"

    if [[ -z "$issues_str" ]]; then
        log_info "No specific issues detected, checking general remediation"

        # Try uncordoning if the node is cordoned
        uncordon_node "$node"

        log_info "General recommendations:"
        log_info "  1. SSH to node and check kubelet: systemctl status kubelet"
        log_info "  2. Check kubelet logs: journalctl -u kubelet -n 100"
        log_info "  3. Check container runtime: systemctl status containerd (or docker)"
        log_info "  4. Verify network connectivity to API server"

        return 0
    fi

    # Apply specific fixes based on issues
    if [[ "$issues_str" == *"DiskPressure"* ]]; then
        fix_disk_pressure "$node"
    fi

    if [[ "$issues_str" == *"MemoryPressure"* ]]; then
        fix_memory_pressure "$node"
    fi

    if [[ "$issues_str" == *"NetworkUnavailable"* ]]; then
        fix_network_unavailable "$node"
    fi

    if [[ "$issues_str" == *"Cordoned"* ]]; then
        uncordon_node "$node"
    fi
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Fix Summary"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE - No changes were made"
    fi

    log_kv "Actions" "${#ACTIONS_TAKEN[@]}"

    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        echo ""
        echo "Actions taken:"
        for action in "${ACTIONS_TAKEN[@]}"; do
            echo "  - $action"
        done
    else
        log_success "No automated fixes applied"
    fi

    echo ""
    log_info "Note: Some issues require manual intervention (SSH access, resource cleanup, etc.)"
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

    log_section "Node NotReady Fix"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"

    # Get NotReady nodes
    local not_ready_nodes
    not_ready_nodes=$(get_not_ready_nodes)

    if [[ -z "$not_ready_nodes" ]]; then
        log_success "All nodes are Ready"
        exit 0
    fi

    log_warn "NotReady nodes found:"
    echo "$not_ready_nodes" | while read -r node; do
        log_warn "  - $node"
    done

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! confirm "Proceed with diagnosis and fixes?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    # Diagnose and fix each node
    echo "$not_ready_nodes" | while read -r node; do
        if [[ -n "$node" ]]; then
            local issues
            issues=$(diagnose_node "$node")
            apply_fixes "$node" "$issues"
        fi
    done

    # Summary
    generate_summary
}

main "$@"
