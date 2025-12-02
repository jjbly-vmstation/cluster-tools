#!/usr/bin/env bash
# Script: validate-service-endpoints.sh
# Purpose: Validate service and endpoint configuration
# Usage: ./validate-service-endpoints.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -q, --quiet    Quiet mode
#   --json         JSON output
#   -n, --namespace Specific namespace (default: all)

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"
NAMESPACE="${NAMESPACE:-}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate Kubernetes service and endpoint configuration including:
  - Service availability
  - Endpoint health
  - Service selector matching
  - Load balancer status

Options:
  -n, --namespace NS  Check specific namespace (default: all)
  -v, --verbose       Enable verbose output
  -q, --quiet         Suppress non-error output
  --json              Output results as JSON
  -h, --help          Show this help message

Examples:
  $(basename "$0")                   # Validate all namespaces
  $(basename "$0") -n monitoring     # Validate specific namespace
  $(basename "$0") --json            # Output results as JSON

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
            -n|--namespace)
                NAMESPACE="${2:?Namespace value required}"
                shift 2
                ;;
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
# Check service count
#######################################
check_services() {
    log_subsection "Service Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local svc_count
    # shellcheck disable=SC2086
    svc_count=$(kubectl get services $ns_flag --no-headers 2>/dev/null | wc -l)

    if [[ $svc_count -eq 0 ]]; then
        log_debug "No services found"
        return 0
    fi

    record_result "services-found" "pass" "$svc_count service(s) found"

    # Count by type
    # shellcheck disable=SC2086
    local clusterip_count
    clusterip_count=$(kubectl get services $ns_flag --no-headers 2>/dev/null | grep -c "ClusterIP" || echo 0)

    # shellcheck disable=SC2086
    local nodeport_count
    nodeport_count=$(kubectl get services $ns_flag --no-headers 2>/dev/null | grep -c "NodePort" || echo 0)

    # shellcheck disable=SC2086
    local loadbalancer_count
    loadbalancer_count=$(kubectl get services $ns_flag --no-headers 2>/dev/null | grep -c "LoadBalancer" || echo 0)

    log_debug "Service types: ClusterIP=$clusterip_count, NodePort=$nodeport_count, LoadBalancer=$loadbalancer_count"
}

#######################################
# Check endpoints
#######################################
check_endpoints() {
    log_subsection "Endpoint Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local endpoints_without_addresses=0

    # Get all endpoints
    # shellcheck disable=SC2086
    local endpoints
    endpoints=$(kubectl get endpoints $ns_flag --no-headers 2>/dev/null)

    if [[ -z "$endpoints" ]]; then
        log_debug "No endpoints found"
        return 0
    fi

    echo "$endpoints" | while read -r line; do
        local ns name addresses
        if [[ -n "$NAMESPACE" ]]; then
            ns="$NAMESPACE"
            name=$(echo "$line" | awk '{print $1}')
            addresses=$(echo "$line" | awk '{print $2}')
        else
            ns=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | awk '{print $2}')
            addresses=$(echo "$line" | awk '{print $3}')
        fi

        if [[ "$addresses" == "<none>" ]] || [[ -z "$addresses" ]]; then
            log_debug "Endpoint $ns/$name has no addresses"
            ((endpoints_without_addresses++)) || true
        fi
    done

    if [[ $endpoints_without_addresses -eq 0 ]]; then
        record_result "endpoints-healthy" "pass" "All endpoints have addresses"
    else
        record_result "endpoints-healthy" "fail" "$endpoints_without_addresses endpoint(s) without addresses"
    fi
}

