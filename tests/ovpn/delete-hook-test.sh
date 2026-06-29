#!/bin/bash

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
CALLS=""
WAIT_CALLS=0

say_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

record_call() {
    CALLS="${CALLS}$1"$'\n'
}

assert_contains() {
    local needle="$1"
    local msg="$2"
    if printf '%s' "$CALLS" | grep -Fqx "$needle"; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  missing: $needle"
    fi
}

assert_not_contains() {
    local needle="$1"
    local msg="$2"
    if printf '%s' "$CALLS" | grep -Fqx "$needle"; then
        say_fail "$msg"
        echo "  unexpected: $needle"
    else
        say_pass "$msg"
    fi
}

uci() {
    record_call "uci $*"
    case "$1 $2" in
        "-q get")
            [ "$3" = "openvpn.ovpurela" ] && { echo "openvpn"; return 0; }
            return 1
            ;;
    esac
    return 0
}

kill() {
    record_call "kill $*"
    return 0
}

sleep() { :; }

ps() {
    cat <<'EOF'
 101 root     S    /usr/sbin/openvpn --syslog openvpn(ovpurela) --dev ovpurela --config .vpnx1_ovpurela.ovpn
 202 root     S    /usr/sbin/openvpn --syslog openvpn(other) --dev other --config .vpnx1_other.ovpn
EOF
}

openvpn_service() {
    record_call "service-openvpn $*"
    return 0
}

rm() {
    record_call "rm $*"
    return 0
}

TMP_COPY="$(mktemp)"
trap 'rm -f "$TMP_COPY"' EXIT
awk '
    /^# === OPENVPN CONFIG PARSER ===/ { keep=1 }
    /^# === ARGUMENT PARSING ===/ { keep=0 }
    keep { print }
' "$PROJECT_ROOT/ovpn.sh" | command sed \
    -e 's|\[ -x /etc/init\.d/openvpn \]|command -v openvpn_service >/dev/null 2>\&1|g' \
    -e 's|/etc/init.d/openvpn|openvpn_service|g' > "$TMP_COPY"

vpn_core_register_hook() { record_call "register $1 $2"; }

# shellcheck disable=SC1090
. "$TMP_COPY"

ovpn_find_pids() {
    printf '101\n'
}

ovpn_wait_for_exit() {
    WAIT_CALLS=$((WAIT_CALLS + 1))
    [ "$WAIT_CALLS" -ge 2 ]
}

CALLS=""
ovpn_pre_delete "ovpurela"
ovpn_post_delete "ovpurela"

assert_contains "uci set openvpn.ovpurela.enabled='0'" "pre-delete disables the OpenVPN instance"
assert_contains "uci commit openvpn" "pre/post-delete commit OpenVPN changes"
assert_contains "service-openvpn reload" "hooks reload OpenVPN service"
assert_contains "kill -TERM 101" "pre-delete sends TERM to matching instance"
assert_contains "kill -KILL 101" "pre-delete escalates to KILL when needed"
assert_not_contains "kill -TERM 202" "pre-delete leaves unrelated OpenVPN instance alone"
assert_contains "rm -f /var/run/openvpn.ovpurela.status" "post-delete removes stale status file"
assert_contains "rm -f /var/run/openvpn.ovpurela.userpass" "post-delete removes stale userpass file"

if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL TESTS PASSED ==="
    exit 0
fi

echo "=== TESTS FAILED ==="
exit 1
