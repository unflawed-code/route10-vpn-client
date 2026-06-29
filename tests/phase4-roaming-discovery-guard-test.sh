#!/bin/sh
# Phase 4 roaming discovery guard regression tests:
# - stale discovery workers must not add IPv6 source rules after roam
# - permissive "auto" fallback must only apply when NAT66 is enabled

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10p4disc)"
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

assert_ge() {
    actual="$1"
    min="$2"
    msg="$3"
    if [ "$actual" -ge "$min" ] 2>/dev/null; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected >= $min"
        echo "  actual:    $actual"
    fi
}

mkdir -p "$TMP_DIR/lib/routing" "$TMP_DIR/tmp"
cp "$PROJECT_ROOT/lib/vpn-core.sh" "$TMP_DIR/lib/vpn-core.sh"
cat > "$TMP_DIR/lib/common.sh" <<'EOF'
#!/bin/sh
normalize_mac() {
    input="$1"
    clean=$(echo "$input" | tr -d ':-' | tr 'A-F' 'a-f')
    [ ${#clean} -eq 12 ] || return 1
    echo "$clean" | sed 's/\(..\)/\1:/g; s/:$//'
}
EOF
cat > "$TMP_DIR/lib/state.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$TMP_DIR/lib/routing/pbr.sh" <<'EOF'
#!/bin/sh
EOF

export VPN_PREFIX="r10test"
export VPN_BASE_DIR="$TMP_DIR"
export VPN_TMP_DIR="$TMP_DIR/tmp"
export TEST_LOG="$TMP_DIR/phase4-discovery.log"

# shellcheck source=/dev/null
. "$TMP_DIR/lib/vpn-core.sh"

# Stubs
RULE_PRESENT=0
MAC_QUERY_MODE="active"
NEIGH_ROWS=""

logger() { echo "logger:$*" >> "$TEST_LOG"; }
sleep() { :; }
ipset() { echo "ipset:$*" >> "$TEST_LOG"; return 0; }

db_get_mac_by_mac() {
    case "$MAC_QUERY_MODE" in
        stale) echo "aa:bb:cc:dd:ee:ff|wgother|10.0.0.9|1001|1" ;;
        active) echo "aa:bb:cc:dd:ee:ff|wgtest|10.0.0.10|1000|1" ;;
        *) echo "" ;;
    esac
}

ip() {
    if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "show" ]; then
        [ -n "$NEIGH_ROWS" ] && echo "$NEIGH_ROWS"
        return 0
    fi
    if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "show" ]; then
        if [ "$RULE_PRESENT" = "1" ]; then
            echo "1000: from 2a02:6ea0:d802:6235::13/128 lookup 1000"
        fi
        return 0
    fi
    if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "add" ]; then
        RULE_PRESENT=1
        echo "ip:$*" >> "$TEST_LOG"
        return 0
    fi
    if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "del" ]; then
        RULE_PRESENT=0
        echo "ip:$*" >> "$TEST_LOG"
        return 0
    fi
    return 0
}

echo "=== Phase 4 Roaming Discovery Guard Tests ==="

token_file="$VPN_TMP_DIR/discover_wgtest_aabbccddeeff.token"

# Case 1: stale worker (MAC no longer mapped to iface) must exit without adding rules.
: > "$TEST_LOG"
RULE_PRESENT=0
MAC_QUERY_MODE="stale"
NEIGH_ROWS="2a02:6ea0:d802:6235::13 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"
vpn_core_discover_client_ipv6 "wgtest" "1000" "aa:bb:cc:dd:ee:ff" "2001:db8:1::/64" "1"
wait
rule_adds="$(grep -c 'ip:-6 rule add from ' "$TEST_LOG" 2>/dev/null || true)"
assert_eq "0" "$rule_adds" "stale discovery worker does not add IPv6 source rule"
if [ ! -f "$token_file" ]; then
    say_pass "stale discovery token is cleaned up"
else
    say_fail "stale discovery token is cleaned up"
fi

# Case 2: NAT66 disabled, non-matching IPv6 must not use permissive auto fallback.
: > "$TEST_LOG"
RULE_PRESENT=0
MAC_QUERY_MODE="active"
NEIGH_ROWS="2a02:6ea0:d802:6235::13 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"
vpn_core_discover_client_ipv6 "wgtest" "1000" "aa:bb:cc:dd:ee:ff" "2001:db8:1::/64" "0"
wait
rule_adds="$(grep -c 'ip:-6 rule add from ' "$TEST_LOG" 2>/dev/null || true)"
assert_eq "0" "$rule_adds" "NAT66=0 does not apply auto IPv6 discovery fallback"

# Case 3: NAT66 enabled, non-matching IPv6 can use permissive auto fallback.
: > "$TEST_LOG"
RULE_PRESENT=0
MAC_QUERY_MODE="active"
NEIGH_ROWS="2a02:6ea0:d802:6235::13 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"
vpn_core_discover_client_ipv6 "wgtest" "1000" "aa:bb:cc:dd:ee:ff" "2001:db8:1::/64" "1"
wait
rule_adds="$(grep -c 'ip:-6 rule add from ' "$TEST_LOG" 2>/dev/null || true)"
assert_ge "$rule_adds" 1 "NAT66=1 allows auto IPv6 discovery fallback"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
