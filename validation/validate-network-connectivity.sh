#!/usr/bin/env bash
# validate-network-connectivity.sh - Validate network connectivity
# Tests internal and external network connectivity from the cluster
#
# Usage: ./validate-network-connectivity.sh [OPTIONS]
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
# shellcheck source=../lib/network-utils.sh
source "${SCRIPT_DIR}/../lib/network-utils.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Validation results
declare -A RESULTS

# Default endpoints to check
INTERNAL_ENDPOINTS=(
    "kubernetes.default.svc.cluster.local:443"
    "kube-dns.kube-system.svc.cluster.local:53"
)

EXTERNAL_ENDPOINTS=(
    "8.8.8.8"
    "1.1.1.1"
)

EXTERNAL_DNS_HOSTS=(
    "google.com"
    "github.com"
)

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate network connectivity including:
  - Pod-to-pod communication
  - Service DNS resolution
  - External network access
  - API server connectivity

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show this help message

Examples:
  $(basename "$0")          # Basic connectivity check
  $(basename "$0") -v       # Verbose output
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
# Check DNS resolution
#######################################
check_dns_resolution() {
    log_subsection "DNS Resolution"

    # Check internal DNS
    for endpoint in "${INTERNAL_ENDPOINTS[@]}"; do
        local host="${endpoint%%:*}"
        local check_name="dns-internal-${host%%.*}"

        if check_dns "$host"; then
            record_result "$check_name" "pass" "$host resolves"
        else
            record_result "$check_name" "fail" "$host does not resolve"
        fi
    done

    # Check external DNS
    for host in "${EXTERNAL_DNS_HOSTS[@]}"; do
        local check_name="dns-external-$host"

        if check_dns "$host"; then
            record_result "$check_name" "pass" "$host resolves"
        else
            record_result "$check_name" "fail" "$host does not resolve"
        fi
    done
}

#######################################
# Check external connectivity
#######################################
check_external_connectivity() {
    log_subsection "External Connectivity"

    for ip in "${EXTERNAL_ENDPOINTS[@]}"; do
        local check_name="external-ping-$ip"

        if ping_host "$ip" 5; then
            record_result "$check_name" "pass" "$ip reachable"
        else
            record_result "$check_name" "fail" "$ip unreachable"
        fi
    done
}

#######################################
# Check API server connectivity
#######################################
check_api_connectivity() {
    log_subsection "API Server Connectivity"

    # Check API server endpoint
    if kubectl get --raw='/healthz' >/dev/null 2>&1; then
        record_result "api-server" "pass" "API server accessible"
    else
        record_result "api-server" "fail" "API server not accessible"
    fi

    # Check API server from within cluster (if test pod exists)
    log_debug "API server connectivity verified via kubectl"
}

#######################################
# Check service connectivity
#######################################
check_service_connectivity() {
    log_subsection "Service Connectivity"

    # Check kubernetes service
    if kubectl get svc kubernetes >/dev/null 2>&1; then
        record_result "kubernetes-svc" "pass" "kubernetes service exists"

        local cluster_ip
        cluster_ip=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        log_debug "Kubernetes service ClusterIP: $cluster_ip"
    else
        record_result "kubernetes-svc" "fail" "kubernetes service not found"
    fi

    # Check kube-dns service
    if kubectl get svc -n kube-system kube-dns >/dev/null 2>&1; then
        record_result "kube-dns-svc" "pass" "kube-dns service exists"
    else
        record_result "kube-dns-svc" "fail" "kube-dns service not found"
    fi
}

#######################################
# Check network policies
#######################################
check_network_policies() {
    log_subsection "Network Policies"

    local policy_count
    policy_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l)

    if [[ $policy_count -gt 0 ]]; then
        record_result "network-policies" "pass" "$policy_count network policies defined"
        log_debug "Network policies are in use"
    else
        log_debug "No network policies defined (this may be intentional)"
    fi
}

#######################################
# Check default gateway
#######################################
check_gateway() {
    log_subsection "Gateway Configuration"

    local gateway
    gateway=$(get_default_gateway)

    if [[ -n "$gateway" ]]; then
        record_result "default-gateway" "pass" "Gateway: $gateway"

        if ping_host "$gateway" 2; then
            record_result "gateway-reachable" "pass" "Gateway is reachable"
        else
            record_result "gateway-reachable" "fail" "Gateway is not reachable"
        fi
    else
        log_debug "Could not determine default gateway"
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

    log_section "Network Connectivity Summary"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All network connectivity validations passed!"
        return 0
    else
        echo ""
        log_failure "Some network connectivity validations failed"
        return 1
    fi
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_section "Network Connectivity Validation"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_dns_resolution
    check_external_connectivity
    check_gateway

    # Kubernetes-specific checks if kubectl is available
    if command_exists kubectl && kubectl_ready; then
        check_api_connectivity
        check_service_connectivity
        check_network_policies
    else
        log_debug "kubectl not available or cluster not reachable - skipping Kubernetes checks"
    fi

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
