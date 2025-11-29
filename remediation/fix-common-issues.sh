#!/usr/bin/env bash
# fix-common-issues.sh - Fix common Kubernetes cluster issues
# Automatically resolves common problems across the cluster
#
# Usage: ./fix-common-issues.sh [OPTIONS]
#
# Options:
#   --dry-run          Show what would be done without making changes
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Fix common Kubernetes cluster issues including:
  - Evicted pods cleanup
  - Stuck namespace termination
  - Failed pod cleanup
  - Node cordoning issues

Options:
  --dry-run     Show what would be done without making changes
  -f, --force   Skip confirmation prompts for dangerous operations
  -v, --verbose Enable verbose output
  -h, --help    Show this help message

Examples:
  $(basename "$0")           # Fix common issues
  $(basename "$0") --dry-run # Preview fixes

Note: Some fixes require cluster-admin privileges
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
            -f|--force)
                FORCE="true"
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
# Clean up evicted pods
#######################################
cleanup_evicted_pods() {
    log_subsection "Cleaning Up Evicted Pods"

    local evicted_pods
    evicted_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
        grep "Evicted" | awk '{print $1"/"$2}' || true)

    if [[ -z "$evicted_pods" ]]; then
        log_success "No evicted pods found"
        return 0
    fi

    local count
    count=$(echo "$evicted_pods" | wc -l)
    log_warn "Found $count evicted pod(s)"

    echo "$evicted_pods" | while read -r ns_pod; do
        if [[ -n "$ns_pod" ]]; then
            local ns="${ns_pod%/*}"
            local pod="${ns_pod#*/}"

            record_action "Delete evicted pod: $pod in $ns"

            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete pod -n "$ns" "$pod" --force --grace-period=0 2>/dev/null || {
                    log_warn "Failed to delete evicted pod: $pod"
                }
            fi
        fi
    done
}

#######################################
# Clean up failed pods
#######################################
cleanup_failed_pods() {
    log_subsection "Cleaning Up Failed Pods"

    local failed_pods
    failed_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
        grep -v "Evicted" | awk '{print $1"/"$2}' || true)

    if [[ -z "$failed_pods" ]]; then
        log_success "No failed pods found"
        return 0
    fi

    local count
    count=$(echo "$failed_pods" | wc -l)
    log_warn "Found $count failed pod(s)"

    echo "$failed_pods" | while read -r ns_pod; do
        if [[ -n "$ns_pod" ]]; then
            local ns="${ns_pod%/*}"
            local pod="${ns_pod#*/}"

            record_action "Delete failed pod: $pod in $ns"

            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete pod -n "$ns" "$pod" 2>/dev/null || {
                    log_warn "Failed to delete failed pod: $pod"
                }
            fi
        fi
    done
}

#######################################
# Fix stuck terminating namespaces
#######################################
fix_terminating_namespaces() {
    log_subsection "Checking for Stuck Terminating Namespaces"

    local terminating_ns
    terminating_ns=$(kubectl get namespaces --no-headers 2>/dev/null | \
        awk '$2 == "Terminating" {print $1}' || true)

    if [[ -z "$terminating_ns" ]]; then
        log_success "No stuck terminating namespaces found"
        return 0
    fi

    log_warn "Found terminating namespaces"

    echo "$terminating_ns" | while read -r ns; do
        if [[ -n "$ns" ]]; then
            log_warn "Namespace stuck in Terminating: $ns"
            record_action "Attempt to fix terminating namespace: $ns"

            if [[ "$DRY_RUN" != "true" ]]; then
                log_warn "WARNING: Removing namespace finalizers can cause data loss!"
                log_warn "This operation forcefully removes the namespace."

                if [[ "$FORCE" != "true" ]]; then
                    if ! confirm "Force remove finalizers from namespace $ns?"; then
                        log_info "Skipping namespace: $ns"
                        continue
                    fi
                fi

                # Try to remove finalizers
                kubectl get namespace "$ns" -o json 2>/dev/null | \
                    jq '.spec.finalizers = []' | \
                    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || {
                    log_warn "Could not automatically fix namespace: $ns"
                    log_info "Manual intervention may be required"
                }
            fi
        fi
    done
}

