#!/bin/sh
# Phase 4 roaming stability tests:
# - DHCP hotplug deployment placeholder replacement
# - cleanup-before-apply ordering
# - tunnel-down kill switch branch
# - block-first IPv6 ordering

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p4)"
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

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins" "$TMP_DIR/hotplug/dhcp" "$TMP_DIR/hotplug/iface" "$TMP_DIR/tmp"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cp "$PROJECT_ROOT/lib/vpn-dhcp-handler.sh" "$TMP_DIR/lib/vpn-dhcp-handler.sh"
cat > "$TMP_DIR/lib/common.sh" <<'EOF'
#!/bin/sh
get_lan_ifaces() { echo "br-lan"; }
EOF
cat > "$TMP_DIR/lib/state.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF'
#!/bin/sh
EOF

export VPN_PREFIX="r10test"
export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/tmp"
export HOTPLUG_DHCP_DIR="$TMP_DIR/hotplug/dhcp"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug/iface"
export TEST_LOG="$TMP_DIR/phase4.log"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

echo "=== Phase 4 Roaming Stability Tests ==="

# T17/T18/T19: DHCP hotplug deployment and placeholder replacement
vpn_core_setup_dhcp_handling
dhcp_script="$HOTPLUG_DHCP_DIR/99-r10test-master-pbr"
if [ -f "$dhcp_script" ]; then
    say_pass "master DHCP hotplug script is deployed"
else
    say_fail "master DHCP hotplug script is deployed"
fi
dhcp_contents="$(cat "$dhcp_script" 2>/dev/null)"
assert_not_contains "$dhcp_contents" "VPN_CORE_LIB_PLACEHOLDER" "VPN core lib placeholder is replaced"
assert_not_contains "$dhcp_contents" "VPN_TMP_DIR_PLACEHOLDER" "VPN tmp dir placeholder is replaced"
assert_contains "$dhcp_contents" "flock -x 200" "DHCP hotplug script includes lock-based serialization"
assert_contains "$dhcp_contents" "dhcp_hotplug.guard" "DHCP hotplug script includes storm guard state"

db_get_mac_by_mac() { echo "${OLD_STATE:-}"; }
db_set_mac_state() { echo "db_set_mac_state:$1:$2:$3:$4:$5" >> "$TEST_LOG"; }
db_delete_mac_by_mac() { echo "db_delete_mac_by_mac:$1" >> "$TEST_LOG"; }
db_get_field() {
    iface="$1"
    field="$2"
    case "$field" in
        dns_servers) echo "9.9.9.9" ;;
        ipv6_subnets) echo "2001:db8:1::/64" ;;
        *) echo "" ;;
    esac
}
vpn_core_find_interface_for_ip() { echo "${MATCH_DATA:-}"; }
pbr_remove_client() { echo "pbr_remove_client:$1:$2:$3:$4" >> "$TEST_LOG"; }
pbr_add_client() { echo "pbr_add_client:$1:$2:$3:$4:$5" >> "$TEST_LOG"; }
vpn_core_discover_client_ipv6() { echo "discover_ipv6:$*" >> "$TEST_LOG"; }
calculate_mark() { echo "65555"; }
logger() { echo "logger:$*" >> "$TEST_LOG"; }

iptables() {
    echo "iptables:$*" >> "$TEST_LOG"
    case " $* " in
        *" -D "*) return 1 ;;
        *" -C "*) return 1 ;;
    esac
    return 0
}
ip6tables() {
    echo "ip6tables:$*" >> "$TEST_LOG"
    case " $* " in
        *" -D "*) return 1 ;;
        *" -C "*) return 1 ;;
    esac
    return 0
}
ip() {
    if [ "$1" = "-4" ] && [ "$2" = "route" ] && [ "$3" = "get" ]; then
        echo "$4 dev br-lan_15 src 10.0.0.1 uid 0"
        return 0
    fi
    if [ "$1" = "link" ] && [ "$2" = "show" ]; then
        if [ "${TUNNEL_UP:-1}" = "1" ]; then
            echo "3: $3: <BROADCAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT"
            return 0
        fi
        return 1
    fi
    if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "show" ]; then
        return 0
    fi
    return 0
}

