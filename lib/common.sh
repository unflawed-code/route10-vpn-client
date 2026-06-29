#!/bin/sh
# Route10 PBR Library - Common Utilities
# Shared helper functions for routing engines

# Load project-wide defaults/overrides when available.
if [ -z "${VPN_PROJECT_CONFIG_LOADED:-}" ] && [ -n "${LIB_DIR:-}" ] && [ -f "${LIB_DIR}/project-config.sh" ]; then
    . "${LIB_DIR}/project-config.sh"
fi

VPN_PREFIX="${VPN_PREFIX:-vpnx1}"
VPN_RT_START="${VPN_RT_START:-1000}"
VPN_RT_END="${VPN_RT_END:-1499}"
PBR_DB_BUSY_TIMEOUT_MS="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
WG_DB_BUSY_TIMEOUT_MS="${WG_DB_BUSY_TIMEOUT_MS:-$PBR_DB_BUSY_TIMEOUT_MS}"

# === STRING UTILITIES ===

# Trim leading and trailing whitespace
trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Validate a routing table number against manager range.
# Usage: validate_routing_table <table> [start] [end]
validate_routing_table() {
    local table="$1"
    local start="${2:-$VPN_RT_START}"
    local end="${3:-$VPN_RT_END}"
    
    case "$table" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    
    [ "$table" -ge "$start" ] && [ "$table" -le "$end" ]
}

# Wait for system to be ready if uptime is less than 60 seconds
wait_for_system_ready() {
    local uptime_secs wait_secs
    uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    if [ -n "$uptime_secs" ] && [ "$uptime_secs" -lt 60 ]; then
        wait_secs=$((60 - uptime_secs))
        echo "System uptime is ${uptime_secs}s. Waiting ${wait_secs}s for system to be ready..."
        sleep "$wait_secs"
    fi
}

# === MAC ADDRESS UTILITIES ===

