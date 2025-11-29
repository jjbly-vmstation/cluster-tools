#!/usr/bin/env bats
# test-autosleep-wake-validation.sh - Auto-sleep and wake validation
# Tests the auto-sleep and wake functionality

# Get the repository root
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# Setup
setup() {
    source "$REPO_ROOT/lib/common-functions.sh" 2>/dev/null || true
    source "$REPO_ROOT/lib/network-utils.sh" 2>/dev/null || true
}

@test "power management scripts exist" {
    [ -f "$REPO_ROOT/power-management/vmstation-event-wake.sh" ]
    [ -f "$REPO_ROOT/power-management/vmstation-collect-wake-logs.sh" ]
    [ -f "$REPO_ROOT/power-management/send-wake-on-lan.sh" ]
    [ -f "$REPO_ROOT/power-management/check-power-state.sh" ]
}

@test "power management scripts are executable" {
    [ -x "$REPO_ROOT/power-management/vmstation-event-wake.sh" ]
    [ -x "$REPO_ROOT/power-management/vmstation-collect-wake-logs.sh" ]
    [ -x "$REPO_ROOT/power-management/send-wake-on-lan.sh" ]
    [ -x "$REPO_ROOT/power-management/check-power-state.sh" ]
}

@test "check-power-state.sh can check multiple hosts" {
    run "$REPO_ROOT/power-management/check-power-state.sh" 127.0.0.1 localhost
    [ "$status" -eq 0 ]
}

@test "check-power-state.sh returns correct status for unreachable host" {
    # Use an IP that's unlikely to respond
    run "$REPO_ROOT/power-management/check-power-state.sh" 192.0.2.1
    # Should return non-zero for offline host
    [ "$status" -ne 0 ] || [[ "$output" =~ "offline" ]]
}

@test "vmstation-collect-wake-logs.sh can run without config" {
    local temp_dir
    temp_dir=$(mktemp -d)

    run "$REPO_ROOT/power-management/vmstation-collect-wake-logs.sh" -o "$temp_dir"

    # Should complete (may have warnings but not fail critically)
    [ "$status" -lt 2 ]

    # Cleanup
    rm -rf "$temp_dir"
}

@test "network-utils.sh ping_host function works" {
    source "$REPO_ROOT/lib/network-utils.sh"

    run ping_host "127.0.0.1" 2
    [ "$status" -eq 0 ]
}

@test "network-utils.sh check_port function works" {
    source "$REPO_ROOT/lib/network-utils.sh"

    # This may fail if nothing is listening, which is OK
    run check_port "127.0.0.1" 22 2
    # Just check it doesn't crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "validate_ip function works correctly" {
    source "$REPO_ROOT/lib/common-functions.sh"

    # Valid IPs
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]

    run validate_ip "10.0.0.1"
    [ "$status" -eq 0 ]

    run validate_ip "255.255.255.255"
    [ "$status" -eq 0 ]

    # Invalid IPs
    run validate_ip "256.1.1.1"
    [ "$status" -eq 1 ]

    run validate_ip "192.168.1"
    [ "$status" -eq 1 ]

    run validate_ip "not.an.ip"
    [ "$status" -eq 1 ]
}

@test "validate_mac function works correctly" {
    source "$REPO_ROOT/lib/common-functions.sh"

    # Valid MACs
    run validate_mac "AA:BB:CC:DD:EE:FF"
    [ "$status" -eq 0 ]

    run validate_mac "aa:bb:cc:dd:ee:ff"
    [ "$status" -eq 0 ]

    run validate_mac "00:11:22:33:44:55"
    [ "$status" -eq 0 ]

    # Invalid MACs
    run validate_mac "AA:BB:CC:DD:EE"
    [ "$status" -eq 1 ]

    run validate_mac "AA:BB:CC:DD:EE:FF:GG"
    [ "$status" -eq 1 ]

    run validate_mac "not-a-mac"
    [ "$status" -eq 1 ]
}

@test "get_default_gateway function works" {
    source "$REPO_ROOT/lib/network-utils.sh"

    run get_default_gateway
    # Should succeed or at least not crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
