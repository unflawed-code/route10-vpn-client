#!/bin/sh
# Validation matrix: IPv6 roaming behavior

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

echo "=== WG IPv6 Roaming Regression ==="
run_test "phase4-roaming-stability" sh "$PROJECT_ROOT/tests/phase4-roaming-stability-test.sh"
run_test "phase4-roaming-discovery-guard" sh "$PROJECT_ROOT/tests/phase4-roaming-discovery-guard-test.sh"
echo "=== WG IPv6 Roaming Regression: PASS ==="
