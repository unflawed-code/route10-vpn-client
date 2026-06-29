#!/bin/sh
# tests/wg/runner.sh - Runner for WireGuard Migration Tests

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
CONF_DIR="/cfg/vpn-custom/conf"

# Ensure we are on the router (mock check or simple path check)
if [ ! -d "/etc/config" ] && [ ! -d "$PROJECT_ROOT/conf" ] ; then
    echo "Warning: Not running on OpenWrt router? Some tests might fail."
fi

# Setup Test Configs
setup_configs() {
    echo "Setting up Test Configs..."
    mkdir -p "$CONF_DIR"
    
    # 1. wgnepsyd (48 prefix + IPv4)
    cat > "$CONF_DIR/wgnepsyd.conf" <<EOF
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.90.1.5/32, 2001:db8:aaaa::5/48
DNS = 1.1.1.1

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

    # 2. wgprtonus81 (128 prefix + IPv4)
    cat > "$CONF_DIR/wgprtonus81.conf" <<EOF
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.90.1.6/32, 2001:db8:bbbb::6/128
DNS = 8.8.8.8

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 5.6.7.8:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF
    
    echo "Configs created."
}

run_tests() {
    failed=0
    
    echo ">>> Running Conf Tests"
    "$SCRIPT_DIR/conf-test.sh" || failed=1
    
    echo ">>> Running IPv6 Logic Tests"
    "$SCRIPT_DIR/ipv6-test.sh" || failed=1
    
    echo ">>> Running MAC Tests"
    "$SCRIPT_DIR/mac-test.sh" || failed=1
    
    return $failed
}

setup_configs
run_tests