#!/bin/sh
# Route10 PBR Library - DNS Routing Engine
# Handles DNS DNAT, DoT/DoH blocking, and DNS leak prevention
# Note: common.sh functions are provided by pbr.sh

# === DNS DNAT (Redirect to VPN DNS) ===

# Setup DNS DNAT for an interface
# Args: $1=interface, $2=vpn_dns_servers (space-sep), $3=target_ips (space-sep), $4=ipv6 (0/1)
setup_dns_dnat() {
    local interface="$1"
    local vpn_dns="$2"
    local targets="$3"
    local ipv6="${4:-0}"
    
    local nat_chain="vpn_dns_nat_${interface}"
    local nat_chain_v6="vpn_dns_nat6_${interface}"
    
    # Separate IPv4 and IPv6 DNS servers
    local dns_v4="" dns_v6=""
    for dns in $(echo "$vpn_dns" | tr ',' ' '); do
        case "$dns" in
            *:*) dns_v6="$dns_v6 $dns" ;;
            *.*) dns_v4="$dns_v4 $dns" ;;
        esac
    done
    dns_v4=$(echo "$dns_v4" | sed 's/^[[:space:]]*//')
    dns_v6=$(echo "$dns_v6" | sed 's/^[[:space:]]*//')
    
    # Cleanup old rules
    cleanup_dns_dnat "$interface"
    
    # Create chains
    iptables -w -t nat -N "$nat_chain" 2>/dev/null
    [ "$ipv6" = "1" ] && ip6tables -w -t nat -N "$nat_chain_v6" 2>/dev/null
    
    # IPv4 DNAT rules
    if [ -n "$dns_v4" ]; then
        local targets_v4=""
        for target in $(echo "$targets" | tr ',' ' '); do
            local actual_ip=$(get_ip_from_target "$target")
            case "$actual_ip" in
                *:*) ;; # Skip IPv6
                *) targets_v4="$targets_v4 $actual_ip" ;;
            esac
        done
        
        local dns_count=$(echo $dns_v4 | wc -w)
        for item in $targets_v4; do
            if [ "$dns_count" -eq 1 ]; then
                iptables -w -t nat -A "$nat_chain" -s "$item" -p udp --dport 53 -j DNAT --to-destination $dns_v4
                iptables -w -t nat -A "$nat_chain" -s "$item" -p tcp --dport 53 -j DNAT --to-destination $dns_v4
            else
                local i=0
                for dns in $dns_v4; do
                    iptables -w -t nat -A "$nat_chain" -s "$item" -p udp --dport 53 \
                        -m statistic --mode nth --every $((dns_count - i)) --packet 0 \
                        -j DNAT --to-destination "$dns"
                    iptables -w -t nat -A "$nat_chain" -s "$item" -p tcp --dport 53 \
                        -m statistic --mode nth --every $((dns_count - i)) --packet 0 \
                        -j DNAT --to-destination "$dns"
                    i=$((i + 1))
                done
            fi
        done
        
        # Hook into PREROUTING
        iptables -w -t nat -C PREROUTING -j "$nat_chain" 2>/dev/null || \
            iptables -w -t nat -I PREROUTING 1 -j "$nat_chain"
    fi
    
    # IPv6 DNAT rules
    if [ -n "$dns_v6" ] && [ "$ipv6" = "1" ]; then
        local targets_v6=""
        for target in $(echo "$targets" | tr ',' ' '); do
            local actual_ip=$(get_ip_from_target "$target")
            case "$actual_ip" in
                *:*) targets_v6="$targets_v6 $actual_ip" ;;
            esac
        done
        
        local dns_count=$(echo $dns_v6 | wc -w)
        for item in $targets_v6; do
            if [ "$dns_count" -eq 1 ]; then
                ip6tables -w -t nat -A "$nat_chain_v6" -s "$item" -p udp --dport 53 -j DNAT --to-destination "$dns_v6"
                ip6tables -w -t nat -A "$nat_chain_v6" -s "$item" -p tcp --dport 53 -j DNAT --to-destination "$dns_v6"
            else
                local i=0
                for dns in $dns_v6; do
                    ip6tables -w -t nat -A "$nat_chain_v6" -s "$item" -p udp --dport 53 \
                        -m statistic --mode nth --every $((dns_count - i)) --packet 0 \
                        -j DNAT --to-destination "[$dns]"
                    ip6tables -w -t nat -A "$nat_chain_v6" -s "$item" -p tcp --dport 53 \
                        -m statistic --mode nth --every $((dns_count - i)) --packet 0 \
                        -j DNAT --to-destination "[$dns]"
                    i=$((i + 1))
                done
            fi
        done
        
        # Hook into PREROUTING
        ip6tables -w -t nat -C PREROUTING -j "$nat_chain_v6" 2>/dev/null || \
            ip6tables -w -t nat -I PREROUTING 1 -j "$nat_chain_v6"
    fi
}

