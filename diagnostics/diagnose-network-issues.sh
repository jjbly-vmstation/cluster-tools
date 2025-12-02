#!/usr/bin/env bash
# Script: diagnose-network-issues.sh
# Purpose: Diagnose network issues in the cluster
# Usage: ./diagnose-network-issues.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -o, --output   Output directory for diagnostic files

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"
# shellcheck source=../lib/network-utils.sh
source "${SCRIPT_DIR}/../lib/network-utils.sh"

# Default configuration
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostic-output}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose network issues in the Kubernetes cluster including:
  - DNS resolution
  - Pod-to-pod connectivity
  - Service connectivity
  - External network access
  - Network policies
  - CNI status

Options:
  -o, --output DIR   Output directory for diagnostic files
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message

Examples:
  $(basename "$0")                  # Basic diagnostics
  $(basename "$0") -o /tmp/diag     # Save to specific directory

Output:
  Creates a directory with network diagnostic information
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
    OUTPUT_DIR="${OUTPUT_DIR}/network-diag-${timestamp}"

    ensure_directory "$OUTPUT_DIR"

    log_info "Diagnostic output will be saved to: $OUTPUT_DIR"
}

#######################################
# Collect DNS diagnostics
#######################################
collect_dns_diagnostics() {
    log_subsection "Collecting DNS Diagnostics"

    {
        echo "=== CoreDNS Status ==="
        kubectl get pods -n kube-system -l k8s-app=kube-dns 2>&1 || true
        echo ""
        echo "=== CoreDNS Service ==="
        kubectl get svc -n kube-system kube-dns 2>&1 || true
        echo ""
        echo "=== CoreDNS ConfigMap ==="
        kubectl get configmap -n kube-system coredns -o yaml 2>&1 || true
        echo ""
        echo "=== DNS Resolution Test ==="
        if check_dns "kubernetes.default.svc.cluster.local"; then
            echo "kubernetes.default.svc.cluster.local: RESOLVED"
        else
            echo "kubernetes.default.svc.cluster.local: FAILED"
        fi
    } > "${OUTPUT_DIR}/dns-diagnostics.txt"

    log_success "DNS diagnostics collected"
}

#######################################
# Collect CNI diagnostics
#######################################
collect_cni_diagnostics() {
    log_subsection "Collecting CNI Diagnostics"

    {
        echo "=== CNI Pods ==="
        # Check for common CNI implementations
        echo "Calico:"
        kubectl get pods -n kube-system -l k8s-app=calico-node 2>&1 || echo "Not found"
        echo ""
        echo "Flannel:"
        kubectl get pods -n kube-system -l app=flannel 2>&1 || echo "Not found"
        echo ""
        echo "Cilium:"
        kubectl get pods -n kube-system -l k8s-app=cilium 2>&1 || echo "Not found"
        echo ""
        echo "Weave:"
        kubectl get pods -n kube-system -l name=weave-net 2>&1 || echo "Not found"
        echo ""
        echo "=== kube-proxy ==="
        kubectl get pods -n kube-system -l k8s-app=kube-proxy 2>&1 || true
        echo ""
        echo "=== kube-proxy ConfigMap ==="
        kubectl get configmap -n kube-system kube-proxy -o yaml 2>&1 || true
    } > "${OUTPUT_DIR}/cni-diagnostics.txt"

    log_success "CNI diagnostics collected"
}

#######################################
# Collect network policy diagnostics
#######################################
collect_network_policy_diagnostics() {
    log_subsection "Collecting Network Policy Diagnostics"

    {
        echo "=== Network Policies ==="
        kubectl get networkpolicies --all-namespaces 2>&1 || true
        echo ""
        echo "=== Network Policy Details ==="
        kubectl get networkpolicies --all-namespaces -o yaml 2>&1 || true
    } > "${OUTPUT_DIR}/network-policies.txt"

    log_success "Network policy diagnostics collected"
}

#######################################
# Collect service diagnostics
#######################################
collect_service_diagnostics() {
    log_subsection "Collecting Service Diagnostics"

    {
        echo "=== All Services ==="
        kubectl get services --all-namespaces -o wide 2>&1 || true
        echo ""
        echo "=== All Endpoints ==="
        kubectl get endpoints --all-namespaces 2>&1 || true
        echo ""
        echo "=== Services Without Endpoints ==="
        kubectl get endpoints --all-namespaces --no-headers 2>/dev/null | \
            awk '$2 == "<none>" {print $1"/"$2}' || true
    } > "${OUTPUT_DIR}/service-diagnostics.txt"

    log_success "Service diagnostics collected"
}

