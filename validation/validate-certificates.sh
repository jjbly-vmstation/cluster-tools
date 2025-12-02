#!/usr/bin/env bash
# Script: validate-certificates.sh
# Purpose: Validate TLS certificate configuration
# Usage: ./validate-certificates.sh [options]
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
CERT_EXPIRY_WARNING_DAYS="${CERT_EXPIRY_WARNING_DAYS:-30}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate TLS certificate configuration including:
  - TLS secrets
  - Certificate expiration
  - cert-manager resources
  - Certificate issuers

Options:
  -n, --namespace NS  Check specific namespace (default: all)
  -v, --verbose       Enable verbose output
  -q, --quiet         Suppress non-error output
  --json              Output results as JSON
  -h, --help          Show this help message

Environment:
  CERT_EXPIRY_WARNING_DAYS  Days before expiry to warn (default: 30)

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
# Check TLS secrets
#######################################
check_tls_secrets() {
    log_subsection "TLS Secret Validation"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Count TLS type secrets
    # shellcheck disable=SC2086
    local tls_secrets
    tls_secrets=$(kubectl get secrets $ns_flag --field-selector type=kubernetes.io/tls --no-headers 2>/dev/null | wc -l)

    if [[ $tls_secrets -eq 0 ]]; then
        log_debug "No TLS secrets found"
        return 0
    fi

    record_result "tls-secrets" "pass" "$tls_secrets TLS secret(s) found"
}

#######################################
# Check certificate expiration
#######################################
check_certificate_expiration() {
    log_subsection "Certificate Expiration Check"

    local ns_flag
    ns_flag=$(get_ns_flag)

    local expiring_soon=0
    local expired=0

    # Get all TLS secrets and check expiration
    # shellcheck disable=SC2086
    kubectl get secrets $ns_flag --field-selector type=kubernetes.io/tls -o json 2>/dev/null | \
        jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r ns name; do
        if [[ -z "$name" ]]; then
            continue
        fi

        # Get certificate data and decode
        local cert_data
        cert_data=$(kubectl get secret -n "$ns" "$name" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)

        if [[ -z "$cert_data" ]]; then
            log_debug "Could not decode certificate for $ns/$name"
            continue
        fi

        # Get expiration date
        local expiry_date
        expiry_date=$(echo "$cert_data" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)

        if [[ -z "$expiry_date" ]]; then
            log_debug "Could not get expiry for $ns/$name"
            continue
        fi

        # Convert to epoch and compare
        local expiry_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)

        local now_epoch
        now_epoch=$(date +%s)

        local days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ $days_until_expiry -lt 0 ]]; then
            log_warn "Certificate $ns/$name has EXPIRED"
            ((expired++)) || true
        elif [[ $days_until_expiry -lt $CERT_EXPIRY_WARNING_DAYS ]]; then
            log_warn "Certificate $ns/$name expires in $days_until_expiry days"
            ((expiring_soon++)) || true
        else
            log_debug "Certificate $ns/$name valid for $days_until_expiry days"
        fi
    done

    if [[ $expired -gt 0 ]]; then
        record_result "cert-expiration" "fail" "$expired expired certificate(s)"
    elif [[ $expiring_soon -gt 0 ]]; then
        record_result "cert-expiration" "fail" "$expiring_soon certificate(s) expiring within $CERT_EXPIRY_WARNING_DAYS days"
    else
        record_result "cert-expiration" "pass" "No certificates near expiration"
    fi
}

#######################################
# Check cert-manager installation
#######################################
check_cert_manager() {
    log_subsection "cert-manager Status"

    # Check for cert-manager namespace
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        # Check cert-manager pods
        local cm_pods
        cm_pods=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "Running" || echo 0)

        if [[ $cm_pods -gt 0 ]]; then
            record_result "cert-manager" "pass" "$cm_pods cert-manager pod(s) running"
        else
            record_result "cert-manager" "fail" "cert-manager pods not running"
        fi
    else
        log_debug "cert-manager not installed"
    fi
}

