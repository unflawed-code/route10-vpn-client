#!/bin/sh
# Tests for MTU support and Cleanup Logic
# Run this on the router

# Mock environment
TEST_DIR="/tmp/vpn-test-$$"
mkdir -p "$TEST_DIR"
CONF_FILE="$TEST_DIR/test.conf"
SCRIPT_DIR="/cfg/vpn-custom"

# Cleanup on exit
trap 'rm -rf "$TEST_DIR"' EXIT

# Create dummy config with MTU
cat > "$CONF_FILE" <<EOF
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Address = 10.200.0.2/32
DNS = 1.1.1.1
MTU = 1350

[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
EOF

# Source wg.sh to test parsing (if possible) or run it
# Since wg.sh executes, we'll try to run it with --internal-exec if supported or just check parsing

echo "Testing MTU Parsing..."
# Extract MTU using grep as a baseline check
GREP_MTU=$(grep "MTU" "$CONF_FILE" | cut -d= -f2 | tr -d ' ')
if [ "$GREP_MTU" != "1350" ]; then
    echo "FAIL: Test setup failed, config not written correctly"
    exit 1
fi

# Run wg.sh commit dry-run/staging if possible, or check UCI after setup
# We will use the 'commit' command to trigger parsing? No, setup triggers parsing.
# We'll run setup function by sourcing wg.sh if it was designed to be sourced, but it's an executable script.
# We will use UCI to verify.

# Mock UCI if not present (unlikely on router)
if ! command -v uci >/dev/null; then
    echo "SKIP: uci not found, cannot run full test"
    exit 0
fi

# Run setup for a dummy interface (routing table is auto-allocated)
INTERFACE="wgtest$$"
$SCRIPT_DIR/wg.sh "$INTERFACE" -c "$CONF_FILE" -t "192.168.1.50"

# Verify UCI
UCI_MTU=$(uci get network.$INTERFACE.mtu 2>/dev/null)
if [ "$UCI_MTU" = "1350" ]; then
    echo "PASS: MTU correctly set to 1350 in UCI"
else
    echo "FAIL: MTU is '$UCI_MTU', expected '1350'"
    uci show network.$INTERFACE
    exit 1
fi

# Cleanup UCI
uci delete network.$INTERFACE
uci commit network

echo "MTU Test Complete."