# Check if a string looks like a MAC address
# Supports: 2a3012ef5aaa, 2a:30:12:ef:5a:aa, 2a-30-12-ef-5a-aa
is_mac() {
    local input="$1"
    local clean=$(echo "$input" | tr -d ':-' | tr 'A-F' 'a-f')
    [ ${#clean} -eq 12 ] && echo "$clean" | grep -qE '^[0-9a-f]{12}$'
}

# Normalize MAC address to lowercase colon-separated format
# Returns 1 if invalid
normalize_mac() {
    local input="$1"
    local clean=$(echo "$input" | tr -d ':-' | tr 'A-F' 'a-f')
    if [ ${#clean} -ne 12 ] || ! echo "$clean" | grep -qE '^[0-9a-f]{12}$'; then
        return 1
    fi
    echo "$clean" | sed 's/\(..\)/\1:/g; s/:$//'
}

# Resolve MAC address to IP via ARP/neighbor table
resolve_mac_to_ip() {
    local mac="$1"
    mac=$(normalize_mac "$mac") || return 1
    ip neigh show | awk -v mac="$mac" 'tolower($5)==mac && $NF!="FAILED" {print $1; exit}'
}

# === IP ADDRESS UTILITIES ===

# Extract IP part from target (handles plain IP, CIDR, or MAC=IP format)
get_ip_from_target() {
    local target="$1"
    case "$target" in
        *=*) echo "${target#*=}" ;;
        *)   echo "$target" ;;
    esac
}

# Convert IPv4 address to integer for subnet calculations
ip_to_int() {
    [ -z "$1" ] && echo "0" && return
    local a b c d
    IFS=. read -r a b c d <<EOF
$1
EOF
    [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -z "$d" ] && echo "0" && return
    echo "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

# Check if an IPv4 address is within a CIDR subnet
is_in_subnet() {
    local ip_to_check="$1" subnet_cidr="$2"
    local ip_int subnet prefix network_int mask i
    ip_int=$(ip_to_int "$ip_to_check")
    subnet="${subnet_cidr%/*}"
    prefix="${subnet_cidr#*/}"
    network_int=$(ip_to_int "$subnet")
    i=0; mask=0
    while [ $i -lt $prefix ]; do
        mask=$(( (mask >> 1) | 0x80000000 ))
        i=$((i+1))
    done
    [ $(( ip_int & mask )) -eq $(( network_int & mask )) ] && return 0 || return 1
}

# Check if an IP matches any item in a list (supports both single IPs and CIDR subnets)
is_in_list() {
    local ip_to_check="$1" list="$2" ip_int item
    ip_int=$(ip_to_int "$ip_to_check")
    for item in $list; do
        local actual_ip=$(get_ip_from_target "$item")
        case "$actual_ip" in
            */*)
                is_in_subnet "$ip_to_check" "$actual_ip" && return 0
                ;;
            *)
                [ "$actual_ip" = "$ip_to_check" ] && return 0
                ;;
        esac
    done
    return 1
}

# === IPV6 UTILITIES ===

# Analyze IPv6 addresses and determine support level
# Args: $1=client_ip6 (list), $2=allowed_ips
# Sets globals: IPV6_SUPPORTED, VPN_IP6_SUBNETS, VPN_IP6_NEEDS_NAT66
analyze_ipv6() {
    local client_ip6="$1"
    local allowed_ips="$2"
    
    IPV6_SUPPORTED=0
    VPN_IP6_SUBNETS=""
    VPN_IP6_NEEDS_NAT66=0
    
    # Check if any client IPv6 addresses are present
    if [ -n "$client_ip6" ] && [ "$client_ip6" != "none" ]; then
        IPV6_SUPPORTED=1
        
        # Process each address
        for ip6 in $(echo "$client_ip6" | tr ',' ' '); do
            if echo "$ip6" | grep -q '/'; then
                local prefix_len="${ip6##*/}"
                local addr_part="${ip6%/*}"
                
                if [ "$prefix_len" -le 64 ]; then
                    # /64 and larger - Expand and extract prefix
                    local network_prefix
                    network_prefix=$(echo "$addr_part" | awk -F: '{
                        n = 0
                        for (i=1; i<=NF; i++) if ($i != "") n++
                        missing = 8 - n
                        out = ""
                        for (i=1; i<=NF; i++) {
                            if ($i == "" && missing > 0) {
                                for (j=0; j<missing; j++) out = out "0:"
                                missing = 0
                            } else if ($i != "") {
                                out = out $i ":"
                            }
                        }
                        gsub(/:$/, "", out)
                        split(out, groups, ":")
                        printf "%s:%s:%s:%s", groups[1], groups[2], groups[3], groups[4]
                    }')
                    local subnet="${network_prefix}::/${prefix_len}"
                    VPN_IP6_SUBNETS="$VPN_IP6_SUBNETS $subnet"
                    VPN_IP6_NEEDS_NAT66=1
                elif [ "$prefix_len" -ge 128 ]; then
                    # /128 needs strict NAT66
                    VPN_IP6_NEEDS_NAT66=1
                else
                    # /65-/127
                    VPN_IP6_SUBNETS="$VPN_IP6_SUBNETS $ip6"
                    VPN_IP6_NEEDS_NAT66=1
                fi
            else
                # Bare IPv6 address with no prefix length - assume /128 and enable NAT66
                VPN_IP6_NEEDS_NAT66=1
            fi
        done
    elif echo "$allowed_ips" | grep -q "::"; then
        IPV6_SUPPORTED=1
        # echo "INFO: IPv6 enabled via AllowedIPs (no local address)"
    fi
    
    VPN_IP6_SUBNETS=$(echo "$VPN_IP6_SUBNETS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}

# Validate global unicast routed prefix input (any non-/128 prefix).
# Usage: is_valid_ipv6_routed_prefix <prefix>
is_valid_ipv6_routed_prefix() {
    local prefix="$1"
    [ -n "$prefix" ] || return 1
    echo "$prefix" | grep -q '/' || return 1
    local plen="${prefix##*/}"
    case "$plen" in ''|*[!0-9]*) return 1 ;; esac
    [ "$plen" -ge 1 ] && [ "$plen" -le 127 ] || return 1
    local base="${prefix%/*}"
    # basic IPv6 shape check
    echo "$base" | grep -Eq '^[0-9A-Fa-f:]+$' || return 1
    # reject link-local/multicast/loopback/unspecified
    case "$(echo "$base" | tr 'A-F' 'a-f')" in
        fe8*|fe9*|fea*|feb*|ff*|::|::1) return 1 ;;
    esac
    # Allow global/ULA style inputs; strict provider checks happen at runtime verify.
    return 0
}

# Ensure all targets are subnet CIDRs (no per-host IP or MAC targets).
# Usage: targets_are_subnets_only <targets>
targets_are_subnets_only() {
    local targets="$1"
    [ -n "$targets" ] || return 1
    [ "$targets" = "none" ] && return 1
    for target in $(echo "$targets" | tr ',' ' '); do
        [ -z "$target" ] && continue
        is_mac "$target" && return 1
        echo "$target" | grep -q '/' || return 1
    done
    return 0
}

# Ensure targets contain exactly one subnet CIDR.
# Usage: targets_have_exactly_one_subnet <targets>
targets_have_exactly_one_subnet() {
    local targets="$1"
    [ -n "$targets" ] || return 1
    [ "$targets" = "none" ] && return 1
    local subnet_count=0
    for target in $(echo "$targets" | tr ',' ' '); do
        [ -z "$target" ] && continue
        if echo "$target" | grep -q '/'; then
            subnet_count=$((subnet_count + 1))
        fi
    done
    [ "$subnet_count" -eq 1 ]
}

# Ensure targets contain exactly one subnet CIDR and no host/MAC entries.
# Usage: targets_are_single_subnet_only <targets>
targets_are_single_subnet_only() {
    local targets="$1"
    targets_are_subnets_only "$targets" || return 1
    targets_have_exactly_one_subnet "$targets"
}

# Verify network interface exists.
# Usage: iface_exists <iface>
iface_exists() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip link show "$iface" >/dev/null 2>&1
}

# Best-effort target-to-downstream check (IPv4 routes only).
# Usage: targets_route_via_iface <targets> <iface>
targets_route_via_iface() {
    local targets="$1"
    local iface="$2"
    [ -n "$targets" ] && [ -n "$iface" ] || return 1
    for target in $(echo "$targets" | tr ',' ' '); do
        [ -z "$target" ] && continue
        local dev query
        query=$(get_ip_from_target "$target")

        # Raw MAC targets are allowed; validate if we can resolve them now.
        if is_mac "$query" 2>/dev/null; then
            query=$(resolve_mac_to_ip "$query" 2>/dev/null || true)
            [ -n "$query" ] || continue
        fi

        if echo "$query" | grep -q '/'; then
            dev=$(ip -4 route show "$query" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        else
            dev=$(ip -4 route get "$query" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        fi
        [ -n "$dev" ] && [ "$dev" = "$iface" ] || return 1
    done
    return 0
}

# === NETWORK INTERFACE UTILITIES ===

# Get LAN bridge interfaces (typically br-lan)
get_lan_ifaces() {
    local lan_ifs
    lan_ifs=$(ip link show type bridge 2>/dev/null | awk -F': ' '/br-lan/{print $2}')
    [ -z "$lan_ifs" ] && lan_ifs=$(uci get network.lan.device 2>/dev/null || echo "br-lan")
    echo "$lan_ifs"
}

# Find the DHCP lease file location
get_dhcp_lease_file() {
    if [ -f "/tmp/dhcp.leases" ]; then echo "/tmp/dhcp.leases"
    elif [ -f "/var/dhcp.leases" ]; then echo "/var/dhcp.leases"
    elif [ -f "/cfg/dhcp.leases" ]; then echo "/cfg/dhcp.leases"
    else echo ""; fi
}

# === FIREWALL UTILITIES ===

# Clean up an iptables -w chain (unlink, flush, delete)
# Args: $1=table, $2=parent_chain, $3=chain_name
cleanup_iptables_chain() {
    local table="$1" parent="$2" chain="$3"
    if [ "$table" = "filter" ]; then
        iptables -w -D "$parent" -j "$chain" 2>/dev/null
        iptables -w -F "$chain" 2>/dev/null
        iptables -w -X "$chain" 2>/dev/null
    else
        iptables -w -t "$table" -D "$parent" -j "$chain" 2>/dev/null
        iptables -w -t "$table" -F "$chain" 2>/dev/null
        iptables -w -t "$table" -X "$chain" 2>/dev/null
    fi
}

# Clean up an ip6tables -w chain (unlink, flush, delete)
# Args: $1=table, $2=parent_chain, $3=chain_name
cleanup_ip6tables_chain() {
    local table="$1" parent="$2" chain="$3"
    if [ "$table" = "filter" ]; then
        ip6tables -w -D "$parent" -j "$chain" 2>/dev/null
        ip6tables -w -F "$chain" 2>/dev/null
        ip6tables -w -X "$chain" 2>/dev/null
    else
        ip6tables -w -t "$table" -D "$parent" -j "$chain" 2>/dev/null
        ip6tables -w -t "$table" -F "$chain" 2>/dev/null
        ip6tables -w -t "$table" -X "$chain" 2>/dev/null
    fi
}

# Discover MAC address for a given IP (with optional retry)
discover_mac_for_ip() {
    local target_ip="$1" max_retries="${2:-3}" mac="" retry=0
    
    # Proactive ping to ensure ARP entry exists
    ping -c 1 -W 1 "$target_ip" >/dev/null 2>&1
    sleep 1
    
    while [ $retry -lt $max_retries ] && [ -z "$mac" ]; do
        mac=$(ip neigh show "$target_ip" | grep -o '[0-9a-f:]\{17\}' | head -1)
        if [ -n "$mac" ] && [ "$mac" != "<incomplete>" ]; then
            echo "$mac"
            return 0
        fi
        mac=""
        sleep 1
        retry=$((retry + 1))
    done
    echo ""
    return 1
}

# === CLIENT DISCOVERY ===

# Discover clients in a subnet from DHCP leases and ARP table
# Args: $1=subnet (CIDR), $2=callback_function
# Callback receives: mac, ip
discover_clients_in_subnet() {
    local subnet="$1"
    local callback="$2"
    local processed_macs=""
    local dhcp_file=$(get_dhcp_lease_file)
    
    # 1. DHCP Leases (Primary)
    if [ -n "$dhcp_file" ] && [ -f "$dhcp_file" ]; then
        while read -r exp mac ip host; do
            if is_in_subnet "$ip" "$subnet" && ! echo "$processed_macs" | grep -q "$mac"; then
                processed_macs="$processed_macs $mac"
                $callback "$mac" "$ip"
            fi
        done < "$dhcp_file"
    fi
    
    # 2. ARP/NDP Table (Fallback)
    ip neigh show | while read -r line; do
        local ip=$(echo $line | awk '{print $1}')
        local mac=$(echo $line | grep -o -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
        if [ -n "$mac" ] && is_in_subnet "$ip" "$subnet" && ! echo "$processed_macs" | grep -q "$mac"; then
            processed_macs="$processed_macs $mac"
            $callback "$mac" "$ip"
        fi
    done
}
