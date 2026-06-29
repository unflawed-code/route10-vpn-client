#!/bin/sh
# Route10 Master DHCP Hotplug Handler
# This script is deployed to /etc/hotplug.d/dhcp/99-r10-master-pbr

# Required action check
[ "$ACTION" = "add" ] || [ "$ACTION" = "new" ] || [ "$ACTION" = "old" ] || [ "$ACTION" = "update" ] || exit 0

# Set environment
VPN_CORE_LIB="VPN_CORE_LIB_PLACEHOLDER"
VPN_TMP_DIR="VPN_TMP_DIR_PLACEHOLDER"
LOCK_FILE="${VPN_TMP_DIR}/dhcp_hotplug.lock"
mkdir -p "$VPN_TMP_DIR" 2>/dev/null || true
exec 200>"$LOCK_FILE"
flock -x 200 || exit 1

# Storm guard:
# - drops duplicate events in a very short interval
# - opens a cooldown window when event rate exceeds burst threshold
GUARD_STATE="${VPN_TMP_DIR}/dhcp_hotplug.guard"
GUARD_LAST="${VPN_TMP_DIR}/dhcp_hotplug.last"
NOW=$(date +%s 2>/dev/null)
[ -n "$NOW" ] || NOW=0
WINDOW=15
BURST=120
COOLDOWN=30
DEDUP=2
EVENT_KEY="${ACTION}|${MACADDR}|${IPADDR}"

WIN_START=0
COUNT=0
SUPPRESS_UNTIL=0
if [ -f "$GUARD_STATE" ]; then
    IFS='|' read -r WIN_START COUNT SUPPRESS_UNTIL < "$GUARD_STATE"
fi
case "$WIN_START" in ''|*[!0-9]*) WIN_START=0 ;; esac
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
case "$SUPPRESS_UNTIL" in ''|*[!0-9]*) SUPPRESS_UNTIL=0 ;; esac

if [ "$SUPPRESS_UNTIL" -gt "$NOW" ]; then
    logger -t vpn-dhcp-handler "Storm guard active; dropping DHCP event $EVENT_KEY"
    flock -u 200
    exit 0
fi

if [ -f "$GUARD_LAST" ]; then
    IFS='|' read -r LAST_TS LAST_KEY < "$GUARD_LAST"
    case "$LAST_TS" in ''|*[!0-9]*) LAST_TS=0 ;; esac
    if [ "$LAST_KEY" = "$EVENT_KEY" ] && [ $((NOW - LAST_TS)) -lt "$DEDUP" ]; then
        flock -u 200
        exit 0
    fi
fi
printf "%s|%s\n" "$NOW" "$EVENT_KEY" > "$GUARD_LAST"

if [ "$WIN_START" -eq 0 ] || [ $((NOW - WIN_START)) -ge "$WINDOW" ]; then
    WIN_START="$NOW"
    COUNT=1
else
    COUNT=$((COUNT + 1))
fi

if [ "$COUNT" -gt "$BURST" ]; then
    SUPPRESS_UNTIL=$((NOW + COOLDOWN))
    printf "%s|%s|%s\n" "$WIN_START" "$COUNT" "$SUPPRESS_UNTIL" > "$GUARD_STATE"
    logger -t vpn-dhcp-handler "Storm guard tripped (count=$COUNT window=${WINDOW}s); cooling down ${COOLDOWN}s"
    flock -u 200
    exit 0
fi

printf "%s|%s|0\n" "$WIN_START" "$COUNT" > "$GUARD_STATE"

if [ -f "$VPN_CORE_LIB" ]; then
    . "$VPN_CORE_LIB"
    # Execute core DHCP handler logic
    vpn_core_handle_dhcp
else
    logger -t vpn-dhcp-handler "Error: vpn-core.sh not found at $VPN_CORE_LIB"
    flock -u 200
    exit 1
fi

flock -u 200
