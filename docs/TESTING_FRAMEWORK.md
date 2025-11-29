# Testing Framework Guide

This guide covers the testing framework and practices used in the cluster-tools repository.

## Overview

The cluster-tools repository uses [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) for testing shell scripts.

### Test Structure

```
tests/
├── README.md                       # Test documentation
├── integration/                    # End-to-end tests
│   ├── test-complete-validation.sh
│   ├── test-sleep-wake-cycle.sh
│   └── test-idempotence.sh
├── component/                      # Component tests
│   ├── test-monitoring-exporters-health.sh
│   ├── test-loki-validation.sh
│   ├── test-monitoring-access.sh
│   └── test-autosleep-wake-validation.sh
├── drift-detection/                # Configuration drift tests
│   └── test-loki-config-drift.sh
└── syntax/                         # Syntax validation
    └── test-syntax.sh
```

## Installation

### Install BATS

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y bats

# macOS
brew install bats-core

# From source
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

### Install BATS Helpers (Optional)

```bash
# bats-support
git clone https://github.com/bats-core/bats-support.git /usr/local/lib/bats-support

# bats-assert
git clone https://github.com/bats-core/bats-assert.git /usr/local/lib/bats-assert

# bats-file
git clone https://github.com/bats-core/bats-file.git /usr/local/lib/bats-file
```

### Install ShellCheck (for syntax tests)

```bash
# Ubuntu/Debian
sudo apt-get install -y shellcheck

# macOS
brew install shellcheck
```

## Running Tests

### Run All Tests

```bash
# From repository root
bats tests/

# With verbose output
bats --verbose-run tests/

# With TAP output (for CI)
bats --tap tests/
```

### Run Specific Test Categories

```bash
# Syntax tests only (no cluster required)
bats tests/syntax/

# Component tests
bats tests/component/

# Integration tests
bats tests/integration/

# Drift detection tests
bats tests/drift-detection/
```

### Run Single Test File

```bash
bats tests/syntax/test-syntax.sh
```

### Run Tests in Parallel

```bash
bats --jobs 4 tests/
```

## Test Categories

### Syntax Tests

Location: `tests/syntax/`

Purpose: Validate shell script syntax and ShellCheck compliance.

Requirements:
- ShellCheck installed
- No cluster required

Tests:
- Bash syntax validation
- ShellCheck compliance
- Shebang presence
- Error handling (set -e)
- Executable permissions

```bash
# Run syntax tests
bats tests/syntax/test-syntax.sh
```

### Component Tests

Location: `tests/component/`

Purpose: Test individual components in isolation.

Requirements:
- Kubernetes cluster (for some tests)
- kubectl configured

Tests:
- Monitoring exporter health
- Loki validation
- Service accessibility
- Power management functions

```bash
# Run component tests
bats tests/component/
```

### Integration Tests

Location: `tests/integration/`

Purpose: Test multiple components working together.

Requirements:
- Full Kubernetes cluster
- Monitoring stack deployed
- kubectl configured

Tests:
- Complete validation suite
- Idempotency verification
- Sleep/wake cycles

```bash
# Run integration tests
bats tests/integration/
```

### Drift Detection Tests

Location: `tests/drift-detection/`

Purpose: Detect configuration drift from expected state.

Requirements:
- Kubernetes cluster
- Loki deployed

Tests:
- Loki configuration drift
- Expected vs actual configuration

```bash
# Run drift detection tests
bats tests/drift-detection/
```

## Writing Tests

### Basic Test Structure

```bash
#!/usr/bin/env bats

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup runs before each test
setup() {
    # Prepare test environment
    source "$REPO_ROOT/lib/common-functions.sh"
}

# Teardown runs after each test
teardown() {
    # Clean up test environment
}

@test "description of what is being tested" {
    run some_command arg1 arg2
    [ "$status" -eq 0 ]
    [[ "$output" =~ expected_pattern ]]
}
```

### Using the run Command

```bash
@test "command succeeds" {
    run ./my-script.sh
    [ "$status" -eq 0 ]
}

@test "command fails with specific exit code" {
    run ./my-script.sh --invalid
    [ "$status" -eq 2 ]
}

@test "output contains expected text" {
    run ./my-script.sh
    [[ "$output" =~ "expected text" ]]
}

@test "output matches exact value" {
    run echo "hello"
    [ "$output" == "hello" ]
}
```

