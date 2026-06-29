#!/bin/sh
# tests/wg/ipv6-test.sh - Unit tests for IPv6 logic in common.sh
# Verifies the migration of 03-ipv6-prefix-routing.sh logic

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
COMMON_LIB="${PROJECT_ROOT}/lib/common.sh"

# Mock globals expected by analyze_ipv6
IPV6_SUPPORTED=0
VPN_IP6_SUBNETS=""
VPN_IP6_NEEDS_NAT66=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# Load library
if [ -f "$COMMON_LIB" ]; then
    . "$COMMON_LIB"
else
    echo "Error: common.sh not found at $COMMON_LIB"
    exit 1
fi

# --- TESTS ---

test_analyze_ipv6_64() {
    # Test valid /64 subnet expansion
    local input="2001:db8:1234:5678::1/64"
    analyze_ipv6 "$input" ""
    
    local errors=0
    [ "$IPV6_SUPPORTED" = "1" ] || { echo "  IPV6_SUPPORTED not set"; errors=1; }
    # Should contain the full subnet
    echo "$VPN_IP6_SUBNETS" | grep -q "2001:db8:1234:5678::/64" || { echo "  Subnet calculation failed. Got: '$VPN_IP6_SUBNETS'"; errors=1; }
    [ "$VPN_IP6_NEEDS_NAT66" = "1" ] || { echo "  NAT66 should be enabled for /64"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "analyze_ipv6: /64 Prefix Calculation"
    else
        log_fail "analyze_ipv6: /64 Prefix Calculation"
    fi
}

test_analyze_ipv6_128() {
    # Test /128 address
    local input="2001:db8::1234/128"
    analyze_ipv6 "$input" ""
    
    local errors=0
    [ "$IPV6_SUPPORTED" = "1" ] || { echo "  IPV6_SUPPORTED not set"; errors=1; }
    # Should expect NAT66 for /128 too? 
    # Logic in common.sh: "elif [ "$prefix_len" -eq 128 ]; then ... VPN_IP6_NEEDS_NAT66=1"
    [ "$VPN_IP6_NEEDS_NAT66" = "1" ] || { echo "  NAT66 should be enabled for /128"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "analyze_ipv6: /128 Support"
    else
        log_fail "analyze_ipv6: /128 Support"
    fi
}

test_analyze_ipv6_expansion() {
    # Test if it correctly expands minimal addresses for prefix calculation
    # e.g. 2001:db8::1/64 -> prefix 2001:db8:0:0::/64
    # The current awkward awk logic is what we are testing
    local input="2001:db8::1/64"
    analyze_ipv6 "$input" ""
    
    local errors=0
    # Expected: 2001:db8:0:0::/64 (or similar canonical form)
    # The awk script: 
    #   missing = 8 - n
    #   if n is small, it fills 0s.
    #   It outputs 4 groups: %s:%s:%s:%s
    
    # 2001:db8::1 -> groups: 2001, db8, 1 (Wait, awk logic splits by :)
    # This test verifies the specific port logic from the plugin behaves as intended
    
    echo "$VPN_IP6_SUBNETS" | grep -q "2001:db8:0:0::/64" || { echo "  Expansion failed. Got: '$VPN_IP6_SUBNETS'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "analyze_ipv6: Address Expansion"
    else
        log_fail "analyze_ipv6: Address Expansion"
    fi
}

echo "Running IPv6 Logic Tests..."
test_analyze_ipv6_64
test_analyze_ipv6_128
test_analyze_ipv6_expansion