#!/bin/sh
# Custom DHCP hook for Route10 VPN Client
# Directly sources vpn-core.sh for reliable DHCP handling

ACTION="$1"
MACADDR="$2"
IPADDR="$3"
HOSTNAME="$4"

export ACTION MACADDR IPADDR HOSTNAME

# Only process add/renew actions
[ "$ACTION" = "add" ] || [ "$ACTION" = "new" ] || [ "$ACTION" = "old" ] || [ "$ACTION" = "update" ] || exit 0

VPN_CORE_LIB="/cfg/vpn-custom/lib/vpn-core.sh"

if [ -f "$VPN_CORE_LIB" ]; then
    . "$VPN_CORE_LIB"
    vpn_core_handle_dhcp
else
    logger -t vpn-dhcp-handler "Error: vpn-core.sh not found at $VPN_CORE_LIB"
fi
