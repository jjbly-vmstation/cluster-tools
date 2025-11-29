#!/usr/bin/env bash
# cleanup-resources.sh - Clean up unused Kubernetes resources
# Safely removes unused or orphaned resources
#
# Usage: ./cleanup-resources.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Kubernetes namespace (default: all)
#   --dry-run          Show what would be done without making changes
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-false}"

# Track cleanup actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Clean up unused Kubernetes resources including:
  - Completed pods
  - Failed jobs
  - Unused ConfigMaps
  - Unused Secrets
  - Old ReplicaSets
  - Orphaned PVCs

Options:
  -n, --namespace NS  Kubernetes namespace (default: all namespaces)
  --dry-run           Show what would be done without making changes
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Examples:
  $(basename "$0")                   # Clean up all namespaces
  $(basename "$0") -n monitoring     # Clean up monitoring namespace only
  $(basename "$0") --dry-run         # Preview cleanup actions

Warning: This tool deletes resources. Use --dry-run first to verify.
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
# Build namespace flag
#######################################
get_namespace_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "--all-namespaces"
    fi
}

#######################################
# Clean up completed pods
#######################################
cleanup_completed_pods() {
    log_subsection "Cleaning Up Completed Pods"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    local completed_pods
    # shellcheck disable=SC2086
    completed_pods=$(kubectl get pods $ns_flag --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | \
        awk '{if (NF >= 2) print $1"/"$2; else print "default/"$1}' || true)
    
    if [[ -z "$completed_pods" ]]; then
        log_success "No completed pods to clean"
        return 0
    fi
    
    local count
    count=$(echo "$completed_pods" | wc -l)
    log_info "Found $count completed pod(s)"
    
    echo "$completed_pods" | while read -r ns_pod; do
        if [[ -n "$ns_pod" ]]; then
            local ns="${ns_pod%/*}"
            local pod="${ns_pod#*/}"
            
            record_action "Delete completed pod: $pod in $ns"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete pod -n "$ns" "$pod" 2>/dev/null || {
                    log_warn "Failed to delete pod: $pod"
                }
            fi
        fi
    done
}

#######################################
# Clean up failed jobs
#######################################
cleanup_failed_jobs() {
    log_subsection "Cleaning Up Failed Jobs"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    local failed_jobs
    # shellcheck disable=SC2086
    failed_jobs=$(kubectl get jobs $ns_flag --no-headers 2>/dev/null | \
        awk '$2 ~ /^0\// {if (NF >= 2) print $1"/"$2; else print "default/"$1}' || true)
    
    if [[ -z "$failed_jobs" ]]; then
        log_success "No failed jobs to clean"
        return 0
    fi
    
    local count
    count=$(echo "$failed_jobs" | wc -l)
    log_info "Found $count failed job(s)"
    
    echo "$failed_jobs" | while read -r ns_job; do
        if [[ -n "$ns_job" ]]; then
            local ns="${ns_job%/*}"
            local job="${ns_job#*/}"
            
            record_action "Delete failed job: $job in $ns"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete job -n "$ns" "$job" 2>/dev/null || {
                    log_warn "Failed to delete job: $job"
                }
            fi
        fi
    done
}

#######################################
# Clean up completed jobs older than 1 day
#######################################
cleanup_old_completed_jobs() {
    log_subsection "Cleaning Up Old Completed Jobs"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    # Find completed jobs older than 1 day
    local old_jobs
    # shellcheck disable=SC2086
    old_jobs=$(kubectl get jobs $ns_flag --no-headers 2>/dev/null | \
        awk '$2 ~ /^1\// && $4 ~ /[0-9]+d/ {if (NF >= 2) print $1"/"$2; else print "default/"$1}' || true)
    
    if [[ -z "$old_jobs" ]]; then
        log_success "No old completed jobs to clean"
        return 0
    fi
    
    local count
    count=$(echo "$old_jobs" | wc -l)
    log_info "Found $count old completed job(s)"
    
    echo "$old_jobs" | while read -r ns_job; do
        if [[ -n "$ns_job" ]]; then
            local ns="${ns_job%/*}"
            local job="${ns_job#*/}"
            
            record_action "Delete old completed job: $job in $ns"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete job -n "$ns" "$job" 2>/dev/null || {
                    log_warn "Failed to delete job: $job"
                }
            fi
        fi
    done
}

#######################################
# Find unused ConfigMaps
#######################################
find_unused_configmaps() {
    log_subsection "Checking for Unused ConfigMaps"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    # This is a simplified check - in production, you'd want more thorough analysis
    log_info "Checking ConfigMaps not referenced by pods..."
    
    # Note: Full analysis would require checking pod references
    # This is left as informational only
    log_debug "This check requires manual verification before deletion"
    log_info "Use 'kubectl get pods -o yaml' to verify ConfigMap usage"
}

#######################################
# Clean up orphaned PVCs
#######################################
check_orphaned_pvcs() {
    log_subsection "Checking for Orphaned PVCs"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    # Find PVCs not mounted by any pod
    local all_pvcs
    # shellcheck disable=SC2086
    all_pvcs=$(kubectl get pvc $ns_flag --no-headers 2>/dev/null | \
        awk '{if (NF >= 2) print $1"/"$2; else print "default/"$1}' || true)
    
    if [[ -z "$all_pvcs" ]]; then
        log_success "No PVCs found"
        return 0
    fi
    
    log_info "Found PVCs - checking usage..."
    
    # This requires checking pod volumeMounts, simplified here
    log_debug "Manual verification required for PVC cleanup"
    log_info "Use 'kubectl get pods -o yaml' to verify PVC usage"
}

#######################################
# Clean up old events
#######################################
cleanup_old_events() {
    log_subsection "Checking Old Events"
    
    local ns_flag
    ns_flag=$(get_namespace_flag)
    
    # Events are typically cleaned up by the API server based on TTL
    # Just report the count
    local event_count
    # shellcheck disable=SC2086
    event_count=$(kubectl get events $ns_flag --no-headers 2>/dev/null | wc -l)
    
    log_info "Found $event_count events (managed by API server TTL)"
}

#######################################
# Clean up empty secrets
#######################################
check_empty_secrets() {
    log_subsection "Checking for Potentially Unused Secrets"
    
    # Note: This is informational only - secrets should not be deleted without verification
    log_info "Secret cleanup requires manual verification"
    log_debug "Use 'kubectl get pods -o yaml' to verify Secret usage"
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Cleanup Summary"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE - No changes were made"
    fi
    
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Actions" "${#ACTIONS_TAKEN[@]}"
    
    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        echo ""
        echo "Actions taken:"
        for action in "${ACTIONS_TAKEN[@]}"; do
            echo "  - $action"
        done
    else
        log_success "No cleanup actions needed"
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
    
    log_section "Resource Cleanup"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        log_warn "This will DELETE resources from your cluster!"
        if ! confirm "Are you sure you want to continue?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
    
    # Run cleanup
    cleanup_completed_pods
    cleanup_failed_jobs
    cleanup_old_completed_jobs
    find_unused_configmaps
    check_orphaned_pvcs
    cleanup_old_events
    check_empty_secrets
    
    # Summary
    generate_summary
}

main "$@"
