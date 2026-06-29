#!/bin/sh
# ${VPN_PREFIX} VPN Library - IP Routing Engine
# Handles routing tables, ip rules, fwmarks, ipsets, and NAT66
# Note: common.sh functions are provided by pbr.sh

# === ROUTING TABLE MANAGEMENT ===

# Auto-allocate routing table from a given range
# Args: $1=interface_name (optional), $2=start (default VPN_RT_START), $3=end (default VPN_RT_END)
# Returns: allocated table number, or empty on failure
allocate_routing_table() {
    local iface="${1:-}"
    local start="${2:-${VPN_RT_START:-1000}}"
    local end="${3:-${VPN_RT_END:-1499}}"
    local rt_tables="/etc/iproute2/rt_tables"
    
    local used_tables=""
    if [ -f "$rt_tables" ]; then
        used_tables=$(awk '{print $1}' "$rt_tables" 2>/dev/null | grep -E '^[0-9]+$' | sort -n)
    fi
    
    local i=$start
    while [ $i -le $end ]; do
        if ! echo "$used_tables" | grep -qw "$i"; then
            # Check for fwmark collision before allocating using the proactive calculate_mark
            local mark=$(calculate_mark "$i")
            if [ $? -eq 0 ]; then
                # Safe mark acquired (or default was safe)
                echo "$i"
                return 0
            fi
        fi
        i=$((i + 1))
    done
    
    echo ""
    return 1
}

# Register routing table in /etc/iproute2/rt_tables
# Args: $1=table_number, $2=table_name
register_routing_table() {
    local table_num="$1"
    local table_name="$2"
    local rt_tables="/etc/iproute2/rt_tables"
    
    if ! grep -q "^${table_num}[[:space:]]*${table_name}" "$rt_tables" 2>/dev/null; then
        echo "$table_num $table_name" >> "$rt_tables"
    fi
}

# Unregister routing table from /etc/iproute2/rt_tables
# Args: $1=table_name
unregister_routing_table() {
    local table_name="$1"
    local rt_tables="${RT_TABLES_PATH:-/etc/iproute2/rt_tables}"
    
    [ -f "$rt_tables" ] && sed -i "/[[:space:]]${table_name}$/d" "$rt_tables"
}

# Check if a proposed fwmark would collide with existing mask-based rules
# Args: $1=proposed_mark, $2=ignore_table (ID or Name, optional)
# Returns: 0 if collision found (unsafe), 1 if no collision (safe)
check_fwmark_collision() {
    local proposed_mark="$1"
    local ignore_table="$2"
    
    # Portably find a temp directory
    local tmp_dir="/tmp"
    [ ! -d "$tmp_dir" ] && tmp_dir="/var/run"
    [ ! -d "$tmp_dir" ] && tmp_dir="."
    
    local tmp_rules="${tmp_dir}/rules.coll.$$.txt"
    ip rule show 2>/dev/null | grep "fwmark" | tr -d '\r' > "$tmp_rules"
    
    local collision_found=""
    while read -r line; do
        [ -z "$line" ] && continue
        
        # Extract mark/mask: find "fwmark", take next word
        local rule_part=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="fwmark") print $(i+1)}')
        [ -z "$rule_part" ] && continue
        
        # Extract table: find "lookup" or "table", take next word
        local table_part=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="lookup" || $i=="table") print $(i+1)}')

        # Resolve ignore_table to name if it's an ID
        local ignore_table_name=""
        case "$ignore_table" in
            [0-9]*) 
                # Try to find name for this table ID in /etc/iproute2/rt_tables
                ignore_table_name=$(grep -E "^$ignore_table[[:space:]]+" /etc/iproute2/rt_tables | awk '{print $2}')
                ;;
        esac

        # Skip if it belongs to the table we want to ignore (self-collision)
        local is_self=false
        if [ -n "$ignore_table" ] && [ -n "$table_part" ]; then
            if [ "$table_part" = "$ignore_table" ] || [ "$table_part" = "${ignore_table}_rt" ]; then
                is_self=true
            elif [ -n "$ignore_table_name" ] && [ "$table_part" = "$ignore_table_name" ]; then
                is_self=true
            fi
        fi

        if [ "$is_self" = "true" ]; then
            continue
        fi

        local mark_hex=$(echo "$rule_part" | cut -d'/' -f1)
        local mask_hex=$(echo "$rule_part" | cut -s -d'/' -f2)
        
        # Convert to decimal (default mask is 0xffffffff)
        local existing_mark=$((mark_hex))
        local mask=$(( ${mask_hex:-0xffffffff} ))
        
        # Check collision: (proposed & mask) == existing_mark
        if [ $((proposed_mark & mask)) -eq "$existing_mark" ]; then
            collision_found="$rule_part (table $table_part)"
            break
        fi
    done < "$tmp_rules"
    rm -f "$tmp_rules"
    
    if [ -n "$collision_found" ]; then
        echo "COLLISION:$collision_found"
        return 0
    fi
    
    return 1
}





