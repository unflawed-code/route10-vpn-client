#!/bin/sh
# Phase 2 core command hook tests for vpn-core.sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p2core)"
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

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/plugins/wg" "$TMP_DIR/plugins/ovpn" "$TMP_DIR/tmp"
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

cat > "$TMP_DIR/plugins/00-generic.sh" <<'EOF'
show_plugin_help() { echo "GEN_HELP"; }
handle_command() {
    [ "$1" = "generic-cmd" ] || return 1
    echo "GEN_HANDLED"
    return 0
}
EOF

cat > "$TMP_DIR/plugins/wg/10-wg.sh" <<'EOF'
show_plugin_help() { echo "WG_HELP"; }
handle_command() {
    [ "$1" = "wg-cmd" ] || return 1
    echo "WG_HANDLED"
    return 0
}
EOF

cat > "$TMP_DIR/plugins/ovpn/10-ovpn.sh" <<'EOF'
show_plugin_help() { echo "OVPN_HELP"; }
handle_command() {
    [ "$1" = "ovpn-cmd" ] || return 1
    echo "OVPN_HANDLED"
    return 0
}
EOF

export VPN_PREFIX="r10test"
export VPN_BASE_DIR="$TMP_DIR"
export PLUGIN_DIR="$TMP_DIR/plugins"
export VPN_TMP_DIR="$TMP_DIR/tmp"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

echo "=== Phase 2 Core Command Hook Tests ==="

vpn_core_set_type "wireguard"
help_out="$(vpn_core_show_plugin_help 2>&1)"
assert_contains "$help_out" "GEN_HELP" "wireguard help includes generic plugin help"
assert_contains "$help_out" "WG_HELP" "wireguard help includes wireguard plugin help"
assert_not_contains "$help_out" "OVPN_HELP" "wireguard help excludes openvpn plugin help"

cmd_out="$(vpn_core_handle_command "wg-cmd" 2>&1)"
rc=$?
assert_rc "0" "$rc" "wireguard command handled by wg plugin returns rc 0"
assert_contains "$cmd_out" "WG_HANDLED" "wireguard command output from wg plugin"

cmd_out="$(vpn_core_handle_command "generic-cmd" 2>&1)"
rc=$?
assert_rc "0" "$rc" "generic command handled in wireguard mode returns rc 0"
assert_contains "$cmd_out" "GEN_HANDLED" "generic command output from generic plugin"

vpn_core_handle_command "unknown-cmd" >/dev/null 2>&1
rc=$?
assert_rc "1" "$rc" "unknown command returns rc 1"

vpn_core_set_type "openvpn"
help_out="$(vpn_core_show_plugin_help 2>&1)"
assert_contains "$help_out" "GEN_HELP" "openvpn help includes generic plugin help"
assert_contains "$help_out" "OVPN_HELP" "openvpn help includes openvpn plugin help"
assert_not_contains "$help_out" "WG_HELP" "openvpn help excludes wireguard plugin help"

cmd_out="$(vpn_core_handle_command "ovpn-cmd" 2>&1)"
rc=$?
assert_rc "0" "$rc" "openvpn command handled by ovpn plugin returns rc 0"
assert_contains "$cmd_out" "OVPN_HANDLED" "openvpn command output from ovpn plugin"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
