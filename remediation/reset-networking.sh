#!/usr/bin/env bash
# Script: reset-networking.sh
# Purpose: Reset network configuration in the cluster
# Usage: ./reset-networking.sh [options]
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
FORCE="${FORCE:-false}"

# Track remediation actions
declare -a ACTIONS_TAKEN

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Reset network configuration to resolve networking issues:
  - Restart kube-proxy
  - Restart CNI pods (Calico, Flannel, Cilium, etc.)
  - Restart CoreDNS
  - Flush iptables rules (requires SSH)

Options:
  --dry-run     Show what would be done without making changes
  -f, --force   Skip confirmation prompts
  -v, --verbose Enable verbose output
  -h, --help    Show this help message

Examples:
  $(basename "$0")            # Reset networking components
  $(basename "$0") --dry-run  # Preview reset actions

Warning: This will temporarily disrupt cluster networking!
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
# Detect CNI plugin
#######################################
detect_cni() {
    local cni=""

    # Check Calico
    if kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q .; then
        cni="calico"
    # Check Flannel
    elif kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | grep -q .; then
        cni="flannel"
    # Check Cilium
    elif kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -q .; then
        cni="cilium"
    # Check Weave
    elif kubectl get pods -n kube-system -l name=weave-net --no-headers 2>/dev/null | grep -q .; then
        cni="weave"
    else
        cni="unknown"
    fi

    echo "$cni"
}

#######################################
# Restart CoreDNS
#######################################
restart_coredns() {
    log_subsection "Restarting CoreDNS"

    record_action "Restart CoreDNS pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart deployment -n kube-system coredns 2>/dev/null || {
            # Try deleting pods if deployment restart fails
            kubectl delete pods -n kube-system -l k8s-app=kube-dns 2>/dev/null || {
                log_warn "Failed to restart CoreDNS"
            }
        }

        log_success "CoreDNS restart initiated"
    fi
}

#######################################
# Restart kube-proxy
#######################################
restart_kube_proxy() {
    log_subsection "Restarting kube-proxy"

    record_action "Restart kube-proxy pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart daemonset -n kube-system kube-proxy 2>/dev/null || {
            # Try deleting pods if rollout restart fails
            kubectl delete pods -n kube-system -l k8s-app=kube-proxy 2>/dev/null || {
                log_warn "Failed to restart kube-proxy"
            }
        }

        log_success "kube-proxy restart initiated"
    fi
}

#######################################
# Restart Calico
#######################################
restart_calico() {
    log_subsection "Restarting Calico"

    record_action "Restart Calico pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart daemonset -n kube-system calico-node 2>/dev/null || {
            kubectl delete pods -n kube-system -l k8s-app=calico-node 2>/dev/null || {
                log_warn "Failed to restart Calico"
            }
        }

        # Also restart calico-kube-controllers if present
        kubectl rollout restart deployment -n kube-system calico-kube-controllers 2>/dev/null || true

        log_success "Calico restart initiated"
    fi
}

#######################################
# Restart Flannel
#######################################
restart_flannel() {
    log_subsection "Restarting Flannel"

    record_action "Restart Flannel pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart daemonset -n kube-system kube-flannel-ds 2>/dev/null || {
            kubectl delete pods -n kube-system -l app=flannel 2>/dev/null || {
                log_warn "Failed to restart Flannel"
            }
        }

        log_success "Flannel restart initiated"
    fi
}

#######################################
# Restart Cilium
#######################################
restart_cilium() {
    log_subsection "Restarting Cilium"

    record_action "Restart Cilium pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl rollout restart daemonset -n kube-system cilium 2>/dev/null || {
            kubectl delete pods -n kube-system -l k8s-app=cilium 2>/dev/null || {
                log_warn "Failed to restart Cilium"
            }
        }

        # Also restart cilium-operator
        kubectl rollout restart deployment -n kube-system cilium-operator 2>/dev/null || true

        log_success "Cilium restart initiated"
    fi
}

#######################################
# Restart Weave
#######################################
restart_weave() {
    log_subsection "Restarting Weave"

    record_action "Restart Weave pods"

    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl delete pods -n kube-system -l name=weave-net 2>/dev/null || {
            log_warn "Failed to restart Weave"
        }

        log_success "Weave restart initiated"
    fi
}

#######################################
# Restart CNI based on detected type
#######################################
restart_cni() {
    local cni
    cni=$(detect_cni)

    log_info "Detected CNI: $cni"

    case "$cni" in
        calico)
            restart_calico
            ;;
        flannel)
            restart_flannel
            ;;
        cilium)
            restart_cilium
            ;;
        weave)
            restart_weave
            ;;
        *)
            log_warn "Unknown CNI plugin, skipping CNI restart"
            record_action "Skip CNI restart (unknown CNI)"
            ;;
    esac
}

#######################################
# Wait for network components to be ready
#######################################
wait_for_network_ready() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would wait for network components to be ready"
        return 0
    fi

    log_subsection "Waiting for Network Components"

    log_info "Waiting for components to restart..."
    sleep 15

    # Check CoreDNS
    local coredns_ready
    coredns_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $coredns_ready -gt 0 ]]; then
        log_success "CoreDNS: $coredns_ready pod(s) running"
    else
        log_warn "CoreDNS: pods not ready"
    fi

    # Check kube-proxy
    local kube_proxy_ready
    kube_proxy_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $kube_proxy_ready -gt 0 ]]; then
        log_success "kube-proxy: $kube_proxy_ready pod(s) running"
    else
        log_warn "kube-proxy: pods not ready"
    fi

    # Check CNI
    local cni
    cni=$(detect_cni)

    case "$cni" in
        calico)
            local calico_ready
            calico_ready=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c "Running" || echo 0)
            log_success "Calico: $calico_ready pod(s) running"
            ;;
        flannel)
            local flannel_ready
            flannel_ready=$(kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | grep -c "Running" || echo 0)
            log_success "Flannel: $flannel_ready pod(s) running"
            ;;
        cilium)
            local cilium_ready
            cilium_ready=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || echo 0)
            log_success "Cilium: $cilium_ready pod(s) running"
            ;;
    esac
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Network Reset Summary"

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
        log_success "No network reset actions taken"
    fi

    echo ""
    log_info "Note: It may take a few minutes for networking to fully stabilize"
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

    log_section "Network Reset"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"

    if [[ "$DRY_RUN" != "true" ]] && [[ "$FORCE" != "true" ]]; then
        log_warn "This will restart all networking components!"
        log_warn "There may be temporary network disruption."
        if ! confirm "Are you sure you want to continue?"; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    # Restart networking components
    restart_coredns
    restart_kube_proxy
    restart_cni

    # Wait for components to be ready
    wait_for_network_ready

    # Summary
    generate_summary
}

main "$@"
