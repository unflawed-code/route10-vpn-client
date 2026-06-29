#!/bin/sh
# Route10 VPN Project Configuration Loader
# Loads project defaults, then optional user overrides from project.conf.

if [ -n "${VPN_PROJECT_CONFIG_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
VPN_PROJECT_CONFIG_LOADED=1

# Built-in defaults (safe fallback even if project.conf is missing)
VPN_PREFIX="${VPN_PREFIX:-vpnx1}"
VPN_RT_START="${VPN_RT_START:-1000}"
VPN_RT_END="${VPN_RT_END:-1499}"
PBR_DB_BUSY_TIMEOUT_MS="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
VPN_IPV6_MODE_DEFAULT="${VPN_IPV6_MODE_DEFAULT:-nat66}"
VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC="${VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC:-5}"
VPN_IPV6_ROUTED_VERIFY_RETRIES="${VPN_IPV6_ROUTED_VERIFY_RETRIES:-3}"
VPN_IPV6_ROUTED_PROBE_ADDR="${VPN_IPV6_ROUTED_PROBE_ADDR:-2606:4700:4700::1111}"
VPN_IPV6_FORCE_TAKEOVER="${VPN_IPV6_FORCE_TAKEOVER:-0}"
VPN_ENABLE_AUTO_UPDATE="${VPN_ENABLE_AUTO_UPDATE:-0}"
VPN_UPDATE_CRON="${VPN_UPDATE_CRON:-40 4 * * *}"

# Resolve project root when not preset by caller.
if [ -z "$VPN_BASE_DIR" ]; then
    if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR" ]; then
        VPN_BASE_DIR="$SCRIPT_DIR"
    elif [ -n "$LIB_DIR" ] && [ -d "$LIB_DIR" ]; then
        VPN_BASE_DIR="$(dirname "$LIB_DIR")"
    else
        VPN_BASE_DIR="/cfg/vpn-custom"
    fi
fi

# Optional override file (user-editable)
VPN_PROJECT_CONFIG_FILE="${VPN_PROJECT_CONFIG_FILE:-$VPN_BASE_DIR/project.conf}"
if [ -f "$VPN_PROJECT_CONFIG_FILE" ]; then
    . "$VPN_PROJECT_CONFIG_FILE"
fi

is_valid_cron_schedule() {
    [ -n "${1:-}" ] || return 1
    printf '%s\n' "$1" | awk '
        function isnum(v) { return v ~ /^[0-9]+$/ }
        function check_token(tok, min, max,    base, step, pair) {
            base = tok
            step = ""
            if (index(tok, "/")) {
                split(tok, pair, "/")
                if (length(pair[1]) == 0 || length(pair[2]) == 0) return 0
                base = pair[1]
                step = pair[2]
                if (!isnum(step) || step < 1) return 0
            }
            if (base == "*") return 1
            if (index(base, "-")) {
                split(base, pair, "-")
                if (length(pair[1]) == 0 || length(pair[2]) == 0) return 0
                if (!isnum(pair[1]) || !isnum(pair[2])) return 0
                if (pair[1] < min || pair[1] > max || pair[2] < min || pair[2] > max) return 0
                return (pair[1] <= pair[2])
            }
            if (isnum(base)) return (base >= min && base <= max)
            return 0
        }
        function check_field(field, min, max,    i, n, parts) {
            n = split(field, parts, ",")
            if (n < 1) return 0
            for (i = 1; i <= n; i++) {
                if (!check_token(parts[i], min, max)) return 0
            }
            return 1
        }
        NF != 5 { exit 1 }
        !check_field($1, 0, 59) { exit 1 }
        !check_field($2, 0, 23) { exit 1 }
        !check_field($3, 1, 31) { exit 1 }
        !check_field($4, 1, 12) { exit 1 }
        !check_field($5, 0, 7)  { exit 1 }
        { exit 0 }
    ' >/dev/null 2>&1
}

# Normalize and validate post-load values.
_timeout_candidate="${PBR_DB_BUSY_TIMEOUT_MS:-}"
case "$_timeout_candidate" in
    ''|*[!0-9]*) _timeout_candidate="${WG_DB_BUSY_TIMEOUT_MS:-}" ;;
esac
case "$_timeout_candidate" in
    ''|*[!0-9]*) _timeout_candidate=5000 ;;
esac
PBR_DB_BUSY_TIMEOUT_MS="$_timeout_candidate"
WG_DB_BUSY_TIMEOUT_MS="$PBR_DB_BUSY_TIMEOUT_MS"
unset _timeout_candidate

case "$VPN_RT_START" in
    ''|*[!0-9]*) VPN_RT_START=1000 ;;
esac
case "$VPN_RT_END" in
    ''|*[!0-9]*) VPN_RT_END=1499 ;;
esac
if [ "$VPN_RT_START" -gt "$VPN_RT_END" ]; then
    VPN_RT_START=1000
    VPN_RT_END=1499
fi

case "$VPN_IPV6_MODE_DEFAULT" in
    auto) VPN_IPV6_MODE_DEFAULT=nat66 ;;
    nat66|routed-prefix|disabled) ;;
    *) VPN_IPV6_MODE_DEFAULT=nat66 ;;
esac

case "$VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC" in
    ''|*[!0-9]*) VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC=5 ;;
esac
if [ "$VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC" -lt 1 ]; then
    VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC=5
fi

case "$VPN_IPV6_ROUTED_VERIFY_RETRIES" in
    ''|*[!0-9]*) VPN_IPV6_ROUTED_VERIFY_RETRIES=3 ;;
esac
if [ "$VPN_IPV6_ROUTED_VERIFY_RETRIES" -lt 1 ]; then
    VPN_IPV6_ROUTED_VERIFY_RETRIES=3
fi

case "$VPN_IPV6_FORCE_TAKEOVER" in
    0|1) ;;
    *) VPN_IPV6_FORCE_TAKEOVER=0 ;;
esac

case "$VPN_ENABLE_AUTO_UPDATE" in
    0|1) ;;
    *) VPN_ENABLE_AUTO_UPDATE=0 ;;
esac

if ! is_valid_cron_schedule "$VPN_UPDATE_CRON"; then
    VPN_UPDATE_CRON="40 4 * * *"
fi
