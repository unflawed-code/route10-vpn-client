#!/bin/sh
# Phase 2 manage commands plugin tests:
# - assign/remove IPs update targets + target_only
# - assign/remove domains validate split mode

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p2manage)"
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
    fi
}

mkdir -p "$TMP_DIR/lib" "$TMP_DIR/plugins"
cp "$PROJECT_ROOT/plugins/05-manage-commands.sh" "$TMP_DIR/plugins/05-manage-commands.sh"

cat > "$TMP_DIR/lib/common.sh" <<'EOF'
#!/bin/sh
is_mac() {
    [ "$1" = "aa:bb:cc:dd:ee:ff" ] || [ "$1" = "bb:cc:dd:ee:ff:00" ]
}
normalize_mac() { echo "$1"; }
resolve_mac_to_ip() {
    case "$1" in
        aa:bb:cc:dd:ee:ff) echo "10.0.0.5" ;;
        bb:cc:dd:ee:ff:00) echo "10.90.5.11" ;;
    esac
}
get_ip_from_target() {
    case "$1" in
        *=*) echo "${1#*=}" ;;
        *) echo "$1" ;;
    esac
}
targets_route_via_iface() {
    local targets="$1"
    local iface="$2"
    local t ip
    for t in $(echo "$targets" | tr ',' ' '); do
        [ -z "$t" ] && continue
        ip=$(get_ip_from_target "$t")
        case "$ip" in
            10.90.5.*|10.90.5.0/24)
                [ "$iface" = "br-lan_5" ] || return 1
                ;;
            10.90.6.*|10.90.6.0/24)
                [ "$iface" = "br-lan_6" ] || return 1
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 0
}
EOF

cat > "$TMP_DIR/lib/state.sh" <<'EOF'
#!/bin/sh
DB_ENTRY_IP="wg0|wireguard|conf/wg0.conf|101|10.0.0.2|none|8.8.8.8|1|0|0||0|0|1"
DB_ENTRY_SPLIT="wg1|wireguard|conf/wg1.conf|102|none|example.com|8.8.8.8|1|0|0||0|0|1"
DB_ENTRY_ROUTED="wg2|wireguard|conf/wg2.conf|103|10.90.5.0/24|none|8.8.8.8|1|0|1||0|0|1|routed-prefix|2001:db8:5::/64|br-lan_5"
DB_ENTRY_ROUTED_SINGLE="wg3|wireguard|conf/wg3.conf|104|10.90.6.0/24|none|8.8.8.8|1|0|1||0|0|1|routed-prefix|2001:db8:6::/64|br-lan_6"
LAST_UPDATE_TARGETS=""
LAST_TARGET_ONLY=""
LAST_UPDATE_DOMAINS=""

db_get_interface() {
    case "$1" in
        wg0) echo "$DB_ENTRY_IP" ;;
        wg1) echo "$DB_ENTRY_SPLIT" ;;
        wg2) echo "$DB_ENTRY_ROUTED" ;;
        wg3) echo "$DB_ENTRY_ROUTED_SINGLE" ;;
    esac
}

db_get_field() {
    case "$1|$2" in
        wg0|target_ips) echo "10.0.0.2" ;;
        wg1|target_ips) echo "none" ;;
        wg2|target_ips) echo "10.90.5.0/24" ;;
        wg3|target_ips) echo "10.90.6.0/24" ;;
    esac
}

db_find_interface_by_ip() { :; }

db_is_committed() {
    [ "$1" = "wg0" ] || [ "$1" = "wg1" ]
}

db_update_targets() { LAST_UPDATE_TARGETS="$1|$2"; }
db_set_target_only() { LAST_TARGET_ONLY="$1|$2"; }
db_update_staged_domains() { LAST_UPDATE_DOMAINS="$1|$2|$3"; }
EOF

export LIB_DIR="$TMP_DIR/lib"

# shellcheck source=/dev/null
. "$TMP_DIR/plugins/05-manage-commands.sh"

echo "=== Phase 2 Manage Commands Tests ==="

cmd_assign_ip "wg0" "10.0.0.3,aa:bb:cc:dd:ee:ff"
assert_eq "wg0|10.0.0.2,10.0.0.3,aa:bb:cc:dd:ee:ff=10.0.0.5" "$LAST_UPDATE_TARGETS" "assign-ips appends targets and MAC=IP"
assert_eq "wg0|1" "$LAST_TARGET_ONLY" "assign-ips sets target_only when committed"

cmd_remove_ip "wg0" "10.0.0.2"
assert_eq "wg0|none" "$LAST_UPDATE_TARGETS" "remove-ips clears last target to none"
assert_eq "wg0|1" "$LAST_TARGET_ONLY" "remove-ips sets target_only when committed"

out="$(cmd_assign_domains "wg0" "example.com" 2>&1 || true)"
assert_contains "$out" "Cannot assign domains to IP-routing interface" "assign-domains blocked on IP interface"

cmd_assign_domains "wg1" "NetFlix.com,apple.com"
assert_eq "wg1|example.com,netflix.com,apple.com|1" "$LAST_UPDATE_DOMAINS" "assign-domains lowercases and accumulates"

out="$(cmd_remove_domains "wg0" "example.com" 2>&1 || true)"
assert_contains "$out" "Cannot remove domains from IP-routing interface" "remove-domains blocked on IP interface"

LAST_UPDATE_TARGETS=""
out="$(cmd_remove_ip "wg2" "10.90.5.0/24" 2>&1 || true)"
assert_contains "$out" "requires exactly one subnet target only" "routed-prefix remove-ips blocks removing the only subnet target"
assert_eq "" "$LAST_UPDATE_TARGETS" "routed-prefix blocked remove does not stage target update"

LAST_UPDATE_TARGETS=""
out="$(cmd_assign_ip "wg2" "10.90.7.0/24" 2>&1 || true)"
assert_contains "$out" "requires exactly one subnet target only" "routed-prefix assign-ips blocks adding a second subnet"
assert_eq "" "$LAST_UPDATE_TARGETS" "routed-prefix blocked assign does not stage target update"

LAST_UPDATE_TARGETS=""
out="$(cmd_assign_ip "wg2" "10.90.1.10" 2>&1 || true)"
assert_contains "$out" "accepts subnet targets only" "routed-prefix assign-ips blocks host targets"
assert_eq "" "$LAST_UPDATE_TARGETS" "out-of-iface routed-prefix assign does not stage target update"

LAST_UPDATE_TARGETS=""
out="$(cmd_remove_ip "wg2" "bb:cc:dd:ee:ff:00" 2>&1 || true)"
assert_contains "$out" "accepts subnet targets only" "routed-prefix remove-ips blocks MAC targets"
assert_eq "" "$LAST_UPDATE_TARGETS" "routed-prefix blocked MAC remove does not stage target update"

LAST_UPDATE_TARGETS=""
out="$(cmd_remove_ip "wg3" "10.90.6.0/24" 2>&1 || true)"
assert_contains "$out" "requires exactly one subnet target only" "routed-prefix remove-ips keeps one subnet target required"
assert_eq "" "$LAST_UPDATE_TARGETS" "routed-prefix remove of last subnet does not stage target update"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