# === HIGH-LEVEL SETUP FUNCTIONS ===

# Derive a manager-specific fwmark namespace base.
# This keeps marks isolated across different managers sharing the same router.
get_mark_namespace_base() {
    local configured="${VPN_MARK_BASE:-}"
    if [ -n "$configured" ]; then
        echo "$((configured))"
        return 0
    fi
    
    local prefix="${VPN_PREFIX:-vpnx1}"
    local checksum=""
    if command -v cksum >/dev/null 2>&1; then
        checksum=$(printf '%s' "$prefix" | cksum 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$checksum" ]; then
        # Busybox builds may not provide `cksum`. Use an awk-only fallback hash.
        checksum=$(awk -v s="$prefix" '
            BEGIN {
                chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
                h = 5381
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    p = index(chars, c)
                    if (p == 0) p = 1
                    h = ((h * 33) + p) % 2147483647
                }
                print h
            }')
    fi
    [ -z "$checksum" ] && checksum=1
    # Keep namespace in upper bits, leave low bits for table + retry offsets.
    local namespace=$(( ((checksum % 240) + 1) << 20 ))
    echo "$namespace"
}

# Calculate mark value from routing table
# Args: $1=routing_table
# Returns: non-colliding calculated mark, or best-effort fallback mark
calculate_mark() {
    local table="$1"
    local base_ns
    base_ns=$(get_mark_namespace_base)
    local base=$((base_ns + 0x10000))
    local offset=0
    local retry_count=0
    local max_retries=10
    local mark
    
    # 0. Sticky check: If this table already has a mark assigned, use it.
    # This ensures consistency between initial setup and DHCP hotplugs.
    local table_name_from_id=""
    [ -f /etc/iproute2/rt_tables ] && table_name_from_id=$(grep -E "^$table[[:space:]]+" /etc/iproute2/rt_tables | awk '{print $2}')
    
    local pattern="lookup ($table|${table}_rt"
    [ -n "$table_name_from_id" ] && pattern="$pattern|$table_name_from_id"
    pattern="$pattern)"
    
    local existing_rules=$(ip rule show 2>/dev/null | grep -E "$pattern")
    local existing_mark=$(echo "$existing_rules" | grep "fwmark" | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="fwmark") print $(i+1)}' | cut -d'/' -f1)
    
    if [ -n "$existing_mark" ]; then
        # Already have a mark for this table, return it (decimal)
        echo "$((existing_mark))"
        return 0
    fi
    
    # Try different marks by adding an offset if collision occurs
    while [ $retry_count -lt $max_retries ]; do
        mark=$((base + table + offset))
        
        # Note: we pass table ID to check_fwmark_collision
        local collision=$(check_fwmark_collision "$mark" "$table")
        if [ -z "$collision" ]; then
            # No collision found, this mark is safe to use
            [ $offset -gt 0 ] && echo "Acquired offset mark 0x$(printf '%x' $mark) for table $table to avoid collision" >&2
            echo "$mark"
            return 0
        fi
        
        # Collision found, increment offset and retry count
        # Using 0x1000 (4096) as a bit-shifted step
        offset=$((offset + 0x1000))
        retry_count=$((retry_count + 1))
    done
    
    # Failed to find a collision-free mark in retry window.
    # Return a deterministic fallback so callers never receive an empty mark.
    mark=$((base + table))
    echo "WARN: Failed to find safe fwmark for table $table after $max_retries attempts; using fallback 0x$(printf '%x' "$mark")." >&2
    echo "$mark"
    return 0
}



# === IP RULE MANAGEMENT ===


