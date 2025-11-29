# Diagnostic Tools Guide

This guide covers the diagnostic tools included in the cluster-tools repository. These tools help troubleshoot issues and collect information for debugging.

## Overview

The diagnostic tools are located in the `diagnostics/` directory:

| Tool | Description |
|------|-------------|
| `diagnose-monitoring-stack.sh` | Diagnose monitoring stack issues |
| `diagnose-cluster-issues.sh` | General cluster diagnostics |
| `collect-logs.sh` | Collect logs from pods |
| `generate-diagnostic-report.sh` | Generate comprehensive report |

## Quick Start

```bash
# Diagnose monitoring issues
./diagnostics/diagnose-monitoring-stack.sh

# Diagnose general cluster issues
./diagnostics/diagnose-cluster-issues.sh

# Collect logs from all pods
./diagnostics/collect-logs.sh

# Generate a full diagnostic report
./diagnostics/generate-diagnostic-report.sh -o report.txt
```

## diagnose-monitoring-stack.sh

Collects diagnostic information specifically for the monitoring stack.

### Usage

```bash
./diagnostics/diagnose-monitoring-stack.sh [OPTIONS]

Options:
  -n, --namespace NS   Kubernetes namespace (default: monitoring)
  -o, --output DIR     Output directory for diagnostic files
  -v, --verbose        Enable verbose output
  -h, --help           Show help message
```

### Information Collected

1. **Pod Information**
   - Pod status and descriptions
   - Container logs (current and previous)
   - Pod events

2. **Service Information**
   - Service configuration
   - Endpoints
   - Ingresses

3. **Events**
   - All namespace events
   - Warning events

4. **Resource Usage**
   - Pod resource consumption
   - Resource requests/limits

5. **Configuration**
   - ConfigMaps
   - Secrets list (not content)

### Output Structure

```
diagnostic-output/monitoring-diag-20240115-103000/
├── pod-status.txt
├── pod-logs/
│   ├── prometheus-server-0.log
│   ├── prometheus-server-0-previous.log
│   ├── grafana-xxxxx.log
│   └── ...
├── service-info.txt
├── events.txt
├── warning-events.txt
├── resource-usage.txt
├── configs/
│   ├── prometheus-configmap.yaml
│   └── ...
└── diagnosis-summary.txt
```

### Example Usage

```bash
# Diagnose monitoring in custom namespace
./diagnostics/diagnose-monitoring-stack.sh -n observability

# Save to specific directory
./diagnostics/diagnose-monitoring-stack.sh -o /tmp/monitoring-debug

# Verbose output
./diagnostics/diagnose-monitoring-stack.sh -v
```

## diagnose-cluster-issues.sh

Collects comprehensive diagnostics for the entire cluster.

### Usage

```bash
./diagnostics/diagnose-cluster-issues.sh [OPTIONS]

Options:
  -o, --output DIR   Output directory for diagnostic files
  -v, --verbose      Enable verbose output
  -h, --help         Show help message
```

### Information Collected

1. **Cluster Information**
   - Cluster info and version
   - Current context

2. **Node Information**
   - Node list and status
   - Node descriptions
   - Resource usage

3. **Namespace Information**
   - All namespaces
   - Pods across all namespaces
   - Deployments and services

4. **System Components**
   - kube-system pods
   - Component status
   - API health

5. **Events**
   - All events
   - Warning events

6. **Resources**
   - Resource quotas
   - Limit ranges
   - PersistentVolumes

7. **Network**
   - Network policies
   - Ingresses
   - Endpoints

### Output Structure

```
diagnostic-output/cluster-diag-20240115-103000/
├── cluster-info.txt
├── nodes/
│   ├── node-list.txt
│   ├── node1-describe.txt
│   ├── node2-describe.txt
│   └── node-resources.txt
├── namespaces/
│   ├── namespace-list.txt
│   ├── all-pods.txt
│   ├── all-deployments.txt
│   ├── all-services.txt
│   └── non-running-pods.txt
├── system/
│   ├── kube-system-pods.txt
│   ├── component-status.txt
│   └── api-health.txt
├── all-events.txt
├── warning-events.txt
├── resource-info.txt
├── network-info.txt
└── diagnosis-summary.txt
```

## collect-logs.sh

Flexible log collection from pods with filtering options.

### Usage

```bash
./diagnostics/collect-logs.sh [OPTIONS]

Options:
  -n, --namespace NS   Kubernetes namespace (default: all)
  -l, --labels LABELS  Label selector for pods
  -o, --output DIR     Output directory for logs
  --since DURATION     Only logs newer than this (e.g., 1h, 30m)
  --tail N             Number of lines from end (default: 1000)
  -v, --verbose        Enable verbose output
  -h, --help           Show help message
```

### Examples

