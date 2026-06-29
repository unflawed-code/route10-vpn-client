#!/bin/sh
# Phase 1 config tests:
# - project config loader defaults
# - user override file loading
# - timeout alias normalization

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_LIB="$PROJECT_ROOT/lib/project-config.sh"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10cfg)"
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

run_loader_with_base() {
    base="$1"
    (
        unset VPN_PROJECT_CONFIG_LOADED VPN_PREFIX VPN_RT_START VPN_RT_END
        unset PBR_DB_BUSY_TIMEOUT_MS WG_DB_BUSY_TIMEOUT_MS VPN_PROJECT_CONFIG_FILE
        unset VPN_IPV6_MODE_DEFAULT VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC VPN_IPV6_ROUTED_VERIFY_RETRIES
        unset VPN_IPV6_ROUTED_PROBE_ADDR VPN_IPV6_FORCE_TAKEOVER
        VPN_BASE_DIR="$base"
        . "$CONFIG_LIB"
        echo "$VPN_PREFIX|$VPN_RT_START|$VPN_RT_END|$PBR_DB_BUSY_TIMEOUT_MS|$WG_DB_BUSY_TIMEOUT_MS|$VPN_IPV6_MODE_DEFAULT|$VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC|$VPN_IPV6_ROUTED_VERIFY_RETRIES|$VPN_IPV6_ROUTED_PROBE_ADDR|$VPN_IPV6_FORCE_TAKEOVER"
    )
}

echo "=== Phase 1 Project Config Tests ==="

# T01: Loader defaults when no project.conf exists
mkdir -p "$TMP_DIR/no-conf"
vals="$(run_loader_with_base "$TMP_DIR/no-conf")"
assert_eq "vpnx1|1000|1499|5000|5000|nat66|5|3|2606:4700:4700::1111|0" "$vals" "loader uses built-in defaults without project.conf"

# T02: Loader reads project.conf overrides
mkdir -p "$TMP_DIR/with-conf"
cat > "$TMP_DIR/with-conf/project.conf" <<'EOF_CFG'
VPN_PREFIX="rtx"
VPN_RT_START=1200
VPN_RT_END=1299
PBR_DB_BUSY_TIMEOUT_MS=6500
VPN_IPV6_MODE_DEFAULT="routed-prefix"
VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC=8
VPN_IPV6_ROUTED_VERIFY_RETRIES=4
VPN_IPV6_ROUTED_PROBE_ADDR="2001:4860:4860::8888"
VPN_IPV6_FORCE_TAKEOVER=1
EOF_CFG
vals="$(run_loader_with_base "$TMP_DIR/with-conf")"
assert_eq "rtx|1200|1299|6500|6500|routed-prefix|8|4|2001:4860:4860::8888|1" "$vals" "loader applies project.conf overrides"

# T03: Loader normalizes invalid values and alias
mkdir -p "$TMP_DIR/bad-conf"
cat > "$TMP_DIR/bad-conf/project.conf" <<'EOF_BAD'
VPN_RT_START=foo
VPN_RT_END=bar
WG_DB_BUSY_TIMEOUT_MS=7777
PBR_DB_BUSY_TIMEOUT_MS=abc
VPN_IPV6_MODE_DEFAULT=invalid
VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC=bad
VPN_IPV6_ROUTED_VERIFY_RETRIES=zero
VPN_IPV6_FORCE_TAKEOVER=5
EOF_BAD
vals="$(run_loader_with_base "$TMP_DIR/bad-conf")"
assert_eq "vpnx1|1000|1499|7777|7777|nat66|5|3|2606:4700:4700::1111|0" "$vals" "loader normalizes invalid config and keeps timeout alias"

# T04: Loader keeps backward compatibility with legacy 'auto' mode keyword
mkdir -p "$TMP_DIR/legacy-auto-conf"
cat > "$TMP_DIR/legacy-auto-conf/project.conf" <<'EOF_AUTO'
VPN_IPV6_MODE_DEFAULT="auto"
EOF_AUTO
vals="$(run_loader_with_base "$TMP_DIR/legacy-auto-conf")"
assert_eq "vpnx1|1000|1499|5000|5000|nat66|5|3|2606:4700:4700::1111|0" "$vals" "loader maps legacy auto keyword to nat66"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

[ "$FAIL" -eq 0 ]