# Add source-based routing rule
# Args: $1=source (IP or CIDR), $2=table, $3=priority (optional)
add_source_rule() {
    local source="$1"
    local table="$2"
    local priority="${3:-$table}"
    
    ip rule add from "$source" table "$table" priority "$priority" 2>/dev/null
}

# Delete source-based routing rule
# Args: $1=source, $2=table
del_source_rule() {
    local source="$1"
    local table="$2"
    
    ip rule del from "$source" table "$table" 2>/dev/null
}

# Add fwmark-based routing rule
# Args: $1=mark, $2=table, $3=priority (optional), $4=ipv6 (0/1, default 0)
add_fwmark_rule() {
    local mark="$1"
    local table="$2"
    local priority="${3:-$((table - 5))}"
    local ipv6="${4:-0}"
    
    if [ "$ipv6" = "1" ]; then
        ip -6 rule del fwmark "$mark" table "$table" 2>/dev/null
        ip -6 rule add fwmark "$mark" table "$table" priority "$priority"
    else
        ip rule del fwmark "$mark" table "$table" 2>/dev/null
        ip rule add fwmark "$mark" table "$table" priority "$priority"
    fi
}

# Delete fwmark-based routing rule
# Args: $1=mark, $2=table, $3=ipv6 (0/1, default 0)
del_fwmark_rule() {
    local mark="$1"
    local table="$2"
    local ipv6="${3:-0}"
    
    if [ "$ipv6" = "1" ]; then
        ip -6 rule del fwmark "$mark" table "$table" 2>/dev/null
    else
        ip rule del fwmark "$mark" table "$table" 2>/dev/null
    fi
}

# === IPSET MANAGEMENT ===

# Create or flush an ipset
# Args: $1=set_name, $2=family (inet/inet6, default inet)
create_or_flush_ipset() {
    local set_name="$1"
    local family="${2:-inet}"
    
    if [ "$family" = "inet6" ]; then
        ipset create "$set_name" hash:net family inet6 2>/dev/null || ipset flush "$set_name"
    else
        ipset create "$set_name" hash:net 2>/dev/null || ipset flush "$set_name"
    fi
}

# Add entry to ipset
# Args: $1=set_name, $2=entry (IP or CIDR)
add_to_ipset() {
    local set_name="$1"
    local entry="$2"
    
    ipset add "$set_name" "$entry" 2>/dev/null
}

# Delete entry from ipset
# Args: $1=set_name, $2=entry
del_from_ipset() {
    local set_name="$1"
    local entry="$2"
    
    ipset del "$set_name" "$entry" 2>/dev/null
}

# Destroy an ipset entirely
# Args: $1=set_name
destroy_ipset() {
    local set_name="$1"
    
    ipset flush "$set_name" 2>/dev/null
    ipset destroy "$set_name" 2>/dev/null
}

# === DUAL-STACK DISCOVERY ===

# Resolve IPv6 addresses for an IPv4 target via MAC and Neighbor Table
# Args: $1=ipv4_address
# Returns: Space-separated list of IPv6 addresses (or empty)
resolve_ipv6_from_ipv4_target() {
    local ipv4="$1"
    
    # 1. Resolve MAC from IPv4
    local mac=$(ip neigh show "$ipv4" | awk '{print $5}' | head -1)
    
    # If not found in neighbor table, try arping/ping (though usually caller handles proactive ping)
    if [ -z "$mac" ]; then
        return 0
    fi
    
    # 2. Find IPv6 neighbors with this MAC
    # Filter for global unicast (exclude fe80:: link-local if desired, though link-local might be needed for some setups? 
    # Usually we only route GUA/ULA via VPN. Let's include everything valid except maybe multicast/special)
    # Actually, simpler: just grep the MAC in ip -6 neigh
    local ipv6_addrs=$(ip -6 neigh show | grep -i "$mac" | awk '{print $1}' | cut -d'/' -f1)
    
    # Return as space-separated list
    echo "$ipv6_addrs"
}

# Resolve LAN interface from target IP/Subnet
# Args: $1=ip_or_subnet
# Returns: device name (e.g. br-lan) or empty
resolve_dev_from_target() {
    local target="$1"
    # Use ip route to find the device associated with this target.
    # For a subnet, prefer "ip route show <cidr>" since "route get" expects a host.
    # For a host IP, "route get" is fine.
    if echo "$target" | grep -q '/'; then
        ip -4 route show "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
    else
        ip -4 route get "$target" 2>/dev/null | grep -o "dev [^ ]*" | head -1 | cut -d' ' -f2
    fi
}

