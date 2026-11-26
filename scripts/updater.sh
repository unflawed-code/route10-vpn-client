#!/bin/ash

# Keep script buffered in memory to allow safe self-overwrite during update.
{
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$SELF_DIR")" = "scripts" ]; then
    REMOTE_DIR="$(dirname "$SELF_DIR")"
else
    REMOTE_DIR="$SELF_DIR"
fi

LOG_FILE="/var/log/route10-vpn-client-updater.log"
GITHUB_REPO="unflawed-code/route10-vpn-client"
REPO_NAME="${GITHUB_REPO##*/}"
LATEST_RELEASE_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
RELEASE_DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download"
WEB_LATEST_URL="https://github.com/${GITHUB_REPO}/releases/latest"
INSTALL_VERSION_FILE="${REMOTE_DIR}/.installed-version"

UPDATE_SUCCESS=0
UPDATE_TMP_DIR=""
UPDATE_BACKUP_DIR=""
PARITY_VERSION=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] updater: $*" | tee -a "$LOG_FILE" >&2
}

# === TRUST POLICY ===
# project.conf is preserved across updates, so a compromised release cannot
# rewrite these values; they are the only anchors that survive a bad release.
if [ -f "${REMOTE_DIR}/project.conf" ]; then
    . "${REMOTE_DIR}/project.conf"
fi
PINNED_SHA256="${VPN_UPDATE_PINNED_SHA256:-}"
ALLOW_UNVERIFIED="${VPN_UPDATE_ALLOW_UNVERIFIED:-0}"
case "$ALLOW_UNVERIFIED" in
    1) ;;
    *) ALLOW_UNVERIFIED=0 ;;
esac
if [ -n "$PINNED_SHA256" ]; then
    case "$PINNED_SHA256" in
        *[!0-9a-fA-F]*)
            log "WARNING: ignoring malformed VPN_UPDATE_PINNED_SHA256"
            PINNED_SHA256=""
            ;;
        *)
            if [ "${#PINNED_SHA256}" -ne 64 ]; then
                log "WARNING: ignoring VPN_UPDATE_PINNED_SHA256 (expected 64 hex characters)"
                PINNED_SHA256=""
            fi
            ;;
    esac
fi

UPDATE_VERIFY_LIB="${REMOTE_DIR}/lib/update-verify.sh"
if [ ! -f "$UPDATE_VERIFY_LIB" ]; then
    log "ERROR: update verification library missing at $UPDATE_VERIFY_LIB"
    exit 1
fi
. "$UPDATE_VERIFY_LIB"

get_uci_installed_version() {
    command -v uci >/dev/null 2>&1 || return 0
    uci -q get vpn-client.system.version 2>/dev/null | tr -d '\r[:space:]'
}

set_uci_installed_version() {
    local script_version="$1"
    command -v uci >/dev/null 2>&1 || return 0
    [ -f "/etc/config/vpn-client" ] || touch "/etc/config/vpn-client"
    if ! uci -q get vpn-client.system >/dev/null 2>&1; then
        uci set vpn-client.system=system
    fi
    uci set vpn-client.system.version="$script_version"
    uci set vpn-client.system.wireguard="$(sed -n 's/^WG_VERSION="\(.*\)"/\1/p' "${REMOTE_DIR}/wg.sh" | head -n 1 | tr -d '\r')"
    uci set vpn-client.system.openvpn="$(sed -n 's/^OVPN_VERSION="\(.*\)"/\1/p' "${REMOTE_DIR}/ovpn.sh" | head -n 1 | tr -d '\r')"
    uci commit vpn-client >/dev/null 2>&1 || true
}

get_local_version() {
    local version
    if [ -f "$INSTALL_VERSION_FILE" ]; then
        version="$(sed -n '1p' "$INSTALL_VERSION_FILE" | tr -d '\r[:space:]')"
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    version=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "${REMOTE_DIR}/setup.sh" | head -n 1 | tr -d '\r')
    [ -n "$version" ] || version="v0.0.0"
    echo "$version"
}

reconcile_version_parity() {
    local local_version="$1"
    local uci_version

    PARITY_VERSION="$local_version"
    uci_version="$(get_uci_installed_version)"
    if [ -z "$uci_version" ]; then
        printf '%s\n' "$PARITY_VERSION" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
        set_uci_installed_version "$PARITY_VERSION"
        return 0
    fi

    if [ "$uci_version" = "$PARITY_VERSION" ]; then
        return 0
    fi

    if version_gt "$uci_version" "$PARITY_VERSION"; then
        log "Version parity mismatch (file=${PARITY_VERSION}, uci=${uci_version}). Trusting UCI value."
        PARITY_VERSION="$uci_version"
        printf '%s\n' "$PARITY_VERSION" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
        return 0
    fi

    log "Version parity mismatch (file=${PARITY_VERSION}, uci=${uci_version}). Updating UCI to file version."
    set_uci_installed_version "$PARITY_VERSION"
}

