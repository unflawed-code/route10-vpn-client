#!/bin/sh
# Route10 PBR Library - Main Orchestrator
# Provides high-level PBR functions for VPN clients (WireGuard, OpenVPN)

# Source library modules (uses LIB_DIR defined by vpn-core.sh)
ROUTING_DIR="${LIB_DIR:-$(dirname "$0")}/routing"
COMMON_LIB="${LIB_DIR:-$(dirname "$0")}/common.sh"

# Source common utilities
[ -f "$COMMON_LIB" ] && . "$COMMON_LIB"

. "$ROUTING_DIR/ip-routing.sh"
. "$ROUTING_DIR/dns-routing.sh"

# === HIGH-LEVEL PBR FUNCTIONS ===

# Full PBR setup for a VPN interface
# Args: $1=interface, $2=routing_table, $3=target_ips (space-sep),
#       $4=vpn_dns (space-sep), $5=ipv6_supported (0/1),
#       $6=ipv6_mode (nat66|routed-prefix|disabled),
#       $7=ipv6_routed_prefix, $8=ipv6_downstream_iface
pbr_setup() {
    local interface="$1"
    local table="$2"
    local targets="$3"
    local vpn_dns="$4"
    local ipv6="${5:-0}"
    local ipv6_mode="${6:-nat66}"
    local ipv6_routed_prefix="${7:-}"
    local ipv6_downstream_iface="${8:-}"
    
    local ipset_name="vpn_${interface}"
    local mark=$(calculate_mark "$table")
    
    # Setup IP routing
    setup_ip_routing "$interface" "$table" "$targets" "$ipv6" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface"
    
    # Setup DNS routing
    setup_secure_dns "$interface" "$vpn_dns" "$targets" "$ipset_name" "$mark" "$ipv6"
    
    echo "PBR setup complete for $interface (table=$table, mark=$mark)"
}

# Full PBR teardown for a VPN interface
# Args: $1=interface, $2=routing_table, $3=target_ips (space-sep), $4=ipv6 (0/1)
pbr_teardown() {
    local interface="$1"
    local table="$2"
    local targets="$3"
    local ipv6="${4:-0}"
    
    local ipset_name="vpn_${interface}"
    local mark=$(calculate_mark "$table")
    
    # Cleanup DNS routing
    cleanup_secure_dns "$interface" "$ipset_name" "$mark" "$ipv6"
    
    # Cleanup IP routing
    cleanup_ip_routing "$interface" "$table" "$targets"
    
    # Cleanup NAT66
    cleanup_nat66 "$interface"
    
    echo "PBR teardown complete for $interface"
}

