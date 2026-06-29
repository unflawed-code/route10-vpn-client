#!/bin/sh
# Phase 2 wrapper command surface tests for wg.sh / ovpn.sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p2wrap)"
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

assert_rc() {
    expected="$1"
    actual="$2"
    msg="$3"
    if [ "$expected" = "$actual" ]; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected rc: $expected"
        echo "  actual rc:   $actual"
    fi
}

mkdir -p "$TMP_DIR/lib/util"
cp "$PROJECT_ROOT/wg.sh" "$TMP_DIR/wg.sh"
cp "$PROJECT_ROOT/ovpn.sh" "$TMP_DIR/ovpn.sh"

cat > "$TMP_DIR/lib/vpn-core.sh" <<'EOF'
#!/bin/sh
vpn_core_set_type() { VPN_CURRENT_TYPE="$1"; }
vpn_core_show_plugin_help() { echo "PLUGIN_HELP_${VPN_CURRENT_TYPE}"; }
vpn_core_handle_command() {
    [ "$1" = "plugin-cmd" ] || return 1
    echo "PLUGIN_HANDLED_${VPN_CURRENT_TYPE}"
    return 0
}
vpn_core_commit() { echo "MOCK_COMMIT_${VPN_CURRENT_TYPE}"; }
vpn_core_reapply() { echo "MOCK_REAPPLY_${VPN_CURRENT_TYPE}"; }
vpn_core_delete() { echo "MOCK_DELETE_${VPN_CURRENT_TYPE}_$1"; }
vpn_core_register_hook() { :; }
trim() { echo "$1"; }
db_init() { :; }
db_list_interfaces() { :; }
db_get_interface() { :; }
db_allocate_routing_table() { echo "100"; }
EOF

cat > "$TMP_DIR/lib/util/table.sh" <<'EOF'
#!/bin/sh
print_table_header() { echo "$1"; }
print_table_row() { echo "$1: $2"; }
tbl_init() { :; }
tbl_top() { :; }
tbl_row() { echo "$1 $2"; }
tbl_bottom() { :; }
EOF

chmod +x "$TMP_DIR/wg.sh" "$TMP_DIR/ovpn.sh"

echo "=== Phase 2 Wrapper Command Surface Tests ==="

# wg help: plugin help line + reapply command
help_out="$(cd "$TMP_DIR" && ./wg.sh --help 2>&1 || true)"
assert_contains "$help_out" "PLUGIN_HELP_wireguard" "wg --help invokes plugin help hook"
assert_contains "$help_out" "reapply" "wg --help includes reapply command"

# ovpn help: plugin help line + reapply command
help_out="$(cd "$TMP_DIR" && ./ovpn.sh --help 2>&1 || true)"
assert_contains "$help_out" "PLUGIN_HELP_openvpn" "ovpn --help invokes plugin help hook"
assert_contains "$help_out" "reapply" "ovpn --help includes reapply command"

# plugin command dispatch
cmd_out="$(cd "$TMP_DIR" && ./wg.sh plugin-cmd 2>&1)"
rc=$?
assert_rc "0" "$rc" "wg plugin command exits 0 when handled"
assert_contains "$cmd_out" "PLUGIN_HANDLED_wireguard" "wg plugin dispatch output"

cmd_out="$(cd "$TMP_DIR" && ./ovpn.sh plugin-cmd 2>&1)"
rc=$?
assert_rc "0" "$rc" "ovpn plugin command exits 0 when handled"
assert_contains "$cmd_out" "PLUGIN_HANDLED_openvpn" "ovpn plugin dispatch output"

# reapply command surface
cmd_out="$(cd "$TMP_DIR" && ./wg.sh reapply 2>&1)"
rc=$?
assert_rc "0" "$rc" "wg reapply exits 0"
assert_contains "$cmd_out" "MOCK_REAPPLY_wireguard" "wg reapply calls vpn_core_reapply"

cmd_out="$(cd "$TMP_DIR" && ./ovpn.sh reapply 2>&1)"
rc=$?
assert_rc "0" "$rc" "ovpn reapply exits 0"
assert_contains "$cmd_out" "MOCK_REAPPLY_openvpn" "ovpn reapply calls vpn_core_reapply"

# -r support removed: should be treated as unknown option
cmd_out="$(cd "$TMP_DIR" && ./wg.sh wg0 -c test.conf -t 10.0.0.2 -r 1000 2>&1 || true)"
assert_contains "$cmd_out" "Unknown option: -r" "wg rejects removed -r option"

cmd_out="$(cd "$TMP_DIR" && ./ovpn.sh ovpn0 -c test.conf -t 10.0.0.2 -r 1000 2>&1 || true)"
assert_contains "$cmd_out" "Unknown option: -r" "ovpn rejects removed -r option"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
