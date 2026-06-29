#!/bin/sh
# OpenVPN runtime config generation regression:
# - injects pull-filter guards for redirect-gateway/route
# - keeps source config untouched

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
OVPN_SH="$PROJECT_ROOT/ovpn.sh"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10ovpnrt)"

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

assert_contains_file() {
    file="$1"
    needle="$2"
    msg="$3"
    if grep -Fq -- "$needle" "$file"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  missing: $needle"
    fi
}

assert_not_contains_file() {
    file="$1"
    needle="$2"
    msg="$3"
    if grep -Fq -- "$needle" "$file"; then
        say_fail "$msg"
        echo "  unexpected: $needle"
    else
        say_pass "$msg"
    fi
}

extract_functions() {
    sed -n '/^ovpn_runtime_config_path() {/,/^}/p' "$OVPN_SH" > "$TMP_DIR/lib.sh"
    sed -n '/^prepare_runtime_ovpn_config() {/,/^}/p' "$OVPN_SH" >> "$TMP_DIR/lib.sh"
    # shellcheck source=/dev/null
    . "$TMP_DIR/lib.sh"
}

echo "=== OpenVPN Runtime Config Filter Test ==="

if [ ! -f "$OVPN_SH" ]; then
    echo "[FAIL] ovpn.sh not found at $OVPN_SH"
    exit 1
fi

extract_functions

export VPN_PREFIX="vpnx1"
export SCRIPT_DIR="$TMP_DIR/project"
mkdir -p "$SCRIPT_DIR/conf"

SOURCE_CONF="$TMP_DIR/source.ovpn"
cat > "$SOURCE_CONF" <<'EOF_CONF'
client
remote 1.2.3.4 1194
pull-filter ignore "redirect-gateway"
EOF_CONF

RUNTIME_CONF="$(prepare_runtime_ovpn_config "ovpntest1" "$SOURCE_CONF")"

if [ -f "$RUNTIME_CONF" ]; then
    say_pass "runtime config file generated"
else
    say_fail "runtime config file generated"
fi

assert_contains_file "$RUNTIME_CONF" 'pull-filter ignore "redirect-gateway"' "redirect-gateway pull-filter injected"
assert_contains_file "$RUNTIME_CONF" 'pull-filter ignore "route "' "route pull-filter injected"
assert_not_contains_file "$SOURCE_CONF" 'pull-filter ignore "route "' "source config remains unchanged"

# Ensure no duplicate redirect-gateway directives after regeneration.
RUNTIME_CONF2="$(prepare_runtime_ovpn_config "ovpntest1" "$SOURCE_CONF")"
count_redirect="$(grep -Fc 'pull-filter ignore "redirect-gateway"' "$RUNTIME_CONF2" 2>/dev/null || true)"
if [ "$count_redirect" = "1" ]; then
    say_pass "runtime config has single redirect-gateway filter"
else
    say_fail "runtime config has single redirect-gateway filter"
    echo "  count: $count_redirect"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
