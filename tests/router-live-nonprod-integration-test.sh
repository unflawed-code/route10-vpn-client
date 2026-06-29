#!/bin/sh
# Router live integration flow (non-production interfaces only).
# Covers:
# - client-routing + split-tunnel stage/commit on temporary interfaces
# - DHCP apply + roam update path for a synthetic client
# - split-chain source-set isolation against managed client-routing ipset
#
# Safety:
# - requires R10_LIVE_ALLOW_COMMIT=1
# - refuses production iface name "wgtorla"
# - aborts if unrelated staged entries already exist
#
# Usage (on router, from project root):
#   R10_LIVE_ALLOW_COMMIT=1 sh tests/router-live-nonprod-integration-test.sh
# Optional:
#   R10_TEST_WG_CONF=/cfg/vpn-custom/conf/wgprtonus85.conf
#   R10_LIVE_CR_IFACE=wglivecr1
#   R10_LIVE_SP_IFACE=wglivesp1

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
WG_SCRIPT="$PROJECT_ROOT/wg.sh"
PROJECT_CONFIG_LIB="$PROJECT_ROOT/lib/project-config.sh"
VPN_BASE_DIR="$PROJECT_ROOT"
[ -f "$PROJECT_CONFIG_LIB" ] && . "$PROJECT_CONFIG_LIB"

VPN_PREFIX="${VPN_PREFIX:-vpnx1}"
DB_PATH="/tmp/${VPN_PREFIX}/pbr.db"

PASS=0
FAIL=0

IFACE_CR="${R10_LIVE_CR_IFACE:-wglivecr1}"
IFACE_SP="${R10_LIVE_SP_IFACE:-wglivesp1}"
PROD_IFACE="wgtorla"

TEST_MAC="${R10_LIVE_TEST_MAC:-aa:bb:cc:dd:ee:01}"
TEST_IP1="${R10_LIVE_TEST_IP1:-10.251.0.10}"
TEST_IP2="${R10_LIVE_TEST_IP2:-10.251.0.11}"
TEST_TARGETS="${R10_LIVE_TARGETS:-10.251.0.0/24}"
TEST_DOMAINS="${R10_LIVE_DOMAINS:-example.com}"

TEST_CONF="${R10_TEST_WG_CONF:-}"
TMP_CONF="/tmp/r10-live-int-${IFACE_CR}-$$.conf"
CREATED_CR=0
CREATED_SP=0

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
    if printf "%s" "$haystack" | grep -Fq -- "$needle"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected substring: $needle"
    fi
}

assert_cmd() {
    msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        say_pass "$msg"
    else
        say_fail "$msg"
    fi
}

cleanup() {
    if [ "$CREATED_CR" = "1" ]; then
        "$WG_SCRIPT" delete "$IFACE_CR" >/dev/null 2>&1 || true
    fi
    if [ "$CREATED_SP" = "1" ]; then
        "$WG_SCRIPT" delete "$IFACE_SP" >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_CONF"
}
trap cleanup EXIT INT TERM

echo "=== Router Live Non-Prod Integration Test ==="

if [ "${R10_LIVE_ALLOW_COMMIT:-0}" != "1" ]; then
    echo "[SKIP] R10_LIVE_ALLOW_COMMIT is not set to 1."
    echo "Set R10_LIVE_ALLOW_COMMIT=1 to run live commit tests."
    exit 0
fi

for bin in sqlite3 uci iptables ip6tables ipset; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "[SKIP] missing required binary: $bin"
        exit 0
    fi
done

if [ ! -x "$WG_SCRIPT" ]; then
    echo "[FAIL] missing wg wrapper: $WG_SCRIPT"
    exit 1
fi

if [ "$IFACE_CR" = "$PROD_IFACE" ] || [ "$IFACE_SP" = "$PROD_IFACE" ]; then
    echo "[FAIL] test interface name must not be $PROD_IFACE"
    exit 1
fi

if [ "$IFACE_CR" = "$IFACE_SP" ]; then
    echo "[FAIL] client-routing and split interface names must differ"
    exit 1
fi

if ip link show "$IFACE_CR" >/dev/null 2>&1 || ip link show "$IFACE_SP" >/dev/null 2>&1; then
    echo "[FAIL] test interface already exists in kernel: $IFACE_CR or $IFACE_SP"
    exit 1
fi

if [ -f "$DB_PATH" ]; then
    existing_rows="$(sqlite3 "$DB_PATH" "SELECT name FROM interfaces WHERE name IN ('$IFACE_CR','$IFACE_SP');" 2>/dev/null)"
    if [ -n "$existing_rows" ]; then
        echo "[FAIL] test interface already exists in db:"
        echo "$existing_rows"
        exit 1
    fi

    pending="$(sqlite3 "$DB_PATH" "SELECT name FROM interfaces WHERE committed = 0;" 2>/dev/null)"
    if [ -n "$pending" ]; then
        echo "[FAIL] found unrelated staged entries; refusing to run live commit:"
        echo "$pending"
        exit 1
    fi
fi