# Ensure router-originated traffic from a LAN interface is not captured by VPN PBR.
# This prevents DNS replies and local services from being routed into the tunnel.
ensure_local_src_rule() {
    local lan_dev="$1"
    local prio="${2:-40}"
    [ -z "$lan_dev" ] && return 0
    local gw_ip
    gw_ip=$(ip -4 addr show dev "$lan_dev" 2>/dev/null | awk '/inet / {print $2}' | head -1 | cut -d'/' -f1)
    [ -z "$gw_ip" ] && return 0
    ip rule add from "${gw_ip}/32" lookup main priority "$prio" 2>/dev/null || true
}

# Block IPv6 on a LAN interface (Input/Forward)
# Args: $1=interface, $2=lan_if
block_ipv6_on_lan_interface() {
    local interface="$1"
    local lan_if="$2"
    local subnet="${3:-}"
    local chain="${interface}_ipv4_only_block"
    local src_opt=""
    if [ -n "$subnet" ] && echo "$subnet" | grep -q ':'; then
        src_opt="-s $subnet"
    fi
    
    # Chain is already attached to INPUT/FORWARD; just add scoped drops here.
    ip6tables -w -C "$chain" -i "$lan_if" $src_opt -j DROP 2>/dev/null || \
        ip6tables -w -A "$chain" -i "$lan_if" $src_opt -j DROP
}

# === FWMARK CHAIN MANAGEMENT ===

# Create a marking chain in mangle table
# Args: $1=chain_name, $2=ipv6 (0/1, default 0)
create_mark_chain() {
    local chain="$1"
    local ipv6="${2:-0}"
    
    if [ "$ipv6" = "1" ]; then
        ip6tables -w -t mangle -N "$chain" 2>/dev/null || ip6tables -w -t mangle -F "$chain"
    else
        iptables -w -t mangle -N "$chain" 2>/dev/null || iptables -w -t mangle -F "$chain"
    fi
}

# Add mark rule to chain (match ipset source, set mark)
# Args: $1=chain, $2=ipset_name, $3=mark_value, $4=ipv6 (0/1)
add_ipset_mark_rule() {
    local chain="$1"
    local ipset_name="$2"
    local mark="$3"
    local ipv6="${4:-0}"
    
    if [ "$ipv6" = "1" ]; then
        ip6tables -w -t mangle -A "$chain" -m set --match-set "$ipset_name" src -j MARK --set-mark "$mark"
    else
        iptables -w -t mangle -A "$chain" -m set --match-set "$ipset_name" src -j MARK --set-mark "$mark"
    fi
}

# Add MAC-based mark rule
# Args: $1=chain, $2=mac_address, $3=mark_value, $4=ipv6 (0/1), $5=in_iface(optional)
add_mac_mark_rule() {
    local chain="$1"
    local mac="$2"
    local mark="$3"
    local ipv6="${4:-0}"
    local in_iface="${5:-}"
    
    if [ "$ipv6" = "1" ]; then
        if [ -n "$in_iface" ]; then
            local lan_ifaces
            lan_ifaces=$(get_lan_ifaces)
            while ip6tables -w -t mangle -D "$chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
            for lan_if in $lan_ifaces; do
                while ip6tables -w -t mangle -D "$chain" -i "$lan_if" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
            done
            ip6tables -w -t mangle -C "$chain" -i "$in_iface" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || \
                ip6tables -w -t mangle -A "$chain" -i "$in_iface" -m mac --mac-source "$mac" -j MARK --set-mark "$mark"
        else
            ip6tables -w -t mangle -C "$chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || \
                ip6tables -w -t mangle -A "$chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark"
        fi
    else
        iptables -w -t mangle -C "$chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || \
            iptables -w -t mangle -A "$chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark"
    fi
}