#######################################
# Collect ingress diagnostics
#######################################
collect_ingress_diagnostics() {
    log_subsection "Collecting Ingress Diagnostics"

    {
        echo "=== Ingress Resources ==="
        kubectl get ingress --all-namespaces 2>&1 || true
        echo ""
        echo "=== Ingress Controllers ==="
        kubectl get pods -n ingress-nginx 2>&1 || echo "nginx-ingress not found"
        kubectl get pods --all-namespaces -l app=traefik 2>&1 || echo "traefik not found"
        echo ""
        echo "=== IngressClasses ==="
        kubectl get ingressclasses 2>&1 || true
    } > "${OUTPUT_DIR}/ingress-diagnostics.txt"

    log_success "Ingress diagnostics collected"
}

#######################################
# Collect node network info
#######################################
collect_node_network_info() {
    log_subsection "Collecting Node Network Information"

    {
        echo "=== Node IP Addresses ==="
        kubectl get nodes -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,EXTERNAL-IP:.status.addresses[?(@.type=="ExternalIP")].address' 2>&1 || true
        echo ""
        echo "=== Node Pod CIDRs ==="
        kubectl get nodes -o custom-columns='NAME:.metadata.name,POD-CIDR:.spec.podCIDR' 2>&1 || true
    } > "${OUTPUT_DIR}/node-network-info.txt"

    log_success "Node network information collected"
}

#######################################
# Test external connectivity
#######################################
test_external_connectivity() {
    log_subsection "Testing External Connectivity"

    {
        echo "=== External Connectivity Test ==="
        echo ""
        echo "Testing 8.8.8.8 (Google DNS):"
        if ping_host "8.8.8.8" 5; then
            echo "  Status: Reachable"
        else
            echo "  Status: Unreachable"
        fi
        echo ""
        echo "Testing 1.1.1.1 (Cloudflare DNS):"
        if ping_host "1.1.1.1" 5; then
            echo "  Status: Reachable"
        else
            echo "  Status: Unreachable"
        fi
        echo ""
        echo "Testing DNS resolution for google.com:"
        if check_dns "google.com"; then
            echo "  Status: Resolved"
        else
            echo "  Status: Failed"
        fi
    } > "${OUTPUT_DIR}/external-connectivity.txt"

    log_success "External connectivity tests completed"
}

#######################################
# Collect network events
#######################################
collect_network_events() {
    log_subsection "Collecting Network-Related Events"

    {
        echo "=== Network-Related Events ==="
        kubectl get events --all-namespaces --sort-by='.lastTimestamp' 2>/dev/null | \
            grep -iE "network|dns|route|connection|timeout" || echo "No network-related events found"
    } > "${OUTPUT_DIR}/network-events.txt"

    log_success "Network events collected"
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_subsection "Generating Summary"

    local summary_file="${OUTPUT_DIR}/diagnosis-summary.txt"

    {
        echo "Network Diagnostic Summary"
        echo "=========================="
        echo "Timestamp: $(date -Iseconds)"
        echo ""

        echo "DNS Status:"
        echo "-----------"
        local coredns_running
        coredns_running=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        echo "- CoreDNS pods running: $coredns_running"

        echo ""
        echo "CNI Status:"
        echo "-----------"
        local cni_found="Unknown"
        if kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q "Running"; then
            cni_found="Calico"
        elif kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | grep -q "Running"; then
            cni_found="Flannel"
        elif kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -q "Running"; then
            cni_found="Cilium"
        fi
        echo "- CNI: $cni_found"

        echo ""
        echo "Network Policies:"
        echo "-----------------"
        local np_count
        np_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l)
        echo "- Network policies: $np_count"

        echo ""
        echo "Services:"
        echo "---------"
        local svc_count
        svc_count=$(kubectl get services --all-namespaces --no-headers 2>/dev/null | wc -l)
        echo "- Total services: $svc_count"

        echo ""
        echo "Files Collected:"
        echo "----------------"
        echo "- dns-diagnostics.txt"
        echo "- cni-diagnostics.txt"
        echo "- network-policies.txt"
        echo "- service-diagnostics.txt"
        echo "- ingress-diagnostics.txt"
        echo "- node-network-info.txt"
        echo "- external-connectivity.txt"
        echo "- network-events.txt"
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

    log_section "Network Diagnostics"
    log_kv "Timestamp" "$(date -Iseconds)"

    # Initialize output
    init_output_dir

    # Collect all diagnostic information
    collect_dns_diagnostics
    collect_cni_diagnostics
    collect_network_policy_diagnostics
    collect_service_diagnostics
    collect_ingress_diagnostics
    collect_node_network_info
    test_external_connectivity
    collect_network_events

    # Generate summary
    generate_summary

    log_section "Diagnostic Collection Complete"
    log_info "All diagnostic files saved to: $OUTPUT_DIR"
}

main "$@"