if [ -z "$TEST_CONF" ]; then
    for f in "$PROJECT_ROOT"/conf/*.conf; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        [ "$base" = "${PROD_IFACE}.conf" ] && continue
        grep -q '^\[Interface\]' "$f" 2>/dev/null || continue
        grep -q '^\[Peer\]' "$f" 2>/dev/null || continue
        TEST_CONF="$f"
        break
    done
fi

if [ -z "$TEST_CONF" ] || [ ! -f "$TEST_CONF" ]; then
    echo "[FAIL] could not resolve test WireGuard config."
    echo "Set R10_TEST_WG_CONF to a non-production .conf file."
    exit 1
fi

cp "$TEST_CONF" "$TMP_CONF"
say_pass "resolved test config: $TEST_CONF"

stage_cr="$("$WG_SCRIPT" "$IFACE_CR" -c "$TMP_CONF" -t "$TEST_TARGETS" 2>&1)"
if [ $? -eq 0 ]; then
    CREATED_CR=1
    say_pass "staged client-routing interface $IFACE_CR"
else
    say_fail "staged client-routing interface $IFACE_CR"
    echo "$stage_cr"
fi

stage_sp="$("$WG_SCRIPT" "$IFACE_SP" -c "$TMP_CONF" -d "$TEST_DOMAINS" 2>&1)"
if [ $? -eq 0 ]; then
    CREATED_SP=1
    say_pass "staged split-tunnel interface $IFACE_SP"
else
    say_fail "staged split-tunnel interface $IFACE_SP"
    echo "$stage_sp"
fi

if [ "$FAIL" -eq 0 ]; then
    commit_out="$("$WG_SCRIPT" commit 2>&1)"
    if [ $? -eq 0 ]; then
        say_pass "commit applied staged interfaces"
    else
        say_fail "commit applied staged interfaces"
        echo "$commit_out"
    fi
fi

status_cr="$("$WG_SCRIPT" status "$IFACE_CR" 2>&1 || true)"
status_sp="$("$WG_SCRIPT" status "$IFACE_SP" 2>&1 || true)"
assert_contains "$status_cr" "Mode             | Client Routing" "status shows client-routing mode"
assert_contains "$status_sp" "Mode             | Split-Tunnel" "status shows split-tunnel mode"
assert_contains "$status_cr" "Staged           | Committed" "client-routing interface is committed"
assert_contains "$status_sp" "Staged           | Committed" "split interface is committed"

MASTER_DHCP_HOTPLUG="/etc/hotplug.d/dhcp/99-${VPN_PREFIX}-master-pbr"
assert_cmd "master DHCP hotplug is deployed" test -x "$MASTER_DHCP_HOTPLUG"

if [ "$FAIL" -eq 0 ] && [ -x "$MASTER_DHCP_HOTPLUG" ]; then
    ACTION=add MACADDR="$TEST_MAC" IPADDR="$TEST_IP1" "$MASTER_DHCP_HOTPLUG" >/dev/null 2>&1
    ACTION=update MACADDR="$TEST_MAC" IPADDR="$TEST_IP2" "$MASTER_DHCP_HOTPLUG" >/dev/null 2>&1
    say_pass "synthetic DHCP add/update events executed"

    mac_row="$(sqlite3 -separator '|' "$DB_PATH" "SELECT mac,interface,ip FROM mac_state WHERE mac='${TEST_MAC}' LIMIT 1;" 2>/dev/null)"
    assert_contains "$mac_row" "|$IFACE_CR|$TEST_IP2" "MAC state moved to latest IP on client-routing iface"
fi

split_chain="split_${IFACE_SP}"
assert_cmd "split chain exists (mangle)" iptables -w -t mangle -S "$split_chain"
if iptables -w -t mangle -S "$split_chain" >/tmp/r10-split-chain.$$ 2>/dev/null; then
    split_rules="$(cat /tmp/r10-split-chain.$$ 2>/dev/null)"
    rm -f /tmp/r10-split-chain.$$
    assert_contains "$split_rules" "--match-set vpn_${IFACE_CR} src -j RETURN" "split chain bypasses client-routing vpn_* source set"
fi

if [ "$CREATED_CR" = "1" ]; then
    "$WG_SCRIPT" delete "$IFACE_CR" >/dev/null 2>&1 || true
    CREATED_CR=0
    say_pass "deleted temporary client-routing interface"
fi
if [ "$CREATED_SP" = "1" ]; then
    "$WG_SCRIPT" delete "$IFACE_SP" >/dev/null 2>&1 || true
    CREATED_SP=0
    say_pass "deleted temporary split interface"
fi

if [ -f "$DB_PATH" ]; then
    rows_after="$(sqlite3 "$DB_PATH" "SELECT name FROM interfaces WHERE name IN ('$IFACE_CR','$IFACE_SP');" 2>/dev/null)"
    if [ -z "$rows_after" ]; then
        say_pass "temporary interfaces removed from database"
    else
        say_fail "temporary interfaces removed from database"
        echo "$rows_after"
    fi
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
