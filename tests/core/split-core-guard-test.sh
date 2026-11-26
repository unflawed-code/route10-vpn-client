#!/bin/sh
# Split-tunnel core guard regression:
# - the core marks itself loaded so it is never re-sourced
# - lib/split-tunnel.sh never resolves vpn-core.sh from $0
# - a decoy vpn-core.sh beside the calling wrapper is ignored
# - sourcing the library does not clobber the caller's SCRIPT_DIR

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10splitguard)"
PASS=0
FAIL=0

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

assert_eq() {
    expected="$1"
    actual="$2"
    msg="$3"
    if [ "$expected" = "$actual" ]; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

assert_absent() {
    path="$1"
    msg="$2"
    if [ -e "$path" ]; then
        say_fail "$msg"
    else
        say_pass "$msg"
    fi
}

PROJECT="$TMP_DIR/project"
OUT="$TMP_DIR/out"
mkdir -p "$PROJECT" "$OUT" "$TMP_DIR/runtime"
cp -r "$PROJECT_ROOT/lib" "$PROJECT/lib"

# Decoy: sits exactly where a $0-relative lookup would find it.
cat > "$PROJECT/vpn-core.sh" <<EOF
#!/bin/sh
echo "decoy sourced" > "$OUT/decoy-marker"
EOF

# A: normal wrapper flow - core loaded first, then the split library.
cat > "$PROJECT/driver_a.sh" <<EOF
#!/bin/sh
VPN_BASE_DIR="$PROJECT"
VPN_TMP_DIR="$TMP_DIR/runtime"
SCRIPT_DIR="$PROJECT"
. "$PROJECT/lib/vpn-core.sh"
. "$PROJECT/lib/split-tunnel.sh"
printf '%s' "\${VPN_CORE_LOADED:-unset}" > "$OUT/a_flag"
type split_tunnel_apply >/dev/null 2>&1 && echo ok > "$OUT/a_func"
printf '%s' "\$SCRIPT_DIR" > "$OUT/a_scriptdir"
EOF

# B: core not pre-loaded - fallback must use LIB_DIR, never the decoy.
cat > "$PROJECT/driver_b.sh" <<EOF
#!/bin/sh
VPN_BASE_DIR="$PROJECT"
VPN_TMP_DIR="$TMP_DIR/runtime"
LIB_DIR="$PROJECT/lib"
. "$PROJECT/lib/split-tunnel.sh"
printf '%s' "\${VPN_CORE_LOADED:-unset}" > "$OUT/b_flag"
type split_tunnel_apply >/dev/null 2>&1 && echo ok > "$OUT/b_func"
EOF

echo "=== Split Core Guard Test ==="

( cd "$PROJECT" && sh ./driver_a.sh ) >/dev/null 2>&1
assert_absent "$OUT/decoy-marker" "decoy beside wrapper is not sourced when core is already loaded"
assert_eq "1" "$(cat "$OUT/a_flag" 2>/dev/null)" "core marks itself loaded"
assert_eq "ok" "$(cat "$OUT/a_func" 2>/dev/null)" "split-tunnel functions available after guarded source"
assert_eq "$PROJECT" "$(cat "$OUT/a_scriptdir" 2>/dev/null)" "split library does not clobber caller SCRIPT_DIR"

rm -f "$OUT/decoy-marker"
( cd "$PROJECT" && sh ./driver_b.sh ) >/dev/null 2>&1
assert_absent "$OUT/decoy-marker" "fallback path ignores decoy beside wrapper"
assert_eq "1" "$(cat "$OUT/b_flag" 2>/dev/null)" "fallback resolves the real core through LIB_DIR"
assert_eq "ok" "$(cat "$OUT/b_func" 2>/dev/null)" "split-tunnel functions available after fallback source"

if grep -q 'SCRIPT_DIR/vpn-core.sh' "$PROJECT_ROOT/lib/split-tunnel.sh"; then
    say_fail "split library contains no \$0-relative core lookup"
else
    say_pass "split library contains no \$0-relative core lookup"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
