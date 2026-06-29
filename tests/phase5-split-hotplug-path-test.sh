#!/bin/sh
# Phase 5 split hotplug generation test:
# - no hardcoded DB path or self-path assumptions
# - hotplug includes ifdown cleanup path

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p5hp)"
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

assert_not_contains() {
    haystack="$1"
    needle="$2"
    msg="$3"
    if printf "%s" "$haystack" | grep -Fq "$needle"; then
        say_fail "$msg"
        echo "  unexpected substring: $needle"
        echo "  actual: $haystack"
    else
        say_pass "$msg"
    fi
}

mkdir -p "$TMP_DIR/hotplug" "$TMP_DIR/lib"
cp "$PROJECT_ROOT/lib/split-tunnel.sh" "$TMP_DIR/lib/split-tunnel.sh"

export VPN_PREFIX="r10test"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug"
export VPN_TMP_DIR="$TMP_DIR/runtime"
export PBR_DB_PATH="$TMP_DIR/runtime/pbr.db"
export LIB_DIR="$PROJECT_ROOT/lib"
export VPN_BASE_DIR="$PROJECT_ROOT"
export VPN_DNSMASQ_SERVICE="/tmp/mock-dnsmasq"
cat > "$TMP_DIR/project.conf" <<'EOF_CFG'
PBR_DB_BUSY_TIMEOUT_MS=4321
WG_DB_BUSY_TIMEOUT_MS="$PBR_DB_BUSY_TIMEOUT_MS"
EOF_CFG
export VPN_PROJECT_CONFIG_FILE="$TMP_DIR/project.conf"
export VPN_CORE_LOADED=""

# shellcheck source=/dev/null
. "$TMP_DIR/lib/split-tunnel.sh"

echo "=== Phase 5 Split Hotplug Path Test ==="

script_path="$(split_tunnel_generate_hotplug wg0 101 example.com,netflix.com 1.1.1.1,2606:4700:4700::1111 1)"
if [ -f "$script_path" ]; then
    say_pass "split hotplug script is generated"
else
    say_fail "split hotplug script is generated"
fi

script_data="$(cat "$script_path" 2>/dev/null)"
assert_contains "$script_data" "PBR_DB_PATH=\"$PBR_DB_PATH\"" "hotplug uses configured DB path"
assert_contains "$script_data" "SPLIT_LIB=\"$PROJECT_ROOT/lib/split-tunnel.sh\"" "hotplug uses deterministic split library path"
assert_contains "$script_data" "split_tunnel_cleanup \"\$INTERFACE\" \"\$TABLE\" \"\$DNS\" \"\$IPV6\"" "hotplug includes ifdown cleanup path"
assert_contains "$script_data" "flock -x 202" "split hotplug uses lock-based serialization"
assert_contains "$script_data" "split_\${INTERFACE}.guard" "split hotplug includes storm guard state"
assert_contains "$script_data" "SQLITE_TIMEOUT_MS=\"4321\"" "hotplug embeds configured sqlite busy timeout"
assert_not_contains "$script_data" "/cfg/unflawed-code/route10-vpn-client/lib/split-tunnel.sh" "hotplug no longer hardcodes repository-specific split lib path"
assert_not_contains "$script_data" "/tmp/\${VPN_PREFIX}/pbr.db" "hotplug no longer hardcodes legacy DB path"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