# Attach chain to PREROUTING
# Args: $1=chain, $2=lan_interface, $3=ipv6 (0/1)
attach_chain_to_prerouting() {
    local chain="$1"
    local lan_if="$2"
    local ipv6="${3:-0}"
    
    if [ "$ipv6" = "1" ]; then
        ip6tables -w -t mangle -C PREROUTING -i "$lan_if" -j "$chain" 2>/dev/null || \
            ip6tables -w -t mangle -A PREROUTING -i "$lan_if" -j "$chain"
    else
        iptables -w -t mangle -C PREROUTING -i "$lan_if" -j "$chain" 2>/dev/null || \
            iptables -w -t mangle -A PREROUTING -i "$lan_if" -j "$chain"
    fi
}

# Cleanup marking chain
# Args: $1=chain, $2=ipv6 (0/1)
cleanup_mark_chain() {
    local chain="$1"
    local ipv6="${2:-0}"
    
    local lan_ifaces=$(get_lan_ifaces)
    for lan_if in $lan_ifaces; do
        if [ "$ipv6" = "1" ]; then
            ip6tables -w -t mangle -D PREROUTING -i "$lan_if" -j "$chain" 2>/dev/null
        else
            iptables -w -t mangle -D PREROUTING -i "$lan_if" -j "$chain" 2>/dev/null
        fi
    done
    
    if [ "$ipv6" = "1" ]; then
        ip6tables -w -t mangle -F "$chain" 2>/dev/null
        ip6tables -w -t mangle -X "$chain" 2>/dev/null
    else
        iptables -w -t mangle -F "$chain" 2>/dev/null
        iptables -w -t mangle -X "$chain" 2>/dev/null
    fi
}

# === ROUTING TABLE SETUP ===

# Setup default route in routing table
# Args: $1=interface, $2=table, $3=ipv6_supported (0/1)
setup_default_route() {
    local interface="$1"
    local table="$2"
    local ipv6="${3:-0}"
    
    ip route flush table "$table" 2>/dev/null
    
    # Only add route if interface exists
    if ip link show "$interface" >/dev/null 2>&1; then
        ip route add default dev "$interface" table "$table"
        
        if [ "$ipv6" = "1" ]; then
            ip -6 route flush table "$table" 2>/dev/null
            ip -6 route add default dev "$interface" table "$table" 2>/dev/null
        fi
    else
        # If interface doesn't exist yet (staging), this is expected.
        # The hotplug script will handle it when interface comes up.
        true
    fi
}

# === NAT66 (IPv6 NAT) ===

# Setup NAT66 for /128 VPN addresses
# Args: $1=interface, $2=vpn_ipv6_address (without prefix)
setup_nat66() {
    local interface="$1"
    local vpn_ip6="$2"
    local chain="nat66_${interface}"
    
    # Create NAT66 chain
    ip6tables -w -t nat -N "$chain" 2>/dev/null || ip6tables -w -t nat -F "$chain"
    
    # SNAT outgoing traffic to VPN IPv6 address
    ip6tables -w -t nat -A "$chain" -o "$interface" -j SNAT --to-source "$vpn_ip6"
    
    # Hook into POSTROUTING
    ip6tables -w -t nat -C POSTROUTING -j "$chain" 2>/dev/null || \
        ip6tables -w -t nat -I POSTROUTING 1 -j "$chain"
}

# Cleanup NAT66 configuration
# Args: $1=interface
cleanup_nat66() {
    local interface="$1"
    local chain="nat66_${interface}"
    
    ip6tables -w -t nat -D POSTROUTING -j "$chain" 2>/dev/null
    ip6tables -w -t nat -F "$chain" 2>/dev/null
    ip6tables -w -t nat -X "$chain" 2>/dev/null
}

# === IPv6 LEAK PREVENTION ===

# Create IPv6 block chain for leak prevention
# Args: $1=interface
create_ipv6_block_chain() {
    local interface="$1"
    local chain="${interface}_ipv6_block"
    
    ip6tables -w -N "$chain" 2>/dev/null || ip6tables -w -F "$chain"
    ip6tables -w -C FORWARD -j "$chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$chain"
}

# Add MAC to IPv6 block chain (block unless marked)
# Args: $1=interface, $2=mac, $3=mark_value, $4=in_iface(optional)
add_ipv6_block_rule() {
    local interface="$1"
    local mac="$2"
    local mark="$3"
    local in_iface="${4:-}"
    local chain="${interface}_ipv6_block"
    
    if [ -n "$in_iface" ]; then
        local lan_ifaces
        lan_ifaces=$(get_lan_ifaces)
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$chain" -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP 2>/dev/null; do :; done
        done
        ip6tables -w -C "$chain" -i "$in_iface" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP 2>/dev/null || \
            ip6tables -w -I "$chain" 1 -i "$in_iface" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP
        return 0
    fi

    local lan_ifaces
    lan_ifaces=$(get_lan_ifaces)
    for lan_if in $lan_ifaces; do
        ip6tables -w -C "$chain" -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP 2>/dev/null || \
            ip6tables -w -I "$chain" 1 -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP
    done
}

