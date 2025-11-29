#!/usr/bin/env bash
# validate-cluster-health.sh - Validate overall Kubernetes cluster health
# Checks nodes, system pods, networking, and core services
#
# Usage: ./validate-cluster-health.sh [OPTIONS]
#
# Options:
#   -v, --verbose      Enable verbose output
#   -q, --quiet        Suppress non-error output
#   --json             Output results as JSON
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate overall Kubernetes cluster health including:
  - Node status and conditions
  - System pods (kube-system)
  - Core services (DNS, API server)
  - Network connectivity
  - Resource availability

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show this help message

Examples:
  $(basename "$0")          # Basic cluster health check
  $(basename "$0") -v       # Verbose output with debug info
  $(basename "$0") --json   # Output results as JSON

Exit Codes:
  0 - All validations passed
  1 - One or more validations failed
  2 - Script error (missing dependencies, etc.)
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -q|--quiet)
                export LOG_LEVEL="ERROR"
                shift
                ;;
            --json)
                JSON_OUTPUT="true"
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
# Record validation result
#######################################
record_result() {
    local check="$1"
    local status="$2"
    local message="$3"

    RESULTS["$check"]="$status|$message"

    if [[ "$status" == "pass" ]]; then
        log_success "$check: $message"
    else
        log_failure "$check: $message"
    fi
}

#######################################
# Check node health
#######################################
check_nodes() {
    log_subsection "Node Health"

    local ready_nodes
    local total_nodes

    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [[ $total_nodes -eq 0 ]]; then
        record_result "nodes-available" "fail" "No nodes found"
        return 1
    fi

    if [[ $ready_nodes -eq $total_nodes ]]; then
        record_result "nodes-ready" "pass" "$ready_nodes/$total_nodes nodes Ready"
    else
        record_result "nodes-ready" "fail" "Only $ready_nodes/$total_nodes nodes Ready"
    fi

    # Check for node conditions
    local nodes_with_issues
    nodes_with_issues=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}{"\n"}{end}' 2>/dev/null | grep -v "Ready" | grep -v "^$" || true)

    if [[ -z "$nodes_with_issues" ]]; then
        record_result "nodes-conditions" "pass" "No node conditions"
    else
        log_debug "Nodes with conditions:"
        log_debug "$nodes_with_issues"
        record_result "nodes-conditions" "fail" "Some nodes have conditions"
    fi
}

#######################################
# Check system pods
#######################################
check_system_pods() {
    log_subsection "System Pods (kube-system)"

    local running_pods
    local total_pods

    running_pods=$(kubectl get pods -n kube-system --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    total_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)

    if [[ $running_pods -eq $total_pods ]] && [[ $total_pods -gt 0 ]]; then
        record_result "system-pods" "pass" "$running_pods/$total_pods pods running"
    else
        record_result "system-pods" "fail" "Only $running_pods/$total_pods pods running"

        # List non-running pods
        local failed_pods
        failed_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" || true)
        if [[ -n "$failed_pods" ]]; then
            log_debug "Non-running pods in kube-system:"
            log_debug "$failed_pods"
        fi
    fi
}

#######################################
# Check CoreDNS / DNS
#######################################
check_dns() {
    log_subsection "DNS Health"

    # Check CoreDNS pods
    local coredns_running
    coredns_running=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    if [[ $coredns_running -gt 0 ]]; then
        record_result "coredns-pods" "pass" "$coredns_running CoreDNS pods running"
    else
        record_result "coredns-pods" "fail" "No CoreDNS pods running"
    fi

    # Check DNS service
    if kubectl get svc -n kube-system kube-dns >/dev/null 2>&1; then
        record_result "dns-service" "pass" "kube-dns service exists"
    else
        record_result "dns-service" "fail" "kube-dns service not found"
    fi
}

#######################################
# Check API server health
#######################################
check_api_server() {
    log_subsection "API Server Health"

    # Check if API server is responsive
    if kubectl get --raw='/healthz' >/dev/null 2>&1; then
        record_result "api-server-health" "pass" "API server responding"
    else
        record_result "api-server-health" "fail" "API server not responding"
    fi

    # Check API server version
    local version
    version=$(kubectl version --short 2>/dev/null | grep "Server" | awk '{print $3}' || kubectl version 2>/dev/null | grep "Server Version" | head -1 || echo "unknown")
    log_debug "Kubernetes server version: $version"
}

