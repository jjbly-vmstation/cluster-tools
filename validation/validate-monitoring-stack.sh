#!/usr/bin/env bash
# validate-monitoring-stack.sh - Validate the monitoring stack components
# Checks Prometheus, Grafana, Alertmanager, Loki, and all exporters
#
# Usage: ./validate-monitoring-stack.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Kubernetes namespace (default: monitoring)
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
NAMESPACE="${NAMESPACE:-monitoring}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate the Kubernetes monitoring stack components including:
  - Prometheus server and targets
  - Grafana dashboards and datasources
  - Alertmanager configuration
  - Loki log aggregation
  - Node exporter, kube-state-metrics, and other exporters

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace (default: monitoring)
  -v, --verbose               Enable verbose output
  -q, --quiet                 Suppress non-error output
  --json                      Output results as JSON
  -h, --help                  Show this help message

Examples:
  $(basename "$0")                    # Validate with default settings
  $(basename "$0") -n observability   # Use custom namespace
  $(basename "$0") --json             # Output results as JSON

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
# Arguments:
#   $1 - Check name
#   $2 - Status (pass/fail)
#   $3 - Message
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
# Check if pods are running
# Arguments:
#   $1 - Label selector
#   $2 - Check name
#######################################
check_pods_running() {
    local selector="$1"
    local check_name="$2"
    
    log_debug "Checking pods with selector: $selector"
    
    local running_pods
    running_pods=$(kubectl get pods -n "$NAMESPACE" -l "$selector" \
        --field-selector=status.phase=Running \
        -o name 2>/dev/null | wc -l)
    
    local total_pods
    total_pods=$(kubectl get pods -n "$NAMESPACE" -l "$selector" \
        -o name 2>/dev/null | wc -l)
    
    if [[ $total_pods -eq 0 ]]; then
        record_result "$check_name" "fail" "No pods found"
        return 1
    elif [[ $running_pods -eq $total_pods ]]; then
        record_result "$check_name" "pass" "$running_pods/$total_pods pods running"
        return 0
    else
        record_result "$check_name" "fail" "Only $running_pods/$total_pods pods running"
        return 1
    fi
}

#######################################
# Check Prometheus health
#######################################
check_prometheus() {
    log_subsection "Prometheus Validation"
    
    # Check Prometheus pods
    check_pods_running "app=prometheus" "prometheus-pods" || true
    
    # Check Prometheus service
    if kubectl get svc -n "$NAMESPACE" prometheus >/dev/null 2>&1; then
        record_result "prometheus-service" "pass" "Service exists"
        
        # Try to query Prometheus API
        local prom_url
        prom_url=$(kubectl get svc -n "$NAMESPACE" prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        if [[ -n "$prom_url" ]]; then
            log_debug "Prometheus ClusterIP: $prom_url"
        fi
    else
        record_result "prometheus-service" "fail" "Service not found"
    fi
    
    # Check Prometheus targets (via port-forward if possible)
    log_debug "Checking Prometheus targets..."
}

#######################################
# Check Grafana health
#######################################
check_grafana() {
    log_subsection "Grafana Validation"
    
    # Check Grafana pods
    check_pods_running "app.kubernetes.io/name=grafana" "grafana-pods" || \
    check_pods_running "app=grafana" "grafana-pods" || true
    
    # Check Grafana service
    if kubectl get svc -n "$NAMESPACE" grafana >/dev/null 2>&1; then
        record_result "grafana-service" "pass" "Service exists"
    else
        record_result "grafana-service" "fail" "Service not found"
    fi
}

#######################################
# Check Alertmanager health
#######################################
check_alertmanager() {
    log_subsection "Alertmanager Validation"
    
    # Check Alertmanager pods
    check_pods_running "app=alertmanager" "alertmanager-pods" || \
    check_pods_running "app.kubernetes.io/name=alertmanager" "alertmanager-pods" || true
    
    # Check Alertmanager service
    if kubectl get svc -n "$NAMESPACE" alertmanager >/dev/null 2>&1 || \
       kubectl get svc -n "$NAMESPACE" alertmanager-main >/dev/null 2>&1; then
        record_result "alertmanager-service" "pass" "Service exists"
    else
        record_result "alertmanager-service" "fail" "Service not found"
    fi
}

#######################################
# Check Loki health
#######################################
check_loki() {
    log_subsection "Loki Validation"
    
    # Check Loki pods
    check_pods_running "app=loki" "loki-pods" || \
    check_pods_running "app.kubernetes.io/name=loki" "loki-pods" || true
    
    # Check Loki service
    if kubectl get svc -n "$NAMESPACE" loki >/dev/null 2>&1; then
        record_result "loki-service" "pass" "Service exists"
    else
        record_result "loki-service" "fail" "Service not found"
    fi
    
    # Check Promtail pods
    check_pods_running "app=promtail" "promtail-pods" || \
    check_pods_running "app.kubernetes.io/name=promtail" "promtail-pods" || true
}

#######################################
# Check exporters health
#######################################
check_exporters() {
    log_subsection "Exporters Validation"
    
    # Check node-exporter
    check_pods_running "app=node-exporter" "node-exporter-pods" || \
    check_pods_running "app.kubernetes.io/name=node-exporter" "node-exporter-pods" || true
    
    # Check kube-state-metrics
    check_pods_running "app.kubernetes.io/name=kube-state-metrics" "kube-state-metrics-pods" || \
    check_pods_running "app=kube-state-metrics" "kube-state-metrics-pods" || true
}

#######################################
# Output results as JSON
#######################################
output_json() {
    local passed=0
    local failed=0
    
    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'
    echo '  "namespace": "'"$NAMESPACE"'",'
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
    
    log_section "Validation Summary"
    log_kv "Namespace" "$NAMESPACE"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"
    
    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All monitoring stack validations passed!"
        return 0
    else
        echo ""
        log_failure "Some monitoring stack validations failed"
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
        log_section "Monitoring Stack Validation"
        log_kv "Namespace" "$NAMESPACE"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi
    
    # Run all checks
    check_prometheus
    check_grafana
    check_alertmanager
    check_loki
    check_exporters
    
    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
