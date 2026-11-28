#!/bin/sh
# Regression: a client routed into a VPN must fail closed, not fall back to WAN.
#
# The kill switch chain used to be flushed on every ifup/fw-reload and left
# empty while the tunnel was up. Any packet that missed the policy route (the
# routing table rebuild window, a tunnel that vanished without an ifdown event)
# then left via the WAN and exposed the router's real address. The chain must
# always hold an "egress through the tunnel only" rule per target.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10ks)"
PASS=0
FAIL=0
STUB_LOG="$TMP_DIR/stub.log"
export STUB_LOG

cleanup() {
    rm -rf "$TMP_DIR"
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
    "link show wgtorla"*|"link show wgsub"*) exit 0 ;;
    "link show "*) exit 1 ;;
    "-4 route get 10.90.1.5") echo "10.90.1.5 dev br-lan src 10.90.1.1" ;;
    "-4 route get 10.90.1.6") echo "10.90.1.6 dev br-lan src 10.90.1.1" ;;
    "-4 route get 10.90.1.7") echo "10.90.1.7 dev br-lan src 10.90.1.1" ;;
    "-4 route show 10.90.5.0/24") echo "10.90.5.0/24 dev br-lan_5 proto kernel scope link src 10.90.5.1" ;;
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

export VPN_BASE_DIR="$PROJECT_ROOT"
export VPN_TMP_DIR="$TMP_DIR/runtime"
export HOTPLUG_IFACE_DIR="$TMP_DIR/hotplug"
export VPN_PREFIX=testx

LIB_DIR="$PROJECT_ROOT/lib"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/vpn-core.sh"

echo "=== Kill switch: fail closed on tunnel loss ==="

# 1. Generated ifup script pins every target's egress to the tunnel device.
up_script=$(vpn_core_generate_ifup_script wgtorla 1000 "10.90.1.5 10.90.1.6" "1.1.1.1" 0 "" 0)

: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgtorla "$up_script" >/dev/null 2>&1
up_log=$(cat "$STUB_LOG")

assert_contains "$up_log" \
    "-A wgtorla_killswitch -s 10.90.1.6 ! -o wgtorla -j REJECT --reject-with icmp-host-prohibited" \
    "ifup pins client egress to the tunnel device"
assert_contains "$up_log" \
    "-A wgtorla_killswitch -s 10.90.1.5 ! -o wgtorla -j REJECT --reject-with icmp-host-prohibited" \
    "every host target gets its own egress rule"

# 2. Chain and FORWARD jump are re-created, so a firewall restart cannot leave
#    an orphaned (unenforced) chain behind.
assert_contains "$up_log" "-I FORWARD 1 -j wgtorla_killswitch" \
    "ifup re-attaches the kill switch chain"
assert_contains "$up_log" "-N wgtorla_killswitch" \
    "ifup re-creates the kill switch chain"

# 2b. Same-LAN traffic must not be caught by the kill switch (casting, phone
#     remote, local services never touch the WAN).
assert_contains "$up_log" "iptables -w -I wgtorla_killswitch 1 -o br-lan -j RETURN" \
    "same-LAN IPv4 egress skips the kill switch"
assert_contains "$up_log" "ip6tables -w -I wgtorla_killswitch 1 -o br-lan -j RETURN" \
    "same-LAN IPv6 egress skips the kill switch"
ret_line=$(awk '/-I wgtorla_killswitch 1 -o br-lan -j RETURN/ {print NR; exit}' "$STUB_LOG")
rej_line=$(awk '/-A wgtorla_killswitch -s 10.90.1.6 ! -o wgtorla/ {print NR; exit}' "$STUB_LOG")
if [ -n "$ret_line" ] && [ -n "$rej_line" ] && [ "$ret_line" -lt "$rej_line" ]; then
    say_pass "LAN exception precedes the tunnel-only reject"
else
    say_fail "LAN exception precedes the tunnel-only reject"
fi

# 3. The rule must exist before the routing table is rebuilt.
ks_line=$(awk '/-A wgtorla_killswitch -s 10.90.1.6/ {print NR; exit}' "$STUB_LOG")
flush_line=$(awk '/route flush table 1000/ {print NR; exit}' "$STUB_LOG")
if [ -n "$ks_line" ] && [ -n "$flush_line" ] && [ "$ks_line" -lt "$flush_line" ]; then
    say_pass "kill switch is installed before the routing table rebuild"