# Cleanup DNS DNAT for an interface
# Args: $1=interface
cleanup_dns_dnat() {
    local interface="$1"
    local nat_chain="vpn_dns_nat_${interface}"
    local nat_chain_v6="vpn_dns_nat6_${interface}"
    
    # IPv4
    iptables -w -t nat -D PREROUTING -j "$nat_chain" 2>/dev/null
    iptables -w -t nat -F "$nat_chain" 2>/dev/null
    iptables -w -t nat -X "$nat_chain" 2>/dev/null
    
    # IPv6
    ip6tables -w -t nat -D PREROUTING -j "$nat_chain_v6" 2>/dev/null
    ip6tables -w -t nat -F "$nat_chain_v6" 2>/dev/null
    ip6tables -w -t nat -X "$nat_chain_v6" 2>/dev/null
}

# === DoT BLOCKING (Port 853) ===

# Block DNS over TLS for target IPs
# Args: $1=interface, $2=target_ips (space-sep), $3=ipv6 (0/1)
block_dot() {
    local interface="$1"
    local targets="$2"
    local ipv6="${3:-0}"
    
    local chain="vpn_dns_filter_${interface}"
    local chain_v6="vpn_dns_filter6_${interface}"
    
    # Create chains
    iptables -w -N "$chain" 2>/dev/null || iptables -w -F "$chain"
    [ "$ipv6" = "1" ] && (ip6tables -w -N "$chain_v6" 2>/dev/null || ip6tables -w -F "$chain_v6")
    
    for target in $targets; do
        local actual_ip=$(get_ip_from_target "$target")
        case "$actual_ip" in
            *:*)
                [ "$ipv6" = "1" ] && {
                    ip6tables -w -A "$chain_v6" -s "$actual_ip" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
                    ip6tables -w -A "$chain_v6" -s "$actual_ip" -p udp --dport 853 -j REJECT --reject-with icmp6-port-unreachable
                }
                ;;
            *)
                iptables -w -A "$chain" -s "$actual_ip" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
                iptables -w -A "$chain" -s "$actual_ip" -p udp --dport 853 -j REJECT --reject-with icmp-port-unreachable
                ;;
        esac
    done
    
    # Hook into FORWARD
    iptables -w -C FORWARD -j "$chain" 2>/dev/null || iptables -w -I FORWARD 1 -j "$chain"
    [ "$ipv6" = "1" ] && {
        ip6tables -w -C FORWARD -j "$chain_v6" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$chain_v6"
    }
}

# Remove DoT blocking for interface
# Args: $1=interface
unblock_dot() {
    local interface="$1"
    local chain="vpn_dns_filter_${interface}"
    local chain_v6="vpn_dns_filter6_${interface}"
    
    iptables -w -D FORWARD -j "$chain" 2>/dev/null
    iptables -w -F "$chain" 2>/dev/null
    iptables -w -X "$chain" 2>/dev/null
    
    ip6tables -w -D FORWARD -j "$chain_v6" 2>/dev/null
    ip6tables -w -F "$chain_v6" 2>/dev/null
    ip6tables -w -X "$chain_v6" 2>/dev/null
}

# === DoH BLOCKING (HTTPS DNS Providers) ===

# Block DNS over HTTPS providers (reads from https-dns-proxy config)
# Args: $1=chain, $2=source_ip (optional), $3=ipt_cmd (iptables -w/ip6tables -w)
_block_doh_providers() {
    local chain="$1"
    local src="${2:-}"
    local ipt_cmd="${3:-iptables -w}"
    
    [ -f /etc/config/https-dns-proxy ] || return 0
    
    local domains=$(grep 'resolver_url' /etc/config/https-dns-proxy 2>/dev/null | awk -F'/' '{print $3}')
    for domain in $domains; do
        local src_opt=""
        [ -n "$src" ] && src_opt="-s $src"
        $ipt_cmd -A "$chain" $src_opt -p tcp --dport 443 -m string --algo bm --string "$domain" -j REJECT --reject-with tcp-reset
    done
}

