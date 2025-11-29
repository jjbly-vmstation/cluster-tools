# Validation Tools Guide

This guide covers the validation tools included in the cluster-tools repository. These tools help ensure your Kubernetes cluster and monitoring stack are functioning correctly.

## Overview

The validation tools are located in the `validation/` directory:

| Tool | Description |
|------|-------------|
| `validate-cluster-health.sh` | Comprehensive cluster health validation |
| `validate-monitoring-stack.sh` | Monitoring stack validation (Prometheus, Grafana, etc.) |
| `validate-network-connectivity.sh` | Network connectivity testing |
| `pre-deployment-checklist.sh` | Pre-deployment requirement verification |

## Quick Start

```bash
# Run all validation tools
./validation/validate-cluster-health.sh
./validation/validate-monitoring-stack.sh
./validation/validate-network-connectivity.sh

# Run pre-deployment checks
./validation/pre-deployment-checklist.sh
```

## validate-cluster-health.sh

Validates overall Kubernetes cluster health including nodes, system pods, DNS, and networking.

### Usage

```bash
./validation/validate-cluster-health.sh [OPTIONS]

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show help message
```

### Checks Performed

1. **Node Health**
   - All nodes are in Ready state
   - No node conditions (MemoryPressure, DiskPressure, etc.)

2. **System Pods**
   - kube-system pods are running
   - No failed or pending pods

3. **DNS Health**
   - CoreDNS pods are running
   - kube-dns service exists

4. **API Server**
   - API server responds to health checks
   - Kubernetes version information

5. **Networking**
   - CNI pods are running (Calico, Flannel, or Cilium)
   - kube-proxy pods are running

6. **Resources**
   - No OOM events detected
   - Metrics server available

### Example Output

```
============================================================
= Cluster Health Validation =
============================================================

Timestamp: 2024-01-15T10:30:00+0000

--- Node Health ---

✓ nodes-ready: 3/3 nodes Ready
✓ nodes-conditions: No node conditions

--- System Pods (kube-system) ---

✓ system-pods: 15/15 pods running

--- DNS Health ---

✓ coredns-pods: 2 CoreDNS pods running
✓ dns-service: kube-dns service exists

============================================================
= Cluster Health Summary =
============================================================

  Total Checks         : 8
  Passed              : 8
  Failed              : 0

✓ All cluster health validations passed!
```

## validate-monitoring-stack.sh

Validates the monitoring stack including Prometheus, Grafana, Alertmanager, and Loki.

### Usage

```bash
./validation/validate-monitoring-stack.sh [OPTIONS]

Options:
  -n, --namespace NS   Kubernetes namespace (default: monitoring)
  -v, --verbose        Enable verbose output
  -q, --quiet          Suppress non-error output
  --json               Output results as JSON
  -h, --help           Show help message
```

### Checks Performed

1. **Prometheus**
   - Server pods running
   - Service available

2. **Grafana**
   - Pods running
   - Service available

3. **Alertmanager**
   - Pods running
   - Service available

4. **Loki**
   - Loki pods running
   - Promtail pods running
   - Service available

5. **Exporters**
   - node-exporter pods running
   - kube-state-metrics pods running

### JSON Output

```bash
./validation/validate-monitoring-stack.sh --json | jq
```

```json
{
  "timestamp": "2024-01-15T10:30:00+0000",
  "namespace": "monitoring",
  "checks": {
    "prometheus-pods": {"status": "pass", "message": "2/2 pods running"},
    "grafana-pods": {"status": "pass", "message": "1/1 pods running"},
    "loki-pods": {"status": "pass", "message": "1/1 pods running"}
  },
  "summary": {"passed": 8, "failed": 0, "total": 8}
}
```

## validate-network-connectivity.sh

Tests network connectivity including DNS resolution, external access, and service connectivity.

### Usage

```bash
./validation/validate-network-connectivity.sh [OPTIONS]

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show help message
```

### Checks Performed

1. **DNS Resolution**
   - Internal service DNS (kubernetes.default.svc.cluster.local)
   - External DNS (google.com, github.com)

2. **External Connectivity**
   - Ping to 8.8.8.8 and 1.1.1.1

3. **Gateway Configuration**
   - Default gateway reachable

4. **API Server Connectivity**
   - API server accessible via kubectl

5. **Service Connectivity**
   - kubernetes service exists
   - kube-dns service exists

6. **Network Policies**
   - Count of network policies

## pre-deployment-checklist.sh

Verifies all prerequisites before deploying applications to the cluster.

### Usage

```bash
./validation/pre-deployment-checklist.sh [OPTIONS]

Options:
  -c, --config FILE   Path to deployment config file
  -v, --verbose       Enable verbose output
  -q, --quiet         Suppress non-error output
  --json              Output results as JSON
  -h, --help          Show help message
```

### Checks Performed

1. **Required Tools**
   - kubectl installed and accessible
   - helm installed and accessible

2. **Optional Tools**
   - kustomize, jq, yq available

3. **Disk Space**
   - Sufficient disk space available

4. **Cluster Connectivity**
   - Cluster reachable
   - API server healthy

5. **RBAC Permissions**
   - Required permissions available

6. **Resource Quotas**
   - Resource quotas checked

7. **Helm Repositories**
   - Helm repositories configured

8. **Configuration File**
   - Config file exists and is valid YAML

## Exit Codes

All validation tools use consistent exit codes:

| Code | Meaning |
|------|---------|
| 0 | All validations passed |
| 1 | One or more validations failed |
| 2 | Script error (missing dependencies, etc.) |

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Validate Cluster
on:
  schedule:
    - cron: '0 */6 * * *'  # Every 6 hours

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up kubectl
        uses: azure/setup-kubectl@v3
        
      - name: Validate cluster health
        run: ./validation/validate-cluster-health.sh --json > health.json
        
      - name: Validate monitoring
        run: ./validation/validate-monitoring-stack.sh --json > monitoring.json
        
      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: validation-results
          path: '*.json'
```

### Slack Notification on Failure

```bash
#!/bin/bash
./validation/validate-cluster-health.sh --json > /tmp/health.json

if [ $? -ne 0 ]; then
    curl -X POST "$SLACK_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"Cluster validation failed! Check results.\"}"
fi
```

## Best Practices

1. **Run regularly**: Schedule validation checks to run periodically
2. **Use JSON output**: For integration with monitoring and alerting
3. **Check before deployments**: Run pre-deployment checklist before any changes
4. **Review failures**: Don't ignore validation failures
5. **Custom namespaces**: Use `-n` flag for non-default monitoring namespaces

## Troubleshooting

### "kubectl not configured" Error

Ensure your kubeconfig is properly set:

```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl cluster-info
```

### Validation Hangs

Check for network connectivity issues:

```bash
kubectl get nodes
kubectl get pods -A
```

### Permission Denied

Ensure you have sufficient RBAC permissions:

```bash
kubectl auth can-i get pods --all-namespaces
```