else
    say_fail "kill switch is installed before the routing table rebuild"
fi

# 4. Tunnel down: the chain blocks the target outright.
down_script=$(vpn_core_generate_ifdown_script wgtorla 1000 "10.90.1.5 10.90.1.6")
: > "$STUB_LOG"
ACTION=ifdown INTERFACE=wgtorla "$down_script" >/dev/null 2>&1
down_log=$(cat "$STUB_LOG")
assert_contains "$down_log" \
    "-A wgtorla_killswitch -s 10.90.1.6 -j DROP" \
    "ifdown blocks the client outright"
assert_contains "$down_log" "-N wgtorla_killswitch" \
    "ifdown re-creates the kill switch chain"

# 5. Comma-separated targets are split (regression: enabled no rule at all).
: > "$STUB_LOG"
vpn_core_enable_killswitch wgtorla "10.90.1.5,10.90.1.6"
ks_log=$(cat "$STUB_LOG")
assert_contains "$ks_log" "-A wgtorla_killswitch -s 10.90.1.5 -j DROP" \
    "comma-separated first target gets a drop rule"
assert_contains "$ks_log" "-A wgtorla_killswitch -s 10.90.1.6 -j DROP" \
    "comma-separated second target gets a drop rule"

# 6. The per-client helper used by the DHCP path is idempotent and scoped.
: > "$STUB_LOG"
_vpn_core_allow_tunnel_egress_only wgtorla 10.90.1.6
assert_contains "$(cat "$STUB_LOG")" \
    "-C wgtorla_killswitch -s 10.90.1.6 ! -o wgtorla -j REJECT --reject-with icmp-host-prohibited" \
    "per-client kill switch rule is checked before it is added"
assert_contains "$(cat "$STUB_LOG")" \
    "-I wgtorla_killswitch 1 -o br-lan -j RETURN" \
    "per-client path also exempts same-LAN egress, at the head of the chain"

: > "$STUB_LOG"
if _vpn_core_allow_tunnel_egress_only wgtorla ec:2b:eb:22:58:76; then
    say_fail "MAC-only address is not treated as an IP"
else
    say_pass "MAC-only address is not treated as an IP"
fi
assert_not_contains "$(cat "$STUB_LOG")" "! -o wgtorla" \
    "no rule emitted for a MAC-only value"

# 7. Bare MAC targets cannot be matched by address and must not emit a rule.
mac_script=$(vpn_core_generate_ifup_script wgmac 1001 "ec:2b:eb:22:58:76" "1.1.1.1" 0 "" 0)
: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgmac "$mac_script" >/dev/null 2>&1
assert_not_contains "$(cat "$STUB_LOG")" "-A wgmac_killswitch" \
    "bare MAC target emits no kill switch rule"

# 8. Targets spread over two LAN bridges: both exemptions must exist and must
#    be inserted at the head, otherwise the second bridge's RETURN would sit
#    behind the first target's reject and cross-VLAN traffic would be dropped.
mix_script=$(vpn_core_generate_ifup_script wgmix 1004 "10.90.5.0/24 10.90.1.7" "1.1.1.1" 1 "2001:db8::/64" 1)
: > "$STUB_LOG"
ACTION=fw-reload INTERFACE=wgmix "$mix_script" >/dev/null 2>&1
mix_log=$(cat "$STUB_LOG")
assert_contains "$mix_log" "iptables -w -I wgmix_killswitch 1 -o br-lan_5 -j RETURN" \
    "subnet bridge gets its own head-inserted exemption"
assert_contains "$mix_log" "iptables -w -I wgmix_killswitch 1 -o br-lan -j RETURN" \
    "host bridge gets its own head-inserted exemption"
assert_contains "$mix_log" "-A wgmix_killswitch -s 10.90.5.0/24 ! -o wgmix -j REJECT" \
    "subnet target is pinned to the tunnel"
assert_contains "$mix_log" "-A wgmix_killswitch -s 10.90.1.7 ! -o wgmix -j REJECT" \
    "host target is pinned to the tunnel"
assert_not_contains "$mix_log" "-A wgmix_killswitch -o " \
    "no LAN exemption is appended behind a reject"

echo
if [ "$FAIL" -gt 0 ]; then
    echo "=== Kill switch: $FAIL failed, $PASS passed ==="
    exit 1
fi
echo "=== Kill switch: $PASS passed ==="
