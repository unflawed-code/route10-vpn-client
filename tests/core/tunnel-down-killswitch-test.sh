#!/bin/sh
# Validation matrix: tunnel-down onboarding kill-switch behavior

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

echo "=== Core Tunnel-Down Kill-Switch Regression ==="
sh "$PROJECT_ROOT/tests/phase4-roaming-stability-test.sh"
echo "=== Core Tunnel-Down Kill-Switch Regression: PASS ==="
