#!/bin/sh
# Phase 1 core hotplug timeout test:
# - generated ifdown hotplug embeds configured sqlite timeout

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p1core)"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

say_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

assert_contains() {
    haystack="$1"
    needle="$2"
    msg="$3"
    if printf "%s" "$haystack" | grep -Fq "$needle"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected substring: $needle"
        echo "  actual: $haystack"
    fi
}

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins" "$TMP_DIR/hotplug" "$TMP_DIR/runtime"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cat > "$TMP_DIR/lib/common.sh" <<'EOF_COMMON'
#!/bin/sh
EOF_COMMON
cat > "$TMP_DIR/lib/state.sh" <<'EOF_STATE'
#!/bin/sh
EOF_STATE
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF_PBR'
#!/bin/sh
EOF_PBR

export VPN_PREFIX="r10cfg"
export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/runtime"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug"
export PBR_DB_BUSY_TIMEOUT_MS="6789"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

echo "=== Phase 1 Core Hotplug Timeout Test ==="

script_path="$(vpn_core_generate_ifdown_script wg0 100 "10.0.0.2")"
if [ -f "$script_path" ]; then
    say_pass "ifdown hotplug script is generated"
else
    say_fail "ifdown hotplug script is generated"
fi

script_data="$(cat "$script_path" 2>/dev/null)"
assert_contains "$script_data" "SQLITE_TIMEOUT_MS=\"6789\"" "ifdown hotplug embeds configured sqlite timeout"
assert_contains "$script_data" "VPN_TMP_DIR=\"${VPN_TMP_DIR}\"" "ifdown hotplug uses configured temp dir"
assert_contains "$script_data" "DB_PATH=\"\${VPN_TMP_DIR}/pbr.db\"" "ifdown hotplug derives db path from configured temp dir"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
