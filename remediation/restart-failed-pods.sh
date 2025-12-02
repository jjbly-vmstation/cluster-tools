#!/usr/bin/env bash
# Script: restart-failed-pods.sh
# Purpose: Restart pods in CrashLoopBackOff or Error state
# Usage: ./restart-failed-pods.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -n, --namespace Specific namespace (default: all)
#   --dry-run      Show what would be done without making changes

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-false}"
MAX_RESTARTS="${MAX_RESTARTS:-10}"
INCLUDE_ERROR="${INCLUDE_ERROR:-true}"
INCLUDE_CRASHLOOP="${INCLUDE_CRASHLOOP:-true}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Restart pods in failed states including:
  - CrashLoopBackOff
  - Error state
  - High restart count

Options:
  -n, --namespace NS    Kubernetes namespace (default: all)
  --dry-run             Show what would be done without making changes
  --max-restarts N      Max restart count threshold (default: 10)
  --skip-error          Skip pods in Error state
  --skip-crashloop      Skip CrashLoopBackOff pods
  -v, --verbose         Enable verbose output
  -h, --help            Show this help message

Examples:
  $(basename "$0")                    # Restart failed pods in all namespaces
  $(basename "$0") -n monitoring      # Restart in specific namespace
  $(basename "$0") --dry-run          # Preview restart actions
  $(basename "$0") --max-restarts 5   # Lower threshold

Warning: This tool deletes pods to trigger restarts.
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
            --max-restarts)
                MAX_RESTARTS="${2:?Max restarts value required}"
                shift 2
                ;;
            --skip-error)
                INCLUDE_ERROR="false"
                shift
                ;;
            --skip-crashloop)
                INCLUDE_CRASHLOOP="false"
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
# Restart CrashLoopBackOff pods
#######################################
restart_crashloop_pods() {
    if [[ "$INCLUDE_CRASHLOOP" != "true" ]]; then
        log_debug "Skipping CrashLoopBackOff pods"
        return 0
    fi

    log_subsection "Restarting CrashLoopBackOff Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # shellcheck disable=SC2086
    local crashloop_pods
    crashloop_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep "CrashLoopBackOff" || true)

    if [[ -z "$crashloop_pods" ]]; then
        log_success "No CrashLoopBackOff pods found"
        return 0
    fi

    local count
    count=$(echo "$crashloop_pods" | wc -l)
    log_warn "Found $count CrashLoopBackOff pod(s)"

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

        record_action "Restart CrashLoopBackOff pod: $ns/$name"

        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl delete pod -n "$ns" "$name" --grace-period=30 2>/dev/null || {
                log_warn "Failed to delete pod: $ns/$name"
            }
        fi
    done
}

#######################################
# Restart Error pods
#######################################
restart_error_pods() {
    if [[ "$INCLUDE_ERROR" != "true" ]]; then
        log_debug "Skipping Error state pods"
        return 0
    fi

    log_subsection "Restarting Error State Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # shellcheck disable=SC2086
    local error_pods
    error_pods=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -E "\sError\s" || true)

    if [[ -z "$error_pods" ]]; then
        log_success "No Error state pods found"
        return 0
    fi

    local count
    count=$(echo "$error_pods" | wc -l)
    log_warn "Found $count Error state pod(s)"

    echo "$error_pods" | while read -r line; do
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

        record_action "Restart Error pod: $ns/$name"

        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl delete pod -n "$ns" "$name" --grace-period=30 2>/dev/null || {
                log_warn "Failed to delete pod: $ns/$name"
            }
        fi
    done
}

#######################################
# Restart high restart count pods
#######################################
restart_high_restart_pods() {
    log_subsection "Checking High Restart Count Pods"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local high_restart_count=0

    # Get pods with restart counts
    # shellcheck disable=SC2086
    kubectl get pods $ns_flag -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null | \
    while IFS= read -r line; do
        local ns name restarts
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        restarts=$(echo "$line" | awk '{print $3}')

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

        if [[ $total_restarts -gt $MAX_RESTARTS ]]; then
            record_action "Restart high-restart pod ($total_restarts restarts): $ns/$name"
            ((high_restart_count++)) || true

            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete pod -n "$ns" "$name" --grace-period=30 2>/dev/null || {
                    log_warn "Failed to delete pod: $ns/$name"
                }
            fi
        fi
    done

    if [[ $high_restart_count -eq 0 ]]; then
        log_success "No pods with restarts > $MAX_RESTARTS"
    fi
}

#######################################
# Wait and verify
#######################################
verify_restarts() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would verify pod restarts"
        return 0
    fi

    if [[ ${#ACTIONS_TAKEN[@]} -eq 0 ]]; then
        return 0
    fi

    log_subsection "Verifying Pod Restarts"

    log_info "Waiting for pods to restart..."
    sleep 10

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Check for remaining failed pods
    # shellcheck disable=SC2086
    local remaining_failed
    remaining_failed=$(kubectl get pods $ns_flag --no-headers 2>/dev/null | grep -cE "CrashLoopBackOff|Error" || echo 0)

    if [[ $remaining_failed -eq 0 ]]; then
        log_success "All pods restarted successfully"
    else
        log_warn "$remaining_failed pod(s) still in failed state"
        log_info "Some pods may need further investigation"
    fi
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Restart Summary"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE - No changes were made"
    fi

    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Max Restarts" "$MAX_RESTARTS"
    log_kv "Actions" "${#ACTIONS_TAKEN[@]}"

    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        echo ""
        echo "Actions taken:"
        for action in "${ACTIONS_TAKEN[@]}"; do
            echo "  - $action"
        done
    else
        log_success "No pods needed to be restarted"
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

    log_section "Pod Restart Remediation"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Max Restarts" "$MAX_RESTARTS"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! confirm "This will delete and restart failed pods. Continue?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    # Restart failed pods
    restart_crashloop_pods
    restart_error_pods
    restart_high_restart_pods

    # Verify
    verify_restarts

    # Summary
    generate_summary
}

main "$@"
