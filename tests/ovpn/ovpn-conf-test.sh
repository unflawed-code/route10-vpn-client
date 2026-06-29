#!/bin/sh
# ovpn-conf-test.sh - Test suite for OpenVPN configuration parsing

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
OVPN_SH="${PROJECT_ROOT}/ovpn.sh"
TEMP_DIR="/tmp/ovpn-conf-test-$$"

mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
PASS=0
FAIL=0

log_pass() {
    printf "%b[PASS]%b %s\n" "$GREEN" "$NC" "$1"
    PASS=$((PASS + 1))
}

log_fail() {
    printf "%b[FAIL]%b %s\n" "$RED" "$NC" "$1"
    FAIL=$((FAIL + 1))
}

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1; depth=0 }
        capture {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$OVPN_SH"
}

# Helper to load the parser from the main script
load_parser() {
    extract_function parse_ovpn_auth_credentials > "$TEMP_DIR/parser.sh"
    extract_function parse_ovpn_config >> "$TEMP_DIR/parser.sh"
    . "$TEMP_DIR/parser.sh"
}

# --- TESTS ---

test_valid_config() {
    local test_file="$TEMP_DIR/valid.ovpn"
    cat > "$test_file" <<EOF
client
dev tun
proto udp
remote 1.2.3.4 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert client.crt
key client.key
remote-cert-tls server
tls-auth ta.key 1
cipher AES-256-GCM
verb 3
setenv UV_IPV6 1
EOF

    # Variables must be cleared before parsing
    unset DNS_SERVERS IPV6_SUPPORTED OVPN_AUTH_USERNAME OVPN_AUTH_PASSWORD
    
    parse_ovpn_config "$test_file"
    
    local errors=0
    [ "$IPV6_SUPPORTED" = "1" ] || { echo "  IPv6 support mismatch: '$IPV6_SUPPORTED'"; errors=1; }
    [ -z "$DNS_SERVERS" ] || { echo "  DNS should be empty: '$DNS_SERVERS'"; errors=1; }
    [ -z "$OVPN_AUTH_USERNAME" ] || { echo "  Auth username should be empty: '$OVPN_AUTH_USERNAME'"; errors=1; }
    [ -z "$OVPN_AUTH_PASSWORD" ] || { echo "  Auth password should be empty: '$OVPN_AUTH_PASSWORD'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "Basic Config Parsing"
    else
        log_fail "Basic Config Parsing"
    fi
}

test_dns_pushed() {
    local test_file="$TEMP_DIR/dns.ovpn"
    cat > "$test_file" <<EOF
remote 1.1.1.1 1194
# Some other stuff
dhcp-option DNS 8.8.8.8
dhcp-option DNS 8.8.4.4
EOF

    unset DNS_SERVERS
    
    parse_ovpn_config "$test_file"
    
    local errors=0
    echo "$DNS_SERVERS" | grep -q "8.8.8.8" || { echo "  DNS missing 8.8.8.8: '$DNS_SERVERS'"; errors=1; }
    echo "$DNS_SERVERS" | grep -q "8.8.4.4" || { echo "  DNS missing 8.8.4.4: '$DNS_SERVERS'"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log_pass "DNS Directive Parsing"
    else
        log_fail "DNS Directive Parsing"
    fi
}

# --- MAIN ---

echo "Running OpenVPN Config Tests..."
echo "Target Script: $OVPN_SH"

if [ ! -f "$OVPN_SH" ]; then
    echo "Error: ovpn.sh not found at $OVPN_SH"
    exit 1
fi

load_parser

test_valid_config
test_dns_pushed

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Done."

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