# Add a client to VPN routing
# Args: $1=interface, $2=routing_table, $3=client_ip_or_mac, $4=vpn_dns, $5=ipv6 (0/1)
pbr_add_client() {
    local interface="$1"
    local table="$2"
    local client="$3"
    local vpn_dns="$4"
    local ipv6="${5:-0}"
    
    local ipset_name="vpn_${interface}"
    local ipset_v6="vpn6_${interface}"
    local table_name="${interface}_rt"
    local mark=$(calculate_mark "$table")
    
    # Resolve MAC to IP if needed
    local client_ip="$client"
    local client_mac=""
    local client_lan_if=""
    if is_mac "$client"; then
        client_mac=$(normalize_mac "$client")
        client_ip=$(resolve_mac_to_ip "$client_mac")
        [ -z "$client_ip" ] && return 1
    else
        client_mac=$(discover_mac_for_ip "$client" || true)
    fi

    # Determine ingress LAN interface for this client. Interface-scoped MAC rules
    # avoid cross-VLAN leakage when the same client MAC appears elsewhere.
    client_lan_if=$(ip -4 route get "$client_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$client_lan_if" ] && client_lan_if=$(ip neigh show "$client_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$client_lan_if" ] && client_lan_if=$(ip -6 route get "$client_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    
    # Add to ipset
    case "$client_ip" in
        *:*) add_to_ipset "$ipset_v6" "$client_ip" ;;
        *)   
            add_to_ipset "$ipset_name" "$client_ip" 
            
            # Dual-Stack Discovery
            if [ "$ipv6" = "1" ]; then
                # We need to source ip-routing if not already (it is sourced at top of pbr.sh)
                local discovered_ipv6=$(resolve_ipv6_from_ipv4_target "$client_ip")
                for ip6 in $discovered_ipv6; do
                    add_to_ipset "$ipset_v6" "$ip6"
                done
            fi
            ;;
    esac
    
    # Proactive Ping to populate ARP/NDP tables (important for IPv6 discovery)
    (ping -c 1 -W 1 "$client_ip" >/dev/null 2>&1 &)

    # Add source rule
    add_source_rule "$client_ip" "$table" "$table"
    
    # Update DNS DNAT
    if [ -n "$vpn_dns" ]; then
        local nat_chain="vpn_dns_nat_${interface}"
        local dns_v4=$(echo "$vpn_dns" | tr ' ' '\n' | grep -v ':' | head -1)
        if [ -n "$dns_v4" ] && ! echo "$client_ip" | grep -q ':'; then
            iptables -w -t nat -C "$nat_chain" -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "$dns_v4" 2>/dev/null || {
                iptables -w -t nat -A "$nat_chain" -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "$dns_v4"
                iptables -w -t nat -A "$nat_chain" -s "$client_ip" -p tcp --dport 53 -j DNAT --to-destination "$dns_v4"
            }
        fi
        local dns_v6=$(echo "$vpn_dns" | tr ' ' '\n' | grep ':' | head -1)
        if [ -n "$dns_v6" ] && echo "$client_ip" | grep -q ':'; then
            local nat_chain_v6="vpn_dns_nat6_${interface}"
            ip6tables -w -t nat -C "$nat_chain_v6" -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "$dns_v6" 2>/dev/null || {
                ip6tables -w -t nat -A "$nat_chain_v6" -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "$dns_v6"
                ip6tables -w -t nat -A "$nat_chain_v6" -s "$client_ip" -p tcp --dport 53 -j DNAT --to-destination "$dns_v6"
            }
        fi
    fi
    
    # Add IPv6 fwmark rule if we have a MAC
    if [ -n "$client_mac" ] && [ "$ipv6" = "1" ]; then
        local mark_chain="mark_${interface}"
        add_mac_mark_rule "$mark_chain" "$client_mac" "$mark" 1 "$client_lan_if"
        add_ipv6_block_rule "$interface" "$client_mac" "$mark" "$client_lan_if"
        add_ipv6_dns_block "$interface" "$client_mac" "$client_lan_if"
    elif [ -n "$client_mac" ] && [ "$ipv6" = "0" ]; then
        add_ipv4_only_block "$interface" "$client_mac" "$client_lan_if"
    fi
    
    echo "Added client $client_ip to $interface"
}

