# Tool Development Guide

This guide provides standards and best practices for developing tools in the cluster-tools repository.

## Table of Contents

- [Script Template](#script-template)
- [Coding Standards](#coding-standards)
- [Error Handling](#error-handling)
- [Logging](#logging)
- [Testing](#testing)
- [Documentation](#documentation)

## Script Template

Use this template for all new scripts:

```bash
#!/usr/bin/env bash
# Script: <script-name>.sh
# Purpose: <brief description>
# Usage: ./<script-name>.sh [options]
# Options:
#   -h, --help     Show help
#   -v, --verbose  Verbose output
#   -q, --quiet    Quiet mode
#   --json         JSON output (validation scripts)
#   --dry-run      Dry run (remediation scripts)

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
# Add your defaults here

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

<Description of what the tool does>

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  --json          Output results as JSON
  -h, --help      Show this help message

Examples:
  $(basename "$0")          # Basic usage
  $(basename "$0") -v       # Verbose output

Exit Codes:
  0 - Success
  1 - Failure
  2 - Invalid arguments / prerequisites
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -q|--quiet)
                export LOG_LEVEL="ERROR"
                shift
                ;;
            --json)
                JSON_OUTPUT="true"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"

    # Check prerequisites
    require_command kubectl

    if ! kubectl_ready; then
        log_error "kubectl is not configured or cluster is not reachable"
        exit 2
    fi

    # Tool logic goes here
}

main "$@"
```

## Coding Standards

### Shebang and Error Handling

Always start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Variable Naming

- Use UPPER_CASE for constants and environment variables
- Use lower_case for local variables
- Use descriptive names

```bash
# Constants
readonly MAX_RETRIES=3

# Local variables
local pod_name="my-pod"
local namespace="default"
```

### Function Documentation

Document all functions with a header comment:

```bash
#######################################
# Brief description of the function.
# Globals:
#   VARIABLE_NAME - Description
# Arguments:
#   $1 - First argument
# Outputs:
#   Writes result to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
my_function() {
    local arg1="${1:?Argument required}"
    # ...
}
```

### Quoting

Always quote variables to prevent word splitting:

```bash
# Correct
echo "$variable"
kubectl get pods -n "$namespace"

# Wrong - never do this
echo $variable
kubectl get pods -n $namespace
```

### Command Substitution

Use `$()` instead of backticks:

```bash
# Correct
result=$(kubectl get pods)

# Wrong
result=`kubectl get pods`
```

## Error Handling

### Check Command Existence

```bash
require_command kubectl
require_command helm
```

### Validate Input

```bash
# Check required variables
require_var "NAMESPACE" "$NAMESPACE"

# Validate IP addresses
if ! validate_ip "$ip_address"; then
    log_error "Invalid IP address: $ip_address"
    exit 2
fi
```

### Exit Codes

Use consistent exit codes:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Operation failed |
| 2 | Invalid arguments / prerequisites |

### Trap for Cleanup

```bash
cleanup() {
    rm -f "$temp_file"
}
trap cleanup EXIT
```

## Logging

### Use the Logging Library

```bash
source "${SCRIPT_DIR}/../lib/logging-utils.sh"

log_debug "Debug message"
log_info "Informational message"
log_warn "Warning message"
log_error "Error message"
log_success "Success message"
log_failure "Failure message"
```

### Structured Output

```bash
log_section "Main Section"
log_subsection "Subsection"
log_kv "Key" "Value"
```

### Log Levels

The log level can be set via environment variable:

```bash
export LOG_LEVEL="DEBUG"  # Show all messages
export LOG_LEVEL="INFO"   # Default
export LOG_LEVEL="WARN"   # Warnings and errors only
export LOG_LEVEL="ERROR"  # Errors only
```

## Testing

### BATS Tests

Create BATS tests for new functionality:

```bash
#!/usr/bin/env bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
    # Setup before each test
}

teardown() {
    # Cleanup after each test
}

@test "my-tool.sh shows help with -h" {
    run "$REPO_ROOT/validation/my-tool.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "my-tool.sh validates correctly" {
    run "$REPO_ROOT/validation/my-tool.sh"
    [ "$status" -lt 2 ]  # Allow 0 or 1, not 2
}
```

### Running Tests

```bash
# Run all tests
bats tests/

# Run specific test file
bats tests/syntax/test-syntax.sh

# Run with verbose output
bats tests/ --verbose
```

### ShellCheck

All scripts must pass ShellCheck:

```bash
# Check single file
shellcheck -e SC1091 myscript.sh

# Check all scripts
find . -name "*.sh" -exec shellcheck -e SC1091 {} \;
```

## Documentation

### Script Header

Every script must have a header:

```bash
#!/usr/bin/env bash
# Script: script-name.sh
# Purpose: Brief description
# Usage: ./script-name.sh [options]
# Options:
#   -h, --help     Show help
```

### Help Text

All scripts must implement `-h` / `--help`:

```bash
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Description of the tool.

Options:
  -v, --verbose   Enable verbose output
  -h, --help      Show this help message

Examples:
  $(basename "$0")          # Basic usage
  $(basename "$0") -v       # Verbose output

Exit Codes:
  0 - Success
  1 - Failure
  2 - Invalid arguments
EOF
}
```

### README Updates

When adding new tools, update:

1. Main README.md with tool description
2. Category-specific README (if exists)
3. IMPROVEMENTS_AND_STANDARDS.md if applicable

## Best Practices Checklist

Before submitting a new tool, verify:

- [ ] Script uses `set -euo pipefail`
- [ ] Script sources common libraries
- [ ] Help text implemented with `-h/--help`
- [ ] Exit codes are consistent (0, 1, 2)
- [ ] Variables are properly quoted
- [ ] ShellCheck passes without errors
- [ ] BATS tests are added
- [ ] Documentation is complete
- [ ] Dry-run mode for destructive operations
- [ ] Confirmation prompts for dangerous actions