#######################################
# Check cert-manager certificates
#######################################
check_cert_manager_certs() {
    log_subsection "cert-manager Certificate Resources"

    # Check if Certificate CRD exists
    if ! kubectl api-resources | grep -q "certificates.cert-manager.io"; then
        log_debug "cert-manager CRDs not installed"
        return 0
    fi

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Get certificate resources
    # shellcheck disable=SC2086
    local cert_count
    cert_count=$(kubectl get certificates $ns_flag --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $cert_count -eq 0 ]]; then
        log_debug "No Certificate resources found"
        return 0
    fi

    # Check for not ready certificates
    # shellcheck disable=SC2086
    local not_ready
    not_ready=$(kubectl get certificates $ns_flag -o json 2>/dev/null | \
        jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True"))] | length' 2>/dev/null || echo 0)

    if [[ $not_ready -gt 0 ]]; then
        record_result "cm-certificates" "fail" "$not_ready Certificate(s) not ready"
    else
        record_result "cm-certificates" "pass" "$cert_count Certificate(s) ready"
    fi
}

#######################################
# Check certificate issuers
#######################################
check_certificate_issuers() {
    log_subsection "Certificate Issuer Validation"

    # Check if Issuer CRD exists
    if ! kubectl api-resources | grep -q "issuers.cert-manager.io"; then
        log_debug "cert-manager Issuer CRD not installed"
        return 0
    fi

    # Check ClusterIssuers
    local cluster_issuers
    cluster_issuers=$(kubectl get clusterissuers --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $cluster_issuers -gt 0 ]]; then
        # Check ready status
        local ready_issuers
        ready_issuers=$(kubectl get clusterissuers -o json 2>/dev/null | \
            jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)

        if [[ $ready_issuers -eq $cluster_issuers ]]; then
            record_result "cluster-issuers" "pass" "$cluster_issuers ClusterIssuer(s) ready"
        else
            record_result "cluster-issuers" "fail" "Only $ready_issuers/$cluster_issuers ClusterIssuer(s) ready"
        fi
    fi

    # Check namespace-scoped Issuers
    local ns_flag
    ns_flag=$(get_ns_flag)

    # shellcheck disable=SC2086
    local ns_issuers
    ns_issuers=$(kubectl get issuers $ns_flag --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $ns_issuers -gt 0 ]]; then
        log_debug "$ns_issuers namespace Issuer(s) found"
    fi
}

#######################################
# Check certificate challenges
#######################################
check_certificate_challenges() {
    log_subsection "Certificate Challenge Status"

    # Check if Challenge CRD exists
    if ! kubectl api-resources | grep -q "challenges.acme.cert-manager.io"; then
        log_debug "ACME challenges CRD not available"
        return 0
    fi

    # Check for pending challenges
    local pending_challenges
    pending_challenges=$(kubectl get challenges --all-namespaces --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $pending_challenges -gt 0 ]]; then
        log_debug "$pending_challenges pending ACME challenge(s)"
        record_result "acme-challenges" "fail" "$pending_challenges pending challenge(s)"
    else
        record_result "acme-challenges" "pass" "No pending ACME challenges"
    fi
}

#######################################
# Check certificate orders
#######################################
check_certificate_orders() {
    log_subsection "Certificate Order Status"

    # Check if Order CRD exists
    if ! kubectl api-resources | grep -q "orders.acme.cert-manager.io"; then
        log_debug "ACME orders CRD not available"
        return 0
    fi

    # Check for pending orders
    local pending_orders
    pending_orders=$(kubectl get orders --all-namespaces -o json 2>/dev/null | \
        jq '[.items[] | select(.status.state != "valid")] | length' 2>/dev/null || echo 0)

    if [[ $pending_orders -gt 0 ]]; then
        log_debug "$pending_orders pending certificate order(s)"
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

    log_section "Certificate Validation Summary"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All certificate validations passed!"
        return 0
    else
        echo ""
        log_failure "Some certificate validations failed"
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
        log_section "Certificate Validation"
        log_kv "Namespace" "${NAMESPACE:-all}"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_tls_secrets
    check_certificate_expiration
    check_cert_manager
    check_cert_manager_certs
    check_certificate_issuers
    check_certificate_challenges
    check_certificate_orders

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