# Case 1: Roam to new interface; cleanup old mapping first.
: > "$TEST_LOG"
OLD_STATE="aa:bb:cc:dd:ee:ff|wgold|10.0.0.40|100|1"
MATCH_DATA="wgnew|101|9.9.9.9|1|0"
TUNNEL_UP=1
ACTION="add" MACADDR="aa:bb:cc:dd:ee:ff" IPADDR="10.0.0.50" vpn_core_handle_dhcp

log_data="$(cat "$TEST_LOG")"
rm_line="$(awk '/pbr_remove_client:wgold:100:10.0.0.40:aa:bb:cc:dd:ee:ff/ {print NR; exit}' "$TEST_LOG")"
add_line="$(awk '/pbr_add_client:wgnew:101:10.0.0.50:9.9.9.9:1/ {print NR; exit}' "$TEST_LOG")"
if [ -n "$rm_line" ] && [ -n "$add_line" ] && [ "$rm_line" -lt "$add_line" ]; then
    say_pass "roaming cleanup happens before new apply"
else
    say_fail "roaming cleanup happens before new apply"
fi
assert_contains "$log_data" "db_set_mac_state:aa:bb:cc:dd:ee:ff:wgnew:10.0.0.50:101:1" "new MAC state is persisted after apply"

block_line="$(awk '/ip6tables:-w -I wgnew_ipv6_block 1 -i br-lan_15/ {print NR; exit}' "$TEST_LOG")"
mark_line="$(awk '/ip6tables:-w -t mangle -A mark_wgnew -i br-lan_15 -m mac --mac-source aa:bb:cc:dd:ee:ff -j MARK --set-mark 65555/ {print NR; exit}' "$TEST_LOG")"
if [ -n "$block_line" ] && [ -n "$mark_line" ] && [ "$block_line" -lt "$mark_line" ]; then
    say_pass "IPv6 leak block is installed before fwmark rule"
else
    say_fail "IPv6 leak block is installed before fwmark rule"
fi
assert_not_contains "$log_data" "ip6tables:-w -t mangle -A mark_wgnew -m mac --mac-source aa:bb:cc:dd:ee:ff -j MARK --set-mark 65555" "MAC mark rule is interface-scoped"
assert_not_contains "$log_data" "ip6tables:-w -I wgnew_ipv6_block 1 -i br-lan -m mac --mac-source aa:bb:cc:dd:ee:ff -m mark ! --mark 65555 -j DROP" "IPv6 block rule is not installed on unrelated VLANs"

# Case 2: Tunnel down branch applies kill switch and skips pbr_add_client.
: > "$TEST_LOG"
OLD_STATE=""
MATCH_DATA="wgnew|101|9.9.9.9|1|0"
TUNNEL_UP=0
ACTION="add" MACADDR="aa:bb:cc:dd:ee:ff" IPADDR="10.0.0.60" vpn_core_handle_dhcp

log_data="$(cat "$TEST_LOG")"
assert_contains "$log_data" "logger:-t vpn-core [wgnew] Client 10.0.0.60 (aa:bb:cc:dd:ee:ff) detected while tunnel is down; enforcing kill switch." "tunnel-down branch logs kill switch path"
assert_contains "$log_data" "iptables:-w -A wgnew_killswitch -s 10.0.0.60 -j REJECT --reject-with icmp-host-prohibited" "tunnel-down branch adds IPv4 kill switch rule"
assert_not_contains "$log_data" "pbr_add_client:wgnew" "tunnel-down branch skips pbr_add_client"

# Case 3: Same interface with new IP cleans old rule before apply.
: > "$TEST_LOG"
OLD_STATE="aa:bb:cc:dd:ee:ff|wgnew|10.0.0.70|101|1"
MATCH_DATA="wgnew|101|9.9.9.9|1|0"
TUNNEL_UP=1
ACTION="update" MACADDR="aa:bb:cc:dd:ee:ff" IPADDR="10.0.0.71" vpn_core_handle_dhcp

rm_line="$(awk '/pbr_remove_client:wgnew:101:10.0.0.70:aa:bb:cc:dd:ee:ff/ {print NR; exit}' "$TEST_LOG")"
add_line="$(awk '/pbr_add_client:wgnew:101:10.0.0.71:9.9.9.9:1/ {print NR; exit}' "$TEST_LOG")"
if [ -n "$rm_line" ] && [ -n "$add_line" ] && [ "$rm_line" -lt "$add_line" ]; then
    say_pass "same-interface IP update cleans old state before apply"
else
    say_fail "same-interface IP update cleans old state before apply"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
