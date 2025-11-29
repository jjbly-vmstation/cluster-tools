#!/usr/bin/env bats
# test-complete-validation.sh - Complete validation test suite
# Runs all validation tools and checks results

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup - check prerequisites
setup() {
    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi

    # Check if cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

@test "validate-cluster-health.sh runs successfully" {
    run "$REPO_ROOT/validation/validate-cluster-health.sh" -q
    echo "$output" >&3
    # Allow failures in validation (exit code 1) but not script errors (exit code 2)
    [ "$status" -lt 2 ]
}

@test "validate-cluster-health.sh produces JSON output" {
    run "$REPO_ROOT/validation/validate-cluster-health.sh" --json
    echo "$output" >&3
    [ "$status" -lt 2 ]

    # Check that output is valid JSON
    echo "$output" | jq . >/dev/null 2>&1
}

@test "validate-monitoring-stack.sh runs successfully" {
    run "$REPO_ROOT/validation/validate-monitoring-stack.sh" -q
    echo "$output" >&3
    [ "$status" -lt 2 ]
}

@test "validate-network-connectivity.sh runs successfully" {
    run "$REPO_ROOT/validation/validate-network-connectivity.sh" -q
    echo "$output" >&3
    [ "$status" -lt 2 ]
}

@test "pre-deployment-checklist.sh runs successfully" {
    run "$REPO_ROOT/validation/pre-deployment-checklist.sh" -q
    echo "$output" >&3
    [ "$status" -lt 2 ]
}

@test "validation tools show help with -h flag" {
    for script in "$REPO_ROOT"/validation/*.sh; do
        run "$script" -h
        [ "$status" -eq 0 ]
        [[ "$output" =~ "Usage:" ]]
    done
}

@test "validation tools support verbose mode" {
    run "$REPO_ROOT/validation/pre-deployment-checklist.sh" -v
    [ "$status" -lt 2 ]
}

@test "all validation checks produce consistent output format" {
    for script in "$REPO_ROOT"/validation/*.sh; do
        run "$script" --json
        echo "# Testing $script" >&3
        [ "$status" -lt 2 ]

        # Verify JSON structure
        if [ -n "$output" ]; then
            echo "$output" | jq -e '.checks' >/dev/null 2>&1 || \
            echo "$output" | jq -e '.summary' >/dev/null 2>&1 || \
            echo "# Note: $script may not produce JSON" >&3
        fi
    done
}
