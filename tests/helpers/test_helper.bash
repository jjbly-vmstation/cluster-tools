# Test Helper Functions for BATS
# Source this file in BATS tests for common helper functions
#
# Usage: load '../helpers/test_helper'

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." 2>/dev/null && pwd)"

#######################################
# Setup functions
#######################################

# Standard setup - check for kubectl
setup_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi

    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

# Setup for scripts that need a cluster
setup_cluster() {
    setup_kubectl
}

# Setup for scripts that don't need a cluster
setup_local() {
    # Source common functions
    source "${REPO_ROOT}/lib/common-functions.sh" 2>/dev/null || true
}

#######################################
# Assertion helpers
#######################################

# Assert command succeeded
assert_success() {
    [ "$status" -eq 0 ]
}

# Assert command failed
assert_failure() {
    [ "$status" -ne 0 ]
}

# Assert output contains string
assert_output_contains() {
    local expected="$1"
    [[ "$output" =~ $expected ]]
}

# Assert output does not contain string
assert_output_not_contains() {
    local unexpected="$1"
    [[ ! "$output" =~ $unexpected ]]
}

# Assert exit code
assert_exit_code() {
    local expected="$1"
    [ "$status" -eq "$expected" ]
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    [ -f "$file" ]
}

# Assert directory exists
assert_dir_exists() {
    local dir="$1"
    [ -d "$dir" ]
}

# Assert file is executable
assert_executable() {
    local file="$1"
    [ -x "$file" ]
}

#######################################
# Helper functions
#######################################

# Count non-running pods from output
count_non_running_pods() {
    local pod_output="$1"
    echo "$pod_output" | grep -vc "Running" || true
}

# Check if output is valid JSON
is_valid_json() {
    local json="$1"
    echo "$json" | jq . >/dev/null 2>&1
}

# Get JSON field value
get_json_field() {
    local json="$1"
    local field="$2"
    echo "$json" | jq -r "$field" 2>/dev/null
}

# Create temporary directory
create_temp_dir() {
    mktemp -d
}

# Clean up temporary directory
cleanup_temp_dir() {
    local dir="$1"
    [ -d "$dir" ] && rm -rf "$dir"
}

# Wait for condition with timeout
wait_for() {
    local condition="$1"
    local timeout="${2:-30}"
    local interval="${3:-1}"

    local start_time
    start_time=$(date +%s)

    while true; do
        if eval "$condition"; then
            return 0
        fi

        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi

        sleep "$interval"
    done
}

#######################################
# Skip helpers
#######################################

# Skip if command not available
skip_if_no_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        skip "$cmd not installed"
    fi
}

# Skip if cluster not reachable
skip_if_no_cluster() {
    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

# Skip if namespace doesn't exist
skip_if_no_namespace() {
    local namespace="$1"
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        skip "Namespace $namespace does not exist"
    fi
}

# Skip if pod label selector returns empty
skip_if_no_pods() {
    local namespace="$1"
    local label="$2"

    local pods
    pods=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null)

    if [ -z "$pods" ]; then
        skip "No pods found with label $label in namespace $namespace"
    fi
}

#######################################
# Test data generators
#######################################

# Generate random string
random_string() {
    local length="${1:-8}"
    head /dev/urandom | tr -dc a-z0-9 | head -c "$length"
}

# Generate test namespace name
test_namespace() {
    echo "test-$(random_string 6)"
}

# Generate test pod name
test_pod_name() {
    echo "test-pod-$(random_string 6)"
}

#######################################
# Script runners
#######################################

# Run validation script
run_validation() {
    local script="$1"
    shift
    run "${REPO_ROOT}/validation/${script}" "$@"
}

# Run diagnostic script
run_diagnostic() {
    local script="$1"
    shift
    run "${REPO_ROOT}/diagnostics/${script}" "$@"
}

# Run remediation script
run_remediation() {
    local script="$1"
    shift
    run "${REPO_ROOT}/remediation/${script}" "$@"
}

# Run power management script
run_power_management() {
    local script="$1"
    shift
    run "${REPO_ROOT}/power-management/${script}" "$@"
}
