#!/bin/sh
# Phase 5 split isolation bypass test:
# - split chain bypasses source clients from vpn_* / vpn6_* sets
# - split chain bypasses source MACs from mark_* / mark_ipv6_* chains
# - split chain does not treat dst_vpn_* sets as source-bypass sets

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p5iso)"
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

mkdir -p "$TMP_DIR/lib"
cp "$PROJECT_ROOT/lib/split-tunnel.sh" "$TMP_DIR/lib/split-tunnel.sh"

export TEST_LOG="$TMP_DIR/phase5-split-isolation.log"
export VPN_CORE_LOADED="1"
export VPN_PREFIX="r10test"
export VPN_TMP_DIR="$TMP_DIR/tmp"

# Mock commands used by setup_split_pbr
ipset() {
    if [ "${1:-}" = "list" ] && [ "${2:-}" = "-n" ]; then
        cat <<'EOF'
vpn_wgprtonus85
vpn_legacytarget
vpn6_wgprtonus85
vpn6_legacytarget
dst_vpn_wgsplit
EOF
        return 0
    fi
    echo "ipset:$*" >> "$TEST_LOG"
    return 0
}

iptables() {
    echo "iptables:$*" >> "$TEST_LOG"
    return 0
}

ip6tables() {
    if [ "${1:-}" = "-w" ] && [ "${2:-}" = "-t" ] && [ "${3:-}" = "mangle" ] && [ "${4:-}" = "-S" ]; then
        cat <<'EOF'
-A mark_wgprtonus85 -m mac --mac-source aa:bb:cc:dd:ee:ff -j MARK --set-mark 0x12345
-A mark_ipv6_wgprtonus81 -m mac --mac-source 11:22:33:44:55:66 -j MARK --set-mark 0x54321
EOF
        return 0
    fi
    echo "ip6tables:$*" >> "$TEST_LOG"
    return 0
}

ip() {
    echo "ip:$*" >> "$TEST_LOG"
    return 0
}

# shellcheck source=/dev/null
. "$TMP_DIR/lib/split-tunnel.sh"

echo "=== Phase 5 Split Isolation Bypass Test ==="

setup_split_pbr "wgsplit" "1100" "1" "1.1.1.1 2606:4700:4700::1111" >/dev/null 2>&1
log_data="$(cat "$TEST_LOG" 2>/dev/null)"

assert_contains "$log_data" "iptables:-w -t mangle -A split_wgsplit -m set --match-set vpn_wgprtonus85 src -j RETURN" "IPv4 split chain bypasses vpn_* source sets"
assert_contains "$log_data" "ip6tables:-w -t mangle -A split_wgsplit -m set --match-set vpn6_wgprtonus85 src -j RETURN" "IPv6 split chain bypasses vpn6_* source sets"
assert_contains "$log_data" "ip6tables:-w -t mangle -A split_wgsplit -m mac --mac-source aa:bb:cc:dd:ee:ff -j RETURN" "IPv6 split chain bypasses MAC from mark_* chain"
assert_contains "$log_data" "ip6tables:-w -t mangle -A split_wgsplit -m mac --mac-source 11:22:33:44:55:66 -j RETURN" "IPv6 split chain bypasses MAC from mark_ipv6_* chain"
assert_not_contains "$log_data" "iptables:-w -t mangle -A split_wgsplit -m set --match-set dst_vpn_wgsplit src -j RETURN" "split destination ipset is not used as source bypass"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
