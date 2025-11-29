#!/usr/bin/env bats
# test-loki-validation.sh - Loki validation tests
# Validates Loki logging stack functionality

# Get the repository root
# shellcheck disable=SC2034
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Helper function to count non-running pods
# Arguments: $1 - pod output text
# Returns: count of non-running pods (0 if all running)
count_non_running_pods() {
    local pod_output="$1"
    echo "$pod_output" | grep -vc "Running" || true
}

# Setup
setup() {
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi

    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

@test "loki pods are running" {
    run kubectl get pods -n monitoring -l app=loki --no-headers 2>/dev/null

    if [ -z "$output" ]; then
        run kubectl get pods -n monitoring -l app.kubernetes.io/name=loki --no-headers 2>/dev/null
    fi

    if [ -z "$output" ]; then
        run kubectl get pods -n logging -l app=loki --no-headers 2>/dev/null
    fi

    if [ -z "$output" ]; then
        skip "loki not deployed"
    fi

    local non_running
    non_running=$(count_non_running_pods "$output")
    [ "$non_running" -eq 0 ]
}

@test "promtail pods are running" {
    run kubectl get pods -n monitoring -l app=promtail --no-headers 2>/dev/null

    if [ -z "$output" ]; then
        run kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail --no-headers 2>/dev/null
    fi

    if [ -z "$output" ]; then
        run kubectl get pods -n logging -l app=promtail --no-headers 2>/dev/null
    fi

    if [ -z "$output" ]; then
        skip "promtail not deployed"
    fi

    local non_running
    non_running=$(count_non_running_pods "$output")
    [ "$non_running" -eq 0 ]
}

@test "loki service exists" {
    run kubectl get svc -n monitoring loki 2>/dev/null

    if [ "$status" -ne 0 ]; then
        run kubectl get svc -n logging loki 2>/dev/null
    fi

    if [ "$status" -ne 0 ]; then
        skip "loki service not found"
    fi

    [ "$status" -eq 0 ]
}

@test "promtail daemonset is healthy" {
    # Check if promtail is a daemonset
    run kubectl get ds -n monitoring promtail --no-headers 2>/dev/null

    if [ "$status" -ne 0 ]; then
        run kubectl get ds -n logging promtail --no-headers 2>/dev/null
    fi

    if [ "$status" -ne 0 ]; then
        skip "promtail daemonset not found"
    fi

    # Check desired vs ready
    local desired ready
    desired=$(echo "$output" | awk '{print $2}')
    ready=$(echo "$output" | awk '{print $4}')

    [ "$desired" -eq "$ready" ]
}

@test "loki configmap exists" {
    run kubectl get configmap -n monitoring loki 2>/dev/null

    if [ "$status" -ne 0 ]; then
        run kubectl get configmap -n monitoring -l app=loki 2>/dev/null
    fi

    if [ "$status" -ne 0 ]; then
        run kubectl get configmap -n logging -l app=loki 2>/dev/null
    fi

    if [ "$status" -ne 0 ]; then
        skip "loki configmap not found"
    fi

    [ "$status" -eq 0 ]
}

@test "no loki pods in error state" {
    # Check monitoring namespace
    run kubectl get pods -n monitoring -l app=loki --no-headers 2>/dev/null
    local mon_output="$output"

    # Check logging namespace
    run kubectl get pods -n logging -l app=loki --no-headers 2>/dev/null
    local log_output="$output"

    local combined="$mon_output$log_output"

    if [ -z "$combined" ]; then
        skip "loki not deployed"
    fi

    local errors
    errors=$(echo "$combined" | grep -c "Error\|CrashLoopBackOff" || echo 0)
    [ "$errors" -eq 0 ]
}

@test "loki pvc is bound (if using persistence)" {
    run kubectl get pvc -n monitoring -l app=loki --no-headers 2>/dev/null

    if [ -z "$output" ]; then
        run kubectl get pvc -n logging -l app=loki --no-headers 2>/dev/null
    fi

    if [ -z "$output" ]; then
        skip "loki PVC not found (may not use persistence)"
    fi

    local pending
    pending=$(echo "$output" | grep -c "Pending" || echo 0)
    [ "$pending" -eq 0 ]
}
