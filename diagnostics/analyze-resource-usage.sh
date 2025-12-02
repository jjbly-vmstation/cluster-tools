#!/usr/bin/env bash
# Script: analyze-resource-usage.sh
# Purpose: Analyze cluster resource utilization
# Usage: ./analyze-resource-usage.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -n, --namespace Specific namespace (default: all)
#   --json         JSON output

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"
NAMESPACE="${NAMESPACE:-}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Analyze cluster resource utilization including:
  - Node CPU and memory usage
  - Pod resource consumption
  - Namespace resource allocation
  - Resource quotas and limits
  - Top resource consumers

Options:
  -n, --namespace NS  Check specific namespace (default: all)
  -v, --verbose       Enable verbose output
  --json              Output results as JSON
  -h, --help          Show this help message

Examples:
  $(basename "$0")                   # Analyze all namespaces
  $(basename "$0") -n monitoring     # Analyze specific namespace
  $(basename "$0") --json            # Output results as JSON

Exit Codes:
  0 - Analysis completed successfully
  1 - Analysis completed with warnings
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
# Analyze node resources
#######################################
analyze_node_resources() {
    log_subsection "Node Resource Analysis"

    # Check if metrics are available
    local node_metrics
    node_metrics=$(kubectl top nodes --no-headers 2>/dev/null || true)

    if [[ -z "$node_metrics" ]]; then
        log_warn "Node metrics not available (metrics-server may not be installed)"
        return 0
    fi

    echo ""
    echo "Node Resource Usage:"
    echo "===================="
    kubectl top nodes 2>/dev/null || true
    echo ""

    # Calculate total and used resources
    local total_cpu_percent=0
    local total_mem_percent=0
    local node_count=0

    echo "$node_metrics" | while read -r name cpu cpu_percent mem mem_percent; do
        # Extract numeric percentage
        local cpu_num="${cpu_percent//%/}"
        local mem_num="${mem_percent//%/}"

        log_debug "Node $name: CPU=$cpu_num%, MEM=$mem_num%"

        ((total_cpu_percent += cpu_num)) || true
        ((total_mem_percent += mem_num)) || true
        ((node_count++)) || true
    done

    if [[ $node_count -gt 0 ]]; then
        local avg_cpu=$((total_cpu_percent / node_count))
        local avg_mem=$((total_mem_percent / node_count))
        log_info "Average CPU usage: ${avg_cpu}%"
        log_info "Average Memory usage: ${avg_mem}%"
    fi
}

#######################################
# Analyze pod resources
#######################################
analyze_pod_resources() {
    log_subsection "Pod Resource Analysis"

    local ns_flag
    ns_flag=$(get_ns_flag)

    # Check if metrics are available
    # shellcheck disable=SC2086
    local pod_metrics
    pod_metrics=$(kubectl top pods $ns_flag --no-headers 2>/dev/null || true)

    if [[ -z "$pod_metrics" ]]; then
        log_warn "Pod metrics not available"
        return 0
    fi

    echo ""
    echo "Top 10 CPU Consuming Pods:"
    echo "=========================="
    # shellcheck disable=SC2086
    kubectl top pods $ns_flag --sort-by=cpu 2>/dev/null | head -11 || true
    echo ""

    echo "Top 10 Memory Consuming Pods:"
    echo "============================="
    # shellcheck disable=SC2086
    kubectl top pods $ns_flag --sort-by=memory 2>/dev/null | head -11 || true
    echo ""
}

#######################################
# Analyze namespace resources
#######################################
analyze_namespace_resources() {
    log_subsection "Namespace Resource Analysis"

    if [[ -n "$NAMESPACE" ]]; then
        log_debug "Analyzing specific namespace: $NAMESPACE"
        return 0
    fi

    echo ""
    echo "Resource Usage by Namespace:"
    echo "============================"

    local namespaces
    namespaces=$(kubectl get namespaces --no-headers 2>/dev/null | awk '{print $1}')

    echo "$namespaces" | while read -r ns; do
        if [[ -z "$ns" ]]; then
            continue
        fi

        local pod_count
        pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)

        local running_count
        running_count=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

        # Get resource usage if metrics available
        local ns_metrics
        ns_metrics=$(kubectl top pods -n "$ns" --no-headers 2>/dev/null || true)

        if [[ -n "$ns_metrics" ]]; then
            # Sum up resources (simplified)
            local total_cpu=0
            local total_mem=0

            echo "$ns_metrics" | while read -r name cpu mem; do
                # Extract numeric values
                local cpu_num="${cpu//[^0-9]/}"
                local mem_num="${mem//[^0-9]/}"

                ((total_cpu += cpu_num)) || true
                ((total_mem += mem_num)) || true
            done

            # These would be used for more detailed reporting
            log_debug "  Namespace $ns: CPU=${total_cpu}m, MEM=${total_mem}Mi"
        fi

        printf "  %-30s Pods: %d/%d\n" "$ns" "$running_count" "$pod_count"
    done

    echo ""
}

