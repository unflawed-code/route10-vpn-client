#!/bin/sh
# tests/routing-test.sh - Unit tests for ip-routing.sh library functions

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IP_ROUTING_LIB="${PROJECT_ROOT}/lib/routing/ip-routing.sh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

# --- MOCKS ---

# Prep mock directory
MOCK_BIN="/tmp/mock-bin.$$"
mkdir -p "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH"

# Create mock ip script
# Use unquoted INTERNAL_EOF inside to ensure it expands from the environment when RUN
cat > "$MOCK_BIN/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "rule" ] && [ "$2" = "show" ]; then
    [ -n "$DEBUG_ROUTING" ] && echo "--- MOCK IP RULE SHOW (RULES: $EXTRA_RULES) ---" >&2
    cat <<INTERNAL_EOF
0:	from all lookup local 
95:	from all fwmark 0x10064/0x10064 lookup wgprtonus81_rt 
96:	from all fwmark 0x20065 lookup wgnepsyd_rt 
$EXTRA_RULES
32766:	from all lookup main 
32767:	from all lookup default 
INTERNAL_EOF
fi
EOF
chmod +x "$MOCK_BIN/ip"

# Clear mock on exit
trap 'rm -rf "$MOCK_BIN"' EXIT

# Load library
if [ -f "$IP_ROUTING_LIB" ]; then
    # Ensure it is exported
    export EXTRA_RULES=""
    . "$IP_ROUTING_LIB"
else
    echo "Error: ip-routing.sh not found at $IP_ROUTING_LIB"
    exit 1
fi

# --- TESTS ---

test_collision_detection() {
    echo "Running check_fwmark_collision tests..."
    
    # 1. Test hitting the mask 0x10064/0x10064
    local result=$(check_fwmark_collision $((0x10065)))
    if [ -n "$result" ] && echo "$result" | grep -q "0x10064/0x10064"; then
        log_pass "Collision detected for 0x10065 against 0x10064/0x10064"
    else
        log_fail "Failed to detect collision for 0x10065 (Result: '$result')"
    fi
    
    # 2. Test hitting the exact match 0x20065
    result=$(check_fwmark_collision $((0x20065)))
    if [ -n "$result" ] && echo "$result" | grep -q "0x20065"; then
        log_pass "Collision detected for 0x20065 (Exact match)"
    else
        log_fail "Failed to detect exact match collision for 0x20065"
    fi
    
    # 3. Test ignore_table parameter (using name as seen in mock)
    # 0x20065 matches Rule 96 (wgnepsyd_rt)
    result=$(check_fwmark_collision $((0x20065)) "wgnepsyd")
    if [ -z "$result" ]; then
        log_pass "Correctly ignored self-collision for table 'wgnepsyd' (name match)"
    else
        log_fail "Failed to ignore self-collision for table 'wgnepsyd' (Result: '$result')"
    fi

    # 4. Test non-colliding mark
    result=$(check_fwmark_collision $((0x20066)))
    if [ -z "$result" ]; then
        log_pass "No collision detected for 0x20066 (Safe)"
    else
        log_fail "False positive collision for 0x20066 (Result: '$result')"
    fi
}

test_dynamic_mark_acquisition() {
    echo "Running calculate_mark dynamic acquisition tests..."
    
    local base_ns
    local base
    local table
    local base_mark
    local offset_mark

    table=130
    base_ns=$(get_mark_namespace_base)
    base=$((base_ns + 0x10000))
    base_mark=$((base + table))
    offset_mark=$((base_mark + 0x1000))

    # Mock a collision for the first candidate mark.
    EXTRA_RULES="99: from all fwmark 0x$(printf '%x' "$base_mark") lookup zzlegacy_rt"
    export EXTRA_RULES

    local direct_collision
    direct_collision=$(check_fwmark_collision "$base_mark" "$table")
    if [ -n "$direct_collision" ]; then
        log_pass "calculate_mark fixture: base candidate collision is visible"
    else
        log_fail "calculate_mark fixture: expected base candidate collision was not visible"
    fi
    
    local mark
    mark=$(calculate_mark "$table" 2>/dev/null)
    if [ "$mark" = "$offset_mark" ]; then
        log_pass "calculate_mark: Acquired offset mark after first-candidate collision"
    else
        log_fail "calculate_mark: Failed to acquire correct offset mark. Got: '$mark' (Expected $offset_mark)"
    fi
    
    # Force collision for all retry candidates and assert deterministic fallback.
    local colliding_rules=""
    local i=0
    while [ $i -lt 10 ]; do
        local candidate=$((base + 100 + (i * 0x1000)))
        colliding_rules="${colliding_rules}
$((200 + i)): from all fwmark 0x$(printf '%x' "$candidate") lookup blackhole"
        i=$((i + 1))
    done
    EXTRA_RULES="$colliding_rules"
    export EXTRA_RULES
    
    mark=$(calculate_mark 100 2>/dev/null)
    if [ "$mark" = "$((base + 100))" ]; then
        log_pass "calculate_mark: Returned deterministic fallback mark after retry window"
    else
        log_fail "calculate_mark: Expected fallback mark $((base + 100)) after collisions, got '$mark'"
    fi
    
    EXTRA_RULES=""
}

test_collision_aware_allocation() {
    echo "Running allocate_routing_table collision-aware tests..."
    
    EXTRA_RULES="95: from all fwmark 0x20064 lookup legacy_rt"
    export EXTRA_RULES
    
    local result=$(allocate_routing_table "" 100 110)
    if [ -n "$result" ] && [ "$result" -ge 100 ] 2>/dev/null && [ "$result" -le 110 ] 2>/dev/null; then
        log_pass "allocate_routing_table: Selected available table within requested range ($result)"
    else
        log_fail "allocate_routing_table: Unexpected table selection. Got: '$result' (Expected 100-110)"
    fi
    EXTRA_RULES=""
}

# --- SUMMARY ---
test_collision_detection
test_dynamic_mark_acquisition
test_collision_aware_allocation

echo "--------------------------------"
echo "Tests Passed: $pass_count"
echo "Tests Failed: $fail_count"

if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
fi
