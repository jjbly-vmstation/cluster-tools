#!/usr/bin/env bats
# test-monitoring-exporters-health.sh - Test monitoring exporters health
# Validates that all monitoring exporters are healthy

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup
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

@test "node-exporter pods are running" {
    run kubectl get pods -n monitoring -l app=node-exporter --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        # Try alternative label
        run kubectl get pods -n monitoring -l app.kubernetes.io/name=node-exporter --no-headers 2>/dev/null
    fi
    
    if [ -z "$output" ]; then
        skip "node-exporter not deployed"
    fi
    
    # Check that all pods are Running
    local non_running
    non_running=$(echo "$output" | grep -v "Running" | wc -l)
    [ "$non_running" -eq 0 ]
}

@test "kube-state-metrics pods are running" {
    run kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        # Try alternative label
        run kubectl get pods -n monitoring -l app=kube-state-metrics --no-headers 2>/dev/null
    fi
    
    if [ -z "$output" ]; then
        skip "kube-state-metrics not deployed"
    fi
    
    local non_running
    non_running=$(echo "$output" | grep -v "Running" | wc -l)
    [ "$non_running" -eq 0 ]
}

@test "prometheus pods are running" {
    run kubectl get pods -n monitoring -l app=prometheus --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        skip "prometheus not deployed"
    fi
    
    local non_running
    non_running=$(echo "$output" | grep -v "Running" | wc -l)
    [ "$non_running" -eq 0 ]
}

@test "alertmanager pods are running" {
    run kubectl get pods -n monitoring -l app=alertmanager --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        run kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null
    fi
    
    if [ -z "$output" ]; then
        skip "alertmanager not deployed"
    fi
    
    local non_running
    non_running=$(echo "$output" | grep -v "Running" | wc -l)
    [ "$non_running" -eq 0 ]
}

@test "grafana pods are running" {
    run kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        run kubectl get pods -n monitoring -l app=grafana --no-headers 2>/dev/null
    fi
    
    if [ -z "$output" ]; then
        skip "grafana not deployed"
    fi
    
    local non_running
    non_running=$(echo "$output" | grep -v "Running" | wc -l)
    [ "$non_running" -eq 0 ]
}

@test "monitoring namespace exists" {
    run kubectl get namespace monitoring
    [ "$status" -eq 0 ]
}

@test "prometheus service is accessible" {
    run kubectl get svc -n monitoring prometheus 2>/dev/null
    
    if [ "$status" -ne 0 ]; then
        skip "prometheus service not found"
    fi
    
    # Service should have a cluster IP
    local cluster_ip
    cluster_ip=$(kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [ -n "$cluster_ip" ]
}

@test "grafana service is accessible" {
    run kubectl get svc -n monitoring grafana 2>/dev/null
    
    if [ "$status" -ne 0 ]; then
        skip "grafana service not found"
    fi
    
    local cluster_ip
    cluster_ip=$(kubectl get svc -n monitoring grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [ -n "$cluster_ip" ]
}

@test "no exporter pods in CrashLoopBackOff" {
    run kubectl get pods -n monitoring --no-headers 2>/dev/null
    
    local crashloop
    crashloop=$(echo "$output" | grep -c "CrashLoopBackOff" || echo 0)
    [ "$crashloop" -eq 0 ]
}

@test "no exporter pods in ImagePullBackOff" {
    run kubectl get pods -n monitoring --no-headers 2>/dev/null
    
    local image_pull
    image_pull=$(echo "$output" | grep -c "ImagePullBackOff\|ErrImagePull" || echo 0)
    [ "$image_pull" -eq 0 ]
}

@test "validate-monitoring-stack.sh reports exporter status" {
    run "$REPO_ROOT/validation/validate-monitoring-stack.sh" --json
    [ "$status" -lt 2 ]
    
    if command -v jq &>/dev/null; then
        echo "$output" | jq . >/dev/null 2>&1
        [ $? -eq 0 ]
    fi
}
