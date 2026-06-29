#!/bin/sh
# OpenVPN auth credential parsing regression:
# - supports USERNAME=/PASSWORD= auth files
# - supports plain two-line auth files

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
OVPN_SH="$PROJECT_ROOT/ovpn.sh"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10ovpnauth)"

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

extract_parser() {
    sed -n '/^parse_ovpn_auth_credentials() {/,/^}/p' "$OVPN_SH" > "$TMP_DIR/parser.sh"
    sed -n '/^parse_ovpn_config() {/,/^}/p' "$OVPN_SH" >> "$TMP_DIR/parser.sh"
    # shellcheck source=/dev/null
    . "$TMP_DIR/parser.sh"
}

echo "=== OpenVPN Auth Credential Parse Test ==="

if [ ! -f "$OVPN_SH" ]; then
    echo "[FAIL] ovpn.sh not found at $OVPN_SH"
    exit 1
fi

extract_parser

# Case 1: KEY=VALUE auth file
cat > "$TMP_DIR/keyval.conf" <<'EOF_CONF'
client
remote 1.2.3.4 1194
auth-user-pass keyval.auth
EOF_CONF
cat > "$TMP_DIR/keyval.auth" <<'EOF_AUTH'
USERNAME=test-user
PASSWORD=test-pass
EOF_AUTH

parse_ovpn_config "$TMP_DIR/keyval.conf"
assert_eq "test-user" "${OVPN_AUTH_USERNAME:-}" "parses USERNAME= format"
assert_eq "test-pass" "${OVPN_AUTH_PASSWORD:-}" "parses PASSWORD= format"

# Case 2: plain two-line auth file (quoted path)
cat > "$TMP_DIR/plain.conf" <<'EOF_CONF'
client
remote 1.2.3.4 1194
auth-user-pass "plain.auth"
EOF_CONF
cat > "$TMP_DIR/plain.auth" <<'EOF_AUTH'
plain-user
plain-pass
EOF_AUTH

parse_ovpn_config "$TMP_DIR/plain.conf"
assert_eq "plain-user" "${OVPN_AUTH_USERNAME:-}" "parses plain username line"
assert_eq "plain-pass" "${OVPN_AUTH_PASSWORD:-}" "parses plain password line"

# Case 3: Proton-style IPv6 request via setenv UV_IPV6 1
cat > "$TMP_DIR/uv6.conf" <<'EOF_CONF'
client
setenv UV_IPV6 1
remote 1.2.3.4 1194
EOF_CONF
parse_ovpn_config "$TMP_DIR/uv6.conf"
assert_eq "1" "${IPV6_SUPPORTED:-0}" "detects IPv6 support from setenv UV_IPV6 1"

# Case 4: --auth override path takes precedence over config auth-user-pass path
cat > "$TMP_DIR/override.conf" <<'EOF_CONF'
client
remote 1.2.3.4 1194
auth-user-pass wrong-path.auth
EOF_CONF
cat > "$TMP_DIR/override.auth" <<'EOF_AUTH'
override-user
override-pass
EOF_AUTH
AUTH_FILE_OVERRIDE="$TMP_DIR/override.auth"
parse_ovpn_config "$TMP_DIR/override.conf"
assert_eq "override-user" "${OVPN_AUTH_USERNAME:-}" "uses auth override username"
assert_eq "override-pass" "${OVPN_AUTH_PASSWORD:-}" "uses auth override password"
AUTH_FILE_OVERRIDE=""

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
