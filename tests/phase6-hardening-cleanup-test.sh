#!/bin/sh
# Phase 6 hardening/delete parity test:
# - residual cleanup covers split artifacts
# - critical firewall writes use iptables/ip6tables -w

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p6)"
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

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins" "$TMP_DIR/runtime"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cat > "$TMP_DIR/lib/common.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/state.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF'
#!/bin/sh
EOF

export VPN_PREFIX="r10test"
export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/runtime"
export TEST_LOG="$TMP_DIR/phase6.log"

mkdir -p /tmp/dnsmasq.d 2>/dev/null || true
touch "$VPN_TMP_DIR/wg0-split-dnsmasq.conf"
touch "$VPN_TMP_DIR/wg0-split-dnsmasq.pid"
touch "/tmp/dnsmasq.d/wg0-split-stub.conf"
touch "$VPN_TMP_DIR/prefix_wg0_aabbccddeeff"
touch "$VPN_TMP_DIR/ip_wg0_aabbccddeeff"
touch "/tmp/dnsmasq.d/99-wg0-dns.conf"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

iptables() { echo "iptables:$*" >> "$TEST_LOG"; return 0; }
ip6tables() { echo "ip6tables:$*" >> "$TEST_LOG"; return 0; }
ipset() { echo "ipset:$*" >> "$TEST_LOG"; return 0; }

echo "=== Phase 6 Hardening/Cleanup Test ==="

_vpn_core_cleanup_residual_artifacts "wg0"
log_data="$(cat "$TEST_LOG")"

assert_contains "$log_data" "iptables:-w -t mangle -D PREROUTING -j split_wg0" "residual cleanup unhooks split chain from PREROUTING"
assert_contains "$log_data" "ipset:destroy dst_vpn_wg0" "residual cleanup destroys split IPv4 destination ipset"
assert_contains "$log_data" "ipset:destroy dst6_vpn_wg0" "residual cleanup destroys split IPv6 destination ipset"

if [ ! -f "$VPN_TMP_DIR/wg0-split-dnsmasq.conf" ] && [ ! -f "$VPN_TMP_DIR/wg0-split-dnsmasq.pid" ] && [ ! -f "/tmp/dnsmasq.d/wg0-split-stub.conf" ]; then
    say_pass "residual cleanup removes split dnsmasq artifacts"
else
    say_fail "residual cleanup removes split dnsmasq artifacts"
fi

if [ ! -f "$VPN_TMP_DIR/prefix_wg0_aabbccddeeff" ] && [ ! -f "$VPN_TMP_DIR/ip_wg0_aabbccddeeff" ] && [ ! -f "/tmp/dnsmasq.d/99-wg0-dns.conf" ]; then
    say_pass "residual cleanup removes roaming and dns state artifacts"
else
    say_fail "residual cleanup removes roaming and dns state artifacts"
fi

hotplug_dir="$TMP_DIR/hotplug"
mkdir -p "$hotplug_dir"
HOTPLUG_IFACE_DIR="$hotplug_dir"
touch "$hotplug_dir/99-r10test-wg0-split"
touch "$hotplug_dir/99-r10test-wg0-routing"
touch "$hotplug_dir/99-r10test-wg0-cleanup"
vpn_core_remove_hotplug_scripts "wg0"
if [ ! -f "$hotplug_dir/99-r10test-wg0-split" ] && [ ! -f "$hotplug_dir/99-r10test-wg0-routing" ] && [ ! -f "$hotplug_dir/99-r10test-wg0-cleanup" ]; then
    say_pass "hotplug cleanup removes split and standard scripts"
else
    say_fail "hotplug cleanup removes split and standard scripts"
fi

# Killswitch cleanup must be tolerant when chains are already gone.
iptables() { echo "iptables:$*" >> "$TEST_LOG"; return 1; }
ip6tables() { echo "ip6tables:$*" >> "$TEST_LOG"; return 1; }
vpn_core_remove_killswitch "wg0"
rc=$?
assert_eq "0" "$rc" "vpn_core_remove_killswitch tolerates missing chains"

if command -v rg >/dev/null 2>&1; then
    ipt_w_count="$(rg -o '\biptables -w\b' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')"
    ip6_w_count="$(rg -o '\bip6tables -w\b' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')"
else
    ipt_w_count="$(grep -Rho 'iptables -w' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')"
    ip6_w_count="$(grep -Rho 'ip6tables -w' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')"
fi
if [ "${ipt_w_count:-0}" -gt 0 ]; then
    say_pass "iptables -w coverage is present in lib/"
else
    say_fail "iptables -w coverage is present in lib/"
fi
if [ "${ip6_w_count:-0}" -gt 0 ]; then
    say_pass "ip6tables -w coverage is present in lib/"
else
    say_fail "ip6tables -w coverage is present in lib/"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