# Create IPv4-only block chain (for IPv4-only tunnels)
# Args: $1=interface
create_ipv4_only_block_chain() {
    local interface="$1"
    local chain="${interface}_ipv4_only_block"
    
    ip6tables -w -N "$chain" 2>/dev/null || ip6tables -w -F "$chain"
    ip6tables -w -C FORWARD -j "$chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$chain"
    ip6tables -w -C INPUT -j "$chain" 2>/dev/null || ip6tables -w -I INPUT 1 -j "$chain"
}

# Block all IPv6 for a MAC (IPv4-only tunnel)
# Args: $1=interface, $2=mac, $3=in_iface(optional)
add_ipv4_only_block() {
    local interface="$1"
    local mac="$2"
    local in_iface="${3:-}"
    local chain="${interface}_ipv4_only_block"
    
    if [ -n "$in_iface" ]; then
        local lan_ifaces
        lan_ifaces=$(get_lan_ifaces)
        while ip6tables -w -D "$chain" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$chain" -i "$lan_if" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do :; done
        done
        ip6tables -w -C "$chain" -i "$in_iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null || \
            ip6tables -w -A "$chain" -i "$in_iface" -m mac --mac-source "$mac" -j DROP
    else
        ip6tables -w -C "$chain" -m mac --mac-source "$mac" -j DROP 2>/dev/null || \
            ip6tables -w -A "$chain" -m mac --mac-source "$mac" -j DROP
    fi
}

# Cleanup all IPv6 block chains for interface
# Args: $1=interface
cleanup_ipv6_blocks() {
    local interface="$1"
    local block_chain="${interface}_ipv6_block"
    local ipv4_only_chain="${interface}_ipv4_only_block"
    
    ip6tables -w -D FORWARD -j "$block_chain" 2>/dev/null
    ip6tables -w -F "$block_chain" 2>/dev/null
    ip6tables -w -X "$block_chain" 2>/dev/null
    
    ip6tables -w -D FORWARD -j "$ipv4_only_chain" 2>/dev/null
    ip6tables -w -D INPUT -j "$ipv4_only_chain" 2>/dev/null
    ip6tables -w -F "$ipv4_only_chain" 2>/dev/null
    ip6tables -w -X "$ipv4_only_chain" 2>/dev/null
}

# === HIGH-LEVEL SETUP FUNCTIONS ===

