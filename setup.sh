#!/bin/ash
# Route10 VPN Client setup and updater integration.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="v1.1.0"
CRON_FILE="/etc/crontabs/root"
UPDATER_SCRIPT="${SCRIPT_DIR}/scripts/updater.sh"
UPDATER_JOB_CMD="/bin/ash ${UPDATER_SCRIPT} check >/dev/null 2>&1"
NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --non-interactive|-n) NON_INTERACTIVE=1 ;;
    esac
    shift
done

normalize_crlf_file() {
    [ -f "$1" ] || return 0
    sed -i 's/\r$//' "$1" 2>/dev/null || true
}

normalize_project_line_endings() {
    local candidate
    for candidate in \
        "${SCRIPT_DIR}/"*.sh \
        "${SCRIPT_DIR}/lib/"*.sh \
        "${SCRIPT_DIR}/lib/routing/"*.sh \
        "${SCRIPT_DIR}/plugins/"*.sh \
        "${SCRIPT_DIR}/scripts/"*.sh
    do
        [ -f "$candidate" ] || continue
        normalize_crlf_file "$candidate"
    done
}

normalize_project_line_endings

[ -f "${SCRIPT_DIR}/lib/project-config.sh" ] && . "${SCRIPT_DIR}/lib/project-config.sh"

VPN_ENABLE_AUTO_UPDATE="${VPN_ENABLE_AUTO_UPDATE:-0}"
VPN_UPDATE_CRON="${VPN_UPDATE_CRON:-40 4 * * *}"
UPDATER_CRON="${VPN_UPDATE_CRON} ${UPDATER_JOB_CMD}"
INSTALL_VERSION_FILE="${SCRIPT_DIR}/.installed-version"

get_script_version() {
    sed -n 's/^VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/setup.sh" | head -n 1 | tr -d '\r'
}

get_wg_version() {
    sed -n 's/^WG_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/wg.sh" | head -n 1 | tr -d '\r'
}

get_ovpn_version() {
    sed -n 's/^OVPN_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/ovpn.sh" | head -n 1 | tr -d '\r'
}

update_uci_version() {
    command -v uci >/dev/null 2>&1 || return 0
    [ -f "/etc/config/vpn-client" ] || touch "/etc/config/vpn-client"
    if ! uci -q get vpn-client.system >/dev/null 2>&1; then
        uci set vpn-client.system=system
    fi
    uci set vpn-client.system.version="$VERSION"
    uci set vpn-client.system.wireguard="$(get_wg_version)"
    uci set vpn-client.system.openvpn="$(get_ovpn_version)"
    uci commit vpn-client >/dev/null 2>&1 || true
}

ensure_project_script_permissions() {
    local script_path

    find "$SCRIPT_DIR" -type f -name '*.sh' | while IFS= read -r script_path; do
        [ -f "$script_path" ] || continue
        chmod 700 "$script_path" 2>/dev/null || chmod +x "$script_path" 2>/dev/null || true
    done
}

configure_cron() {
    [ -f "$CRON_FILE" ] || touch "$CRON_FILE"
    [ -f "$CRON_FILE" ] || return 0

    grep -Fv "/route10-vpn-client/scripts/updater.sh check" "$CRON_FILE" 2>/dev/null | \
        grep -Fv "/vpn-custom/scripts/updater.sh check" | \
        grep -Fv "route10-vpn-client/setup.sh" > "${CRON_FILE}.tmp" || true

    if [ "$VPN_ENABLE_AUTO_UPDATE" = "1" ]; then
        echo "$UPDATER_CRON" >> "${CRON_FILE}.tmp"
    fi

    if ! cmp -s "$CRON_FILE" "${CRON_FILE}.tmp" 2>/dev/null; then
        mv "${CRON_FILE}.tmp" "$CRON_FILE"
        /etc/init.d/cron restart >/dev/null 2>&1 || true
        if [ "$VPN_ENABLE_AUTO_UPDATE" = "1" ]; then
            echo "Configured updater cron: $UPDATER_CRON"
        else
            echo "Auto-update disabled; updater cron removed."
        fi
    else
        rm -f "${CRON_FILE}.tmp"
    fi
}

echo "=== Route10 VPN Client Setup (${VERSION}) ==="

ensure_project_script_permissions

configure_cron
update_uci_version
printf '%s\n' "$VERSION" > "$INSTALL_VERSION_FILE" 2>/dev/null || true

echo "Setup complete."
if [ "$VPN_ENABLE_AUTO_UPDATE" = "1" ]; then
    echo "Auto-update is enabled (daily: ${VPN_UPDATE_CRON})."
else
    echo "Auto-update is disabled (VPN_ENABLE_AUTO_UPDATE=0)."
fi

[ "$NON_INTERACTIVE" -eq 1 ] && exit 0
