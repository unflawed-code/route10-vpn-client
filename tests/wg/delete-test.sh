#!/bin/sh
# tests/wg/delete-test.sh - Integration test for wg.sh delete command
# Verifies database removal, UCI cleanup, and interface removal.
# CONFIG Preservation: Verifies that the .conf file is NOT deleted.

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WG_SCRIPT="${PROJECT_ROOT}/wg.sh"
TEMP_DIR="/tmp/r10-wg-delete-test-$$"
BIN_DIR="$TEMP_DIR/bin"

mkdir -p "$TEMP_DIR" "$BIN_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Colors
GREEN='\\033[0;32m'
RED='\\033[0;31m'
NC='\\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# SETUP MOCKS
export PATH="$BIN_DIR:$PATH"

# Mock UCI
cat > "$BIN_DIR/uci" << 'EOF'
#!/bin/sh
echo "uci $@" >> /tmp/uci.log
EOF
chmod +x "$BIN_DIR/uci"

# Mock SQLite3
cat > "$BIN_DIR/sqlite3" << 'EOF'
#!/bin/sh
echo "sqlite3 $@" >> /tmp/sqlite3.full.log

last_arg=""
for arg in "$@"; do
    last_arg="$arg"
done

if echo "$last_arg" | grep -q "SELECT.*interfaces.*WHERE name"; then
    if echo "$last_arg" | grep -q "SELECT \*"; then
        echo "mock_iface|wireguard|conf/mock.conf|100|1.2.3.4|none|8.8.8.8|1|0|0|0|0|1|0"
        exit 0
    fi
    if echo "$last_arg" | grep -q "routing_table"; then
        echo "100"
        exit 0
    fi
    if echo "$last_arg" | grep -q "target_ips"; then
        echo "1.2.3.4"
        exit 0
    fi
    if echo "$last_arg" | grep -q "type"; then
        echo "wireguard"
        exit 0
    fi
    if echo "$last_arg" | grep -q "domains"; then
        echo "none"
        exit 0
    fi
fi

if echo "$last_arg" | grep -q "SELECT.*mac_state"; then
    echo ""
    exit 0
fi

if echo "$last_arg" | grep -q "DELETE FROM"; then
    echo "DELETE executed" >> /tmp/sqlite3.log
    exit 0
fi

echo "sqlite3 $@" >> /tmp/sqlite3.log
EOF
chmod +x "$BIN_DIR/sqlite3"

# Mock IP
cat > "$BIN_DIR/ip" << 'EOF'
#!/bin/sh
if [ "$1" = "link" ] && [ "$2" = "show" ]; then
    echo "mock_iface: <POINTOPOINT,NOARP,UP,LOWER_UP>"
    exit 0
fi
echo "ip $@" >> /tmp/ip.log
EOF
chmod +x "$BIN_DIR/ip"

# Mock ifdown
cat > "$BIN_DIR/ifdown" << 'EOF'
#!/bin/sh
echo "ifdown $@" >> /tmp/ifdown.log
EOF
chmod +x "$BIN_DIR/ifdown"

# Mock rm
cat > "$BIN_DIR/rm" << 'EOF'
#!/bin/sh
echo "rm $@" >> /tmp/rm.log
EOF
chmod +x "$BIN_DIR/rm"

# Mock other tools
echo "#!/bin/sh" > "$BIN_DIR/ipset" && chmod +x "$BIN_DIR/ipset"
echo "#!/bin/sh" > "$BIN_DIR/iptables" && chmod +x "$BIN_DIR/iptables"
echo "#!/bin/sh" > "$BIN_DIR/ip6tables" && chmod +x "$BIN_DIR/ip6tables"
echo "#!/bin/sh" > "$BIN_DIR/logger" && chmod +x "$BIN_DIR/logger"

# Mock Config File
mkdir -p "$TEMP_DIR/cfg/vpn-custom/conf"
touch "$TEMP_DIR/cfg/vpn-custom/conf/mock.conf"

# --- TEST EXECUTION ---

test_delete_interface() {
    rm -f /tmp/uci.log /tmp/sqlite3.log /tmp/sqlite3.full.log /tmp/ip.log /tmp/rm.log /tmp/ifdown.log /tmp/wg.log
    
    echo "Running: $WG_SCRIPT delete mock_iface"
    "$WG_SCRIPT" delete mock_iface >/tmp/wg.log 2>&1
    local ret=$?
    
    if [ $ret -ne 0 ]; then
        log_fail "Delete command returned error code $ret"
        echo "--- STDOUT/STDERR ---"
        cat /tmp/wg.log
        return 1
    fi
    
    local errors=0
    
    # UCI Cleanup
    if grep -q "delete network.mock_iface" /tmp/uci.log; then
        echo "  [OK] UCI network cleaned"
    else
        echo "  [ERR] UCI network cleanup missing"
        errors=1
    fi
    
    if grep -q "delete firewall.mock_iface_zone" /tmp/uci.log; then
        echo "  [OK] UCI firewall cleaned"
    else
        echo "  [ERR] UCI firewall cleanup missing"
        errors=1
    fi

    if grep -q "delete network.@wireguard_mock_iface\\[0\\]" /tmp/uci.log; then
        echo "  [OK] WireGuard peer sections cleaned"
    else
        echo "  [ERR] WireGuard peer cleanup missing"
        errors=1
    fi

    if grep -q "commit network" /tmp/uci.log && grep -q "commit firewall" /tmp/uci.log; then
        echo "  [OK] UCI commits persisted cleanup"
    else
        echo "  [ERR] UCI commit missing"
        errors=1
    fi
    
    # DB Cleanup
    if grep -q "DELETE executed" /tmp/sqlite3.log; then
        echo "  [OK] DB interface deleted"
    else
        echo "  [ERR] DB deletion missing"
        errors=1
    fi
    
    # System Cleanup
    if grep -q "mock_iface" /tmp/ifdown.log; then
        echo "  [OK] Interface brought down"
    else
         echo "  [ERR] ifdown missing"
         errors=1
    fi
    
    if grep -q "link delete mock_iface" /tmp/ip.log; then
        echo "  [OK] Kernel link deleted"
    else
         echo "  [ERR] ip link delete missing"
         errors=1
    fi
    
    # Preservation Check
    if grep -q "rm .*mock.conf" /tmp/rm.log; then
         echo "  [ERR] Config file removed (Should be preserved)"
         errors=1
    else
         echo "  [OK] Config file preserved"
    fi

    if [ $errors -eq 0 ]; then
        log_pass "Delete Interface Integration"
    else
        log_fail "Delete Interface Integration"
    fi
}

echo "Running WireGuard Delete Tests (Simplified)..."
test_delete_interface
