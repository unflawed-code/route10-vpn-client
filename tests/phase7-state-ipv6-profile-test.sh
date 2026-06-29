#!/bin/sh
# Phase 7 state tests:
# - ipv6 profile persistence helpers
# - ipv6 health markers
# - ra state save/read/delete

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_LIB="$PROJECT_ROOT/lib/state.sh"
COMMON_LIB="$PROJECT_ROOT/lib/common.sh"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p7state)"
DB_PATH="$TMP_DIR/pbr.db"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[SKIP] sqlite3 not available; skipping IPv6 profile state tests."
    exit 0
fi

say_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

assert_eq() {
    expected="$1"
    actual="$2"
    msg="$3"
    if [ "$expected" = "$actual" ]; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

export VPN_PREFIX="vpnx1"
export PBR_DB_PATH="$DB_PATH"
export LIB_DIR="$PROJECT_ROOT/lib"
export VPN_BASE_DIR="$PROJECT_ROOT"

. "$COMMON_LIB"
. "$STATE_LIB"

echo "=== Phase 7 IPv6 State Profile Tests ==="

db_init
db_stage_interface "wgp7" "wireguard" "conf/wgp7.conf" "1201" "10.90.15.0/24" "1.1.1.1"

profile="$(db_get_ipv6_profile "wgp7")"
assert_eq "nat66|||unknown|" "$profile" "new staged interface defaults to nat66 ipv6 profile"

db_set_ipv6 "wgp7" 1 "2001:db8:abcd:10::/64" 0
db_set_ipv6_profile "wgp7" "routed-prefix" "2001:db8:abcd:10::/64" "br-vlan15"
db_set_ipv6_health "wgp7" "ok" ""
profile="$(db_get_ipv6_profile "wgp7")"
assert_eq "routed-prefix|2001:db8:abcd:10::/64|br-vlan15|ok|" "$profile" "ipv6 profile + health are persisted"

nat66="$(db_get_field "wgp7" "nat66")"
assert_eq "0" "$nat66" "nat66 value remains independent from routed-prefix profile"

db_save_ra_state "wgp7" "br-vlan15" "fd00:1::1/64" "wan6" "64" "relay" "relay" "0"
ra_state="$(db_get_ra_state "wgp7" "br-vlan15")"
assert_eq "wgp7|br-vlan15|fd00:1::1/64|wan6|64|relay|relay|0" "$ra_state" "ra snapshot save/read works"

db_delete_ra_state "wgp7" "br-vlan15"
ra_state="$(db_get_ra_state "wgp7" "br-vlan15")"
assert_eq "" "$ra_state" "ra snapshot delete works"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

[ "$FAIL" -eq 0 ]
