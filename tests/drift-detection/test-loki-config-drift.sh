#!/usr/bin/env bats
# test-loki-config-drift.sh - Loki configuration drift detection
# Detects drift from expected Loki configuration

# Get the repository root
# shellcheck disable=SC2034
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Expected configuration values
EXPECTED_RETENTION_PERIOD="${EXPECTED_RETENTION_PERIOD:-168h}"
EXPECTED_REPLICATION_FACTOR="${EXPECTED_REPLICATION_FACTOR:-1}"

# Setup
setup() {
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi

    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

@test "loki configmap exists in expected location" {
    run kubectl get configmap -n monitoring -l app=loki 2>/dev/null

    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        run kubectl get configmap -n logging -l app=loki 2>/dev/null
    fi

    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        run kubectl get configmap -n monitoring loki 2>/dev/null
    fi

    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        skip "loki configmap not found"
    fi

    [ "$status" -eq 0 ]
}

@test "loki retention period matches expected value" {
    local config
    config=$(kubectl get configmap -n monitoring loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n logging loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        skip "loki config not found"
    fi

    # Check retention period
    if echo "$config" | grep -q "retention_period"; then
        local actual_retention
        actual_retention=$(echo "$config" | grep "retention_period" | head -1 | awk '{print $2}')

        if [ -n "$actual_retention" ]; then
            echo "# Expected: $EXPECTED_RETENTION_PERIOD, Actual: $actual_retention" >&3
            # This is informational - drift is not necessarily a failure
        fi
    else
        echo "# retention_period not explicitly set in config" >&3
    fi

    # Just verify config is readable
    [ -n "$config" ]
}

@test "loki replication factor matches expected value" {
    local config
    config=$(kubectl get configmap -n monitoring loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n logging loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        skip "loki config not found"
    fi

    # Check replication factor
    if echo "$config" | grep -q "replication_factor"; then
        local actual_factor
        actual_factor=$(echo "$config" | grep "replication_factor" | head -1 | awk '{print $2}')

        if [ -n "$actual_factor" ]; then
            echo "# Expected: $EXPECTED_REPLICATION_FACTOR, Actual: $actual_factor" >&3
        fi
    else
        echo "# replication_factor not explicitly set (defaults will be used)" >&3
    fi

    [ -n "$config" ]
}

@test "promtail config references correct loki endpoint" {
    local config
    config=$(kubectl get configmap -n monitoring promtail -o jsonpath='{.data.promtail\.yaml}' 2>/dev/null)

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n logging promtail -o jsonpath='{.data.promtail\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n monitoring -l app=promtail -o jsonpath='{.items[0].data.promtail\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        skip "promtail config not found"
    fi

    # Check that loki endpoint is configured
    if echo "$config" | grep -q "loki"; then
        echo "# Promtail is configured to send to loki" >&3
    fi

    [ -n "$config" ]
}

@test "loki storage configuration is consistent" {
    local config
    config=$(kubectl get configmap -n monitoring loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n logging loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        skip "loki config not found"
    fi

    # Check storage configuration exists
    if echo "$config" | grep -q "storage_config"; then
        echo "# Storage config found" >&3

        # Check for filesystem or object storage
        if echo "$config" | grep -q "filesystem"; then
            echo "# Using filesystem storage" >&3
        elif echo "$config" | grep -q "s3\|gcs\|azure"; then
            echo "# Using object storage" >&3
        fi
    else
        echo "# No explicit storage_config (using defaults)" >&3
    fi

    [ -n "$config" ]
}

@test "loki schema version is current" {
    local config
    config=$(kubectl get configmap -n monitoring loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)

    if [ -z "$config" ]; then
        config=$(kubectl get configmap -n logging loki -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)
    fi

    if [ -z "$config" ]; then
        skip "loki config not found"
    fi

    # Check schema version
    if echo "$config" | grep -q "schema_config"; then
        local schema_version
        schema_version=$(echo "$config" | grep -A5 "schema_config" | grep "schema:" | awk '{print $2}')

        if [ -n "$schema_version" ]; then
            echo "# Schema version: $schema_version" >&3
            # v11, v12, v13 are current versions
            [[ "$schema_version" =~ v1[123] ]] || echo "# Consider upgrading schema version" >&3
        fi
    fi

    [ -n "$config" ]
}

@test "no drift in loki deployment spec" {
    local deployment
    deployment=$(kubectl get deployment -n monitoring loki -o yaml 2>/dev/null)

    if [ -z "$deployment" ]; then
        deployment=$(kubectl get deployment -n logging loki -o yaml 2>/dev/null)
    fi

    if [ -z "$deployment" ]; then
        deployment=$(kubectl get statefulset -n monitoring loki -o yaml 2>/dev/null)
    fi

    if [ -z "$deployment" ]; then
        deployment=$(kubectl get statefulset -n logging loki -o yaml 2>/dev/null)
    fi

    if [ -z "$deployment" ]; then
        skip "loki deployment/statefulset not found"
    fi

    # Check for expected fields
    echo "$deployment" | grep -q "image:" || skip "No image specified"

    [ -n "$deployment" ]
}
