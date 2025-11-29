#!/usr/bin/env bats
# test-sleep-wake-cycle.sh - Sleep/wake cycle testing
# Tests power management functionality

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup
setup() {
    # Source libraries
    source "$REPO_ROOT/lib/common-functions.sh" 2>/dev/null || true
    source "$REPO_ROOT/lib/network-utils.sh" 2>/dev/null || true
}

@test "send-wake-on-lan.sh validates MAC address format" {
    # Invalid MAC should fail
    run "$REPO_ROOT/power-management/send-wake-on-lan.sh" "invalid-mac"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Invalid MAC" ]]
}

@test "send-wake-on-lan.sh accepts valid MAC address" {
    # Valid MAC format (may fail to send if no network, but should pass validation)
    run "$REPO_ROOT/power-management/send-wake-on-lan.sh" "AA:BB:CC:DD:EE:FF" 2>&1
    # Should not fail with exit code 2 (validation error)
    [ "$status" -ne 2 ] || [[ "$output" =~ "No WoL tool" ]]
}

@test "send-wake-on-lan.sh shows help with -h" {
    run "$REPO_ROOT/power-management/send-wake-on-lan.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
    [[ "$output" =~ "mac-address" ]]
}

@test "check-power-state.sh shows help with -h" {
    run "$REPO_ROOT/power-management/check-power-state.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "check-power-state.sh can check localhost" {
    run "$REPO_ROOT/power-management/check-power-state.sh" 127.0.0.1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "online" ]]
}

@test "check-power-state.sh JSON output is valid" {
    run "$REPO_ROOT/power-management/check-power-state.sh" --json 127.0.0.1
    [ "$status" -eq 0 ]

    # Verify JSON structure
    if command -v jq &>/dev/null; then
        echo "$output" | jq . >/dev/null 2>&1
        [ $? -eq 0 ]
        echo "$output" | jq -e '.hosts' >/dev/null
        [ $? -eq 0 ]
    fi
}

@test "vmstation-event-wake.sh shows help with -h" {
    run "$REPO_ROOT/power-management/vmstation-event-wake.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "vmstation-collect-wake-logs.sh shows help with -h" {
    run "$REPO_ROOT/power-management/vmstation-collect-wake-logs.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "validate_mac function accepts valid MAC" {
    source "$REPO_ROOT/lib/common-functions.sh"

    run validate_mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 0 ]

    run validate_mac "aa:bb:cc:dd:ee:ff"
    [ "$status" -eq 0 ]

    run validate_mac "11:22:33:44:55:66"
    [ "$status" -eq 0 ]
}

@test "validate_mac function rejects invalid MAC" {
    source "$REPO_ROOT/lib/common-functions.sh"

    run validate_mac "invalid"
    [ "$status" -eq 1 ]

    run validate_mac "AA:BB:CC:DD:EE"
    [ "$status" -eq 1 ]

    run validate_mac "AA:BB:CC:DD:EE:FF:GG"
    [ "$status" -eq 1 ]

    run validate_mac "GG:HH:II:JJ:KK:LL"
    [ "$status" -eq 1 ]
}