#######################################
# Analyze resource quotas
#######################################
analyze_resource_quotas() {
    log_subsection "Resource Quota Analysis"

    local ns_flag
    ns_flag=$(get_ns_flag)

    echo ""
    echo "Resource Quotas:"
    echo "================"
    # shellcheck disable=SC2086
    kubectl get resourcequotas $ns_flag 2>/dev/null || echo "No resource quotas defined"
    echo ""

    # Show detailed quota usage
    # shellcheck disable=SC2086
    local quotas
    quotas=$(kubectl get resourcequotas $ns_flag --no-headers 2>/dev/null | awk '{print $1"/"$2}' || true)

    if [[ -n "$quotas" ]]; then
        echo "Quota Usage Details:"
        echo "-------------------"
        echo "$quotas" | while read -r ns_quota; do
            local ns="${ns_quota%/*}"
            local quota="${ns_quota#*/}"

            if [[ -n "$quota" ]]; then
                log_debug "Quota: $ns/$quota"
                kubectl describe resourcequota -n "$ns" "$quota" 2>/dev/null | grep -A 100 "Resource" | head -20 || true
                echo ""
            fi
        done
    fi
}

#######################################
# Analyze limit ranges
#######################################
analyze_limit_ranges() {
    log_subsection "Limit Range Analysis"

    local ns_flag
    ns_flag=$(get_ns_flag)

    echo ""
    echo "Limit Ranges:"
    echo "============="
    # shellcheck disable=SC2086
    kubectl get limitranges $ns_flag 2>/dev/null || echo "No limit ranges defined"
    echo ""
}

#######################################
# Analyze pods without resource limits
#######################################
analyze_pods_without_limits() {
    log_subsection "Pods Without Resource Limits"

    local ns_flag
    ns_flag=$(get_ns_flag)

    echo ""
    echo "Pods Without CPU Limits:"
    echo "========================"

    # shellcheck disable=SC2086
    local pods_no_cpu
    pods_no_cpu=$(kubectl get pods $ns_flag -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.containers[].resources.limits.cpu == null) | [.metadata.namespace, .metadata.name] | @tsv' 2>/dev/null | wc -l || echo 0)

    echo "Count: $pods_no_cpu"
    echo ""

    echo "Pods Without Memory Limits:"
    echo "==========================="

    # shellcheck disable=SC2086
    local pods_no_mem
    pods_no_mem=$(kubectl get pods $ns_flag -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.containers[].resources.limits.memory == null) | [.metadata.namespace, .metadata.name] | @tsv' 2>/dev/null | wc -l || echo 0)

    echo "Count: $pods_no_mem"
    echo ""
}

#######################################
# Analyze PVC storage usage
#######################################
analyze_storage_usage() {
    log_subsection "Storage Usage Analysis"

    local ns_flag
    ns_flag=$(get_ns_flag)

    echo ""
    echo "PersistentVolumeClaim Usage:"
    echo "============================"
    # shellcheck disable=SC2086
    kubectl get pvc $ns_flag 2>/dev/null || echo "No PVCs found"
    echo ""

    # Show PV usage
    echo "PersistentVolume Status:"
    echo "========================"
    kubectl get pv 2>/dev/null || echo "No PVs found"
    echo ""
}

#######################################
# Generate JSON output
#######################################
output_json() {
    echo "{"
    echo '  "timestamp": "'"$(date -Iseconds)"'",'

    # Node metrics
    echo '  "nodes": ['
    local first=true
    kubectl top nodes --no-headers 2>/dev/null | while read -r name cpu cpu_percent mem mem_percent; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo -n "    {\"name\": \"$name\", \"cpu\": \"$cpu\", \"cpu_percent\": \"$cpu_percent\", \"memory\": \"$mem\", \"memory_percent\": \"$mem_percent\"}"
    done
    echo ""
    echo "  ],"

    # Summary stats
    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    local total_pods
    if [[ -n "$NAMESPACE" ]]; then
        total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    else
        total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
    fi

    echo '  "summary": {'
    echo "    \"total_nodes\": $total_nodes,"
    echo "    \"total_pods\": $total_pods"
    echo "  }"
    echo "}"
}

#######################################
# Generate summary
#######################################
generate_summary() {
    log_section "Resource Usage Summary"

    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    local total_pods
    if [[ -n "$NAMESPACE" ]]; then
        total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    else
        total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
    fi

    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Total Nodes" "$total_nodes"
    log_kv "Total Pods" "$total_pods"

    # Check for metrics availability
    if kubectl top nodes >/dev/null 2>&1; then
        log_kv "Metrics" "Available"
    else
        log_kv "Metrics" "Not available (install metrics-server)"
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

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
        exit 0
    fi

    log_section "Resource Usage Analysis"
    log_kv "Namespace" "${NAMESPACE:-all}"
    log_kv "Timestamp" "$(date -Iseconds)"

    # Run all analysis
    analyze_node_resources
    analyze_pod_resources
    analyze_namespace_resources
    analyze_resource_quotas
    analyze_limit_ranges
    analyze_pods_without_limits
    analyze_storage_usage

    # Generate summary
    generate_summary
}

main "$@"
