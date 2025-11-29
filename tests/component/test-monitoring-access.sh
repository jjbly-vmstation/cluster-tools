#!/usr/bin/env bats
# test-monitoring-access.sh - Test monitoring service accessibility
# Validates that monitoring services are accessible

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup
setup() {
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
}

@test "prometheus service has endpoints" {
    run kubectl get endpoints -n monitoring prometheus --no-headers 2>/dev/null
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        skip "prometheus endpoints not found"
    fi
    
    # Check that there are IP addresses (not <none>)
    [[ ! "$output" =~ "<none>" ]]
}

@test "grafana service has endpoints" {
    run kubectl get endpoints -n monitoring grafana --no-headers 2>/dev/null
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        skip "grafana endpoints not found"
    fi
    
    [[ ! "$output" =~ "<none>" ]]
}

@test "alertmanager service has endpoints" {
    run kubectl get endpoints -n monitoring alertmanager --no-headers 2>/dev/null
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        run kubectl get endpoints -n monitoring alertmanager-main --no-headers 2>/dev/null
    fi
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        skip "alertmanager endpoints not found"
    fi
    
    [[ ! "$output" =~ "<none>" ]]
}

@test "loki service has endpoints" {
    run kubectl get endpoints -n monitoring loki --no-headers 2>/dev/null
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        run kubectl get endpoints -n logging loki --no-headers 2>/dev/null
    fi
    
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        skip "loki endpoints not found"
    fi
    
    [[ ! "$output" =~ "<none>" ]]
}

@test "prometheus service is ClusterIP or LoadBalancer" {
    run kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.type}' 2>/dev/null
    
    if [ "$status" -ne 0 ]; then
        skip "prometheus service not found"
    fi
    
    [[ "$output" =~ "ClusterIP" ]] || [[ "$output" =~ "LoadBalancer" ]] || [[ "$output" =~ "NodePort" ]]
}

@test "grafana service is ClusterIP or LoadBalancer" {
    run kubectl get svc -n monitoring grafana -o jsonpath='{.spec.type}' 2>/dev/null
    
    if [ "$status" -ne 0 ]; then
        skip "grafana service not found"
    fi
    
    [[ "$output" =~ "ClusterIP" ]] || [[ "$output" =~ "LoadBalancer" ]] || [[ "$output" =~ "NodePort" ]]
}

@test "ingress exists for monitoring services" {
    run kubectl get ingress -n monitoring --no-headers 2>/dev/null
    
    if [ -z "$output" ]; then
        skip "no ingress configured for monitoring"
    fi
    
    [ "$status" -eq 0 ]
}

@test "monitoring services have correct port configuration" {
    # Check prometheus port
    run kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.ports[0].port}' 2>/dev/null
    
    if [ "$status" -eq 0 ] && [ -n "$output" ]; then
        # Prometheus typically runs on 9090 or 80
        [[ "$output" =~ "9090" ]] || [[ "$output" =~ "80" ]]
    fi
}

@test "grafana has correct port configuration" {
    run kubectl get svc -n monitoring grafana -o jsonpath='{.spec.ports[0].port}' 2>/dev/null
    
    if [ "$status" -eq 0 ] && [ -n "$output" ]; then
        # Grafana typically runs on 3000 or 80
        [[ "$output" =~ "3000" ]] || [[ "$output" =~ "80" ]]
    fi
}

@test "no services with selector mismatch" {
    # Check for services without matching pods
    local services
    services=$(kubectl get svc -n monitoring --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -z "$services" ]; then
        skip "no monitoring services found"
    fi
    
    local mismatched=0
    for svc in $services; do
        local endpoints
        endpoints=$(kubectl get endpoints -n monitoring "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        
        if [ -z "$endpoints" ]; then
            echo "# Service $svc has no endpoints" >&3
            mismatched=1
        fi
    done
    
    [ "$mismatched" -eq 0 ]
}