### Skipping Tests

```bash
@test "requires cluster" {
    if ! kubectl cluster-info &>/dev/null; then
        skip "Kubernetes cluster not reachable"
    fi
    
    run kubectl get pods
    [ "$status" -eq 0 ]
}

@test "requires specific tool" {
    if ! command -v jq &>/dev/null; then
        skip "jq not installed"
    fi
    
    run jq --version
    [ "$status" -eq 0 ]
}
```

### Debug Output

```bash
@test "with debug output" {
    run ./my-script.sh
    
    # Print debug info (visible with bats -t)
    echo "# Status: $status" >&3
    echo "# Output: $output" >&3
    
    [ "$status" -eq 0 ]
}
```

### Testing Functions

```bash
@test "validate_ip accepts valid IP" {
    source "$REPO_ROOT/lib/common-functions.sh"
    
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects invalid IP" {
    source "$REPO_ROOT/lib/common-functions.sh"
    
    run validate_ip "999.999.999.999"
    [ "$status" -eq 1 ]
}
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Tests
on: [push, pull_request]

jobs:
  syntax:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y bats shellcheck
          
      - name: Run syntax tests
        run: bats tests/syntax/

  component:
    runs-on: ubuntu-latest
    needs: syntax
    steps:
      - uses: actions/checkout@v3
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y bats
          
      - name: Set up kind cluster
        uses: helm/kind-action@v1
        
      - name: Run component tests
        run: bats tests/component/
```

### Jenkins

```groovy
pipeline {
    agent any
    stages {
        stage('Syntax Tests') {
            steps {
                sh 'bats tests/syntax/'
            }
        }
        stage('Component Tests') {
            steps {
                sh 'bats tests/component/'
            }
        }
    }
    post {
        always {
            junit 'test-results.xml'
        }
    }
}
```

### TAP Output for CI

```bash
# Generate TAP output
bats --tap tests/ > tap-output.txt

# Convert TAP to JUnit (for CI systems)
npm install -g tap-xunit
bats --tap tests/ | tap-xunit > test-results.xml
```

## Best Practices

### 1. Keep Tests Focused

Each test should verify one thing:

```bash
# Good
@test "validate_ip accepts 192.168.1.1" {
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts 10.0.0.1" {
    run validate_ip "10.0.0.1"
    [ "$status" -eq 0 ]
}

# Avoid combining multiple checks in one test
```

### 2. Use Meaningful Names

```bash
# Good
@test "prometheus pods are running in monitoring namespace" { ... }

# Bad
@test "test1" { ... }
```

### 3. Clean Up Resources

```bash
setup() {
    TEST_DIR=$(mktemp -d)
}

teardown() {
    rm -rf "$TEST_DIR"
}
```

### 4. Skip When Needed

```bash
@test "requires kubernetes" {
    if ! command -v kubectl &>/dev/null; then
        skip "kubectl not installed"
    fi
    # ...
}
```

### 5. Document Assumptions

```bash
# This test assumes:
# - kubectl is configured
# - monitoring namespace exists
# - prometheus is deployed
@test "prometheus is healthy" {
    # ...
}
```

## Troubleshooting

### Tests Hang

Check for:
- Infinite loops
- Blocking operations
- Missing timeouts

```bash
# Add timeout
@test "command completes" {
    run timeout 30 ./my-script.sh
    [ "$status" -eq 0 ]
}
```

### Flaky Tests

Add retry logic or waits:

```bash
@test "eventually succeeds" {
    local retries=3
    local success=false
    
    for ((i=0; i<retries; i++)); do
        run ./my-script.sh
        if [ "$status" -eq 0 ]; then
            success=true
            break
        fi
        sleep 5
    done
    
    [ "$success" == "true" ]
}
```

### Debug Mode

```bash
# Run with trace
bats --trace tests/my-test.sh

# Print status and output
@test "debug" {
    run ./my-script.sh
    echo "# status=$status" >&3
    echo "# output=$output" >&3
    [ "$status" -eq 0 ]
}
```
