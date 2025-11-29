# Tool Development Guide

This guide covers best practices and standards for developing new tools in the cluster-tools repository.

## Overview

All tools in this repository follow consistent patterns for:
- Error handling
- Logging
- Command-line interface
- Documentation
- Testing

## Getting Started

### Basic Tool Template

```bash
#!/usr/bin/env bash
# my-tool.sh - Brief description of what the tool does
# Longer description of functionality
#
# Usage: ./my-tool.sh [OPTIONS] <arguments>
#
# Options:
#   -v, --verbose      Enable verbose output
#   -q, --quiet        Suppress non-error output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
VERBOSE="${VERBOSE:-false}"
QUIET="${QUIET:-false}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <arguments>

Brief description of what the tool does.

Options:
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-error output
  -h, --help      Show this help message

Examples:
  $(basename "$0") example1
  $(basename "$0") -v example2

Exit Codes:
  0 - Success
  1 - Operation failed
  2 - Invalid arguments
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE="true"
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -q|--quiet)
                QUIET="true"
                export LOG_LEVEL="ERROR"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
            *)
                # Handle positional arguments
                ARGS+=("$1")
                shift
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
    require_command some_command
    
    log_section "Tool Name"
    
    # Main logic here
    
    log_success "Operation completed successfully"
}

main "$@"
```

## Core Libraries

### common-functions.sh

Location: `lib/common-functions.sh`

Provides:
- `command_exists` - Check if command exists
- `require_command` - Require a command, exit if not found
- `require_var` - Require a variable to be set
- `require_file` - Require a file to exist
- `require_directory` - Require a directory to exist
- `ensure_directory` - Create directory if needed
- `confirm` - Prompt for user confirmation
- `run_cmd` - Execute command with dry-run support
- `wait_for` - Wait for condition with timeout
- `validate_ip` - Validate IP address format
- `validate_mac` - Validate MAC address format

### logging-utils.sh

Location: `lib/logging-utils.sh`

Provides:
- `log_debug` - Debug level logging
- `log_info` - Info level logging
- `log_warn` - Warning level logging
- `log_error` - Error level logging
- `log_section` - Print section header
- `log_subsection` - Print subsection header
- `log_success` - Print success message with checkmark
- `log_failure` - Print failure message with X
- `log_kv` - Print key-value pair
- `log_progress` - Show progress indicator
- `set_log_level` - Set logging level

### network-utils.sh

Location: `lib/network-utils.sh`

Provides:
- `ping_host` - Check if host is reachable
- `check_port` - Check if TCP port is open
- `wait_for_host` - Wait for host to become reachable
- `wait_for_port` - Wait for port to become available
- `send_wol` - Send Wake-on-LAN packet
- `get_interface_ip` - Get IP of network interface
- `get_interface_mac` - Get MAC of network interface
- `check_dns` - Check DNS resolution
- `check_http` - Check HTTP endpoint

## Code Style

### ShellCheck Compliance

All scripts must pass ShellCheck:

```bash
shellcheck -e SC1091 my-script.sh
```

Common issues to avoid:
- Unquoted variables: Use `"$var"` not `$var`
- Word splitting: Use arrays for multiple arguments
- Command substitution: Use `$(cmd)` not backticks

### Error Handling

Always use:

```bash
set -euo pipefail
```

This enables:
- `-e`: Exit on error
- `-u`: Error on undefined variables
- `-o pipefail`: Catch pipeline errors

### Quoting

Always quote variables:

```bash
# Good
echo "$variable"
cd "$directory"

# Bad
echo $variable
cd $directory
```

### Function Documentation

Use Google Shell Style Guide format:

```bash
#######################################
# Brief description of the function.
# Longer description if needed.
# Globals:
#   VARIABLE - Description of global used
# Arguments:
#   $1 - First argument description
#   $2 - Second argument description (optional)
# Outputs:
#   Writes to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
my_function() {
    local arg1="${1:?First argument required}"
    local arg2="${2:-default_value}"
    
    # Function implementation
}
```

## Command-Line Interface