# Remove a client from VPN routing
# Args: $1=interface, $2=routing_table, $3=client_ip, $4=optional_mac
pbr_remove_client() {
    local interface="$1"
    local table="$2"
    local client_ip="$3"
    local mac_arg="$4"
    
    local ipset_name="vpn_${interface}"
    local ipset_v6="vpn6_${interface}"
    local table_name="${interface}_rt"
    local mark=$(calculate_mark "$table")
    
    # Remove from ipset
    case "$client_ip" in
        *:*) del_from_ipset "$ipset_v6" "$client_ip" ;;
        *)   del_from_ipset "$ipset_name" "$client_ip" ;;
    esac
    
    # Remove source rule
    del_source_rule "$client_ip" "$table"
    
    # Remove DNS DNAT rules
    local nat_chain="vpn_dns_nat_${interface}"
    while iptables -w -t nat -L "$nat_chain" --line-numbers -n 2>/dev/null | grep -q "${client_ip}"; do
        local line=$(iptables -w -t nat -L "$nat_chain" --line-numbers -n | grep "${client_ip}" | head -1 | awk '{print $1}')
        [ -n "$line" ] && iptables -w -t nat -D "$nat_chain" "$line" 2>/dev/null || break
    done
    
    # Remove DNS block rules (IPv4)
    local dns_block_chain="vpn_dns_block_${interface}"
    local dns_filter_chain="vpn_dns_filter_${interface}"
    
    iptables -w -D "$dns_block_chain" -s "$client_ip" -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    iptables -w -D "$dns_block_chain" -s "$client_ip" -p tcp --dport 53 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    
    iptables -w -D "$dns_filter_chain" -s "$client_ip" -p udp --dport 853 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    iptables -w -D "$dns_filter_chain" -s "$client_ip" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null || true

    # Clean up DoH block rules by IP (port 443 with string matching)
    if [ -f /etc/config/https-dns-proxy ]; then
        local domains=$(grep 'resolver_url' /etc/config/https-dns-proxy 2>/dev/null | awk -F'/' '{print $3}')
        for domain in $domains; do
            iptables -w -D "$dns_filter_chain" -s "$client_ip" -p tcp --dport 443 -m string --algo bm --string "$domain" -j REJECT --reject-with tcp-reset 2>/dev/null || true
            iptables -w -D "$dns_filter_chain" -s "$client_ip" -p udp --dport 443 -m string --algo bm --string "$domain" -j REJECT --reject-with tcp-reset 2>/dev/null || true
        done
    fi

    # Discover MAC and cleanup firewall rules (use provided MAC if available)
    local mac="$mac_arg"
    [ -z "$mac" ] && mac=$(discover_mac_for_ip "$client_ip" || true)
    
    if [ -n "$mac" ]; then
        if type normalize_mac >/dev/null 2>&1; then
            mac=$(normalize_mac "$mac" 2>/dev/null || echo "$mac" | tr 'A-F' 'a-f')
        else
            mac=$(echo "$mac" | tr 'A-F' 'a-f')
        fi
        local mark_chain="mark_${interface}"
        local block_chain="${interface}_ipv6_block"
        local ipv4_only_chain="${interface}_ipv4_only_block"
        local dns_chain="${interface}_v6_dns_in"
        local mac_key
        mac_key=$(echo "$mac" | tr -d ':')
        local token_file="${VPN_TMP_DIR}/discover_${interface}_${mac_key}.token"
        local lan_ifaces
        lan_ifaces=$(get_lan_ifaces)

        # Stop any in-flight IPv6 discovery worker for this client/interface.
        rm -f "$token_file" 2>/dev/null || true
        
        # Remove fwmark rule(s) - loop for resilience against duplicates.
        while ip6tables -w -t mangle -D "$mark_chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
        while ip6tables -w -t mangle -D "$mark_chain" -m mac --mac-source "$mac" -j MARK --set-xmark $(printf "0x%x" $mark)/0xffffffff 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -t mangle -D "$mark_chain" -i "$lan_if" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
            while ip6tables -w -t mangle -D "$mark_chain" -i "$lan_if" -m mac --mac-source "$mac" -j MARK --set-xmark $(printf "0x%x" $mark)/0xffffffff 2>/dev/null; do :; done
        done
        
        # Remove block rules
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$block_chain" -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP 2>/dev/null; do :; done
        done
        
        while ip6tables -w -D "$ipv4_only_chain" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$ipv4_only_chain" -i "$lan_if" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do :; done
        done
        
        # Remove DNS block
        while ip6tables -w -D "$dns_chain" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null; do :; done
        while ip6tables -w -D "$dns_chain" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$dns_chain" -i "$lan_if" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null; do :; done
            while ip6tables -w -D "$dns_chain" -i "$lan_if" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null; do :; done
        done
        
        # Cleanup dynamic IPv6 discovery rules
        local state_file="$VPN_TMP_DIR/prefix_${interface}_${mac_key}"
        if [ -f "$state_file" ]; then
            while read -r rule; do
                if [ -n "$rule" ]; then
                    while ip -6 rule del from "$rule" lookup "$table" 2>/dev/null; do :; done
                fi
            done < "$state_file"
            rm -f "$state_file"
        fi
    fi
    
    echo "Removed client $client_ip from $interface"
}

# Hot-reload: Update targets without full restart
# Args: $1=interface, $2=new_targets (comma-sep), $3=routing_table, $4=vpn_dns
pbr_hot_reload() {
    local interface="$1"
    local new_targets="$2"
    local table="$3"
    local vpn_dns="$4"
    
    local ipset_name="vpn_${interface}"
    local ipset_v6="vpn6_${interface}"
    local table_name="${interface}_rt"
    
    # Get current targets from ipset
    local old_targets=$(ipset list "$ipset_name" 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')
    
    # Convert new targets to space-separated
    local new_list=$(echo "$new_targets" | tr ',' ' ')
    
    # Remove stale IPs
    for old_ip in $old_targets; do
        local still_exists=0
        for new_ip in $new_list; do
            local actual_ip=$(get_ip_from_target "$new_ip")
            [ "$old_ip" = "$actual_ip" ] && still_exists=1 && break
        done
        [ "$still_exists" = "0" ] && pbr_remove_client "$interface" "$table" "$old_ip"
    done
    
    # Add new IPs
    for new_ip in $new_list; do
        local actual_ip=$(get_ip_from_target "$new_ip")
        case "$actual_ip" in
            *:*) ;; # Skip IPv6 for now
            *)
                if ! ipset test "$ipset_name" "$actual_ip" 2>/dev/null; then
                    pbr_add_client "$interface" "$table" "$actual_ip" "$vpn_dns" 0
                fi
                ;;
        esac
    done
    
    echo "Hot-reload complete for $interface"
}

# Show library version
pbr_version() {
    echo "Route10 PBR Library $PBR_VERSION"
}

# === UTILITY EXPORTS ===
# These are re-exported from sub-modules for convenience

# From ip-routing.sh
# calculate_mark, allocate_routing_table, setup_ip_routing, cleanup_ip_routing

# From dns-routing.sh
# setup_secure_dns, cleanup_secure_dns

# From common.sh
# get_ip_from_target, is_mac, normalize_mac, discover_mac_for_ip, get_lan_ifaces