#######################################
# Uncordon nodes that should be schedulable
#######################################
fix_cordoned_nodes() {
    log_subsection "Checking for Cordoned Nodes"

    local cordoned_nodes
    cordoned_nodes=$(kubectl get nodes --no-headers 2>/dev/null | \
        grep "SchedulingDisabled" | awk '{print $1}' || true)

    if [[ -z "$cordoned_nodes" ]]; then
        log_success "No cordoned nodes found"
        return 0
    fi

    log_warn "Found cordoned nodes"

    echo "$cordoned_nodes" | while read -r node; do
        if [[ -n "$node" ]]; then
            log_warn "Node cordoned: $node"
            record_action "Review cordoned node: $node (manual uncordon required)"
        fi
    done
}

#######################################
# Clean up old replica sets
#######################################
cleanup_old_replicasets() {
    log_subsection "Cleaning Up Old ReplicaSets"

    # Find replica sets with 0 desired replicas
    local old_rs
    old_rs=$(kubectl get rs --all-namespaces --no-headers 2>/dev/null | \
        awk '$3 == 0 && $4 == 0 && $5 == 0 {print $1"/"$2}' || true)

    if [[ -z "$old_rs" ]]; then
        log_success "No old replica sets to clean"
        return 0
    fi

    local count
    count=$(echo "$old_rs" | wc -l)
    log_info "Found $count old replica set(s) with 0 replicas"

    # Only log for now, as these are usually handled by deployment revision history
    log_debug "Old replica sets are typically managed by deployment revisionHistoryLimit"
}

#######################################
# Clean up orphaned endpoints
#######################################
cleanup_orphaned_endpoints() {
    log_subsection "Checking for Orphaned Endpoints"

    local endpoints_no_svc
    endpoints_no_svc=$(kubectl get endpoints --all-namespaces --no-headers 2>/dev/null | \
        while read -r ns ep rest; do
            if ! kubectl get svc -n "$ns" "$ep" >/dev/null 2>&1; then
                echo "$ns/$ep"
            fi
        done || true)

    if [[ -z "$endpoints_no_svc" ]]; then
        log_success "No orphaned endpoints found"
        return 0
    fi

    log_warn "Found orphaned endpoints"

    echo "$endpoints_no_svc" | while read -r ns_ep; do
        if [[ -n "$ns_ep" ]]; then
            log_warn "Orphaned endpoint: $ns_ep"
        fi
    done
}

#######################################
# Clear stuck PVC
#######################################
check_stuck_pvcs() {
    log_subsection "Checking for Stuck PVCs"

    local pending_pvcs
    pending_pvcs=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | \
        awk '$3 == "Pending" {print $1"/"$2}' || true)

    if [[ -z "$pending_pvcs" ]]; then
        log_success "No stuck PVCs found"
        return 0
    fi

    log_warn "Found pending PVCs"

    echo "$pending_pvcs" | while read -r ns_pvc; do
        if [[ -n "$ns_pvc" ]]; then
            local ns="${ns_pvc%/*}"
            local pvc="${ns_pvc#*/}"

            # Get the reason for pending
            local events
            events=$(kubectl get events -n "$ns" --field-selector "involvedObject.name=$pvc" --no-headers 2>/dev/null | tail -1 || true)

            log_warn "PVC $pvc in $ns is Pending"
            if [[ -n "$events" ]]; then
                log_debug "Last event: $events"
            fi

            record_action "Review pending PVC: $pvc in $ns"
        fi
    done
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
        log_success "No remediation actions needed"
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

    log_section "Common Issues Fix"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! confirm "This will make changes to your cluster. Continue?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    # Run fixes
    cleanup_evicted_pods
    cleanup_failed_pods
    fix_terminating_namespaces
    fix_cordoned_nodes
    cleanup_old_replicasets
    cleanup_orphaned_endpoints
    check_stuck_pvcs

    # Summary
    generate_summary
}

main "$@"
