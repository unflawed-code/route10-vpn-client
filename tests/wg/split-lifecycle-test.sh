#!/bin/sh
# Validation matrix: split tunnel lifecycle

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

echo "=== WG Split Lifecycle Regression ==="
run_test "phase5-split-stage" sh "$PROJECT_ROOT/tests/phase5-split-stage-test.sh"
run_test "phase5-split-hotplug-path" sh "$PROJECT_ROOT/tests/phase5-split-hotplug-path-test.sh"
run_test "phase5-split-isolation-bypass" sh "$PROJECT_ROOT/tests/phase5-split-isolation-bypass-test.sh"
run_test "phase6-hardening-cleanup" sh "$PROJECT_ROOT/tests/phase6-hardening-cleanup-test.sh"
echo "=== WG Split Lifecycle Regression: PASS ==="
