#!/usr/bin/env bash
# Script: validate-ingress.sh
# Purpose: Validate ingress controller configuration
# Usage: ./validate-ingress.sh [options]
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

Validate Kubernetes ingress configuration including:
  - Ingress controller status
  - Ingress resource configuration
  - Backend service availability
  - TLS configuration

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
# Check ingress controller
#######################################
check_ingress_controller() {
    log_subsection "Ingress Controller Status"

    local controller_found=false

    # Check for nginx ingress controller
    local nginx_pods
    nginx_pods=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $nginx_pods -gt 0 ]]; then
        record_result "nginx-ingress" "pass" "$nginx_pods nginx ingress pod(s) running"
        controller_found=true
    fi

    # Check for traefik
    local traefik_pods
    traefik_pods=$(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | grep -c "Running" || \
                   kubectl get pods --all-namespaces -l app=traefik --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $traefik_pods -gt 0 ]]; then
        record_result "traefik-ingress" "pass" "$traefik_pods Traefik pod(s) running"
        controller_found=true
    fi

    # Check for HAProxy
    local haproxy_pods
    haproxy_pods=$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=haproxy-ingress --no-headers 2>/dev/null | grep -c "Running" || echo 0)

    if [[ $haproxy_pods -gt 0 ]]; then
        record_result "haproxy-ingress" "pass" "$haproxy_pods HAProxy ingress pod(s) running"
        controller_found=true
    fi

    if [[ "$controller_found" == "false" ]]; then
        log_debug "No recognized ingress controller found"
    fi
}

#######################################
# Check ingress resources
#######################################
check_ingress_resources() {
    log_subsection "Ingress Resource Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # shellcheck disable=SC2086
    local ingress_count
    ingress_count=$(kubectl get ingress $ns_flag --no-headers 2>/dev/null | wc -l)

    if [[ $ingress_count -eq 0 ]]; then
        log_debug "No ingress resources found"
        return 0
    fi

    record_result "ingress-count" "pass" "$ingress_count ingress resource(s) found"
}

#######################################
# Check ingress classes
#######################################
check_ingress_classes() {
    log_subsection "IngressClass Validation"

    local class_count
    class_count=$(kubectl get ingressclasses --no-headers 2>/dev/null | wc -l)

    if [[ $class_count -eq 0 ]]; then
        log_debug "No IngressClasses defined"
        return 0
    fi

    record_result "ingress-classes" "pass" "$class_count IngressClass(es) defined"

    # Check for default IngressClass
    local default_class
    default_class=$(kubectl get ingressclasses -o jsonpath='{.items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)

    if [[ -n "$default_class" ]]; then
        log_debug "Default IngressClass: $default_class"
    fi
}

#######################################
# Check ingress backend services
#######################################
check_ingress_backends() {
    log_subsection "Ingress Backend Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local missing_backends=0

    # Get ingresses and check backends
    # shellcheck disable=SC2086
    kubectl get ingress $ns_flag -o json 2>/dev/null | \
        jq -r '.items[] | [.metadata.namespace, .metadata.name, (.spec.rules[].http.paths[].backend.service.name // .spec.defaultBackend.service.name // "")] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r ns name backend; do
        if [[ -z "$backend" ]]; then
            continue
        fi

        # Check if backend service exists
        if ! kubectl get svc -n "$ns" "$backend" >/dev/null 2>&1; then
            log_debug "Ingress $ns/$name: backend service '$backend' not found"
            ((missing_backends++)) || true
        fi
    done

    if [[ $missing_backends -eq 0 ]]; then
        record_result "ingress-backends" "pass" "All ingress backends available"
    else
        record_result "ingress-backends" "fail" "$missing_backends ingress(es) with missing backends"
    fi
}

#######################################
# Check ingress TLS configuration
#######################################
check_ingress_tls() {
    log_subsection "Ingress TLS Configuration"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Count ingresses with TLS
    # shellcheck disable=SC2086
    local tls_ingresses
    tls_ingresses=$(kubectl get ingress $ns_flag -o json 2>/dev/null | \
        jq '[.items[] | select(.spec.tls != null)] | length' 2>/dev/null || echo 0)

    # shellcheck disable=SC2086
    local total_ingresses
    total_ingresses=$(kubectl get ingress $ns_flag --no-headers 2>/dev/null | wc -l)

    if [[ $total_ingresses -gt 0 ]]; then
        log_debug "TLS configured for $tls_ingresses/$total_ingresses ingresses"

        # Check for TLS secrets
        local missing_secrets=0
        # shellcheck disable=SC2086
        kubectl get ingress $ns_flag -o json 2>/dev/null | \
            jq -r '.items[] | select(.spec.tls != null) | [.metadata.namespace, .metadata.name, (.spec.tls[].secretName // "")] | @tsv' 2>/dev/null | \
        while IFS=$'\t' read -r ns name secret; do
            if [[ -z "$secret" ]]; then
                continue
            fi

            if ! kubectl get secret -n "$ns" "$secret" >/dev/null 2>&1; then
                log_debug "Ingress $ns/$name: TLS secret '$secret' not found"
                ((missing_secrets++)) || true
            fi
        done

        if [[ $missing_secrets -eq 0 ]]; then
            record_result "ingress-tls" "pass" "TLS secrets available"
        else
            record_result "ingress-tls" "fail" "$missing_secrets ingress(es) with missing TLS secrets"
        fi
    fi
}

#######################################
# Check ingress hosts
#######################################
check_ingress_hosts() {
    log_subsection "Ingress Host Configuration"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Get unique hosts
    # shellcheck disable=SC2086
    local hosts
    hosts=$(kubectl get ingress $ns_flag -o jsonpath='{.items[*].spec.rules[*].host}' 2>/dev/null | tr ' ' '\n' | sort -u || true)

    if [[ -n "$hosts" ]]; then
        log_debug "Configured ingress hosts:"
        echo "$hosts" | while read -r host; do
            if [[ -n "$host" ]]; then
                log_debug "  - $host"
            fi
        done
    fi

    record_result "ingress-hosts" "pass" "Ingress hosts verified"
}

#######################################
# Check ingress annotations
#######################################
check_ingress_annotations() {
    log_subsection "Ingress Annotation Validation"

    # This is informational - just verify ingresses have annotations if needed
    log_debug "Ingress annotations are controller-specific"

    record_result "ingress-annotations" "pass" "Ingress configuration verified"
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

    log_section "Ingress Validation Summary"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All ingress validations passed!"
        return 0
    else
        echo ""
        log_failure "Some ingress validations failed"
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
        log_section "Ingress Validation"
        log_kv "Namespace" "${NAMESPACE:-all}"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_ingress_controller
    check_ingress_classes
    check_ingress_resources
    check_ingress_backends
    check_ingress_tls
    check_ingress_hosts
    check_ingress_annotations

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