# Full IP routing setup for an interface
# Args: $1=interface, $2=routing_table, $3=target_ips (space-separated), $4=ipv6_supported (0/1),
#       $5=ipv6_mode (nat66|routed-prefix|disabled), $6=ipv6_routed_prefix, $7=ipv6_downstream_iface
setup_ip_routing() {
    local interface="$1"
    local table="$2"
    local targets="$3"
    local ipv6="${4:-0}"
    local ipv6_mode="${5:-nat66}"
    local ipv6_routed_prefix="${6:-}"
    local ipv6_downstream_iface="${7:-}"
    
    local table_name="${interface}_rt"
    local ipset_name="vpn_${interface}"
    local ipset_v6="vpn6_${interface}"
    local mark_chain="mark_${interface}"
    local mark=$(calculate_mark "$table")
    
    # 1. Register routing table
    register_routing_table "$table" "$table_name"
    
    # 2. Setup default route
    setup_default_route "$interface" "$table" "$ipv6"
    
    # 3. Create ipsets
    create_or_flush_ipset "$ipset_name" "inet"
    [ "$ipv6" = "1" ] && create_or_flush_ipset "$ipset_v6" "inet6"
    if [ "$ipv6" = "1" ] && [ "$ipv6_mode" = "routed-prefix" ] && [ -n "$ipv6_routed_prefix" ]; then
        add_to_ipset "$ipset_v6" "$ipv6_routed_prefix"
    fi
    
    # 4. Populate ipsets and add source rules
    if [ "$targets" != "none" ]; then
        for target in $(echo "$targets" | tr ',' ' '); do
            local actual_ip=$(get_ip_from_target "$target")
            case "$actual_ip" in
                *:*)
                    [ "$ipv6" = "1" ] && add_to_ipset "$ipset_v6" "$actual_ip"
                    ;;
                *)
                    # If target is a subnet (contains /), check if we need to block IPv6 on the interface (if vpn is IPv4-only)
                    if [ "$ipv6" = "0" ] && echo "$target" | grep -q "/"; then
                         local lan_dev=$(resolve_dev_from_target "$target")
                         if [ -n "$lan_dev" ]; then
                             block_ipv6_on_lan_interface "$interface" "$lan_dev" "$target"
                             ensure_local_src_rule "$lan_dev"
                         fi
                    fi
                    
                    add_to_ipset "$ipset_name" "$actual_ip"
                    add_source_rule "$actual_ip" "$table" "$table"
                    
                    # Dual-Stack Discovery: If IPv6 enabled, try to find and add associated IPv6 addresses

                    if [ "$ipv6" = "1" ] && [ "$ipv6_mode" != "routed-prefix" ]; then
                        local discovered_ipv6=$(resolve_ipv6_from_ipv4_target "$actual_ip")
                        for ip6 in $discovered_ipv6; do
                            add_to_ipset "$ipset_v6" "$ip6"
                        done
                    fi
                    ;;
            esac
        done
    fi
    
    # 5. Create fwmark chain
    create_mark_chain "$mark_chain" 0
    add_ipset_mark_rule "$mark_chain" "$ipset_name" "$mark" 0
    
    # 6. Attach to PREROUTING
    local lan_ifaces=$(get_lan_ifaces)
    for lan_if in $lan_ifaces; do
        attach_chain_to_prerouting "$mark_chain" "$lan_if" 0
    done
    
    # 7. Add fwmark rule
    add_fwmark_rule "$mark" "$table" "" 0
    
    # 8. IPv6 setup
    if [ "$ipv6" = "1" ]; then
        create_mark_chain "$mark_chain" 1
        add_ipset_mark_rule "$mark_chain" "$ipset_v6" "$mark" 1
        for lan_if in $lan_ifaces; do
            attach_chain_to_prerouting "$mark_chain" "$lan_if" 1
        done
        add_fwmark_rule "$mark" "$table" "" 1
        create_ipv6_block_chain "$interface"
        
        # Ensure block rules are ready for MAC-based clients
        local block_chain="${interface}_ipv6_block"
        local dns_chain="${interface}_v6_dns_in"
        ip6tables -w -N "$dns_chain" 2>/dev/null || ip6tables -w -F "$dns_chain"
        ip6tables -w -C INPUT -j "$dns_chain" 2>/dev/null || ip6tables -w -I INPUT 1 -j "$dns_chain"
    else
        create_ipv4_only_block_chain "$interface"
    fi
}

# Full IP routing cleanup for an interface
# Args: $1=interface, $2=routing_table, $3=target_ips (space-separated)
cleanup_ip_routing() {
    local interface="$1"
    local table="$2"
    local targets="$3"
    
    local table_name="${interface}_rt"
    local ipset_name="vpn_${interface}"
    local ipset_v6="vpn6_${interface}"
    local mark_chain="mark_${interface}"
    local mark=$(calculate_mark "$table")
    
    # Remove source rules
    if [ "$targets" != "none" ]; then
        for target in $(echo "$targets" | tr ',' ' '); do
            local actual_ip=$(get_ip_from_target "$target")
            del_source_rule "$actual_ip" "$table"
        done
    fi
    
    # Remove fwmark rules
    del_fwmark_rule "$mark" "$table" 0
    del_fwmark_rule "$mark" "$table" 1
    
    # Cleanup marking chains
    cleanup_mark_chain "$mark_chain" 0
    cleanup_mark_chain "$mark_chain" 1
    
    # Cleanup IPv6 blocks
    cleanup_ipv6_blocks "$interface"
    
    # Destroy ipsets
    destroy_ipset "$ipset_name"
    destroy_ipset "$ipset_v6"
    
    # Flush routing table
    ip route flush table "$table" 2>/dev/null
    ip -6 route flush table "$table" 2>/dev/null
    
    # Unregister routing table
    unregister_routing_table "$table_name"
}
