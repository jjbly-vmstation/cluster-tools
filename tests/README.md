# Test Suite Documentation

This directory contains the test suite for cluster-tools. Tests are organized by type and use [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) for testing shell scripts.

## Directory Structure

```
tests/
├── README.md                       # This file
├── integration/                    # Integration tests
│   ├── test-complete-validation.sh # Full validation suite
│   ├── test-sleep-wake-cycle.sh    # Sleep/wake testing
│   └── test-idempotence.sh         # Idempotency testing
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

## Prerequisites

### Install BATS

```bash
# Ubuntu/Debian
sudo apt-get install bats

# macOS
brew install bats-core

# From source
git clone https://github.com/bats-core/bats-core.git
cd bats-core
./install.sh /usr/local
```

### Install BATS helpers (optional but recommended)

```bash
# bats-support
git clone https://github.com/bats-core/bats-support.git /usr/local/lib/bats-support

# bats-assert
git clone https://github.com/bats-core/bats-assert.git /usr/local/lib/bats-assert

# bats-file
git clone https://github.com/bats-core/bats-file.git /usr/local/lib/bats-file
```

## Running Tests

### Run all tests

```bash
# From repository root
bats tests/

# Or run specific test files
bats tests/syntax/test-syntax.sh
```

### Run tests with verbose output

```bash
bats --verbose-run tests/
```

### Run tests with TAP output (for CI)

```bash
bats --tap tests/
```

### Run specific test category

```bash
# Syntax tests only
bats tests/syntax/

# Integration tests
bats tests/integration/

# Component tests
bats tests/component/
```

## Test Categories

### Syntax Tests (`syntax/`)
Validate shell script syntax and ShellCheck compliance.
- Fast to run, no cluster required
- Should pass before any other tests
- Checks all `.sh` files in the repository

### Component Tests (`component/`)
Test individual components in isolation.
- May require a running cluster
- Focus on single service/component functionality
- Can be run in parallel

### Integration Tests (`integration/`)
Test multiple components working together.
- Requires a fully configured cluster
- Tests end-to-end workflows
- Should be run after component tests pass

### Drift Detection Tests (`drift-detection/`)
Detect configuration drift from expected state.
- Compares current state to expected configuration
- Useful for ongoing monitoring
- Can be scheduled to run periodically

## Writing Tests

### Basic BATS test structure

```bash
#!/usr/bin/env bats

# Load test helpers
load '../test_helper'

# Setup runs before each test
setup() {
    # Prepare test environment
}

# Teardown runs after each test
teardown() {
    # Clean up test environment
}

@test "description of what is being tested" {
    # Test implementation
    run some_command
    [ "$status" -eq 0 ]
    [[ "$output" =~ expected_pattern ]]
}
```

### Using assertions (with bats-assert)

```bash
#!/usr/bin/env bats

load '/usr/local/lib/bats-support/load'
load '/usr/local/lib/bats-assert/load'

@test "example with assertions" {
    run echo "hello world"
    assert_success
    assert_output --partial "hello"
}
```

### Testing shell functions

```bash
#!/usr/bin/env bats

# Source the library being tested
source "${BATS_TEST_DIRNAME}/../../lib/common-functions.sh"

@test "validate_ip accepts valid IP" {
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects invalid IP" {
    run validate_ip "999.999.999.999"
    [ "$status" -eq 1 ]
}
```

## CI Integration

### GitHub Actions example

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install BATS
        run: |
          sudo apt-get update
          sudo apt-get install -y bats
          
      - name: Run syntax tests
        run: bats tests/syntax/
        
      - name: Run unit tests
        run: bats tests/component/
```

## Test Best Practices

1. **Keep tests focused**: Each test should verify one thing
2. **Use meaningful names**: Test names should describe the expected behavior
3. **Isolate tests**: Tests should not depend on each other
4. **Clean up**: Always clean up resources in teardown
5. **Use fixtures**: Keep test data in separate files
6. **Skip when needed**: Use `skip` for tests that require unavailable resources
7. **Document assumptions**: Comment on any assumptions the test makes

## Troubleshooting

### Common issues

**BATS not found**: Install BATS using your package manager or from source.

**Tests hang**: Check for infinite loops or blocking operations.

**Flaky tests**: Add appropriate waits or retry logic.

**Permission errors**: Ensure test files are executable (`chmod +x`).

### Debug tips

```bash
# Run with debug output
bats --trace tests/syntax/test-syntax.sh

# Print additional info in tests
@test "debug example" {
    echo "# Debug: variable=$variable" >&3
    run command
    [ "$status" -eq 0 ]
}
```
