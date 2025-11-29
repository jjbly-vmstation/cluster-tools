#!/usr/bin/env bash
# pre-deployment-checklist.sh - Pre-deployment validation checklist
# Verifies all prerequisites before deploying to a cluster
#
# Usage: ./pre-deployment-checklist.sh [OPTIONS]
#
# Options:
#   -c, --config FILE  Path to deployment config file
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
CONFIG_FILE="${CONFIG_FILE:-}"

# Validation results
declare -A RESULTS

# Required tools
REQUIRED_TOOLS=(
    "kubectl"
    "helm"
)

# Optional but recommended tools
OPTIONAL_TOOLS=(
    "kustomize"
    "jq"
    "yq"
)

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Pre-deployment checklist to verify:
  - Required tools are installed
  - Cluster connectivity
  - Namespace availability
  - Resource quotas
  - RBAC permissions
  - Configuration validity

Options:
  -c, --config FILE   Path to deployment config file
  -v, --verbose       Enable verbose output
  -q, --quiet         Suppress non-error output
  --json              Output results as JSON
  -h, --help          Show this help message

Examples:
  $(basename "$0")                  # Basic pre-deployment check
  $(basename "$0") -c config.yaml   # Check with config file
  $(basename "$0") --json           # Output results as JSON

Exit Codes:
  0 - All checks passed, safe to deploy
  1 - One or more checks failed
  2 - Script error
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="${2:?Config file path required}"
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
# Check required tools
#######################################
check_required_tools() {
    log_subsection "Required Tools"

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if command_exists "$tool"; then
            local version
            version=$("$tool" version --short 2>/dev/null | head -1 || "$tool" --version 2>/dev/null | head -1 || echo "installed")
            record_result "tool-$tool" "pass" "$version"
        else
            record_result "tool-$tool" "fail" "Not installed"
        fi
    done
}

#######################################
# Check optional tools
#######################################
check_optional_tools() {
    log_subsection "Optional Tools"

    for tool in "${OPTIONAL_TOOLS[@]}"; do
        if command_exists "$tool"; then
            log_success "$tool: Available"
        else
            log_debug "$tool: Not installed (optional)"
        fi
    done
}

#######################################
# Check cluster connectivity
#######################################
check_cluster_connectivity() {
    log_subsection "Cluster Connectivity"

    if ! command_exists kubectl; then
        record_result "cluster-connectivity" "fail" "kubectl not available"
        return 1
    fi

    if kubectl cluster-info >/dev/null 2>&1; then
        record_result "cluster-connectivity" "pass" "Cluster is reachable"

        # Get cluster info
        local context
        context=$(kubectl config current-context 2>/dev/null || echo "unknown")
        log_debug "Current context: $context"

        # Check API server health
        if kubectl get --raw='/healthz' >/dev/null 2>&1; then
            record_result "api-server-health" "pass" "API server healthy"
        else
            record_result "api-server-health" "fail" "API server not healthy"
        fi
    else
        record_result "cluster-connectivity" "fail" "Cluster not reachable"
    fi
}

#######################################
# Check RBAC permissions
#######################################
check_rbac_permissions() {
    log_subsection "RBAC Permissions"

    if ! command_exists kubectl || ! kubectl_ready; then
        log_debug "Skipping RBAC checks - cluster not available"
        return 0
    fi

    # Check basic permissions
    local permissions=(
        "get pods"
        "create pods"
        "get deployments"
        "create deployments"
        "get services"
        "create services"
        "get configmaps"
        "create configmaps"
    )

    local all_permitted=true
    for perm in "${permissions[@]}"; do
        # shellcheck disable=SC2086
        if kubectl auth can-i $perm >/dev/null 2>&1; then
            log_debug "Permission granted: $perm"
        else
            log_debug "Permission denied: $perm"
            all_permitted=false
        fi
    done

    if [[ "$all_permitted" == "true" ]]; then
        record_result "rbac-permissions" "pass" "Required permissions available"
    else
        record_result "rbac-permissions" "fail" "Some permissions missing"
    fi
}

