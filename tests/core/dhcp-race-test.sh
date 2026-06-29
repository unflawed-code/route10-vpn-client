#!/bin/sh
# Validation matrix: DHCP race / MAC state determinism

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

run_test() {
    name="$1"
    shift
    echo "[RUN] $name"
    "$@"
    echo "[PASS] $name"
}

echo "=== Core DHCP Race/State Regression ==="

# Lock/ordering assertions are covered in phase4 roaming stability.
run_test "phase4-roaming-stability" sh "$PROJECT_ROOT/tests/phase4-roaming-stability-test.sh"
# Single-row MAC semantics are covered by state write regression.
run_test "phase4-state-mac-write" sh "$PROJECT_ROOT/tests/phase4-state-mac-write-test.sh"

echo "=== Core DHCP Race/State Regression: PASS ==="
