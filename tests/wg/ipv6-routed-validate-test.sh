#!/bin/sh
# Unit tests for routed-prefix validation helpers in common.sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
COMMON_LIB="$PROJECT_ROOT/lib/common.sh"

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

assert_ok() {
    msg="$1"
    shift
    if "$@"; then
        say_pass "$msg"
    else
        say_fail "$msg"
    fi
}

assert_fail() {
    msg="$1"
    shift
    if "$@"; then
        say_fail "$msg"
    else
        say_pass "$msg"
    fi
}

. "$COMMON_LIB"

echo "=== WG Routed IPv6 Validation Tests ==="

# --- is_valid_ipv6_routed_prefix ---
echo ""
echo "-- is_valid_ipv6_routed_prefix --"

assert_ok   "accepts valid /64 global prefix"    is_valid_ipv6_routed_prefix "2001:db8:abcd:10::/64"
assert_ok   "accepts valid /48 prefix"           is_valid_ipv6_routed_prefix "2001:db8:abcd::/48"
assert_ok   "accepts valid /56 prefix"           is_valid_ipv6_routed_prefix "2001:db8:abcd:10::/56"
assert_ok   "accepts valid /32 prefix"           is_valid_ipv6_routed_prefix "2001:db8::/32"
assert_fail "rejects /128 prefix"                is_valid_ipv6_routed_prefix "2001:db8::1/128"
assert_fail "rejects link-local /64"             is_valid_ipv6_routed_prefix "fe80::/64"
assert_fail "rejects multicast"                  is_valid_ipv6_routed_prefix "ff02::/64"
assert_fail "rejects empty"                      is_valid_ipv6_routed_prefix ""
assert_fail "rejects bare address"               is_valid_ipv6_routed_prefix "2001:db8::1"

# --- targets_are_subnets_only ---
echo ""
echo "-- targets_are_subnets_only --"

assert_ok   "subnet-only target list accepted"   targets_are_subnets_only "10.90.10.0/24,10.90.11.0/24"
assert_fail "single host target rejected"        targets_are_subnets_only "10.90.10.5"
assert_fail "mac target rejected"                targets_are_subnets_only "aa:bb:cc:dd:ee:ff"

# --- targets_have_exactly_one_subnet ---
echo ""
echo "-- targets_have_exactly_one_subnet --"

assert_ok   "exactly 1 subnet"                   targets_have_exactly_one_subnet "10.90.10.0/24"
assert_ok   "1 subnet + IP still counts as 1 subnet"  targets_have_exactly_one_subnet "10.90.10.0/24,10.90.10.5"
assert_ok   "1 subnet + MAC still counts as 1 subnet" targets_have_exactly_one_subnet "10.90.10.0/24,aa:bb:cc:dd:ee:ff"
assert_fail "2 subnets rejected"                 targets_have_exactly_one_subnet "10.90.10.0/24,10.90.11.0/24"
assert_fail "no subnets rejected (IP only)"      targets_have_exactly_one_subnet "10.90.10.5"
assert_fail "no subnets rejected (MAC only)"     targets_have_exactly_one_subnet "aa:bb:cc:dd:ee:ff"
assert_fail "none rejected"                      targets_have_exactly_one_subnet "none"
assert_fail "empty rejected"                     targets_have_exactly_one_subnet ""

# --- targets_are_single_subnet_only ---
echo ""
echo "-- targets_are_single_subnet_only --"

assert_ok   "single subnet accepted"             targets_are_single_subnet_only "10.90.10.0/24"
assert_fail "subnet + IP rejected"               targets_are_single_subnet_only "10.90.10.0/24,10.90.10.5"
assert_fail "subnet + MAC rejected"              targets_are_single_subnet_only "10.90.10.0/24,aa:bb:cc:dd:ee:ff"
assert_fail "2 subnets rejected"                 targets_are_single_subnet_only "10.90.10.0/24,10.90.11.0/24"
assert_fail "none rejected"                      targets_are_single_subnet_only "none"
assert_fail "empty rejected"                     targets_are_single_subnet_only ""

# --- targets_route_via_iface ---
echo ""
echo "-- targets_route_via_iface --"

# Stub route lookups so this test stays deterministic/offline.
ip() {
    if [ "$1" = "-4" ] && [ "$2" = "route" ] && [ "$3" = "show" ]; then
        case "$4" in
            10.90.10.0/24) echo "10.90.10.0/24 dev br-lan_10 proto kernel" ; return 0 ;;
            10.90.11.0/24) echo "10.90.11.0/24 dev br-lan_11 proto kernel" ; return 0 ;;
        esac
        return 1
    fi
    if [ "$1" = "-4" ] && [ "$2" = "route" ] && [ "$3" = "get" ]; then
        case "$4" in
            10.90.10.5|10.90.10.25) echo "$4 dev br-lan_10 src 10.90.10.1" ; return 0 ;;
            10.90.11.9)             echo "$4 dev br-lan_11 src 10.90.11.1" ; return 0 ;;
        esac
        return 1
    fi
    return 1
}

resolve_mac_to_ip() {
    case "$1" in
        aa:bb:cc:dd:ee:ff) echo "10.90.10.25" ; return 0 ;;
    esac
    return 1
}

assert_ok   "subnet + IP + MAC route via same iface" \
    targets_route_via_iface "10.90.10.0/24,10.90.10.5,aa:bb:cc:dd:ee:ff" "br-lan_10"
assert_fail "host target on different iface is rejected" \
    targets_route_via_iface "10.90.10.0/24,10.90.11.9" "br-lan_10"
assert_ok   "unresolved MAC does not block subnet-derived iface validation" \
    targets_route_via_iface "10.90.10.0/24,11:22:33:44:55:66" "br-lan_10"

echo ""
echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

[ "$FAIL" -eq 0 ]