```bash
# Collect logs from all namespaces
./diagnostics/collect-logs.sh

# Collect logs from specific namespace
./diagnostics/collect-logs.sh -n monitoring

# Collect logs with label filter
./diagnostics/collect-logs.sh -l app=prometheus

# Collect last hour of logs
./diagnostics/collect-logs.sh --since 1h

# Collect only last 500 lines
./diagnostics/collect-logs.sh --tail 500

# Combine options
./diagnostics/collect-logs.sh -n monitoring -l app=grafana --since 30m --tail 200
```

### Output Structure

```
logs/logs-20240115-103000/
├── monitoring/
│   ├── prometheus-server-0.log
│   ├── prometheus-server-0-previous.log
│   ├── grafana-xxxxx.log
│   └── ...
├── kube-system/
│   ├── coredns-xxxxx.log
│   └── ...
├── pod-summary.txt
├── container-status.txt
├── events.txt
├── collection-summary.txt
└── logs-20240115-103000.tar.gz
```

## generate-diagnostic-report.sh

Generates a comprehensive, human-readable diagnostic report.

### Usage

```bash
./diagnostics/generate-diagnostic-report.sh [OPTIONS]

Options:
  -o, --output FILE   Output file for the report
  -f, --format FMT    Output format: text, html, markdown
  -v, --verbose       Enable verbose output
  -h, --help          Show help message
```

### Formats

1. **Text** (default): Plain text, suitable for terminals
2. **Markdown**: Markdown formatting, suitable for documentation
3. **HTML**: HTML with styling, suitable for viewing in browsers

### Examples

```bash
# Generate text report to stdout
./diagnostics/generate-diagnostic-report.sh

# Save to file
./diagnostics/generate-diagnostic-report.sh -o report.txt

# Generate markdown report
./diagnostics/generate-diagnostic-report.sh -f markdown -o report.md

# Generate HTML report
./diagnostics/generate-diagnostic-report.sh -f html -o report.html
```

### Report Sections

1. **Cluster Overview**
   - Context and version
   - Report timestamp

2. **Node Status**
   - Node list
   - Resource usage

3. **Workload Summary**
   - Pods by namespace
   - Deployments not fully ready

4. **Resource Utilization**
   - Top memory consuming pods
   - Resource quotas

5. **Recent Events**
   - Warning events

6. **Potential Issues**
   - Nodes not ready
   - Failed pods
   - Pending pods
   - CrashLoopBackOff pods

## Common Workflows

### Troubleshooting a Monitoring Issue

```bash
# 1. Collect monitoring diagnostics
./diagnostics/diagnose-monitoring-stack.sh -o /tmp/debug

# 2. Check the summary
cat /tmp/debug/monitoring-diag-*/diagnosis-summary.txt

# 3. Review specific pod logs if needed
less /tmp/debug/monitoring-diag-*/pod-logs/prometheus-*.log
```

### Preparing for Support Ticket

```bash
# 1. Generate comprehensive report
./diagnostics/generate-diagnostic-report.sh -f markdown -o issue-report.md

# 2. Collect cluster diagnostics
./diagnostics/diagnose-cluster-issues.sh -o /tmp/cluster-debug

# 3. Collect recent logs
./diagnostics/collect-logs.sh --since 2h -o /tmp/logs

# 4. Create archive for support
tar -czvf support-bundle.tar.gz \
    issue-report.md \
    /tmp/cluster-debug/* \
    /tmp/logs/*
```

### Scheduled Diagnostics

```bash
#!/bin/bash
# Run daily diagnostics
DATE=$(date +%Y%m%d)
OUTPUT_DIR="/var/log/cluster-diagnostics/$DATE"

./diagnostics/diagnose-cluster-issues.sh -o "$OUTPUT_DIR"
./diagnostics/generate-diagnostic-report.sh -o "$OUTPUT_DIR/report.txt"

# Clean up old diagnostics (keep 7 days)
find /var/log/cluster-diagnostics -type d -mtime +7 -delete
```

## Best Practices

1. **Run diagnostics early**: Collect information before making changes
2. **Keep historical data**: Store diagnostic output for comparison
3. **Use filters wisely**: Target specific namespaces/pods when possible
4. **Review summaries first**: Check diagnosis-summary.txt before diving into logs
5. **Secure sensitive data**: Be careful with ConfigMaps containing secrets

## Troubleshooting

### "Permission denied" when saving files

```bash
# Use a writable directory
./diagnostics/diagnose-cluster-issues.sh -o /tmp/diagnostics
```

### Large log files

```bash
# Limit log collection
./diagnostics/collect-logs.sh --tail 100 --since 1h
```

### Slow collection

```bash
# Filter to specific namespace
./diagnostics/diagnose-monitoring-stack.sh -n monitoring
```