# Block DoH for target IPs
# Args: $1=interface, $2=target_ips (space-sep), $3=ipv6 (0/1)
block_doh() {
    local interface="$1"
    local targets="$2"
    local ipv6="${3:-0}"
    
    local chain="vpn_dns_filter_${interface}"
    local chain_v6="vpn_dns_filter6_${interface}"
    
    for target in $targets; do
        local actual_ip=$(get_ip_from_target "$target")
        case "$actual_ip" in
            *:*)
                [ "$ipv6" = "1" ] && _block_doh_providers "$chain_v6" "$actual_ip" "ip6tables -w"
                ;;
            *)
                _block_doh_providers "$chain" "$actual_ip" "iptables -w"
                ;;
        esac
    done
}

# === LOCAL DNS BLOCKING (INPUT Chain) ===

# Block VPN clients from accessing router's local DNS
# Args: $1=interface, $2=target_ips (space-sep), $3=ipv6 (0/1)
block_local_dns() {
    local interface="$1"
    local targets="$2"
    local ipv6="${3:-0}"
    
    local chain="vpn_dns_block_${interface}"
    local chain_v6="vpn_dns_block6_${interface}"
    
    # Create chains
    iptables -w -N "$chain" 2>/dev/null || iptables -w -F "$chain"
    iptables -w -C INPUT -j "$chain" 2>/dev/null || iptables -w -I INPUT 1 -j "$chain"
    
    [ "$ipv6" = "1" ] && {
        ip6tables -w -N "$chain_v6" 2>/dev/null || ip6tables -w -F "$chain_v6"
        ip6tables -w -C INPUT -j "$chain_v6" 2>/dev/null || ip6tables -w -I INPUT 1 -j "$chain_v6"
    }
    
    for target in $targets; do
        local actual_ip=$(get_ip_from_target "$target")
        case "$actual_ip" in
            *:*)
                [ "$ipv6" = "1" ] && {
                    ip6tables -w -A "$chain_v6" -s "$actual_ip" -p udp --dport 53 -j REJECT --reject-with icmp6-port-unreachable
                    ip6tables -w -A "$chain_v6" -s "$actual_ip" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
                }
                ;;
            *)
                iptables -w -A "$chain" -s "$actual_ip" -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
                iptables -w -A "$chain" -s "$actual_ip" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
                ;;
        esac
    done
}

# Remove local DNS blocking for interface
# Args: $1=interface
unblock_local_dns() {
    local interface="$1"
    local chain="vpn_dns_block_${interface}"
    local chain_v6="vpn_dns_block6_${interface}"
    
    iptables -w -D INPUT -j "$chain" 2>/dev/null
    iptables -w -F "$chain" 2>/dev/null
    iptables -w -X "$chain" 2>/dev/null
    
    ip6tables -w -D INPUT -j "$chain_v6" 2>/dev/null
    ip6tables -w -F "$chain_v6" 2>/dev/null
    ip6tables -w -X "$chain_v6" 2>/dev/null
}

# === WAN DNS RESPONSE BLOCKING (OUTPUT Chain) ===

# Block WAN DNS responses to VPN clients
# Args: $1=interface, $2=ipset_name, $3=mark_value, $4=ipv6 (0/1)
block_wan_dns_responses() {
    local interface="$1"
    local ipset_name="$2"
    local mark="$3"
    local ipv6="${4:-0}"
    
    # Remove old rules first
    iptables -w -t mangle -D OUTPUT -p udp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
    iptables -w -t mangle -D OUTPUT -p tcp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
    
    # Add new rules
    iptables -w -t mangle -I OUTPUT 1 -p udp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP
    iptables -w -t mangle -I OUTPUT 1 -p tcp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP
    
    if [ "$ipv6" = "1" ]; then
        local ipset_v6="vpn6_${interface}"
        ip6tables -w -t mangle -D OUTPUT -p udp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
        ip6tables -w -t mangle -D OUTPUT -p tcp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
        ip6tables -w -t mangle -I OUTPUT 1 -p udp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP
        ip6tables -w -t mangle -I OUTPUT 1 -p tcp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP
    fi
}

# Remove WAN DNS response blocking
# Args: $1=interface, $2=ipset_name, $3=mark_value, $4=ipv6 (0/1)
unblock_wan_dns_responses() {
    local interface="$1"
    local ipset_name="$2"
    local mark="$3"
    local ipv6="${4:-0}"
    
    iptables -w -t mangle -D OUTPUT -p udp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
    iptables -w -t mangle -D OUTPUT -p tcp --sport 53 -m set --match-set "$ipset_name" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
    
    if [ "$ipv6" = "1" ]; then
        local ipset_v6="vpn6_${interface}"
        ip6tables -w -t mangle -D OUTPUT -p udp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
        ip6tables -w -t mangle -D OUTPUT -p tcp --sport 53 -m set --match-set "$ipset_v6" dst -m mark ! --mark "$mark" -j DROP 2>/dev/null
    fi
}

