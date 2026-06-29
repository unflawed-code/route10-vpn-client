#!/bin/sh
# OpenVPN status detection regression:
# - uses openvpn dev (tun_<iface>) instead of iface name
# - reports connecting state when process exists but tun is not up

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10ovpnstatus)"

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
    if printf "%s" "$haystack" | grep -Fq -- "$needle"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected substring: $needle"
    fi
}

export VPN_PREFIX="vpnx1"
export LIB_DIR="$PROJECT_ROOT/lib"
export WG_TMP_DIR="$TMP_DIR"

CONF_FILE="$TMP_DIR/proton.ovpn"
cat > "$CONF_FILE" <<'EOF_CONF'
client
setenv UV_IPV6 1
EOF_CONF

CONF_FILE_IPV4="$TMP_DIR/ipv4-only.ovpn"
cat > "$CONF_FILE_IPV4" <<'EOF_CONF'
client
EOF_CONF

# shellcheck source=/dev/null
. "$PROJECT_ROOT/plugins/status.sh"

# Stubs
IF_UP=1
PS_OPENVPN=0

db_get_interface() {
    # name|type|conf|routing_table|target_ips|domains|dns_servers|committed|target_only|ipv6_support|ipv6_subnets|nat66|start_time|running
    echo "ovprotonus4|openvpn|$CONF_FILE|1002|10.90.10.0/24|none||1|0|0||0|1700000000|1"
}

resolve_mac_to_ip() { return 1; }
is_mac() { return 1; }
normalize_mac() { echo "$1"; }
print_table_header() { printf "| %s |\n" "$1"; }
print_table_row() { printf "| %-16s | %-50s |\n" "$1" "$2"; }

uci() {
    if [ "$1" = "-q" ] && [ "$2" = "get" ] && [ "$3" = "openvpn.ovprotonus4.dev" ]; then
        echo "tun_ovprotonus4"
        return 0
    fi
    return 1
}

ip() {
    if [ "$1" = "link" ] && [ "$2" = "show" ] && [ "$3" = "tun_ovprotonus4" ]; then
        if [ "$IF_UP" = "1" ]; then
            echo "2: tun_ovprotonus4: <POINTOPOINT,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN mode DEFAULT group default qlen 500"
            return 0
        fi
        return 1
    fi
    return 0
}

ps() {
    if [ "$PS_OPENVPN" = "1" ]; then
        echo "1234 root /usr/sbin/openvpn --syslog openvpn(ovprotonus4)"
    fi
    return 0
}

curl() { return 1; }
wg() { return 0; }

echo "=== OpenVPN Status Detection Test ==="

# Case 1: tun device is up -> Active
IF_UP=1
PS_OPENVPN=0
out="$(cmd_status ovprotonus4)"
assert_contains "$out" "Status           │ Active ✅" "status uses OpenVPN tun device for active detection"
assert_contains "$out" "IPv6 Support     │ Yes ✅" "status infers OpenVPN IPv6 support from Proton setenv flag"

# Case 2: tun down, process alive -> Connecting
IF_UP=0
PS_OPENVPN=1
out="$(cmd_status ovprotonus4)"
assert_contains "$out" "Status           │ Active ⚠️ (Connecting)" "status reports connecting when process exists without tun link"

# Case 3: no IPv6 support in DB or runtime hints -> Disabled, not NAT66
db_get_interface() {
    echo "ovpurela|openvpn|$CONF_FILE_IPV4|1001|10.90.10.0/24|none||1|0|0||0|1700000000|1"
}
uci() {
    if [ "$1" = "-q" ] && [ "$2" = "get" ] && [ "$3" = "openvpn.ovpurela.dev" ]; then
        echo "ovpurela"
        return 0
    fi
    return 1
}
ip() {
    if [ "$1" = "link" ] && [ "$2" = "show" ] && [ "$3" = "ovpurela" ]; then
        echo "50: ovpurela: <POINTOPOINT,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN mode DEFAULT group default qlen 500"
        return 0
    fi
    return 0
}
out="$(cmd_status ovpurela)"
assert_contains "$out" "IPv6 Support     │ No ❌" "status keeps IPv6 support disabled when no hints are present"
assert_contains "$out" "IPv6 Mode        │ Disabled ❌" "status does not show NAT66 when OpenVPN is IPv4-only"

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
