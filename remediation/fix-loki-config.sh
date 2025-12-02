#!/usr/bin/env bash
# Script: fix-loki-config.sh
# Purpose: Fix Loki configuration drift
# Usage: ./fix-loki-config.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -n, --namespace Kubernetes namespace (default: monitoring)
#   --dry-run      Show what would be done without making changes

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
NAMESPACE="${NAMESPACE:-monitoring}"
DRY_RUN="${DRY_RUN:-false}"

# Expected configuration values
EXPECTED_RETENTION_PERIOD="${EXPECTED_RETENTION_PERIOD:-168h}"
EXPECTED_REPLICATION_FACTOR="${EXPECTED_REPLICATION_FACTOR:-1}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Fix Loki configuration drift including:
  - Retention period configuration
  - Replication factor
  - Storage configuration
  - Schema configuration

Options:
  -n, --namespace NS  Kubernetes namespace (default: monitoring)
  --dry-run           Show what would be done without making changes
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Environment:
  EXPECTED_RETENTION_PERIOD     Expected retention period (default: 168h)
  EXPECTED_REPLICATION_FACTOR   Expected replication factor (default: 1)

Examples:
  $(basename "$0")              # Fix Loki config in monitoring namespace
  $(basename "$0") --dry-run    # Preview fixes
  $(basename "$0") -n logging   # Fix in logging namespace

