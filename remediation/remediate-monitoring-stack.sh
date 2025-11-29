#!/usr/bin/env bash
# remediate-monitoring-stack.sh - Remediate common monitoring stack issues
# Automatically fixes common problems with the monitoring stack
#
# Usage: ./remediate-monitoring-stack.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Kubernetes namespace (default: monitoring)
#   -n, --dry-run      Show what would be done without making changes
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-monitoring}"
DRY_RUN="${DRY_RUN:-false}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Remediate common monitoring stack issues including:
  - Restart crashed pods
  - Clear stuck deployments
  - Fix common configuration issues
  - Restart unresponsive services

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace (default: monitoring)
  --dry-run                   Show what would be done without changes
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Examples:
  $(basename "$0")              # Remediate issues in monitoring namespace
  $(basename "$0") --dry-run    # Preview remediation actions
  $(basename "$0") -v           # Verbose output

Remediation Actions:
  - Restart pods in CrashLoopBackOff
  - Delete stuck Pending pods
  - Restart deployments with unavailable replicas
  - Clear completed/failed jobs
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
# Restart crashed pods
#######################################
remediate_crashed_pods() {
    log_subsection "Checking for Crashed Pods"
    
    local crashed_pods
    crashed_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | \
        grep -E "CrashLoopBackOff|Error" | awk '{print $1}' || true)
    
    if [[ -z "$crashed_pods" ]]; then
        log_success "No crashed pods found"
        return 0
    fi
    
    log_warn "Found crashed pods"
    
    echo "$crashed_pods" | while read -r pod; do
        if [[ -n "$pod" ]]; then
            record_action "Delete crashed pod: $pod"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete pod -n "$NAMESPACE" "$pod" --grace-period=30 || {
                    log_warn "Failed to delete pod: $pod"
                }
            fi
        fi
    done
}

#######################################
# Handle stuck pending pods
#######################################
remediate_pending_pods() {
    log_subsection "Checking for Stuck Pending Pods"
    
    # Find pods that have been pending for more than 5 minutes
    local pending_pods
    pending_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | \
        awk '{print $1}' || true)
    
    if [[ -z "$pending_pods" ]]; then
        log_success "No stuck pending pods found"
        return 0
    fi
    
    echo "$pending_pods" | while read -r pod; do
        if [[ -n "$pod" ]]; then
            # Check how long the pod has been pending
            local age
            age=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
            
            if [[ -n "$age" ]]; then
                log_debug "Pod $pod has been pending since $age"
                
                # Get the reason for pending
                local reason
                reason=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || echo "Unknown")
                
                log_warn "Pod $pod pending: $reason"
                
                # Only delete if it's been pending for a while (this is a simplified check)
                record_action "Review pending pod: $pod (Reason: $reason)"
            fi
        fi
    done
}

#######################################
# Restart unhealthy deployments
#######################################
remediate_unhealthy_deployments() {
    log_subsection "Checking Deployment Health"
    
    local deployments
    deployments=$(kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | \
        awk '{split($2, a, "/"); if (a[1] != a[2]) print $1}' || true)
    
    if [[ -z "$deployments" ]]; then
        log_success "All deployments are healthy"
        return 0
    fi
    
    log_warn "Found unhealthy deployments"
    
    echo "$deployments" | while read -r deployment; do
        if [[ -n "$deployment" ]]; then
            local ready
            ready=$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired
            desired=$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            
            log_warn "Deployment $deployment: $ready/$desired ready"
            
            record_action "Restart deployment: $deployment"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl rollout restart deployment -n "$NAMESPACE" "$deployment" || {
                    log_warn "Failed to restart deployment: $deployment"
                }
            fi
        fi
    done
}

#######################################
# Clean up completed jobs
#######################################
cleanup_completed_jobs() {
    log_subsection "Cleaning Up Completed Jobs"
    
    local completed_jobs
    completed_jobs=$(kubectl get jobs -n "$NAMESPACE" --no-headers 2>/dev/null | \
        awk '$2 ~ /1\/1/ && $4 ~ /[0-9]+d/ {print $1}' || true)
    
    if [[ -z "$completed_jobs" ]]; then
        log_success "No old completed jobs to clean"
        return 0
    fi
    
    echo "$completed_jobs" | while read -r job; do
        if [[ -n "$job" ]]; then
            record_action "Delete completed job: $job"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete job -n "$NAMESPACE" "$job" || {
                    log_warn "Failed to delete job: $job"
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
    
    local failed_jobs
    failed_jobs=$(kubectl get jobs -n "$NAMESPACE" --no-headers 2>/dev/null | \
        awk '$2 ~ /0\/1/ {print $1}' || true)
    
    if [[ -z "$failed_jobs" ]]; then
        log_success "No failed jobs to clean"
        return 0
    fi
    
    echo "$failed_jobs" | while read -r job; do
        if [[ -n "$job" ]]; then
            record_action "Delete failed job: $job"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete job -n "$NAMESPACE" "$job" || {
                    log_warn "Failed to delete job: $job"
                }
            fi
        fi
    done
}

#######################################
# Fix common service issues
#######################################
remediate_services() {
    log_subsection "Checking Services"
    
    # Check for services with no endpoints
    local services_no_endpoints
    services_no_endpoints=$(kubectl get endpoints -n "$NAMESPACE" --no-headers 2>/dev/null | \
        awk '$2 == "<none>" {print $1}' || true)
    
    if [[ -n "$services_no_endpoints" ]]; then
        log_warn "Services with no endpoints found:"
        echo "$services_no_endpoints" | while read -r svc; do
            if [[ -n "$svc" ]]; then
                log_warn "  - $svc (check pod selectors and pod status)"
            fi
        done
    else
        log_success "All services have endpoints"
    fi
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Remediation Summary"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE - No changes were made"
    fi
    
    log_kv "Namespace" "$NAMESPACE"
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
    
    log_section "Monitoring Stack Remediation"
    log_kv "Namespace" "$NAMESPACE"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! confirm "This will make changes to your cluster. Continue?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi
    
    # Run remediation
    remediate_crashed_pods
    remediate_pending_pods
    remediate_unhealthy_deployments
    cleanup_completed_jobs
    cleanup_failed_jobs
    remediate_services
    
    # Summary
    generate_summary
}

main "$@"
