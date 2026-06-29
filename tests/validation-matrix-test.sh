#!/bin/sh
# Validation matrix runner

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

run_test() {
    name="$1"
    script="$2"
    echo "[RUN] $name"
    sh "$script"
    echo "[PASS] $name"
}

echo "=== Route10 Validation Matrix ==="
run_test "wg/roaming-ipv6-integration" "$PROJECT_ROOT/tests/wg/roaming-ipv6-integration-test.sh"
run_test "core/dhcp-race" "$PROJECT_ROOT/tests/core/dhcp-race-test.sh"
run_test "wg/target-only-commit" "$PROJECT_ROOT/tests/wg/target-only-commit-test.sh"
run_test "wg/split-lifecycle" "$PROJECT_ROOT/tests/wg/split-lifecycle-test.sh"
run_test "core/tunnel-down-killswitch" "$PROJECT_ROOT/tests/core/tunnel-down-killswitch-test.sh"
run_test "plugins/manage-commands-parity" "$PROJECT_ROOT/tests/plugins/manage-commands-parity-test.sh"
run_test "phase7/state-ipv6-profile" "$PROJECT_ROOT/tests/phase7-state-ipv6-profile-test.sh"
run_test "wg/ipv6-routed-validate" "$PROJECT_ROOT/tests/wg/ipv6-routed-validate-test.sh"
echo "=== Route10 Validation Matrix: PASS ==="
