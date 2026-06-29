#!/bin/sh
# Validation matrix: target-only commit path (no tunnel bounce)

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

echo "=== WG Target-Only Commit Regression ==="
sh "$PROJECT_ROOT/tests/phase3-commit-pipeline-test.sh"
echo "=== WG Target-Only Commit Regression: PASS ==="