#######################################
# Check cluster networking
#######################################
check_networking() {
    log_subsection "Cluster Networking"

    # Check CNI pods (common CNIs)
    local cni_found=false

    # Check for Calico
    if kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q "Running"; then
        record_result "cni-calico" "pass" "Calico CNI running"
        cni_found=true
    fi

    # Check for Flannel
    if kubectl get pods -n kube-system -l app=flannel --no-headers 2>/dev/null | grep -q "Running"; then
        record_result "cni-flannel" "pass" "Flannel CNI running"
        cni_found=true
    fi

    # Check for Cilium
    if kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -q "Running"; then
        record_result "cni-cilium" "pass" "Cilium CNI running"
        cni_found=true
    fi

    if [[ "$cni_found" == "false" ]]; then
        log_debug "No recognized CNI pods found (this may be normal for some setups)"
    fi

    # Check kube-proxy
    local kube_proxy_running
    kube_proxy_running=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    if [[ $kube_proxy_running -gt 0 ]]; then
        record_result "kube-proxy" "pass" "$kube_proxy_running kube-proxy pods running"
    else
        log_debug "kube-proxy pods not found (may be using alternative)"
    fi
}

#######################################
# Check resource availability
#######################################
check_resources() {
    log_subsection "Resource Availability"

    # Get node resource summary
    local node_resources
    node_resources=$(kubectl top nodes 2>/dev/null || echo "")

    if [[ -n "$node_resources" ]]; then
        record_result "metrics-server" "pass" "Metrics available"
        log_debug "Node resource usage:"
        log_debug "$node_resources"
    else
        log_debug "Metrics server not available or not configured"
    fi

    # Check for pods with resource issues
    local oom_pods
    oom_pods=$(kubectl get events --all-namespaces --field-selector reason=OOMKilling --no-headers 2>/dev/null | wc -l)

    if [[ $oom_pods -eq 0 ]]; then
        record_result "oom-events" "pass" "No recent OOM events"
    else
        record_result "oom-events" "fail" "$oom_pods OOM events detected"
    fi
}

#######################################
# Check namespaces
#######################################
check_namespaces() {
    log_subsection "Namespaces"

    local namespace_count
    namespace_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l)

    record_result "namespaces" "pass" "$namespace_count namespaces exist"

    # Check for terminating namespaces
    local terminating
    terminating=$(kubectl get namespaces --no-headers 2>/dev/null | grep "Terminating" | wc -l)

    if [[ $terminating -gt 0 ]]; then
        record_result "stuck-namespaces" "fail" "$terminating namespaces stuck in Terminating"
    fi
}

#######################################
# Output results as JSON
#######################################
output_json() {
    local passed=0
    local failed=0

    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    echo '  "checks": {'

    local first=true
    for check in "${!RESULTS[@]}"; do
        local result="${RESULTS[$check]}"
        local status="${result%%|*}"
        local message="${result#*|}"

        if [[ "$status" == "pass" ]]; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo -n '    "'"$check"'": {"status": "'"$status"'", "message": "'"$message"'"}'
    done

    echo ""
    echo "  },"
    echo '  "summary": {"passed": '$passed', "failed": '$failed', "total": '$((passed + failed))'}'
    echo "}"
}

#######################################
# Output summary
#######################################
output_summary() {
    local passed=0
    local failed=0

    for check in "${!RESULTS[@]}"; do
        local result="${RESULTS[$check]}"
        local status="${result%%|*}"
        if [[ "$status" == "pass" ]]; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi
    done

    log_section "Cluster Health Summary"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All cluster health validations passed!"
        return 0
    else
        echo ""
        log_failure "Some cluster health validations failed"
        return 1
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

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_section "Cluster Health Validation"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_nodes
    check_system_pods
    check_dns
    check_api_server
    check_networking
    check_resources
    check_namespaces

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
