#!/bin/sh
# Regression: IPv6 must stay blocked for HOST targets on an IPv4-only tunnel.
#
# A host target only gives us an IPv4 address, so its IPv6 egress has to be
# dropped by client MAC. Before this fix the block chain was flushed on every
# ifup/fw-reload and only subnet targets were re-added, so a host-only
# interface (e.g. a TorGuard WireGuard tunnel with -t '10.90.1.5,10.90.1.6')
# leaked IPv6 after any firewall reload.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10v4only)"
PASS=0
FAIL=0
STUB_LOG="$TMP_DIR/stub.log"
export STUB_LOG

cleanup() {
    rm -rf "$TMP_DIR"
    rm -f /tmp/dhcp.leases 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say_pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
say_fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    haystack="$1"
    needle="$2"
    msg="$3"
    if printf '%s' "$haystack" | grep -Fq -e "$needle"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected substring: $needle"
    fi
}

assert_not_contains() {
    haystack="$1"
    needle="$2"
    msg="$3"
    if printf '%s' "$haystack" | grep -Fq -e "$needle"; then
        say_fail "$msg"
        echo "  unexpected substring: $needle"
    else
        say_pass "$msg"
    fi
}

# === COMMAND STUBS ===

mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/ip" <<'EOF_IP'
#!/bin/sh
echo "ip $*" >> "$STUB_LOG"
case "$*" in
    "-4 route get 10.90.1.5") echo "10.90.1.5 dev br-lan src 10.90.1.1" ;;
    "-4 route get 10.90.1.6") echo "10.90.1.6 dev br-lan src 10.90.1.1" ;;
    "neigh show 10.90.1.6")   echo "10.90.1.6 dev br-lan lladdr ec:2b:eb:22:58:76 REACHABLE" ;;
    "-4 route show 10.90.5.0/24") echo "10.90.5.0/24 dev br-lan proto kernel scope link src 10.90.5.1" ;;
esac
exit 0
EOF_IP

cat > "$TMP_DIR/bin/ip6tables" <<'EOF_I6'
#!/bin/sh
echo "ip6tables $*" >> "$STUB_LOG"
case " $* " in
    *" -C "*) exit 1 ;;
esac
exit 0
EOF_I6

cat > "$TMP_DIR/bin/iptables" <<'EOF_I4'
#!/bin/sh
echo "iptables $*" >> "$STUB_LOG"
case " $* " in
    *" -C "*) exit 1 ;;
esac
exit 0
EOF_I4

for stub in logger flock ping ipset; do
    printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$stub" > "$TMP_DIR/bin/$stub"
done
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/sleep"
printf '#!/bin/sh\necho 1795769552\n' > "$TMP_DIR/bin/date"
chmod +x "$TMP_DIR/bin"/*

PATH="$TMP_DIR/bin:$PATH"
export PATH

# Lease table: 10.90.1.5 is only resolvable here (offline, no neighbor entry).
cat > /tmp/dhcp.leases <<'EOF_LEASES'
1795769552 78:45:61:d4:e1:a2 10.90.1.5 * 01:78:45:61:d4:e1:a2 br-lan
1795765711 ec:2b:eb:22:58:76 10.90.1.6 * 01:ec:2b:eb:22:58:76 br-lan
EOF_LEASES

# Project libs read these at source time and run under set -u here.
export VPN_BASE_DIR="$PROJECT_ROOT"
export VPN_TMP_DIR="$TMP_DIR/runtime"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug"
export VPN_PREFIX=testx

LIB_DIR="$PROJECT_ROOT/lib"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/routing/ip-routing.sh"

echo "=== IPv4-only host target IPv6 block ==="

# 1. Direct helper: MAC resolved from the lease table.
: > "$STUB_LOG"
if block_ipv6_for_host_target wgtorla 10.90.1.5; then
    say_pass "host target with lease-only MAC is blocked"
else
    say_fail "host target with lease-only MAC is blocked"
fi
assert_contains "$(cat "$STUB_LOG")" \
    "-A wgtorla_ipv4_only_block -i br-lan -m mac --mac-source 78:45:61:d4:e1:a2 -j DROP" \
    "drop rule scoped to MAC resolved from lease table"

# 2. Direct helper: unknown client must not emit a bogus rule.
: > "$STUB_LOG"
if block_ipv6_for_host_target wgtorla 10.90.1.99; then
    say_fail "unknown host target reports failure"
else
    say_pass "unknown host target reports failure"
fi
assert_not_contains "$(cat "$STUB_LOG")" "--mac-source" "no rule emitted when MAC is unknown"

# 3. Generated hotplug script must rebuild host-target blocks on fw-reload.
. "$LIB_DIR/vpn-core.sh"

host_script=$(vpn_core_generate_ifup_script wgtorla 1000 "10.90.1.5 10.90.1.6" "1.1.1.1" 0 "" 0)

: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgtorla "$host_script" >/dev/null 2>&1
reload_log=$(cat "$STUB_LOG")

assert_contains "$reload_log" \
    "-A wgtorla_ipv4_only_block -i br-lan -m mac --mac-source ec:2b:eb:22:58:76 -j DROP" \
    "fw-reload rebuilds block for neighbor-resolved host target"
assert_contains "$reload_log" \
    "-A wgtorla_ipv4_only_block -i br-lan -m mac --mac-source 78:45:61:d4:e1:a2 -j DROP" \
    "fw-reload rebuilds block for lease-resolved host target"

# 4. Subnet behavior is unchanged.
sub_script=$(vpn_core_generate_ifup_script wgsub 1002 "10.90.5.0/24" "1.1.1.1" 0 "" 0)
: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgsub "$sub_script" >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" \
    "-A wgsub_ipv4_only_block -i br-lan -j DROP" \
    "subnet target still blocks the whole LAN device"

# 5. IPv6-capable tunnels are untouched.
v6_script=$(vpn_core_generate_ifup_script wgv6 1003 "10.90.6.0/24" "1.1.1.1" 1 "2001:db8::/64" 1)
: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgv6 "$v6_script" >/dev/null 2>&1
assert_not_contains "$(cat "$STUB_LOG")" "wgv6_ipv4_only_block" \
    "IPv6-capable tunnel installs no IPv4-only block"

echo
if [ "$FAIL" -gt 0 ]; then
    echo "=== IPv4-only host target: $FAIL failed, $PASS passed ==="
    exit 1
fi
echo "=== IPv4-only host target: $PASS passed ==="
