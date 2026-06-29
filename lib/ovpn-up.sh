#!/bin/sh
# OpenVPN up/route-up hook to capture pushed DNS servers.

set -e

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
VPN_CORE_LIB="$SCRIPT_DIR/vpn-core.sh"
[ -f "$VPN_CORE_LIB" ] && . "$VPN_CORE_LIB"

iface="${dev:-${1:-}}"
[ -z "$iface" ] && exit 0

dns_list=""
i=1
while :; do
    eval "opt=\${foreign_option_${i}:-}"
    [ -z "$opt" ] && break
    case "$opt" in
        *"dhcp-option DNS "*)
            dns="${opt#*dhcp-option DNS }"
            dns_list="$dns_list $dns"
            ;;
    esac
    i=$((i + 1))
done

dns_list=$(echo "$dns_list" | tr ',' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -z "$dns_list" ] && exit 0

current_dns=$(db_get_field "$iface" "dns_servers" 2>/dev/null || true)
if [ "$current_dns" = "$dns_list" ]; then
    exit 0
fi

db_set_dns_servers "$iface" "$dns_list"

# Re-apply PBR/DNS rules for this interface using current DB state.
table=$(db_get_field "$iface" "routing_table" 2>/dev/null || true)
targets=$(db_get_field "$iface" "target_ips" 2>/dev/null || true)
ipv6=$(db_get_field "$iface" "ipv6_support" 2>/dev/null || true)
ipv6_mode=$(db_get_field "$iface" "ipv6_mode" 2>/dev/null || true)
ipv6_routed_prefix=$(db_get_field "$iface" "ipv6_routed_prefix" 2>/dev/null || true)
ipv6_downstream_iface=$(db_get_field "$iface" "ipv6_downstream_iface" 2>/dev/null || true)
if [ -n "$table" ] && [ -n "$targets" ]; then
    pbr_setup "$iface" "$table" "$targets" "$dns_list" "${ipv6:-0}" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" 2>/dev/null || true
fi

exit 0
