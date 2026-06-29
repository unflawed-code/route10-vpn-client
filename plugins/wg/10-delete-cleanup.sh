#!/bin/sh
# WireGuard-specific delete cleanup.
# Removes lingering anonymous peer sections for the deleted interface.

post_delete() {
    local iface="$1"
    local type="$2"

    [ "$type" = "wireguard" ] || return 0

    # Drain all anonymous peer sections for this interface type.
    local drain_count=0
    while uci -q delete "network.@wireguard_${iface}[0]" >/dev/null 2>&1; do
        drain_count=$((drain_count + 1))
        [ "$drain_count" -gt 128 ] && break
    done

    return 0
}
