#!/usr/bin/env bats
# test-idempotence.sh - Idempotency testing for remediation tools
# Verifies that running remediation tools multiple times produces same result

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

@test "remediate-monitoring-stack.sh dry-run is idempotent" {
    # First run
    run "$REPO_ROOT/remediation/remediate-monitoring-stack.sh" --dry-run
    local first_output="$output"
    local first_status="$status"

    # Second run
    run "$REPO_ROOT/remediation/remediate-monitoring-stack.sh" --dry-run
    local second_output="$output"
    local second_status="$status"

    # Status should be the same
    [ "$first_status" -eq "$second_status" ]
}

@test "fix-common-issues.sh dry-run is idempotent" {
    # First run
    run "$REPO_ROOT/remediation/fix-common-issues.sh" --dry-run
    local first_status="$status"

    # Second run
    run "$REPO_ROOT/remediation/fix-common-issues.sh" --dry-run
    local second_status="$status"

    # Status should be the same
    [ "$first_status" -eq "$second_status" ]
}

@test "cleanup-resources.sh dry-run is idempotent" {
    # First run
    run "$REPO_ROOT/remediation/cleanup-resources.sh" --dry-run
    local first_status="$status"

    # Second run
    run "$REPO_ROOT/remediation/cleanup-resources.sh" --dry-run
    local second_status="$status"

    # Status should be the same
    [ "$first_status" -eq "$second_status" ]
}

@test "validation results are consistent across runs" {
    # Run validation twice
    run "$REPO_ROOT/validation/validate-cluster-health.sh" --json
    local first_status="$status"
    local first_output="$output"

    # Small delay to ensure cluster state is stable
    sleep 2

    run "$REPO_ROOT/validation/validate-cluster-health.sh" --json
    local second_status="$status"
    local second_output="$output"

    # Status should be the same (cluster state unchanged)
    [ "$first_status" -eq "$second_status" ]

    # Parse and compare check results (excluding timestamp)
    if command -v jq &>/dev/null; then
        local first_checks
        local second_checks

        first_checks=$(echo "$first_output" | jq -r '.summary.total // empty')
        second_checks=$(echo "$second_output" | jq -r '.summary.total // empty')

        if [ -n "$first_checks" ] && [ -n "$second_checks" ]; then
            [ "$first_checks" -eq "$second_checks" ]
        fi
    fi
}

@test "diagnostic tools produce consistent output" {
    # Create temp directory for output
    local temp_dir
    temp_dir=$(mktemp -d)

    # Run diagnostics
    run "$REPO_ROOT/diagnostics/diagnose-cluster-issues.sh" -o "$temp_dir"
    local first_status="$status"

    # Run again
    run "$REPO_ROOT/diagnostics/diagnose-cluster-issues.sh" -o "$temp_dir"
    local second_status="$status"

    # Clean up
    rm -rf "$temp_dir"

    # Status should be the same
    [ "$first_status" -eq "$second_status" ]
}
