#!/bin/sh
# Migration gap verification wrapper.
# Runs the maintained phase tests that cover the originally tracked migration gaps:
# - commit pipeline parity
# - deferred DHCP replay behavior
# - split-tunnel stage/commit behavior
# - status/plugin surface parity

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PASS=0
FAIL=0

say_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

run_phase_test() {
    local label="$1"
    local script="$2"
    local path="$SCRIPT_DIR/$script"

    if [ ! -f "$path" ]; then
        say_fail "$label (missing: $script)"
        return
    fi

    echo "==> $label ($script)"
    if sh "$path"; then
        say_pass "$label"
    else
        say_fail "$label"
    fi
}

echo "=== Migration Gap Verification ==="

run_phase_test "Wrapper command surface parity" "phase2-wrapper-command-surface-test.sh"
run_phase_test "Commit pipeline parity" "phase3-commit-pipeline-test.sh"
run_phase_test "Deferred DHCP subnet replay" "phase4-deferred-dhcp-subnet-test.sh"
run_phase_test "Split staging lifecycle" "phase5-split-stage-test.sh"
run_phase_test "Split hotplug pathing" "phase5-split-hotplug-path-test.sh"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    echo "All migration gap tests passed."
    exit 0
fi

exit 1
