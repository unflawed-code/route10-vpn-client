#!/bin/sh
# Phase 4 deferred DHCP subnet replay test:
# - subnet targets are expanded using DHCP leases
# - master DHCP hotplug is invoked for matching leases

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p4sub)"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMP_DIR"
    rm -f /tmp/dhcp.leases 2>/dev/null || true
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
    fi
}

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins" "$TMP_DIR/runtime" "$TMP_DIR/tmp"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cp "$PROJECT_ROOT/lib/common.sh" "$TMP_DIR/lib/common.sh"
cp "$PROJECT_ROOT/lib/state.sh" "$TMP_DIR/lib/state.sh"
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF_PBR'
#!/bin/sh
EOF_PBR

HOTPLUG_LOG="$TMP_DIR/hotplug.log"
cat > "$TMP_DIR/hotplug.sh" <<'EOF_HOT'
#!/bin/sh
echo "HOTPLUG:$ACTION:$MACADDR:$IPADDR" >> HOTPLUG_LOG_PLACEHOLDER
EOF_HOT
sed -i "s|HOTPLUG_LOG_PLACEHOLDER|$HOTPLUG_LOG|g" "$TMP_DIR/hotplug.sh"
chmod +x "$TMP_DIR/hotplug.sh"

# Create a mock DHCP lease file.
cat > /tmp/dhcp.leases <<'EOF_LEASES'
1710000000 aa:bb:cc:dd:ee:01 10.90.15.10 host1 *
1710000000 aa:bb:cc:dd:ee:02 10.90.15.20 host2 *
1710000000 aa:bb:cc:dd:ee:03 10.90.16.10 host3 *
EOF_LEASES

export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/runtime"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"
MASTER_DHCP_HOTPLUG="$TMP_DIR/hotplug.sh"

echo "=== Phase 4 Deferred DHCP Subnet Test ==="

deferred_file="$TMP_DIR/tmp/deferred_dhcp.tmp"
printf "%s\n" "10.90.15.0/24" > "$deferred_file"

_vpn_core_replay_deferred_dhcp "$deferred_file"

log_data="$(cat "$HOTPLUG_LOG" 2>/dev/null)"
assert_contains "$log_data" "HOTPLUG:add:aa:bb:cc:dd:ee:01:10.90.15.10" "subnet replay triggers hotplug for matching lease 1"
assert_contains "$log_data" "HOTPLUG:add:aa:bb:cc:dd:ee:02:10.90.15.20" "subnet replay triggers hotplug for matching lease 2"

if printf "%s" "$log_data" | grep -Fq "10.90.16.10"; then
    say_fail "subnet replay ignores non-matching lease"
else
    say_pass "subnet replay ignores non-matching lease"
fi

# Neighbor table fallback (no DHCP leases)
rm -f /tmp/dhcp.leases 2>/dev/null || true
rm -f "$HOTPLUG_LOG" 2>/dev/null || true
printf "%s\n" "10.90.15.0/24" > "$deferred_file"
ip() {
    if [ "$1" = "neigh" ] && [ "$2" = "show" ]; then
        cat <<'EOF_NEIGH'
10.90.15.30 dev br-lan lladdr aa:bb:cc:dd:ee:04 REACHABLE
10.90.16.30 dev br-lan lladdr aa:bb:cc:dd:ee:05 REACHABLE
EOF_NEIGH
        return 0
    fi
    return 0
}

_vpn_core_replay_deferred_dhcp "$deferred_file"

log_data="$(cat "$HOTPLUG_LOG" 2>/dev/null)"
assert_contains "$log_data" "HOTPLUG:add:aa:bb:cc:dd:ee:04:10.90.15.30" "neighbor fallback triggers hotplug for matching entry"
if printf "%s" "$log_data" | grep -Fq "10.90.16.30"; then
    say_fail "neighbor fallback ignores non-matching entry"
else
    say_pass "neighbor fallback ignores non-matching entry"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