# === IPv6 DNS INPUT BLOCKING (Per-Client MAC) ===

# Create IPv6 DNS input block chain
# Args: $1=interface
create_ipv6_dns_input_chain() {
    local interface="$1"
    local chain="${interface}_v6_dns_in"
    
    ip6tables -w -N "$chain" 2>/dev/null || ip6tables -w -F "$chain"
    ip6tables -w -C INPUT -j "$chain" 2>/dev/null || ip6tables -w -I INPUT 1 -j "$chain"
}

# Block IPv6 DNS for a specific MAC
# Args: $1=interface, $2=mac, $3=in_iface(optional)
add_ipv6_dns_block() {
    local interface="$1"
    local mac="$2"
    local in_iface="${3:-}"
    local chain="${interface}_v6_dns_in"
    
    if [ -n "$in_iface" ]; then
        local lan_ifaces
        lan_ifaces=$(get_lan_ifaces)
        while ip6tables -w -D "$chain" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null; do :; done
        while ip6tables -w -D "$chain" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$chain" -i "$lan_if" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null; do :; done
            while ip6tables -w -D "$chain" -i "$lan_if" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null; do :; done
        done
        ip6tables -w -C "$chain" -i "$in_iface" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null || \
            ip6tables -w -A "$chain" -i "$in_iface" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT
        ip6tables -w -C "$chain" -i "$in_iface" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null || \
            ip6tables -w -A "$chain" -i "$in_iface" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT
    else
        ip6tables -w -C "$chain" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT 2>/dev/null || \
            ip6tables -w -A "$chain" -m mac --mac-source "$mac" -p udp --dport 53 -j REJECT
        ip6tables -w -C "$chain" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT 2>/dev/null || \
            ip6tables -w -A "$chain" -m mac --mac-source "$mac" -p tcp --dport 53 -j REJECT
    fi
}

# Cleanup IPv6 DNS input chain
# Args: $1=interface
cleanup_ipv6_dns_input_chain() {
    local interface="$1"
    local chain="${interface}_v6_dns_in"
    
    ip6tables -w -D INPUT -j "$chain" 2>/dev/null
    ip6tables -w -F "$chain" 2>/dev/null
    ip6tables -w -X "$chain" 2>/dev/null
}

# === HIGH-LEVEL SETUP FUNCTIONS ===

# Full secure DNS setup for an interface
# Args: $1=interface, $2=vpn_dns (space-sep), $3=targets (space-sep), 
#       $4=ipset_name, $5=mark, $6=ipv6 (0/1)
setup_secure_dns() {
    local interface="$1"
    local vpn_dns="$2"
    local targets="$3"
    local ipset_name="$4"
    local mark="$5"
    local ipv6="${6:-0}"
    
    [ -z "$vpn_dns" ] && return 0
    
    # 1. DNS DNAT
    setup_dns_dnat "$interface" "$vpn_dns" "$targets" "$ipv6"
    
    # 2. Block DoT
    block_dot "$interface" "$targets" "$ipv6"
    
    # 3. Block DoH
    block_doh "$interface" "$targets" "$ipv6"
    
    # 4. Block local DNS
    block_local_dns "$interface" "$targets" "$ipv6"
    
    # 5. Block WAN DNS responses
    block_wan_dns_responses "$interface" "$ipset_name" "$mark" "$ipv6"
    
    # 6. IPv6 DNS input chain
    [ "$ipv6" = "1" ] && create_ipv6_dns_input_chain "$interface"
}

# Full DNS cleanup for an interface
# Args: $1=interface, $2=ipset_name, $3=mark, $4=ipv6 (0/1)
cleanup_secure_dns() {
    local interface="$1"
    local ipset_name="$2"
    local mark="$3"
    local ipv6="${4:-0}"
    
    cleanup_dns_dnat "$interface"
    unblock_dot "$interface"
    unblock_local_dns "$interface"
    unblock_wan_dns_responses "$interface" "$ipset_name" "$mark" "$ipv6"
    [ "$ipv6" = "1" ] && cleanup_ipv6_dns_input_chain "$interface"
}
