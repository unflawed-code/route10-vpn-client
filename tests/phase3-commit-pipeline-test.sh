#!/bin/sh
# Phase 3 commit pipeline tests:
# - two-pass ordering (target first, split second)
# - target-only hot reload paths (no ifup)
# - deferred DHCP replay after commit
# - single dnsmasq restart point

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p3)"
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

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins" "$TMP_DIR/hotplug/dhcp" "$TMP_DIR/hotplug/iface" "$TMP_DIR/tmp"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cat > "$TMP_DIR/lib/common.sh" <<'EOF'
#!/bin/sh
get_ip_from_target() {
    case "$1" in
        *=*) echo "${1#*=}" ;;
        *)   echo "$1" ;;
    esac
}
is_mac() {
    clean=$(echo "$1" | tr -d ':-' | tr 'A-F' 'a-f')
    [ ${#clean} -eq 12 ] && echo "$clean" | grep -qE '^[0-9a-f]{12}$'
}
normalize_mac() {
    clean=$(echo "$1" | tr -d ':-' | tr 'A-F' 'a-f')
    echo "$clean" | sed 's/\(..\)/\1:/g; s/:$//'
}
discover_mac_for_ip() {
    case "$1" in
        10.0.0.3) echo "11:22:33:44:55:66" ;;
        10.0.0.4) echo "22:33:44:55:66:77" ;;
        *) echo "" ;;
    esac
}
resolve_mac_to_ip() { echo ""; }
EOF
cat > "$TMP_DIR/lib/state.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/split-tunnel.sh" <<'EOF'
#!/bin/sh
split_tunnel_apply() {
    echo "split_tunnel_apply:$1:$2:$3:$4:$5" >> "$TEST_LOG"
    return 0
}
EOF
chmod +x "$TMP_DIR/lib/vpn-core.sh"

cat > "$TMP_DIR/mock-dnsmasq.sh" <<'EOF'
#!/bin/sh
echo "dnsmasq:$*" >> "$TEST_LOG"
EOF
chmod +x "$TMP_DIR/mock-dnsmasq.sh"

cat > "$TMP_DIR/hotplug/dhcp/99-r10test-master-pbr" <<'EOF'
#!/bin/sh
echo "dhcp_replay:${ACTION}:${MACADDR}:${IPADDR}" >> "$TEST_LOG"
EOF
chmod +x "$TMP_DIR/hotplug/dhcp/99-r10test-master-pbr"

export VPN_PREFIX="r10test"
export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/tmp"
export HOTPLUG_DHCP_DIR="$TMP_DIR/hotplug/dhcp"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug/iface"
export VPN_DNSMASQ_SERVICE="$TMP_DIR/mock-dnsmasq.sh"
export TEST_LOG="$TMP_DIR/phase3.log"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

db_init() { :; }
db_list_staged() {
    cat <<'EOF'
wg-new|wireguard|conf/wg-new.conf|101|aa:bb:cc:dd:ee:ff=10.0.0.2|0|0|
wg-hot|wireguard|conf/wg-hot.conf|102|10.0.0.3|1|1|
wg-split-new|wireguard|conf/wg-split-new.conf|103|none|0|0|example.com
wg-split-hot|wireguard|conf/wg-split-hot.conf|104|none|1|1|netflix.com
EOF
}
db_get_field() {
    iface="$1"
    field="$2"
    case "$field" in
        dns_servers)
            case "$iface" in
                wg-new) echo "1.1.1.1" ;;
                wg-hot) echo "8.8.8.8" ;;
                wg-split-new) echo "9.9.9.9" ;;
                wg-split-hot) echo "4.4.4.4" ;;
            esac
            ;;
        ipv6_support)
            echo "0"
            ;;
    esac
}
db_set_target_only() {
    echo "db_set_target_only:$1:$2" >> "$TEST_LOG"
}
db_commit_interface() {
    echo "db_commit_interface:$1" >> "$TEST_LOG"
}
db_set_running() {
    echo "db_set_running:$1:$2" >> "$TEST_LOG"
}
pbr_hot_reload() {
    echo "pbr_hot_reload:$1:$2:$3:$4" >> "$TEST_LOG"
}
ifup() {
    echo "ifup:$1" >> "$TEST_LOG"
}
uci() {
    echo "uci:$*" >> "$TEST_LOG"
}
vpn_core_setup_dnsmasq_hook() {
    echo "dnsmasq_hook:changed" >> "$TEST_LOG"
    return 0
}
vpn_core_run_hooks() { return 0; }
logger() {
    echo "logger:$*" >> "$TEST_LOG"
}
ip() { return 1; }

echo "=== Phase 3 Commit Pipeline Tests ==="

vpn_core_commit >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "vpn_core_commit exits 0"

log_data="$(cat "$TEST_LOG" 2>/dev/null)"

assert_contains "$log_data" "pbr_hot_reload:wg-hot:10.0.0.3:102:8.8.8.8" "target-only committed interface uses hot reload"
assert_contains "$log_data" "split_tunnel_apply:wg-split-hot:104:netflix.com:4.4.4.4:0" "split target-only committed interface uses split apply hot reload"

assert_contains "$log_data" "db_commit_interface:wg-new" "new target interface is committed"
assert_contains "$log_data" "db_commit_interface:wg-split-new" "new split interface is committed"
assert_not_contains "$log_data" "db_commit_interface:wg-hot" "target-only hot reload does not re-commit interface"
assert_not_contains "$log_data" "db_commit_interface:wg-split-hot" "split hot reload does not re-commit interface"

assert_contains "$log_data" "ifup:wg-new" "new target interface is brought up"
assert_contains "$log_data" "ifup:wg-split-new" "new split interface is brought up"
assert_not_contains "$log_data" "ifup:wg-hot" "target-only hot reload skips ifup"
assert_not_contains "$log_data" "ifup:wg-split-hot" "split hot reload skips ifup"

target_line="$(awk '/pbr_hot_reload:wg-hot/ {print NR; exit}' "$TEST_LOG")"
split_line="$(awk '/split_tunnel_apply:wg-split-hot/ {print NR; exit}' "$TEST_LOG")"
if [ -n "$target_line" ] && [ -n "$split_line" ] && [ "$target_line" -lt "$split_line" ]; then
    say_pass "two-pass ordering runs target pass before split pass"
else
    say_fail "two-pass ordering runs target pass before split pass"
fi

assert_contains "$log_data" "dhcp_replay:add:aa:bb:cc:dd:ee:ff:10.0.0.2" "deferred DHCP replay includes explicit MAC=IP target"
assert_contains "$log_data" "dhcp_replay:add:11:22:33:44:55:66:10.0.0.3" "deferred DHCP replay resolves MAC for IP target"

dnsmasq_restarts="$(grep -c '^dnsmasq:restart$' "$TEST_LOG" 2>/dev/null || true)"
assert_eq "1" "$dnsmasq_restarts" "dnsmasq restart is coalesced into a single call"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
