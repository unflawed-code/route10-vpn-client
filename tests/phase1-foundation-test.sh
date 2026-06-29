#!/bin/sh
# Phase 1 foundation tests:
# - state.sh helper parity functions
# - ip-routing.sh unregister_routing_table fix

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_LIB="$PROJECT_ROOT/lib/state.sh"
IP_ROUTING_LIB="$PROJECT_ROOT/lib/routing/ip-routing.sh"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p1)"
SQLITE_LOG="$TMP_DIR/sqlite.log"
SQLITE_TYPE_RESULT=""
PBR_DB_PATH="$TMP_DIR/pbr.db"
export PBR_DB_PATH

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

assert_file_contains() {
    file="$1"
    needle="$2"
    msg="$3"
    if grep -Fq "$needle" "$file"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected substring: $needle"
        echo "  in file: $file"
    fi
}

# sqlite3 mock:
# - logs all SQL for assertions
# - returns SQLITE_TYPE_RESULT for SELECT type ... queries used by db_set_staged_split_tunnel
sqlite3() {
    db_path="$1"
    shift || true

    if [ "$#" -gt 0 ]; then
        sql="$*"
    else
        sql="$(cat)"
    fi

    printf "DB:%s\nSQL:%s\n---\n" "$db_path" "$sql" >> "$SQLITE_LOG"

    case "$sql" in
        *"SELECT type FROM interfaces WHERE name ="*)
            printf "%s" "$SQLITE_TYPE_RESULT"
            ;;
    esac
}

# Source after sqlite3 mock is defined
. "$STATE_LIB"
. "$IP_ROUTING_LIB"

latest_sql() {
    awk '
        /^SQL:/ { line=substr($0,5) }
        /^---$/ { last=line }
        END { print last }
    ' "$SQLITE_LOG"
}

echo "=== Phase 1 Foundation Tests ==="

# T01: db_update_staged_domains
db_update_staged_domains "wg0" "example.com,netflix.com" 1
sql="$(latest_sql)"
assert_eq "UPDATE interfaces SET domains = 'example.com,netflix.com', target_only = 1 WHERE name = 'wg0';" "$sql" "db_update_staged_domains writes expected SQL"

# T02: db_set_target_only
db_set_target_only "wg0" 0
sql="$(latest_sql)"
assert_eq "UPDATE interfaces SET target_only = 0 WHERE name = 'wg0';" "$sql" "db_set_target_only writes expected SQL"

# T03a: db_set_staged_split_tunnel with explicit type
db_set_staged_split_tunnel "wg-split" "conf/wg-split.conf" 123 "example.com,foo.com" "wireguard"
sql="$(latest_sql)"
assert_contains "$sql" "INSERT OR REPLACE INTO interfaces" "db_set_staged_split_tunnel issues insert"
assert_file_contains "$SQLITE_LOG" "'wg-split', 'wireguard', 'conf/wg-split.conf', 123, 'none', 'example.com,foo.com'" "db_set_staged_split_tunnel stores split mode fields"

# T03b: db_set_staged_split_tunnel default type fallback to wireguard
SQLITE_TYPE_RESULT=""
db_set_staged_split_tunnel "auto-split" "conf/auto.conf" 124 "a.com"
assert_file_contains "$SQLITE_LOG" "'auto-split', 'wireguard', 'conf/auto.conf', 124, 'none', 'a.com'" "db_set_staged_split_tunnel defaults type to wireguard when missing"

# T03c: db_reconstruct_command target mode with explicit script path
db_get_interface() {
    # name|type|conf|routing_table|target_ips|domains|dns_servers|committed|target_only|ipv6_support|ipv6_subnets|nat66|start_time|running
    echo "wg0|wireguard|conf/wg0.conf|101|10.90.1.10,10.90.5.0/24||1.1.1.1|1|0|1|2001:db8::/64|0|0|1"
}
cmd="$(db_reconstruct_command "wg0" "./wg.sh")"
assert_eq "./wg.sh wg0 --conf conf/wg0.conf --target-ips 10.90.1.10,10.90.5.0/24" "$cmd" "db_reconstruct_command builds target command"

# T03d: db_reconstruct_command split mode chooses script by type
db_get_interface() {
    echo "ovpn1|openvpn|conf/ovpn1.ovpn|201|none|example.com,foo.com|9.9.9.9|1|0|0||0|0|1"
}
cmd="$(db_reconstruct_command "ovpn1")"
assert_eq "./ovpn.sh ovpn1 --conf conf/ovpn1.ovpn --domains example.com,foo.com" "$cmd" "db_reconstruct_command builds split command and auto-selects ovpn wrapper"

# T04: unregister_routing_table uses configurable path and removes only target table
RT_TABLES_PATH="$TMP_DIR/rt_tables_test"
export RT_TABLES_PATH
cat > "$RT_TABLES_PATH" <<'EOF_TABLES'
1 local
100 wg0_rt
101 ovpn_rt
EOF_TABLES

unregister_routing_table "wg0_rt"
file_data="$(cat "$RT_TABLES_PATH")"
assert_not_contains "$file_data" "100 wg0_rt" "unregister_routing_table removes matching table entry"
assert_contains "$file_data" "101 ovpn_rt" "unregister_routing_table keeps unrelated table entries"

# T05: calculate_mark fallback works when cksum is unavailable (Busybox/OpenWrt variants)
cksum() { return 127; }
ip() { [ "$1" = "rule" ] && [ "$2" = "show" ] && return 0; return 0; }
VPN_PREFIX="vpnx1"
mark="$(calculate_mark 103 2>/dev/null)"
case "$mark" in
    ''|*[!0-9]*)
        say_fail "calculate_mark returns numeric mark without cksum"
        echo "  actual: $mark"
        ;;
    *)
        say_pass "calculate_mark returns numeric mark without cksum"
        ;;
esac

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