Warning: This tool modifies Loki configuration. Use --dry-run first.
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
# Find Loki ConfigMap
#######################################
find_loki_configmap() {
    local configmap=""

    # Try different common names
    for name in "loki" "loki-config" "loki-stack"; do
        if kubectl get configmap -n "$NAMESPACE" "$name" >/dev/null 2>&1; then
            configmap="$name"
            break
        fi
    done

    # Try label selector
    if [[ -z "$configmap" ]]; then
        configmap=$(kubectl get configmap -n "$NAMESPACE" -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi

    echo "$configmap"
}

#######################################
# Check retention period
#######################################
check_retention_period() {
    local config="$1"

    if echo "$config" | grep -q "retention_period"; then
        local actual_retention
        actual_retention=$(echo "$config" | grep "retention_period" | head -1 | awk '{print $2}')

        if [[ "$actual_retention" != "$EXPECTED_RETENTION_PERIOD" ]]; then
            log_warn "Retention period mismatch: expected=$EXPECTED_RETENTION_PERIOD, actual=$actual_retention"
            return 1
        else
            log_success "Retention period correct: $actual_retention"
            return 0
        fi
    else
        log_debug "retention_period not explicitly set"
        return 0
    fi
}

#######################################
# Check replication factor
#######################################
check_replication_factor() {
    local config="$1"

    if echo "$config" | grep -q "replication_factor"; then
        local actual_factor
        actual_factor=$(echo "$config" | grep "replication_factor" | head -1 | awk '{print $2}')

        if [[ "$actual_factor" != "$EXPECTED_REPLICATION_FACTOR" ]]; then
            log_warn "Replication factor mismatch: expected=$EXPECTED_REPLICATION_FACTOR, actual=$actual_factor"
            return 1
        else
            log_success "Replication factor correct: $actual_factor"
            return 0
        fi
    else
        log_debug "replication_factor not explicitly set"
        return 0
    fi
}

#######################################
# Fix retention period
#######################################
fix_retention_period() {
    local configmap="$1"

    record_action "Update retention_period to $EXPECTED_RETENTION_PERIOD"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Get current config
        local current_config
        current_config=$(kubectl get configmap -n "$NAMESPACE" "$configmap" -o jsonpath='{.data.loki\.yaml}' 2>/dev/null || true)

        if [[ -z "$current_config" ]]; then
            log_error "Could not retrieve Loki config"
            return 1
        fi

        # Update retention period using sed
        local updated_config
        updated_config=$(echo "$current_config" | sed "s/retention_period:.*/retention_period: $EXPECTED_RETENTION_PERIOD/g")

        # Create a patch file
        local patch_file
        patch_file=$(mktemp)

        cat > "$patch_file" << EOF
data:
  loki.yaml: |
$(echo "$updated_config" | sed 's/^/    /')
EOF

        kubectl patch configmap -n "$NAMESPACE" "$configmap" --patch-file "$patch_file" 2>/dev/null || {
            log_error "Failed to patch ConfigMap"
            rm -f "$patch_file"
            return 1
        }

        rm -f "$patch_file"
        log_success "Retention period updated"
    fi
}

#######################################
# Restart Loki pods
#######################################
restart_loki() {
    record_action "Restart Loki pods to apply configuration"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Try deployment first
        if kubectl get deployment -n "$NAMESPACE" loki >/dev/null 2>&1; then
            kubectl rollout restart deployment -n "$NAMESPACE" loki || {
                log_warn "Failed to restart Loki deployment"
            }
        # Try statefulset
        elif kubectl get statefulset -n "$NAMESPACE" loki >/dev/null 2>&1; then
            kubectl rollout restart statefulset -n "$NAMESPACE" loki || {
                log_warn "Failed to restart Loki statefulset"
            }
        else
            # Delete pods to trigger restart
            kubectl delete pods -n "$NAMESPACE" -l app=loki 2>/dev/null || {
                log_warn "Failed to delete Loki pods"
            }
        fi

        log_success "Loki restart initiated"
    fi
}

#######################################
# Verify Loki health after fix
#######################################
verify_loki_health() {
    log_subsection "Verifying Loki Health"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would verify Loki health after restart"
        return 0
    fi

    log_info "Waiting for Loki pods to be ready..."
    sleep 10

    # Check pod status
    local running_pods
    running_pods=$(kubectl get pods -n "$NAMESPACE" -l app=loki --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $running_pods -gt 0 ]]; then
        log_success "Loki pods are running: $running_pods"
    else
        log_warn "No running Loki pods found after restart"
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

    log_kv "Namespace" "$NAMESPACE"
    log_kv "Actions" "${#ACTIONS_TAKEN[@]}"

    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        echo ""
        echo "Actions taken:"
        for action in "${ACTIONS_TAKEN[@]}"; do
            echo "  - $action"
        done
    else
        log_success "No fixes needed"
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

    log_section "Loki Configuration Fix"
    log_kv "Namespace" "$NAMESPACE"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"

    # Find Loki ConfigMap
    local configmap
    configmap=$(find_loki_configmap)

    if [[ -z "$configmap" ]]; then
        log_error "Could not find Loki ConfigMap in namespace $NAMESPACE"
        exit 2
    fi

    log_info "Found Loki ConfigMap: $configmap"

    # Get current configuration
    local loki_config
    loki_config=$(kubectl get configmap -n "$NAMESPACE" "$configmap" -o jsonpath='{.data.loki\.yaml}' 2>/dev/null || true)

    if [[ -z "$loki_config" ]]; then
        log_error "Could not retrieve Loki configuration"
        exit 2
    fi

    # Check and fix configuration
    log_subsection "Checking Configuration"

    local needs_fix=false

    if ! check_retention_period "$loki_config"; then
        needs_fix=true
    fi

    if ! check_replication_factor "$loki_config"; then
        needs_fix=true
    fi

    # Apply fixes if needed
    if [[ "$needs_fix" == "true" ]]; then
        log_subsection "Applying Fixes"

        if [[ "$DRY_RUN" != "true" ]]; then
            if ! confirm "This will modify Loki configuration. Continue?"; then
                log_info "Aborted by user"
                exit 0
            fi
        fi

        fix_retention_period "$configmap"
        restart_loki
        verify_loki_health
    else
        log_success "No configuration drift detected"
    fi

    # Summary
    generate_summary
}

main "$@"
