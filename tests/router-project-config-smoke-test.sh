#!/bin/sh
# Router smoke test for project.conf overrides.
# Verifies:
# - custom routing table range is used for auto-allocation
# - status reflects staged interface table
# - generated hotplug scripts embed configured sqlite timeout
# Run on router from project root:
#   sh tests/router-project-config-smoke-test.sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
WG_SCRIPT="$PROJECT_ROOT/wg.sh"

PASS=0
FAIL=0
TMP_DIR="/tmp/r10-project-config-smoke-$$"
mkdir -p "$TMP_DIR"

CFG_FILE="$TMP_DIR/project.conf"
WG_CONF="$TMP_DIR/smoke.conf"
IFACE_STD="wgcfgsmk1"
IFACE_SPLIT="wgcfgsmk2"
CFG_PREFIX="cfgsmk"
CFG_RT_START=1400
CFG_RT_END=1402
CFG_TIMEOUT=4321
CFG_DB_PATH="/tmp/${CFG_PREFIX}/pbr.db"

cleanup() {
    VPN_PROJECT_CONFIG_FILE="$CFG_FILE" "$WG_SCRIPT" delete "$IFACE_STD" >/dev/null 2>&1 || true
    VPN_PROJECT_CONFIG_FILE="$CFG_FILE" "$WG_SCRIPT" delete "$IFACE_SPLIT" >/dev/null 2>&1 || true
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
    fi
}

assert_in_range() {
    value="$1"
    start="$2"
    end="$3"
    msg="$4"
    case "$value" in
        ''|*[!0-9]*)
            say_fail "$msg"
            echo "  not numeric: $value"
            return
            ;;
    esac
    if [ "$value" -ge "$start" ] && [ "$value" -le "$end" ]; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  value: $value (expected ${start}-${end})"
    fi
}

echo "=== Router Project Config Smoke Test ==="

for bin in sqlite3 uci iptables ip6tables; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "[SKIP] missing required binary: $bin"
        exit 0
    fi
done

cat > "$CFG_FILE" <<EOF_CFG
VPN_PREFIX="$CFG_PREFIX"
VPN_RT_START=$CFG_RT_START
VPN_RT_END=$CFG_RT_END
PBR_DB_BUSY_TIMEOUT_MS=$CFG_TIMEOUT
WG_DB_BUSY_TIMEOUT_MS="\$PBR_DB_BUSY_TIMEOUT_MS"
EOF_CFG

cat > "$WG_CONF" <<'EOF_WG'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.200.200.1/32
DNS = 1.1.1.1,2606:4700:4700::1111

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
EOF_WG

stage_out="$(VPN_PROJECT_CONFIG_FILE="$CFG_FILE" "$WG_SCRIPT" "$IFACE_STD" -c "$WG_CONF" -t none 2>&1)"
stage_rc=$?
if [ "$stage_rc" -eq 0 ]; then
    say_pass "standard stage command succeeds"
else
    say_fail "standard stage command succeeds"
    echo "$stage_out"
    exit 1
fi

alloc_table="$(printf "%s\n" "$stage_out" | awk -F': ' '/Allocated routing table/ {print $2; exit}')"
assert_in_range "$alloc_table" "$CFG_RT_START" "$CFG_RT_END" "auto-allocation uses configured routing table range"

if [ -f "$CFG_DB_PATH" ]; then
    say_pass "db path follows configured prefix"
else
    say_fail "db path follows configured prefix"
fi

db_table="$(sqlite3 "$CFG_DB_PATH" "SELECT routing_table FROM interfaces WHERE name='${IFACE_STD}';" 2>/dev/null)"
assert_in_range "$db_table" "$CFG_RT_START" "$CFG_RT_END" "database stores table in configured range"

status_out="$(VPN_PROJECT_CONFIG_FILE="$CFG_FILE" "$WG_SCRIPT" status "$IFACE_STD" 2>&1)"
assert_contains "$status_out" "Routing Table" "status command renders routing table row"
assert_contains "$status_out" "$db_table (${IFACE_STD}_rt)" "status reports staged routing table from configured range"

split_out="$(VPN_PROJECT_CONFIG_FILE="$CFG_FILE" "$WG_SCRIPT" "$IFACE_SPLIT" -c "$WG_CONF" -d example.com 2>&1)"
split_rc=$?
if [ "$split_rc" -eq 0 ]; then
    say_pass "split stage command succeeds"
else
    say_fail "split stage command succeeds"
    echo "$split_out"
    exit 1
fi

split_hotplug="/etc/hotplug.d/iface/99-${CFG_PREFIX}-${IFACE_SPLIT}-split"
cleanup_hotplug="/etc/hotplug.d/iface/99-${CFG_PREFIX}-${IFACE_STD}-cleanup"

if [ -f "$split_hotplug" ]; then
    say_pass "split hotplug generated with configured prefix"
    split_data="$(cat "$split_hotplug" 2>/dev/null)"
    assert_contains "$split_data" "SQLITE_TIMEOUT_MS=\"${CFG_TIMEOUT}\"" "split hotplug embeds configured sqlite timeout"
else
    say_fail "split hotplug generated with configured prefix"
fi

if [ -f "$cleanup_hotplug" ]; then
    say_pass "cleanup hotplug generated with configured prefix"
    cleanup_data="$(cat "$cleanup_hotplug" 2>/dev/null)"
    assert_contains "$cleanup_data" "SQLITE_TIMEOUT_MS=\"${CFG_TIMEOUT}\"" "cleanup hotplug embeds configured sqlite timeout"
else
    say_fail "cleanup hotplug generated with configured prefix"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1

