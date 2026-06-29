#!/bin/sh
# Phase 5 split lifecycle test:
# - split setup remains staged (no vpn_core_start)
# - split staging uses DB helpers and stage assets

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p5stage)"
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

mkdir -p "$TMP_DIR/lib/util" "$TMP_DIR/lib"
cp "$PROJECT_ROOT/wg.sh" "$TMP_DIR/wg.sh"

cat > "$TMP_DIR/lib/vpn-core.sh" <<'EOF'
#!/bin/sh
vpn_core_set_type() { VPN_CURRENT_TYPE="$1"; }
vpn_core_show_plugin_help() { :; }
vpn_core_handle_command() { return 1; }
trim() { echo "$1"; }
analyze_ipv6() {
    IPV6_SUPPORTED=1
    VPN_IP6_SUBNETS="2001:db8:1::/64"
    VPN_IP6_NEEDS_NAT66=1
}
is_mac() { return 1; }
resolve_mac_to_ip() { echo ""; }
db_init() { echo "db_init" >> "$TEST_LOG"; }
db_get_field() { echo ""; }
db_set_staged_split_tunnel() { echo "db_set_staged_split_tunnel:$*" >> "$TEST_LOG"; }
db_update_staged_domains() { echo "db_update_staged_domains:$*" >> "$TEST_LOG"; }
db_set_ipv6() { echo "db_set_ipv6:$*" >> "$TEST_LOG"; }
db_set_ipv6_profile() { echo "db_set_ipv6_profile:$*" >> "$TEST_LOG"; }
db_set_ipv6_health() { echo "db_set_ipv6_health:$*" >> "$TEST_LOG"; }
db_commit_interface() { echo "db_commit_interface:$*" >> "$TEST_LOG"; }
db_set_target_only() { echo "db_set_target_only:$*" >> "$TEST_LOG"; }
vpn_core_stage_assets() { echo "vpn_core_stage_assets:$*" >> "$TEST_LOG"; return 0; }
vpn_core_start() { echo "vpn_core_start:$*" >> "$TEST_LOG"; return 0; }
vpn_core_setup_uci_interface() { echo "vpn_core_setup_uci_interface:$1" >> "$TEST_LOG"; }
vpn_core_setup_uci_firewall() { echo "vpn_core_setup_uci_firewall:$1" >> "$TEST_LOG"; }
db_allocate_routing_table() { echo "1000"; }
uci() { [ "$1" = "add" ] && { echo "cfg001"; return 0; }; return 0; }
netstat() { return 1; }
EOF

cat > "$TMP_DIR/lib/split-tunnel.sh" <<'EOF'
#!/bin/sh
EOF

cat > "$TMP_DIR/lib/util/table.sh" <<'EOF'
#!/bin/sh
print_table_header() { :; }
print_table_row() { :; }
EOF

cat > "$TMP_DIR/test.conf" <<'EOF'
[Interface]
PrivateKey = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
Address = 10.10.10.2/24,2001:db8:1::2/64
DNS = 9.9.9.9

[Peer]
PublicKey = yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy=
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
EOF

chmod +x "$TMP_DIR/wg.sh"
export TEST_LOG="$TMP_DIR/phase5-stage.log"

echo "=== Phase 5 Split Stage Test ==="

output="$(cd "$TMP_DIR" && ./wg.sh wgsplit -c test.conf -d example.com 2>&1)"
log_data="$(cat "$TEST_LOG" 2>/dev/null)"

assert_contains "$output" "Split-Tunnel configuration staged for wgsplit." "split setup reports staged state"
assert_contains "$log_data" "db_set_staged_split_tunnel:wgsplit test.conf 1000 example.com wireguard 9.9.9.9" "split setup uses split DB staging helper with DNS"
assert_contains "$log_data" "vpn_core_stage_assets:wgsplit 1000 none 9.9.9.9 1 2001:db8:1::/64 1" "split setup only stages assets"
assert_not_contains "$log_data" "vpn_core_start:" "split setup does not start/commit during staging"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
