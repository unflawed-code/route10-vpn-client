#!/bin/sh
# Validation matrix: wrapper command compatibility and plugin parity

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

echo "=== Plugin/Command Parity Regression ==="
run_test "phase2-command-hooks-core" sh "$PROJECT_ROOT/tests/phase2-command-hooks-core-test.sh"
run_test "phase2-wrapper-command-surface" sh "$PROJECT_ROOT/tests/phase2-wrapper-command-surface-test.sh"
run_test "phase2-manage-commands" sh "$PROJECT_ROOT/tests/phase2-manage-commands-test.sh"
echo "=== Plugin/Command Parity Regression: PASS ==="