#######################################
# Check resource quotas
#######################################
check_resource_quotas() {
    log_subsection "Resource Quotas"

    if ! command_exists kubectl || ! kubectl_ready; then
        log_debug "Skipping quota checks - cluster not available"
        return 0
    fi

    # Check for resource quotas in default namespace
    local quota_count
    quota_count=$(kubectl get resourcequotas --no-headers 2>/dev/null | wc -l)

    if [[ $quota_count -gt 0 ]]; then
        log_debug "$quota_count resource quota(s) defined"

        # Check quota usage
        kubectl get resourcequotas -o custom-columns='NAME:.metadata.name,USED CPU:.status.used.cpu,LIMIT CPU:.status.hard.cpu' 2>/dev/null || true
    else
        log_debug "No resource quotas defined"
    fi

    record_result "resource-quotas" "pass" "Resource quotas checked"
}

#######################################
# Check Helm repositories
#######################################
check_helm_repos() {
    log_subsection "Helm Repositories"

    if ! command_exists helm; then
        log_debug "Helm not available - skipping repo check"
        return 0
    fi

    local repo_count
    repo_count=$(helm repo list 2>/dev/null | tail -n +2 | wc -l)

    if [[ $repo_count -gt 0 ]]; then
        record_result "helm-repos" "pass" "$repo_count repo(s) configured"
        log_debug "Helm repositories:"
        helm repo list 2>/dev/null | tail -n +2 || true
    else
        log_debug "No Helm repositories configured"
    fi
}

#######################################
# Check configuration file
#######################################
check_config_file() {
    if [[ -z "$CONFIG_FILE" ]]; then
        return 0
    fi

    log_subsection "Configuration File"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        record_result "config-file" "fail" "File not found: $CONFIG_FILE"
        return 1
    fi

    # Check file is readable
    if [[ ! -r "$CONFIG_FILE" ]]; then
        record_result "config-file" "fail" "File not readable: $CONFIG_FILE"
        return 1
    fi

    # Validate YAML syntax if yq is available
    if command_exists yq; then
        if yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
            record_result "config-syntax" "pass" "Valid YAML syntax"
        else
            record_result "config-syntax" "fail" "Invalid YAML syntax"
        fi
    elif command_exists python3; then
        if python3 -c "import yaml; yaml.safe_load(open('$CONFIG_FILE'))" 2>/dev/null; then
            record_result "config-syntax" "pass" "Valid YAML syntax"
        else
            record_result "config-syntax" "fail" "Invalid YAML syntax"
        fi
    fi

    record_result "config-file" "pass" "Configuration file exists"
}

#######################################
# Check disk space
#######################################
check_disk_space() {
    log_subsection "Disk Space"

    local available_space
    available_space=$(df -h . | tail -1 | awk '{print $4}')

    local available_bytes
    available_bytes=$(df . | tail -1 | awk '{print $4}')

    # Check if at least 1GB available (approximately)
    if [[ $available_bytes -gt 1000000 ]]; then
        record_result "disk-space" "pass" "$available_space available"
    else
        record_result "disk-space" "fail" "Low disk space: $available_space"
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

    log_section "Pre-Deployment Summary"
    log_kv "Total Checks" "$((passed + failed))"
    log_kv "Passed" "$passed"
    log_kv "Failed" "$failed"

    if [[ $failed -eq 0 ]]; then
        echo ""
        log_success "All pre-deployment checks passed! Safe to proceed."
        return 0
    else
        echo ""
        log_failure "Some pre-deployment checks failed. Please resolve before deploying."
        return 1
    fi
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"

    if [[ "$JSON_OUTPUT" != "true" ]]; then
        log_section "Pre-Deployment Checklist"
        log_kv "Timestamp" "$(date -Iseconds)"
        if [[ -n "$CONFIG_FILE" ]]; then
            log_kv "Config File" "$CONFIG_FILE"
        fi
    fi

    # Run all checks
    check_required_tools
    check_optional_tools
    check_disk_space
    check_cluster_connectivity
    check_rbac_permissions
    check_resource_quotas
    check_helm_repos
    check_config_file

    # Output results
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json
    else
        output_summary
    fi
}

main "$@"
