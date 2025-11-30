# Cluster Tools

Operational tools, scripts, and utilities for VMStation Kubernetes cluster management.

## Overview

This repository contains tools for:
- **Validation** - Cluster and component health checks
- **Diagnostics** - Troubleshooting and log collection
- **Remediation** - Automated issue fixing
- **Power Management** - Wake-on-LAN and power state management
- **Deployment** - Quick deployment utilities
- **Testing** - Automated test framework

## Quick Start

```bash
# Clone the repository
git clone https://github.com/jjbly-vmstation/cluster-tools.git
cd cluster-tools

# Make scripts executable
chmod +x **/*.sh

# Run cluster health validation
./validation/validate-cluster-health.sh

# Run monitoring stack validation
./validation/validate-monitoring-stack.sh
```


## Directory Structure

```
cluster-tools/
├── README.md                    # This file
├── IMPROVEMENTS_AND_STANDARDS.md # Best practices documentation
├── validation/                   # Validation tools
├── diagnostics/                  # Diagnostic tools
├── remediation/                  # Remediation tools
├── power-management/             # Power management tools
├── tests/                        # Test suite
├── deployment/                   # Deployment tools
├── lib/                          # Shared libraries
```

## Documentation

All detailed operational and tool documentation has been centralized in the [cluster-docs/components/](../cluster-docs/components/) directory. Please refer to that location for:
- Validation guides
- Diagnostic tools
- Testing framework
- Tool development

This repository only contains the README and improvements/standards documentation.

## Tools Overview

### Validation Tools

| Tool | Description |
|------|-------------|
| `validate-cluster-health.sh` | Comprehensive Kubernetes cluster health checks |
| `validate-monitoring-stack.sh` | Validate Prometheus, Grafana, Loki, and exporters |
| `validate-network-connectivity.sh` | Test DNS, external access, and service connectivity |
| `pre-deployment-checklist.sh` | Verify prerequisites before deployment |

```bash
# Examples
./validation/validate-cluster-health.sh
./validation/validate-monitoring-stack.sh -n monitoring
./validation/validate-network-connectivity.sh --json
./validation/pre-deployment-checklist.sh -c config.yaml
```

### Diagnostic Tools

| Tool | Description |
|------|-------------|
| `diagnose-monitoring-stack.sh` | Collect monitoring stack diagnostics |
| `diagnose-cluster-issues.sh` | General cluster troubleshooting |
| `collect-logs.sh` | Flexible log collection with filters |
| `generate-diagnostic-report.sh` | Generate comprehensive reports |

```bash
# Examples
./diagnostics/diagnose-monitoring-stack.sh -o /tmp/diag
./diagnostics/collect-logs.sh -n monitoring --since 1h
./diagnostics/generate-diagnostic-report.sh -f markdown -o report.md
```

### Remediation Tools

| Tool | Description |
|------|-------------|
| `remediate-monitoring-stack.sh` | Fix common monitoring issues |
| `fix-common-issues.sh` | Fix general cluster issues |
| `cleanup-resources.sh` | Clean up unused resources |

```bash
# Examples (always use --dry-run first!)
./remediation/remediate-monitoring-stack.sh --dry-run
./remediation/fix-common-issues.sh --dry-run
./remediation/cleanup-resources.sh -n monitoring --dry-run
```

### Power Management Tools

| Tool | Description |
|------|-------------|
| `vmstation-event-wake.sh` | Handle Wake-on-LAN events |
| `vmstation-collect-wake-logs.sh` | Collect wake event logs |
| `send-wake-on-lan.sh` | Send WoL magic packets |
| `check-power-state.sh` | Check node power states |

```bash
# Examples
./power-management/send-wake-on-lan.sh AA:BB:CC:DD:EE:FF
./power-management/check-power-state.sh 192.168.1.10 192.168.1.11
./power-management/vmstation-collect-wake-logs.sh --analyze
```

### Deployment Tools

| Tool | Description |
|------|-------------|
| `quick-deploy.sh` | Quick deployment of common components |
| `deployment-helpers.sh` | Library of deployment utilities |

```bash
# Examples
./deployment/quick-deploy.sh monitoring
./deployment/quick-deploy.sh --dry-run all
./deployment/quick-deploy.sh -e prod logging
```

## Common Options

All tools support common options:

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-v, --verbose` | Enable verbose output |
| `-q, --quiet` | Suppress non-error output |
| `--json` | Output results as JSON (validation tools) |
| `--dry-run` | Show what would be done (remediation tools) |

## Testing

The repository includes a comprehensive test suite using [BATS](https://github.com/bats-core/bats-core).

```bash
# Install BATS
sudo apt-get install bats

# Run all tests
bats tests/

# Run specific test category
bats tests/syntax/
bats tests/component/
bats tests/integration/
```

See [Testing Framework Guide](docs/TESTING_FRAMEWORK.md) for more details.

## Development

### Prerequisites

- Bash 4.0+
- kubectl (for cluster tools)
- ShellCheck (for development)
- BATS (for testing)

### Code Quality

All scripts follow shell best practices:
- ShellCheck compliance
- Proper error handling (`set -euo pipefail`)
- Consistent logging
- Input validation
- Comprehensive documentation

See [Improvements and Standards](IMPROVEMENTS_AND_STANDARDS.md) for details.

### Adding New Tools

1. Use the template in [Tool Development Guide](docs/TOOL_DEVELOPMENT.md)
2. Source common libraries from `lib/`
3. Follow the established patterns
4. Add tests in `tests/`
5. Update documentation

## Documentation

| Document | Description |
|----------|-------------|
| [IMPROVEMENTS_AND_STANDARDS.md](IMPROVEMENTS_AND_STANDARDS.md) | Best practices and standards |
| [docs/VALIDATION_GUIDE.md](docs/VALIDATION_GUIDE.md) | Validation tools guide |
| [docs/DIAGNOSTIC_TOOLS.md](docs/DIAGNOSTIC_TOOLS.md) | Diagnostic tools guide |
| [docs/TESTING_FRAMEWORK.md](docs/TESTING_FRAMEWORK.md) | Testing framework guide |
| [docs/TOOL_DEVELOPMENT.md](docs/TOOL_DEVELOPMENT.md) | Tool development guide |
| [tests/README.md](tests/README.md) | Test suite documentation |

## License

See [LICENSE](LICENSE) for details.
