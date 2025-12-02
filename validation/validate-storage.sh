#!/usr/bin/env bash
# Script: validate-storage.sh
# Purpose: Validate storage configuration (PV, PVC, StorageClass)
# Usage: ./validate-storage.sh [options]
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

# Validation results
declare -A RESULTS

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate Kubernetes storage configuration including:
  - StorageClass availability
  - PersistentVolume status
  - PersistentVolumeClaim bindings
  - CSI drivers

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show this help message

Examples:
  $(basename "$0")          # Basic storage validation
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
# Check StorageClasses
#######################################
check_storage_classes() {
    log_subsection "StorageClass Validation"

    local sc_count
    sc_count=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l)

    if [[ $sc_count -eq 0 ]]; then
        record_result "storage-classes" "fail" "No StorageClasses configured"
        return 1
    fi

    record_result "storage-classes" "pass" "$sc_count StorageClass(es) available"

    # Check for default StorageClass
    local default_sc
    default_sc=$(kubectl get storageclasses -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)

    if [[ -n "$default_sc" ]]; then
        record_result "default-storage-class" "pass" "Default: $default_sc"
    else
        log_debug "No default StorageClass configured"
    fi

    # List all StorageClasses
    log_debug "Available StorageClasses:"
    kubectl get storageclasses --no-headers 2>/dev/null | while read -r line; do
        log_debug "  $line"
    done
}

#######################################
# Check PersistentVolumes
#######################################
check_persistent_volumes() {
    log_subsection "PersistentVolume Validation"

    local pv_count
    pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l)

    if [[ $pv_count -eq 0 ]]; then
        log_debug "No PersistentVolumes found (may be using dynamic provisioning)"
        return 0
    fi

    record_result "pv-count" "pass" "$pv_count PersistentVolume(s) found"

    # Check for problematic PV states
    local failed_pvs
    failed_pvs=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Failed" || echo 0)

    if [[ $failed_pvs -gt 0 ]]; then
        record_result "pv-failed" "fail" "$failed_pvs PV(s) in Failed state"
    fi

    local released_pvs
    released_pvs=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Released" || echo 0)

    if [[ $released_pvs -gt 0 ]]; then
        log_debug "$released_pvs PV(s) in Released state (may need cleanup)"
    fi
}

#######################################
# Check PersistentVolumeClaims
#######################################
check_persistent_volume_claims() {
    log_subsection "PersistentVolumeClaim Validation"

    local pvc_total
    pvc_total=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)

    if [[ $pvc_total -eq 0 ]]; then
        log_debug "No PersistentVolumeClaims found"
        return 0
    fi

    local pvc_bound
    pvc_bound=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Bound" || echo 0)

    local pvc_pending
    pvc_pending=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Pending" || echo 0)

    if [[ $pvc_pending -gt 0 ]]; then
        record_result "pvc-pending" "fail" "$pvc_pending PVC(s) in Pending state"

        # List pending PVCs
        log_debug "Pending PVCs:"
        kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep "Pending" | while read -r line; do
            log_debug "  $line"
        done
    else
        record_result "pvc-status" "pass" "$pvc_bound/$pvc_total PVC(s) Bound"
    fi

    local pvc_lost
    pvc_lost=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Lost" || echo 0)

    if [[ $pvc_lost -gt 0 ]]; then
        record_result "pvc-lost" "fail" "$pvc_lost PVC(s) in Lost state"
    fi
}

#######################################
# Check CSI Drivers
#######################################
check_csi_drivers() {
    log_subsection "CSI Driver Validation"

    local csi_drivers
    csi_drivers=$(kubectl get csidrivers --no-headers 2>/dev/null | wc -l)

    if [[ $csi_drivers -eq 0 ]]; then
        log_debug "No CSI drivers found (may be using in-tree drivers)"
        return 0
    fi

    record_result "csi-drivers" "pass" "$csi_drivers CSI driver(s) installed"

    # List CSI drivers
    log_debug "CSI Drivers:"
    kubectl get csidrivers --no-headers 2>/dev/null | while read -r line; do
        log_debug "  $line"
    done
}

#######################################
# Check VolumeSnapshotClasses
#######################################
check_volume_snapshots() {
    log_subsection "Volume Snapshot Validation"

    # Check for VolumeSnapshotClasses
    local vsc_count
    vsc_count=$(kubectl get volumesnapshotclasses --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ $vsc_count -gt 0 ]]; then
        record_result "volume-snapshot-classes" "pass" "$vsc_count VolumeSnapshotClass(es) available"
    else
        log_debug "No VolumeSnapshotClasses found (snapshots may not be configured)"
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

    log_section "Storage Validation Summary"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All storage validations passed!"
        return 0
    else
        echo ""
        log_failure "Some storage validations failed"
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
        log_section "Storage Validation"
        log_kv "Timestamp" "$(date -Iseconds)"
    fi

    # Run all checks
    check_storage_classes
    check_persistent_volumes
    check_persistent_volume_claims
    check_csi_drivers
    check_volume_snapshots

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
