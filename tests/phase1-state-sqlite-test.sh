#!/bin/sh
# Phase 1 SQLite-backed integration tests for state.sh helpers.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_LIB="$PROJECT_ROOT/lib/state.sh"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[SKIP] sqlite3 not available; skipping SQLite integration tests."
    exit 0
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p1sql)"
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

. "$STATE_LIB"

echo "=== Phase 1 SQLite Integration Tests ==="

db_init
db_stage_interface "wg0" "wireguard" "conf/wg0.conf" 101 "10.10.10.2" "1.1.1.1"

# db_update_staged_domains
db_update_staged_domains "wg0" "example.com,foo.com" 1
domains="$(sqlite3 "$PBR_DB_PATH" "SELECT domains FROM interfaces WHERE name='wg0';")"
target_only="$(sqlite3 "$PBR_DB_PATH" "SELECT target_only FROM interfaces WHERE name='wg0';")"
assert_eq "example.com,foo.com" "$domains" "db_update_staged_domains updates domains"
assert_eq "1" "$target_only" "db_update_staged_domains updates target_only"

# db_set_target_only
db_set_target_only "wg0" 0
target_only="$(sqlite3 "$PBR_DB_PATH" "SELECT target_only FROM interfaces WHERE name='wg0';")"
assert_eq "0" "$target_only" "db_set_target_only updates target_only"

# db_set_staged_split_tunnel explicit type
db_set_staged_split_tunnel "ovpn1" "conf/ovpn1.ovpn" 201 "netflix.com,youtube.com" "openvpn"
type="$(sqlite3 "$PBR_DB_PATH" "SELECT type FROM interfaces WHERE name='ovpn1';")"
targets="$(sqlite3 "$PBR_DB_PATH" "SELECT target_ips FROM interfaces WHERE name='ovpn1';")"
domains="$(sqlite3 "$PBR_DB_PATH" "SELECT domains FROM interfaces WHERE name='ovpn1';")"
assert_eq "openvpn" "$type" "db_set_staged_split_tunnel stores type"
assert_eq "none" "$targets" "db_set_staged_split_tunnel stores target_ips=none"
assert_eq "netflix.com,youtube.com" "$domains" "db_set_staged_split_tunnel stores domains"

# db_reconstruct_command domain mode
cmd="$(db_reconstruct_command "wg0" "./wg.sh")"
assert_eq "./wg.sh wg0 --conf conf/wg0.conf --domains example.com,foo.com" "$cmd" "db_reconstruct_command returns domain mode command when domains exist"

# db_reconstruct_command split mode auto wrapper by type
cmd="$(db_reconstruct_command "ovpn1")"
assert_eq "./ovpn.sh ovpn1 --conf conf/ovpn1.ovpn --domains netflix.com,youtube.com" "$cmd" "db_reconstruct_command auto-selects ovpn wrapper"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