### Standard Options

All tools should support these standard options:

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-h` | `--help` | Show help message |
| `-v` | `--verbose` | Enable verbose output |
| `-q` | `--quiet` | Suppress non-error output |
| `-n` | `--dry-run` | Show what would be done |

### Option Parsing

Use getopts or case statement:

```bash
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -n|--namespace)
                NAMESPACE="${2:?Namespace required}"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 2
                ;;
            *)
                break
                ;;
        esac
    done
}
```

### Exit Codes

Use consistent exit codes:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Operation failed |
| 2 | Invalid arguments / prerequisites |
| 3+ | Tool-specific errors |

## Logging

### Log Levels

| Level | Use For |
|-------|---------|
| DEBUG | Detailed debugging information |
| INFO | Normal operation messages |
| WARN | Warning conditions |
| ERROR | Error conditions |

### Examples

```bash
log_debug "Detailed info for debugging"
log_info "Normal operational message"
log_warn "Something unexpected but not fatal"
log_error "Error condition"

log_section "Main Section Header"
log_subsection "Subsection Header"

log_success "Operation succeeded"
log_failure "Operation failed"

log_kv "Key" "Value"
```

## Testing

### Test Location

Place tests in the appropriate directory:

```
tests/
├── syntax/          # Syntax validation
├── component/       # Component tests
├── integration/     # Integration tests
└── drift-detection/ # Drift detection tests
```

### Test Template

```bash
#!/usr/bin/env bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
    source "$REPO_ROOT/lib/common-functions.sh"
}

@test "tool shows help with -h" {
    run "$REPO_ROOT/path/to/my-tool.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "tool validates input" {
    run "$REPO_ROOT/path/to/my-tool.sh" --invalid
    [ "$status" -eq 2 ]
}
```

## Documentation

### Header Comments

Every script should have header comments:

```bash
#!/usr/bin/env bash
# script-name.sh - Brief one-line description
# Longer description of what the script does,
# its purpose, and any important notes.
#
# Usage: ./script-name.sh [OPTIONS] <arguments>
#
# Options:
#   -v, --verbose   Enable verbose output
#   -h, --help      Show help message
#
# Examples:
#   ./script-name.sh example1
#   ./script-name.sh -v example2
#
# Dependencies:
#   - kubectl
#   - jq
```

### Help Function

Include comprehensive help:

```bash
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <command>

Description of what the tool does.

Commands:
  command1    Description of command1
  command2    Description of command2

Options:
  -v, --verbose   Enable verbose output
  -n, --dry-run   Show what would be done
  -h, --help      Show this help message

Environment Variables:
  VAR_NAME        Description (default: value)

Examples:
  $(basename "$0") command1
  $(basename "$0") -v command2

Exit Codes:
  0 - Success
  1 - Failure
  2 - Invalid arguments
EOF
}
```

## Security Considerations

### Input Validation

Always validate input:

```bash
# Validate IP address
if ! validate_ip "$ip_address"; then
    log_error "Invalid IP address: $ip_address"
    exit 2
fi

# Validate file exists and is readable
if [[ ! -r "$config_file" ]]; then
    log_error "Cannot read config file: $config_file"
    exit 2
fi
```

### Avoid Command Injection

```bash
# Bad - vulnerable to injection
eval "$user_input"

# Good - use arrays
local -a cmd=("kubectl" "get" "pods" "-n" "$namespace")
"${cmd[@]}"
```

### Sensitive Data

Never log sensitive data:

```bash
# Bad
log_info "Password: $password"

# Good
log_info "Password configured (hidden)"
```

## Best Practices Summary

1. **Use set -euo pipefail** for error handling
2. **Quote all variables** to prevent word splitting
3. **Validate all inputs** before using them
4. **Use consistent exit codes** across tools
5. **Include comprehensive help** with examples
6. **Follow ShellCheck** recommendations
7. **Source common libraries** instead of duplicating code
8. **Write tests** for new functionality
9. **Document functions** with header comments
10. **Use meaningful names** for variables and functions
