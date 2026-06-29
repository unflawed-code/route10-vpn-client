#!/bin/sh
# Phase 4 MAC state semantics test:
# db_set_mac_state must enforce single-row-per-MAC by delete-then-insert.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_LIB="$PROJECT_ROOT/lib/state.sh"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p4mac)"
SQL_LOG="$TMP_DIR/sql.log"
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

sqlite3() {
    db="$1"
    shift || true
    if [ "$#" -gt 0 ]; then
        sql="$*"
    else
        sql="$(cat)"
    fi
    printf "DB:%s\nSQL:%s\n---\n" "$db" "$sql" >> "$SQL_LOG"
}

export PBR_DB_PATH="$TMP_DIR/pbr.db"
. "$STATE_LIB"

echo "=== Phase 4 MAC State Semantics Test ==="

db_set_mac_state "aa:bb:cc:dd:ee:ff" "wg0" "10.0.0.22" "101" "1"
sql_block="$(cat "$SQL_LOG")"

assert_contains "$sql_block" "DELETE FROM mac_state WHERE mac = 'aa:bb:cc:dd:ee:ff';" "db_set_mac_state deletes prior rows for the MAC"
assert_contains "$sql_block" "INSERT INTO mac_state (mac, interface, ip, routing_table, ipv6_support)" "db_set_mac_state inserts fresh row after delete"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