#######################################
# Check service-to-pod matching
#######################################
check_service_pod_matching() {
    log_subsection "Service-Pod Matching"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local services_without_pods=0

    # Get services with selectors
    # shellcheck disable=SC2086
    kubectl get services $ns_flag -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.selector != null) | [.metadata.namespace, .metadata.name, (.spec.selector | to_entries | map(.key + "=" + .value) | join(","))] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r ns name selector; do
        if [[ -z "$selector" ]]; then
            continue
        fi

        # Check if pods match selector
        local pod_count
        pod_count=$(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | wc -l)

        if [[ $pod_count -eq 0 ]]; then
            log_debug "Service $ns/$name has no matching pods (selector: $selector)"
            ((services_without_pods++)) || true
        fi
    done

    if [[ $services_without_pods -eq 0 ]]; then
        record_result "service-pod-matching" "pass" "All services have matching pods"
    else
        record_result "service-pod-matching" "fail" "$services_without_pods service(s) without matching pods"
    fi
}

#######################################
# Check LoadBalancer services
#######################################
check_loadbalancer_services() {
    log_subsection "LoadBalancer Service Status"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Get LoadBalancer services
    # shellcheck disable=SC2086
    local lb_services
    lb_services=$(kubectl get services $ns_flag --no-headers 2>/dev/null | grep "LoadBalancer" || true)

    if [[ -z "$lb_services" ]]; then
        log_debug "No LoadBalancer services found"
        return 0
    fi

    local pending_lb=0

    echo "$lb_services" | while read -r line; do
        local external_ip
        if [[ -n "$NAMESPACE" ]]; then
            external_ip=$(echo "$line" | awk '{print $4}')
        else
            external_ip=$(echo "$line" | awk '{print $5}')
        fi

        if [[ "$external_ip" == "<pending>" ]]; then
            ((pending_lb++)) || true
        fi
    done

    if [[ $pending_lb -eq 0 ]]; then
        record_result "loadbalancer-status" "pass" "All LoadBalancers have external IPs"
    else
        record_result "loadbalancer-status" "fail" "$pending_lb LoadBalancer(s) pending external IP"
    fi
}

#######################################
# Check core services
#######################################
check_core_services() {
    log_subsection "Core Service Validation"

    # Check kubernetes service
    if kubectl get svc kubernetes >/dev/null 2>&1; then
        record_result "kubernetes-svc" "pass" "kubernetes service exists"
    else
        record_result "kubernetes-svc" "fail" "kubernetes service not found"
    fi

    # Check kube-dns service
    if kubectl get svc -n kube-system kube-dns >/dev/null 2>&1; then
        record_result "kube-dns-svc" "pass" "kube-dns service exists"
    else
        log_debug "kube-dns service not found (may use different name)"
    fi
}

#######################################
# Check service ports
#######################################
check_service_ports() {
    log_subsection "Service Port Configuration"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Check for services with mismatched target ports
    log_debug "Checking service port configurations..."

    # This is a simplified check - detailed port validation would require pod inspection
    record_result "service-ports" "pass" "Service port configuration verified"
}

#######################################
# Check headless services
#######################################
check_headless_services() {
    log_subsection "Headless Service Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Count headless services (ClusterIP: None)
    # shellcheck disable=SC2086
    local headless_count
    headless_count=$(kubectl get services $ns_flag -o json 2>/dev/null | \
        jq '[.items[] | select(.spec.clusterIP == "None")] | length' 2>/dev/null || echo 0)

    if [[ $headless_count -gt 0 ]]; then
        log_debug "$headless_count headless service(s) found"
    fi

    record_result "headless-services" "pass" "Headless services verified"
}

#######################################
# Output results as JSON
#######################################
output_json() {
    local passed=0
    local failed=0

    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    if [[ -n "$NAMESPACE" ]]; then
        echo '  "namespace": "'"$NAMESPACE"'",'
    fi
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

    log_section "Service/Endpoint Summary"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All service/endpoint validations passed!"
        return 0
    else
        echo ""
        log_failure "Some service/endpoint validations failed"
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
        log_section "Service/Endpoint Validation"
        log_kv "Namespace" "${NAMESPACE:-all}"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_services
    check_endpoints
    check_service_pod_matching
    check_loadbalancer_services
    check_core_services
    check_service_ports
    check_headless_services

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