# Download $1 to $2. TLS verification is always on: never pass
# --no-check-certificate, or a network attacker can substitute any payload.
download() {
    local url="$1"
    local dest="$2"

    case "$url" in
        https://*) ;;
        *)
            log "ERROR: refusing non-https URL: $url"
            return 1
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        log "ERROR: Neither curl nor wget is available."
        return 1
    fi
}

get_latest_version_tag() {
    local tag=""

    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -fsSL --proto '=https' --tlsv1.2 "$LATEST_RELEASE_URL" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    elif command -v wget >/dev/null 2>&1; then
        tag=$(wget -q -O - "$LATEST_RELEASE_URL" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [ -z "$tag" ]; then
        if command -v curl >/dev/null 2>&1; then
            tag=$(curl -fsSIL --proto '=https' --tlsv1.2 "$WEB_LATEST_URL" 2>/dev/null | grep -i "^location:" | sed -n 's|.*/tag\(s\)\?/\([^[:space:]\r]*\).*|\2|p' | tail -n 1)
        elif command -v wget >/dev/null 2>&1; then
            tag=$(wget -S --spider "$WEB_LATEST_URL" 2>&1 | grep -i "Location:" | sed -n 's|.*/tag\(s\)\?/\([^[:space:]\r]*\).*|\2|p' | tail -n 1)
        fi
    fi

    tag=$(printf '%s' "$tag" | tr -d '\r')
    [ -n "$tag" ] || return 1

    # The tag is interpolated into URLs and paths; never trust it blindly.
    if ! update_is_safe_tag "$tag"; then
        log "ERROR: refusing unsafe release tag: $tag"
        return 1
    fi

    echo "$tag"
}

version_gt() {
    local v1
    local v2
    local i
    local p1
    local p2
    v1=$(echo "$1" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')
    v2=$(echo "$2" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')

    if [ "$v1" = "$v2" ]; then
        if echo "$1" | grep -qv "-" && echo "$2" | grep -q "-"; then
            return 0
        fi
        if echo "$1" | grep -q "-" && echo "$2" | grep -q "-"; then
            local rc1
            local rc2
            rc1=$(echo "$1" | sed 's/.*-rc//' | tr -dc '0-9')
            rc2=$(echo "$2" | sed 's/.*-rc//' | tr -dc '0-9')
            if [ "${rc1:-0}" -gt "${rc2:-0}" ]; then return 0; fi
        fi
        return 1
    fi

    i=1
    while [ $i -le 3 ]; do
        p1=$(echo "$v1" | cut -d. -f$i)
        p2=$(echo "$v2" | cut -d. -f$i)
        [ -n "$p1" ] || p1=0
        [ -n "$p2" ] || p2=0
        if [ "$p1" -gt "$p2" ]; then return 0; fi
        if [ "$p1" -lt "$p2" ]; then return 1; fi
        i=$((i + 1))
    done
    return 1
}

rollback_update() {
    local backup_dir="$1"
    log "CRITICAL: Update failed. Starting rollback."
    [ -d "$backup_dir" ] || { log "ERROR: Rollback failed - backup missing."; return 1; }

    rm -rf "${REMOTE_DIR:?}/"*
    cp -rf "${backup_dir}/"* "$REMOTE_DIR/"
    ensure_project_script_permissions "$REMOTE_DIR"
    /bin/ash "${REMOTE_DIR}/setup.sh" --non-interactive >/dev/null 2>&1 || true
    log "Rollback complete."
}

cleanup_trap() {
    if [ "$UPDATE_SUCCESS" -eq 0 ] && [ -n "$UPDATE_BACKUP_DIR" ]; then
        rollback_update "$UPDATE_BACKUP_DIR" || true
    fi
    if [ -n "$UPDATE_TMP_DIR" ]; then
        rm -rf "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR" 2>/dev/null || true
    fi
}

ensure_project_script_permissions() {
    local target_dir="$1"
    local script_path

    [ -d "$target_dir" ] || return 0
    find "$target_dir" -type f -name '*.sh' | while IFS= read -r script_path; do
        [ -f "$script_path" ] || continue
        if [ ! -x "$script_path" ]; then
            chmod 700 "$script_path"
            log "Repaired execute permission on $script_path"
        fi
    done
}

perform_update() {
    local latest_tag="$1"
    local asset_name="${REPO_NAME}-${latest_tag}.tar.gz"
    local release_url="${RELEASE_DOWNLOAD_URL}/${latest_tag}"
    local backup_path="/tmp/route10-vpn-client-backup"
    local archive_path
    local sums_path
    local prov_path
    local digest=""
    local verify_out=""
    local sig_path=""
    local pubkey_path=""
    local extracted_root
    local keep_file
    local keep_target

    UPDATE_TMP_DIR="/tmp/route10-vpn-client-update"
    UPDATE_BACKUP_DIR=""
    archive_path="${UPDATE_TMP_DIR}/${asset_name}"
    sums_path="${UPDATE_TMP_DIR}/SHA256SUMS"
    prov_path="${UPDATE_TMP_DIR}/${asset_name}.intoto.jsonl"

    rm -rf "$UPDATE_TMP_DIR" "$backup_path"
    mkdir -p "$UPDATE_TMP_DIR"
    trap cleanup_trap EXIT

    # Fetch the attested release asset, not GitHub's auto-generated
    # /archive/refs/tags tarball (which is not covered by the provenance).
    log "Fetching release ${latest_tag} from ${release_url}"
    download "${release_url}/${asset_name}" "$archive_path" || {
        log "ERROR: download failed: ${asset_name}"
        return 1
    }
    download "${release_url}/SHA256SUMS" "$sums_path" || {
        log "ERROR: download failed: SHA256SUMS"
        return 1
    }

    if ! digest=$(update_verify_checksum "$archive_path" "$sums_path" "$asset_name"); then
        log "ERROR: checksum verification failed: ${digest}"
        return 1
    fi
    log "Checksum verified (sha256 ${digest})"

    if [ -n "$PINNED_SHA256" ]; then
        if [ "$PINNED_SHA256" != "$digest" ]; then
            log "ERROR: pinned digest mismatch (expected ${PINNED_SHA256}, got ${digest}); refusing update"
            return 1
        fi
        log "Pinned digest matched"
    fi

    # The release signature is the only check the repository cannot forge: the
    # signing key never exists in the repo. Deliberately not bypassable by
    # VPN_UPDATE_ALLOW_UNVERIFIED.
    sig_path="${UPDATE_TMP_DIR}/${asset_name}.sig"
    pubkey_path="${UPDATE_TMP_DIR}/release-pub.pem"
    if [ -n "${VPN_UPDATE_PUBKEY:-}" ]; then
        printf '%s\n' "$VPN_UPDATE_PUBKEY" > "$pubkey_path"
    elif [ -f "${REMOTE_DIR}/conf/release-pub.pem" ]; then
        pubkey_path="${REMOTE_DIR}/conf/release-pub.pem"
    fi
    # Fails closed either way; this only turns a bare "public key is missing"
    # into something an operator can act on, since project.conf is preserved
    # across updates and will not gain the key from a release.
    if [ ! -s "$pubkey_path" ]; then
        log "ERROR: no release public key configured; add VPN_UPDATE_PUBKEY to ${REMOTE_DIR}/project.conf (or install ${REMOTE_DIR}/conf/release-pub.pem) and retry: refusing update"
        return 1
    fi
    download "${release_url}/${asset_name}.sig" "$sig_path" || {
        log "ERROR: download failed: ${asset_name}.sig (release signature); refusing update"
        return 1
    }
    if ! verify_out=$(update_verify_signature "$archive_path" "$sig_path" "$pubkey_path"); then
        log "ERROR: release signature verification failed: ${verify_out}"
        return 1
    fi
    log "Release signature verified (${asset_name})"

    if [ "$ALLOW_UNVERIFIED" = "1" ]; then
        log "WARNING: VPN_UPDATE_ALLOW_UNVERIFIED=1; skipping provenance verification"
    else
        download "${release_url}/${asset_name}.intoto.jsonl" "$prov_path" || {
            log "ERROR: download failed: ${asset_name}.intoto.jsonl (provenance)"
            return 1
        }
        if ! verify_out=$(update_verify_provenance "$prov_path" "$asset_name" "$digest" "$GITHUB_REPO"); then
            log "ERROR: provenance verification failed: ${verify_out}"
            return 1
        fi
        log "Provenance verified for ${asset_name}"
    fi

    log "Extracting verified archive"
    if ! verify_out=$(update_safe_extract "$archive_path" "${UPDATE_TMP_DIR}/extract"); then
        log "ERROR: extraction refused: ${verify_out}"
        return 1
    fi

    extracted_root="${UPDATE_TMP_DIR}/extract/${REPO_NAME}-${latest_tag}"
    if [ ! -d "$extracted_root" ]; then
        log "ERROR: expected archive root ${REPO_NAME}-${latest_tag} not found"
        return 1
    fi
    if [ ! -f "${extracted_root}/setup.sh" ]; then
        log "ERROR: update payload has no setup.sh"
        return 1
    fi

    # Only back up once the artifact is known-good, so a bad download can never
    # trigger a rollback that rewrites the live tree.
    log "Creating backup at $backup_path"
    mkdir -p "$backup_path"
    if ! cp -rf "${REMOTE_DIR}/"* "$backup_path/"; then
        log "ERROR: backup failed; aborting before applying any change"
        return 1
    fi
    UPDATE_BACKUP_DIR="$backup_path"

    # Preserve local custom config before update apply.
    for keep_file in project.conf; do
        if [ -f "${REMOTE_DIR}/${keep_file}" ]; then
            keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
            mkdir -p "$(dirname "$keep_target")"
            cp -f "${REMOTE_DIR}/${keep_file}" "$keep_target"
        fi
    done
    if [ -d "${REMOTE_DIR}/conf" ]; then
        cp -rf "${REMOTE_DIR}/conf" "${UPDATE_TMP_DIR}/conf.keep"
    fi

    log "Applying update files to ${REMOTE_DIR}"
    cp -rf "${extracted_root}/"* "$REMOTE_DIR/"

    for keep_file in project.conf; do
        keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
        if [ -f "$keep_target" ]; then
            cp -f "$keep_target" "${REMOTE_DIR}/${keep_file}"
        fi
    done
    if [ -d "${UPDATE_TMP_DIR}/conf.keep" ]; then
        rm -rf "${REMOTE_DIR}/conf"
        cp -rf "${UPDATE_TMP_DIR}/conf.keep" "${REMOTE_DIR}/conf"
    fi

    ensure_project_script_permissions "$REMOTE_DIR"

    log "Running setup.sh in non-interactive mode"
    /bin/ash "${REMOTE_DIR}/setup.sh" --non-interactive || return 1

    # Refresh runtime firewall/routing scripts for already running interfaces.
    /bin/ash "${REMOTE_DIR}/wg.sh" reapply >/dev/null 2>&1 || true
    /bin/ash "${REMOTE_DIR}/ovpn.sh" reapply >/dev/null 2>&1 || true

    printf '%s\n' "$latest_tag" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
    set_uci_installed_version "$latest_tag"
    UPDATE_SUCCESS=1
    log "Update to ${latest_tag} completed successfully (sha256 ${digest})."
    return 0
}

# Auto-update is only as good as the cron entry that runs it, and a missing
# entry fails silently: the device just never checks again.
warn_if_auto_update_unscheduled() {
    [ "${VPN_ENABLE_AUTO_UPDATE:-1}" = "1" ] || return 0
    cron_file="${CRON_FILE:-/etc/crontabs/root}"
    if [ ! -f "$cron_file" ] || ! grep -qF "${REMOTE_DIR}/scripts/updater.sh check" "$cron_file" 2>/dev/null; then
        log "WARNING: auto-update is enabled but no cron entry runs ${REMOTE_DIR}/scripts/updater.sh; run setup.sh --non-interactive to install it"
    fi
}

check_and_update() {
    local force="${1:-0}"
    local local_version
    local latest_tag

    warn_if_auto_update_unscheduled
    local_version="$(get_local_version)"
    reconcile_version_parity "$local_version"
    local_version="$PARITY_VERSION"
    latest_tag="$(get_latest_version_tag)" || {
        log "ERROR: Unable to fetch latest release tag."
        return 1
    }

    if version_gt "$latest_tag" "$local_version" || [ "$force" = "1" ]; then
        [ "$force" = "1" ] && log "Force update requested." || log "New release available (${local_version} -> ${latest_tag})."
        perform_update "$latest_tag"
    else
        log "No updates found."
    fi
}

cmd="${1:-check}"
case "$cmd" in
    check) check_and_update 0 ;;
    force) check_and_update 1 ;;
    *)
        echo "Usage: $0 {check|force}"
        exit 1
        ;;
esac

} # End buffered block
