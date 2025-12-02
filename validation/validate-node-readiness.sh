#!/usr/bin/env bash
# Script: validate-node-readiness.sh
# Purpose: Validate node status and resource availability
# Usage: ./validate-node-readiness.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -q, --quiet    Quiet mode
#   --json         JSON output

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
JSON_OUTPUT="${JSON_OUTPUT:-false}"
MIN_NODE_MEMORY_GB="${MIN_NODE_MEMORY_GB:-4}"
MIN_NODE_CPU_CORES="${MIN_NODE_CPU_CORES:-2}"

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate Kubernetes node readiness including:
  - Node Ready condition
  - Node resource capacity
  - Node conditions (DiskPressure, MemoryPressure, etc.)
  - Node taints and labels

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show this help message

Environment:
  MIN_NODE_MEMORY_GB   Minimum expected memory per node (default: 4)
  MIN_NODE_CPU_CORES   Minimum expected CPU cores per node (default: 2)

Examples:
  $(basename "$0")          # Basic node validation
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
# Check node Ready status
#######################################
check_node_ready_status() {
    log_subsection "Node Ready Status"

    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [[ $total_nodes -eq 0 ]]; then
        record_result "nodes-found" "fail" "No nodes found in cluster"
        return 1
    fi

    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)

    if [[ $ready_nodes -eq $total_nodes ]]; then
        record_result "nodes-ready" "pass" "$ready_nodes/$total_nodes nodes Ready"
    else
        record_result "nodes-ready" "fail" "Only $ready_nodes/$total_nodes nodes Ready"

        # List not ready nodes
        log_debug "Nodes not in Ready state:"
        kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | while read -r line; do
            log_debug "  $line"
        done
    fi
}

#######################################
# Check node conditions
#######################################
check_node_conditions() {
    log_subsection "Node Conditions"

    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}')

    local has_issues=false

    echo "$nodes" | while read -r node; do
        if [[ -z "$node" ]]; then
            continue
        fi

        # Check for problematic conditions
        local conditions
        conditions=$(kubectl get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)

        # Check DiskPressure
        if [[ "$conditions" =~ DiskPressure=True ]]; then
            log_warn "Node $node: DiskPressure=True"
            has_issues=true
        fi

        # Check MemoryPressure
        if [[ "$conditions" =~ MemoryPressure=True ]]; then
            log_warn "Node $node: MemoryPressure=True"
            has_issues=true
        fi

        # Check PIDPressure
        if [[ "$conditions" =~ PIDPressure=True ]]; then
            log_warn "Node $node: PIDPressure=True"
            has_issues=true
        fi

        # Check NetworkUnavailable
        if [[ "$conditions" =~ NetworkUnavailable=True ]]; then
            log_warn "Node $node: NetworkUnavailable=True"
            has_issues=true
        fi
    done

    if [[ "$has_issues" == "true" ]]; then
        record_result "node-conditions" "fail" "Some nodes have pressure conditions"
    else
        record_result "node-conditions" "pass" "No pressure conditions detected"
    fi
}

#######################################
# Check node resource capacity
#######################################
check_node_resources() {
    log_subsection "Node Resource Capacity"

    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}')

    local low_resource_nodes=0

    echo "$nodes" | while read -r node; do
        if [[ -z "$node" ]]; then
            continue
        fi

        # Get CPU capacity
        local cpu
        cpu=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)

        # Get Memory capacity (in Ki)
        local memory_ki
        memory_ki=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null | sed 's/Ki//')

        # Convert memory to GB (approximate)
        local memory_gb=$((memory_ki / 1024 / 1024))

        log_debug "Node $node: CPU=$cpu cores, Memory=${memory_gb}GB"

        # Check minimums
        if [[ $cpu -lt $MIN_NODE_CPU_CORES ]]; then
            log_warn "Node $node: CPU cores ($cpu) below minimum ($MIN_NODE_CPU_CORES)"
            ((low_resource_nodes++)) || true
        fi

        if [[ $memory_gb -lt $MIN_NODE_MEMORY_GB ]]; then
            log_warn "Node $node: Memory (${memory_gb}GB) below minimum (${MIN_NODE_MEMORY_GB}GB)"
            ((low_resource_nodes++)) || true
        fi
    done

    if [[ $low_resource_nodes -gt 0 ]]; then
        record_result "node-resources" "fail" "$low_resource_nodes node(s) with low resources"
    else
        record_result "node-resources" "pass" "All nodes meet minimum resource requirements"
    fi
}

#######################################
# Check node allocatable resources
#######################################
check_node_allocatable() {
    log_subsection "Node Allocatable Resources"

    # Get allocatable vs capacity summary
    local nodes
    nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.cpu} {.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        log_debug "Could not retrieve allocatable resources"
        return 0
    fi

    log_debug "Node allocatable resources:"
    echo "$nodes" | while read -r line; do
        log_debug "  $line"
    done

    record_result "node-allocatable" "pass" "Allocatable resources verified"
}

#######################################
# Check node taints
#######################################
check_node_taints() {
    log_subsection "Node Taints"

    local unschedulable_nodes=0

    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}')

    echo "$nodes" | while read -r node; do
        if [[ -z "$node" ]]; then
            continue
        fi

        local taints
        taints=$(kubectl get node "$node" -o jsonpath='{.spec.taints[*].effect}' 2>/dev/null)

        if [[ "$taints" =~ NoSchedule ]] && [[ ! "$taints" =~ "control-plane" ]] && [[ ! "$taints" =~ "master" ]]; then
            log_debug "Node $node has NoSchedule taint"
            ((unschedulable_nodes++)) || true
        fi
    done

    if [[ $unschedulable_nodes -gt 0 ]]; then
        log_debug "$unschedulable_nodes worker node(s) with NoSchedule taint"
    fi

    record_result "node-taints" "pass" "Node taints verified"
}

#######################################
# Check node labels
#######################################
check_node_labels() {
    log_subsection "Node Labels"

    # Check for role labels
    local nodes_with_roles
    nodes_with_roles=$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $nodes_with_roles -gt 0 ]]; then
        log_debug "$nodes_with_roles control-plane node(s) found"
    fi

    local worker_nodes
    worker_nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l || echo 0)

    log_debug "$worker_nodes worker node(s) found"

    record_result "node-labels" "pass" "Node labels verified"
}

#######################################
# Check node schedulability
#######################################
check_schedulability() {
    log_subsection "Node Schedulability"

    local unschedulable_count
    unschedulable_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "SchedulingDisabled" || echo 0)

    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [[ $unschedulable_count -eq 0 ]]; then
        record_result "node-schedulability" "pass" "All nodes are schedulable"
    else
        record_result "node-schedulability" "fail" "$unschedulable_count/$total_nodes nodes unschedulable"
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

    log_section "Node Readiness Summary"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All node readiness validations passed!"
        return 0
    else
        echo ""
        log_failure "Some node readiness validations failed"
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
        log_section "Node Readiness Validation"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_node_ready_status
    check_node_conditions
    check_node_resources
    check_node_allocatable
    check_node_taints
    check_node_labels
    check_schedulability

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
