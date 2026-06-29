#!/bin/sh
# wg/conf-test.sh - Test suite for WireGuard configuration parsing
# Migrated from route10-wireguard-client/tests/wg-pbr-suite

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# In new structure, wg.sh is in root
WG_SCRIPT="${PROJECT_ROOT}/wg.sh"
TEMP_DIR="/tmp/r10-wg-conf-test-$$"

mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# Helper to load the parser from the main script
load_parser() {
    # Extract the parse_wg_config function from wg.sh
    # We also need parse_endpoint since it's used
    # And analyze_ipv6 is now in common.sh... wait, wg.sh sources it.
    # But sourcing wg.sh might run it if we aren't careful.
    # wg.sh has logic to run if $1 is set. We source it in a subshell or extract functions?
    # wg.sh functions: parse_wg_config, parse_endpoint
    
    # Let's try sourcing common.sh manually, then extracting functions from wg.sh
    . "$PROJECT_ROOT/lib/common.sh"
    
    sed -n '/^parse_wg_config() {/,/^}/p' "$WG_SCRIPT" > "$TEMP_DIR/parser.sh"
    sed -n '/^parse_endpoint() {/,/^}/p' "$WG_SCRIPT" >> "$TEMP_DIR/parser.sh"
    . "$TEMP_DIR/parser.sh"
}

# --- TESTS ---

test_valid_config() {
    local test_file="$TEMP_DIR/valid.conf"
    cat > "$test_file" <<EOF
[Interface]
PrivateKey = AAAA
Address = 10.0.0.1/32

[Peer]
PublicKey = BBBB
Endpoint = 1.1.1.1:51820
AllowedIPs = 0.0.0.0/0
EOF

    unset PRIVATE_KEY CLIENT_IP PEER_PUBLIC_KEY ENDPOINT ALLOWED_IPS
    
    parse_wg_config "$test_file"
    
    local errors=0
    [ "$PRIVATE_KEY" = "AAAA" ] || { echo "  PrivateKey mismatch: '$PRIVATE_KEY'"; errors=1; }
    [ "$PEER_PUBLIC_KEY" = "BBBB" ] || { echo "  PublicKey mismatch: '$PEER_PUBLIC_KEY'"; errors=1; }
    [ "$ENDPOINT" = "1.1.1.1:51820" ] || { echo "  Endpoint mismatch: '$ENDPOINT'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "Valid Config Parsing"
    else
        log_fail "Valid Config Parsing"
    fi
}

test_comments() {
    local test_file="$TEMP_DIR/comments.conf"
    cat > "$test_file" <<EOF
[Interface]
# This is a comment
PrivateKey = AAAA # Inline comment

[Peer]
PublicKey = BBBB
EOF

    unset PRIVATE_KEY PEER_PUBLIC_KEY
    
    parse_wg_config "$test_file"
    
    local errors=0
    [ "$PRIVATE_KEY" = "AAAA" ] || { echo "  PrivateKey mismatch: '$PRIVATE_KEY'"; errors=1; }
    [ "$PEER_PUBLIC_KEY" = "BBBB" ] || { echo "  PublicKey mismatch: '$PEER_PUBLIC_KEY'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "Comments Handling"
    else
        log_fail "Comments Handling"
    fi
}

test_ipv6_endpoint() {
    local test_file="$TEMP_DIR/ipv6_endpoint.conf"
    cat > "$test_file" <<EOF
[Interface]
PrivateKey = AAAA
Address = 10.0.0.1/32

[Peer]
PublicKey = BBBB
Endpoint = [2001:db8::1]:51820
AllowedIPs = 0.0.0.0/0
EOF

    unset PRIVATE_KEY PEER_PUBLIC_KEY ENDPOINT ENDPOINT_HOST
    
    parse_wg_config "$test_file"
    parse_endpoint "$ENDPOINT"
    
    local errors=0
    [ "$PRIVATE_KEY" = "AAAA" ] || { echo "  PrivateKey mismatch: '$PRIVATE_KEY'"; errors=1; }
    [ "$ENDPOINT" = "[2001:db8::1]:51820" ] || { echo "  IPv6 Endpoint mismatch: '$ENDPOINT'"; errors=1; }
    [ "$ENDPOINT_HOST" = "2001:db8::1" ] || { echo "  Endpoint Host mismatch: '$ENDPOINT_HOST'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "IPv6 Endpoint Parsing"
    else
        log_fail "IPv6 Endpoint Parsing"
    fi
}

test_dual_stack_addresses() {
    local test_file="$TEMP_DIR/dual_stack.conf"
    cat > "$test_file" <<EOF
[Interface]
PrivateKey = AAAA
Address = 10.0.0.1/32, 2001:db8::1/128
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = BBBB
Endpoint = 1.1.1.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

    unset PRIVATE_KEY CLIENT_IP CLIENT_IP6 DNS_SERVERS
    
    parse_wg_config "$test_file"
    
    local errors=0
    [ "$PRIVATE_KEY" = "AAAA" ] || { echo "  PrivateKey mismatch: '$PRIVATE_KEY'"; errors=1; }
    echo "$CLIENT_IP" | grep -q "10.0.0.1/32" || { echo "  CLIENT_IP missing IPv4: '$CLIENT_IP'"; errors=1; }
    echo "$CLIENT_IP6" | grep -q "2001:db8::1/128" || { echo "  CLIENT_IP6 missing IPv6: '$CLIENT_IP6'"; errors=1; }
    echo "$DNS_SERVERS" | grep -q "1.1.1.1" || { echo "  DNS missing IPv4: '$DNS_SERVERS'"; errors=1; }
    echo "$DNS_SERVERS" | grep -q "2606:4700:4700::1111" || { echo "  DNS missing IPv6: '$DNS_SERVERS'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "Dual-Stack Address Parsing"
    else
        log_fail "Dual-Stack Address Parsing"
    fi
}

# --- MAIN ---

echo "Running WireGuard Config Tests..."
echo "Target Script: $WG_SCRIPT"

if [ ! -f "$WG_SCRIPT" ]; then
    echo "Error: wg.sh not found at $WG_SCRIPT"
    exit 1
fi

load_parser

test_valid_config
test_comments
test_ipv6_endpoint
test_dual_stack_addresses

echo "Conf Tests Done."