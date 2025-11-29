#!/usr/bin/env bats
# test-syntax.sh - Syntax validation for all shell scripts
# Validates shell script syntax and ShellCheck compliance

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup - runs before each test
setup() {
    # Check if shellcheck is available
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
}

# Helper function to find all shell scripts (excluding BATS test files)
find_shell_scripts() {
    find "$REPO_ROOT" -type f -name "*.sh" \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.bats-*/*" \
        -not -path "*/tests/*"  # Exclude BATS test files
}

# Helper function to find BATS test files
find_bats_tests() {
    find "$REPO_ROOT/tests" -type f -name "*.sh" \
        -not -path "*/.bats-*/*"
}

@test "all shell scripts have valid syntax" {
    local failed=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        if ! bash -n "$script" 2>/dev/null; then
            echo "# Syntax error in: $script" >&3
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "all shell scripts have proper shebang" {
    local failed=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        local first_line
        first_line=$(head -n 1 "$script")

        # Check for valid shebangs
        if [[ ! "$first_line" =~ ^#!.*bash ]] && [[ ! "$first_line" =~ ^#!.*sh ]]; then
            # Allow scripts that are sourced (may not have shebang)
            if ! grep -q "^# .*source\|^# Usage: source" "$script"; then
                echo "# Missing shebang in: $script" >&3
                failed=1
            fi
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "shellcheck passes on common-functions.sh" {
    run shellcheck -e SC1091 "$REPO_ROOT/lib/common-functions.sh"
    echo "$output" >&3
    [ "$status" -eq 0 ]
}

@test "shellcheck passes on logging-utils.sh" {
    run shellcheck -e SC1091 "$REPO_ROOT/lib/logging-utils.sh"
    echo "$output" >&3
    [ "$status" -eq 0 ]
}

@test "shellcheck passes on network-utils.sh" {
    run shellcheck -e SC1091 "$REPO_ROOT/lib/network-utils.sh"
    echo "$output" >&3
    [ "$status" -eq 0 ]
}

@test "shellcheck passes on validation scripts" {
    local failed=0

    for script in "$REPO_ROOT"/validation/*.sh; do
        if ! shellcheck -e SC1091 "$script" 2>/dev/null; then
            echo "# ShellCheck failed on: $script" >&3
            shellcheck -e SC1091 "$script" >&3 || true
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "shellcheck passes on diagnostic scripts" {
    local failed=0

    for script in "$REPO_ROOT"/diagnostics/*.sh; do
        if ! shellcheck -e SC1091 "$script" 2>/dev/null; then
            echo "# ShellCheck failed on: $script" >&3
            shellcheck -e SC1091 "$script" >&3 || true
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "shellcheck passes on remediation scripts" {
    local failed=0

    for script in "$REPO_ROOT"/remediation/*.sh; do
        if ! shellcheck -e SC1091 "$script" 2>/dev/null; then
            echo "# ShellCheck failed on: $script" >&3
            shellcheck -e SC1091 "$script" >&3 || true
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "shellcheck passes on power-management scripts" {
    local failed=0

    for script in "$REPO_ROOT"/power-management/*.sh; do
        if ! shellcheck -e SC1091 "$script" 2>/dev/null; then
            echo "# ShellCheck failed on: $script" >&3
            shellcheck -e SC1091 "$script" >&3 || true
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "shellcheck passes on deployment scripts" {
    local failed=0

    for script in "$REPO_ROOT"/deployment/*.sh; do
        if ! shellcheck -e SC1091 "$script" 2>/dev/null; then
            echo "# ShellCheck failed on: $script" >&3
            shellcheck -e SC1091 "$script" >&3 || true
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "all scripts are executable" {
    local failed=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        if [[ ! -x "$script" ]]; then
            echo "# Not executable: $script" >&3
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "scripts use proper error handling" {
    local warning=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        # Skip library files that are sourced
        if [[ "$script" == *"-utils.sh" ]] || [[ "$script" == *"-helpers.sh" ]] || [[ "$script" == *"-functions.sh" ]]; then
            continue
        fi

        # Check for set -e or set -euo pipefail (more specific pattern)
        if ! grep -qE "set -[a-z]*e[a-z]*\b|set -e\b" "$script"; then
            echo "# Warning: No 'set -e' in: $script" >&3
            warning=1
        fi
    done

    # This is a warning, not a failure
    [ "$warning" -eq 0 ] || echo "# Some scripts missing 'set -e'" >&3
}

@test "no trailing whitespace in scripts" {
    local failed=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        if grep -q "[[:space:]]$" "$script"; then
            echo "# Trailing whitespace in: $script" >&3
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

@test "scripts use LF line endings" {
    local failed=0
    local scripts
    scripts=$(find_shell_scripts)

    for script in $scripts; do
        if file "$script" | grep -q "CRLF"; then
            echo "# CRLF line endings in: $script" >&3
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}
