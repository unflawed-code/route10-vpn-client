#!/bin/sh
# ${VPN_PREFIX} VPN Client - WireGuard Implementation
# WireGuard-specific setup that uses the VPN core lifecycle manager

WG_VERSION="v1.0.0"

set -e

# Script directory for library paths
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Load project-wide defaults/overrides (project.conf)
PROJECT_CONFIG_LIB="$SCRIPT_DIR/lib/project-config.sh"
[ -f "$PROJECT_CONFIG_LIB" ] && . "$PROJECT_CONFIG_LIB"

VPN_PREFIX="${VPN_PREFIX:-vpnx1}"
VPN_RT_START="${VPN_RT_START:-1000}"
VPN_RT_END="${VPN_RT_END:-1499}"

VPN_CORE_LIB="$SCRIPT_DIR/lib/vpn-core.sh"

# Source VPN core library (includes state.sh, common.sh, and pbr.sh)
if [ -f "$VPN_CORE_LIB" ]; then
    . "$VPN_CORE_LIB"
    vpn_core_set_type "wireguard"
    VPN_TABLE_LIB="$SCRIPT_DIR/lib/util/table.sh"
    if [ -f "$VPN_TABLE_LIB" ]; then
        . "$VPN_TABLE_LIB"
    fi
else
    echo "Error: VPN core library not found at $VPN_CORE_LIB"
    exit 1
fi

# === USAGE ===

show_banner() {
    local title="${VPN_PREFIX} WireGuard Client ${WG_VERSION}"
    local len=${#title}
    local border=""
    local i=0
    while [ $i -lt $len ]; do border="${border}─"; i=$((i+1)); done
    echo "┌─${border}─┐"
    echo "│ ${title} │"
    echo "└─${border}─┘"
}

usage() {
    set +e
    show_banner
    echo "Usage:"
    printf "  %s\n" "$0 [iface] -c [conf] -t [ips]"
    echo ""
    echo "Arguments:"
    tbl_init 100 15 85
    tbl_top
    tbl_row "<iface_name>" "WireGuard interface name (max 11 chars)"
    tbl_row "-c, --conf" "Path to WireGuard .conf file"
    tbl_row "-t, --targets" "Comma-separated list of IPs/subnets/MACs"
    tbl_row "-d, --domains" "Comma-separated domains for split-tunnel"
    tbl_row "--ipv6-mode" "Optional: nat66 | routed-prefix | disabled. Defaults to nat66 if not provided"
    tbl_bottom
    echo ""
    echo "Commands:"
    tbl_init 100 35 65
    tbl_top
    tbl_row "commit" "Apply all staged configurations"
    tbl_row "reapply" "Re-apply firewall rules for running interfaces"
    tbl_row "status" "Show configured interfaces"
    tbl_row "delete [iface]" "Permanently remove an interface"
    tbl_row "version" "Show version"
    vpn_core_show_plugin_help
    tbl_bottom
    set -e
    exit 1
}

# === WIREGUARD CONFIG PARSER ===

# Parse WireGuard .conf file
# Sets: PRIVATE_KEY, CLIENT_IP, CLIENT_IP6, DNS_SERVERS, PEER_PUBLIC_KEY,
#       PRESHARED_KEY, ENDPOINT, ALLOWED_IPS, KEEPALIVE
parse_wg_config() {
    local config_file="$1"
    local section="" line key value value_spaced
    
    PRIVATE_KEY=""
    CLIENT_IP=""
    CLIENT_IP6=""
    DNS_SERVERS=""
    PEER_PUBLIC_KEY=""
    PRESHARED_KEY=""
    ENDPOINT=""
    ALLOWED_IPS=""
    KEEPALIVE=""
    MTU=""
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Remove comments and trim
        line="${line%%#*}"
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        
        # Section headers
        case "$line" in
            \[*\])
                section="${line#[}"
                section="${section%]}"
                continue
                ;;
        esac
        
        # Key=Value pairs
        case "$line" in
            *=*)
                key="${line%%=*}"
                value="${line#*=}"
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Strict Base64 filtering for value (removes \r and non-printables)
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                case "$section" in
                    Interface)
                        case "$key" in
                            PrivateKey) 
                                PRIVATE_KEY=$(echo "$value" | tr -cd 'a-zA-Z0-9+/=')
                                ;;
                            Address)
                                value_spaced=$(echo "$value" | sed 's/,/ /g')
                                for addr in $value_spaced; do
                                    case "$addr" in
                                        *:*) CLIENT_IP6="$CLIENT_IP6 $addr" ;;
                                        *)   CLIENT_IP="$CLIENT_IP $addr" ;;
                                    esac
                                done
                                ;;
                            DNS)
                                value_spaced=$(echo "$value" | sed 's/,/ /g')
                                for dns in $value_spaced; do
                                    DNS_SERVERS="$DNS_SERVERS $dns"
                                done
                                ;;
                            MTU) MTU="$value" ;;
                        esac
                        ;;
                    Peer)
                        case "$key" in
                            PublicKey) 
                                PEER_PUBLIC_KEY=$(echo "$value" | tr -cd 'a-zA-Z0-9+/=')
                                ;;
                            PresharedKey) 
                                PRESHARED_KEY=$(echo "$value" | tr -cd 'a-zA-Z0-9+/=')
                                ;;
                            Endpoint) ENDPOINT="$value" ;;
                            AllowedIPs) ALLOWED_IPS="$value" ;;
                            PersistentKeepalive) KEEPALIVE="$value" ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done < "$config_file"
    
    # Trim whitespace and CR for others
    # Endpoint might have IP:Port, allowed IPs has CIDR
    ENDPOINT=$(echo "$ENDPOINT" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ALLOWED_IPS=$(echo "$ALLOWED_IPS" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    CLIENT_IP=$(echo "$CLIENT_IP" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    CLIENT_IP6=$(echo "$CLIENT_IP6" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DNS_SERVERS=$(echo "$DNS_SERVERS" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Deduplicate IPv6
    CLIENT_IP6=$(echo "$CLIENT_IP6" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    
    # Defaults
    ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0, ::/0}"
    KEEPALIVE="${KEEPALIVE:-25}"
    # MTU is optional, no default needed (OpenWrt defaults to 1420 for WG usually)
}

# Parse endpoint (supports IPv4 and IPv6)
# Sets: ENDPOINT_HOST, ENDPOINT_PORT
parse_endpoint() {
    local endpoint="$1"
    
    case "$endpoint" in
        \[*\]:*)
            # IPv6: [2001:db8::1]:51820
            ENDPOINT_HOST="${endpoint%]:*}"
            ENDPOINT_HOST="${ENDPOINT_HOST#[}"
            ENDPOINT_PORT="${endpoint##*]:}"
            ;;
        *:*)
            # IPv4: 1.2.3.4:51820
            ENDPOINT_HOST="${endpoint%:*}"
            ENDPOINT_PORT="${endpoint##*:}"
            ;;
        *)
            echo "Error: Invalid endpoint format: $endpoint"
            return 1
            ;;
    esac
}



# === UCI CONFIGURATION ===

# Generate a random free listen port
generate_listen_port() {
    local port
    local attempts=0
    while [ $attempts -lt 10 ]; do
        # Range 51820-52000
        port=$(awk -v min=51820 -v max=52000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
        
        # Check against existing uci configuration
        if uci show network | grep -q "listen_port='$port'"; then
            attempts=$((attempts + 1))
            continue
        fi
        
        # Check netstat if available (optional)
        if netstat -un -l 2>/dev/null | grep -q ":$port "; then
             attempts=$((attempts + 1))
             continue
        fi

        echo "$port"
        return 0
    done
    
    # Fallback to random default if we can't find one checked
    echo "51820"
}

# Setup WireGuard interface via UCI
# Args: $1=iface, $2=ipv6_mode(optional), $3=ipv6_routed_prefix(optional)
setup_uci_interface() {
    local iface="$1"
    local ipv6_mode="${2:-nat66}"
    local ipv6_routed_prefix="${3:-}"
    
    # Base UCI setup (protocol-agnostic)
    vpn_core_setup_uci_interface "$iface"
    
    # WireGuard-specific settings
    uci set network.$iface.proto='wireguard'
    uci set network.$iface.private_key="$PRIVATE_KEY"
    if [ -n "$MTU" ]; then
        uci set network.$iface.mtu="$MTU"
    fi
    
    # Generate and set listen port to avoid conflicts
    local listen_port=$(generate_listen_port)
    uci set network.$iface.listen_port="$listen_port"
    
    # Add addresses (Cleanup first to avoid duplication)
    uci delete network.$iface.addresses 2>/dev/null || true
    if [ -n "$CLIENT_IP" ]; then
        for ip in $CLIENT_IP; do
            uci add_list network.$iface.addresses="$ip" || true
        done
    fi
    if [ -n "$CLIENT_IP6" ] && [ "$IPV6_SUPPORTED" = "1" ]; then
        for ip6 in $CLIENT_IP6; do
            local addr="$ip6"
            if [ "$ipv6_mode" = "routed-prefix" ] && [ -n "$ipv6_routed_prefix" ]; then
                # Routed-prefix mode delegates the /64 to LAN, so keep WG as host-only /128
                # to avoid duplicate connected /64 routes on WG and downstream interfaces.
                addr="${ip6%/*}/128"
            fi
            uci add_list network.$iface.addresses="$addr" || true
        done
    fi
    
    # Remove existing peer sections for this interface
    # Using while loop with safety counter to drain all anonymous sections
    local _drain_cnt=0
    while uci -q delete network.@wireguard_${iface}[0]; do
        _drain_cnt=$((_drain_cnt + 1))
        [ $_drain_cnt -gt 100 ] && break
    done

    # Add Peer Section (using uci add for anonymous section of specific type)
    # The type must be wireguard_<iface> for netifd to pick it up
    local peer_type="wireguard_${iface}"
    local peer_section=$(uci add network "$peer_type")
    
    uci set network.$peer_section.public_key="$PEER_PUBLIC_KEY"
    uci set network.$peer_section.endpoint_host="$ENDPOINT_HOST"
    uci set network.$peer_section.endpoint_port="$ENDPOINT_PORT"
    uci set network.$peer_section.persistent_keepalive="$KEEPALIVE"
    
    # Add allowed IPs (Cleanup first)
    uci delete network.$peer_section.allowed_ips 2>/dev/null || true
    echo "$ALLOWED_IPS" | tr ',' '\n' | while read -r ip; do
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$ip" ]; then
            uci add_list network.$peer_section.allowed_ips="$ip" || true
        fi
    done
    
    # Add preshared key if present
    if [ -n "$PRESHARED_KEY" ]; then
        uci set network.$peer_section.preshared_key="$PRESHARED_KEY"
    fi
}

# Setup firewall zone via UCI
setup_uci_firewall() {
    local iface="$1"
    local zone_name=$(echo "$iface" | cut -c1-11)
    
    # Remove existing
    for section in $(uci show firewall 2>/dev/null | grep "\.name='${zone_name}'" | cut -d. -f2 | cut -d= -f1); do
        uci delete firewall.$section 2>/dev/null || true
    done
    
    # Create zone
    uci set firewall.${iface}_zone=zone
    uci set firewall.${iface}_zone.name="$zone_name"
    uci set firewall.${iface}_zone.input='REJECT'
    uci set firewall.${iface}_zone.output='ACCEPT'
    uci set firewall.${iface}_zone.forward='ACCEPT'
    uci set firewall.${iface}_zone.masq='1'
    uci set firewall.${iface}_zone.mtu_fix='1'
    uci add_list firewall.${iface}_zone.network="$iface"
    
    # Create forwarding
    uci set firewall.${iface}_fwd=forwarding
    uci set firewall.${iface}_fwd.src='lan'
    uci set firewall.${iface}_fwd.dest="$zone_name"
}

# === TARGET IP RESOLUTION ===

# Resolve target IPs (handles MACs, checks conflicts, sanitizes commas)
resolve_targets() {
    local targets="$1"
    local iface="$2"
    local resolved=""
    local seen=""
    
    # Normalize comma-separated to space-separated for processing
    local normalized_targets=$(echo "$targets" | tr ',' ' ')
    
    for target in $normalized_targets; do
        local actual_ip=""
        local store_target="$target"
        local target_key=""
        actual_ip=$(get_ip_from_target "$target")
        
        # Resolve MAC to IP
        if is_mac "$actual_ip"; then
            local mac=$(normalize_mac "$target")
            actual_ip=$(resolve_mac_to_ip "$mac")
            if [ -z "$actual_ip" ]; then
                echo "WARN: MAC $mac not found in ARP table, skipping" >&2
                continue
            fi
            store_target="${mac}=${actual_ip}"
            echo "Resolved MAC $mac -> $actual_ip" >&2
        fi
        target_key="$actual_ip"
        [ -n "$target_key" ] || continue
        
        # Dedup by resolved identity (e.g. MAC that maps to an existing IP).
        if printf '%s\n' "$seen" | grep -Fqx "$target_key"; then
            echo "INFO: $target_key already in list, skipping duplicate" >&2
            continue
        fi
        seen="${seen}
${target_key}"
        resolved="$resolved $store_target"
    done
    
    echo "$resolved" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Derive a routed prefix from parsed WireGuard interface IPv6 addresses.
# Prefers the first global-ish non-/128 entry from CLIENT_IP6.
derive_routed_prefix_from_config() {
    local ip6
    for ip6 in $CLIENT_IP6; do
        case "$ip6" in
            */128) continue ;;
            */*)
                if is_valid_ipv6_routed_prefix "$ip6"; then
                    echo "$ip6"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

# Derive downstream device from subnet targets.
# Returns device name when all subnet targets map to the same interface.
# Skips non-subnet entries (bare IPs and MACs).
derive_downstream_iface_from_targets() {
    local targets="$1"
    local inferred=""
    local target dev
    for target in $(echo "$targets" | tr ',' ' '); do
        [ -z "$target" ] && continue
        echo "$target" | grep -q '/' || continue
        dev=$(ip -4 route show "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [ -n "$dev" ] || return 1
        if [ -z "$inferred" ]; then
            inferred="$dev"
        elif [ "$inferred" != "$dev" ]; then
            return 1
        fi
    done
    [ -n "$inferred" ] || return 1
    echo "$inferred"
    return 0
}

# === MAIN SETUP ===

# Full WireGuard interface setup
wg_setup() {
    local iface="$1"
    local config="$2"
    local targets="$3"
    local table="$4"
    local ipv6_mode_opt="$5"
    
    echo "Setting up WireGuard interface: $iface"
    echo "Config: $config"
    
    # Parse config
    parse_wg_config "$config"
    
    # Validate
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PEER_PUBLIC_KEY" ] || [ -z "$ENDPOINT" ]; then
        echo "Error: Missing PrivateKey, PublicKey, or Endpoint in config"
        return 1
    fi
    
    parse_endpoint "$ENDPOINT"
    
    # Analyze IPv6
    analyze_ipv6 "$CLIENT_IP6" "$ALLOWED_IPS"
    
    # Normalize comma-separated lists to space-separated for internal use
    targets=$(echo "$targets" | tr ',' ' ')
    DNS_SERVERS=$(echo "$DNS_SERVERS" | tr ',' ' ')
    
    local ipv6_mode="${ipv6_mode_opt:-${VPN_IPV6_MODE_DEFAULT:-nat66}}"
    local ipv6_routed_prefix=""
    local ipv6_downstream_iface=""

    case "$ipv6_mode" in
        routed-prefix)
            [ "$targets" != "none" ] || { echo "Error: routed-prefix mode requires exactly one subnet target"; return 1; }
            targets_are_single_subnet_only "$targets" || { echo "Error: routed-prefix mode requires exactly one subnet target only"; return 1; }
            ipv6_routed_prefix=$(derive_routed_prefix_from_config || true)
            [ -n "$ipv6_routed_prefix" ] || {
                echo "Error: Could not derive routed IPv6 prefix from config."
                return 1
            }
            is_valid_ipv6_routed_prefix "$ipv6_routed_prefix" || { echo "Error: invalid routed IPv6 prefix (require global non-/128)"; return 1; }

            ipv6_downstream_iface=$(derive_downstream_iface_from_targets "$targets" || true)
            [ -n "$ipv6_downstream_iface" ] || {
                echo "Error: Could not derive downstream interface from targets."
                return 1
            }
            iface_exists "$ipv6_downstream_iface" || { echo "Error: downstream interface '$ipv6_downstream_iface' does not exist"; return 1; }
            targets_route_via_iface "$targets" "$ipv6_downstream_iface" || {
                echo "Error: target subnets do not map cleanly to downstream interface '$ipv6_downstream_iface'"
                return 1
            }
            IPV6_SUPPORTED=1
            VPN_IP6_SUBNETS="$ipv6_routed_prefix"
            VPN_IP6_NEEDS_NAT66=0
            ;;
        disabled)
            IPV6_SUPPORTED=0
            VPN_IP6_SUBNETS=""
            VPN_IP6_NEEDS_NAT66=0
            ;;
        auto|nat66)
            ;;
        *)
            echo "Error: Unsupported --ipv6-mode '$ipv6_mode' (valid: nat66, routed-prefix, disabled)"
            return 1
            ;;
    esac
    
    # 1. Lifecycle: Init (register in DB)
    vpn_core_init "$iface" "wireguard" "$config" "$table" "$targets" "$DNS_SERVERS" || return 1
    db_set_ipv6_profile "$iface" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface"
    db_set_ipv6_health "$iface" "unknown" ""
    
    # 2. UCI Setup
    echo "Configuring UCI for $iface..."
    setup_uci_interface "$iface" "$ipv6_mode" "$ipv6_routed_prefix"
    vpn_core_setup_uci_firewall "$iface"
    
    # 3. Lifecycle: Configure (PBR setup)
    echo "Setting up policy-based routing..."
    vpn_core_configure "$iface" "$table" "$targets" "$DNS_SERVERS" "$IPV6_SUPPORTED" "$VPN_IP6_SUBNETS" "$VPN_IP6_NEEDS_NAT66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || return 1
    
    # 4. Lifecycle: Stage Assets (Generate hotplugs but do not mark committed)
    vpn_core_stage_assets "$iface" "$table" "$targets" "$DNS_SERVERS" "$IPV6_SUPPORTED" "$VPN_IP6_SUBNETS" "$VPN_IP6_NEEDS_NAT66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || return 1
    
    # Setup NAT66 if needed (Core does basic NAT66 call in Configure, but we can add WG specifics if any)
    # VPN Core vpn_core_configure already updates DB with NAT66 settings which hotplug uses.
    
    echo "WireGuard setup complete for $iface"
}

# Full Split-Tunnel Interface setup
wg_split_setup() {
    local iface="$1"
    local config="$2"
    local domains="$3"
    local table="$4"

    echo "Setting up WireGuard Split-Tunnel interface: $iface"
    echo "Domains: $domains"

    # Source split-tunnel library
    local SPLIT_LIB="$SCRIPT_DIR/lib/split-tunnel.sh"
    if [ -f "$SPLIT_LIB" ]; then
        . "$SPLIT_LIB"
    else
        echo "Error: Split-tunnel library not found at $SPLIT_LIB"
        exit 1
    fi

    # Parse config
    parse_wg_config "$config"

    # Validate
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PEER_PUBLIC_KEY" ] || [ -z "$ENDPOINT" ]; then
        echo "Error: Missing PrivateKey, PublicKey, or Endpoint in config"
        return 1
    fi
     
    parse_endpoint "$ENDPOINT"
    
    # Analyze IPv6 (Check if tunnel supports it)
    analyze_ipv6 "$CLIENT_IP6" "$ALLOWED_IPS"

    # 1. Stage split interface in DB (do not start/commit yet).
    db_init 2>/dev/null || true
    local was_committed
    was_committed=$(db_get_field "$iface" "committed")
    
    db_set_staged_split_tunnel "$iface" "$config" "$table" "$domains" "wireguard" "$DNS_SERVERS"
    db_update_staged_domains "$iface" "$domains" 0
    db_set_ipv6 "$iface" "$IPV6_SUPPORTED" "$VPN_IP6_SUBNETS" "$VPN_IP6_NEEDS_NAT66"
    db_set_ipv6_profile "$iface" "nat66" "" ""
    db_set_ipv6_health "$iface" "unknown" ""
    
    if [ "$was_committed" = "1" ]; then
        db_commit_interface "$iface"
        db_set_target_only "$iface" 1
    fi

    # 2. UCI Setup (Same as standard)
    echo "Configuring UCI for $iface..."
    setup_uci_interface "$iface"
    setup_uci_firewall "$iface"

    # 3. Stage hotplug assets only. Commit will apply and bring interface up.
    vpn_core_stage_assets "$iface" "$table" "none" "$DNS_SERVERS" "$IPV6_SUPPORTED" "$VPN_IP6_SUBNETS" "$VPN_IP6_NEEDS_NAT66" || return 1
    
    echo "Split-Tunnel configuration staged for $iface."
}

# === HOOKS ===

# WireGuard-specific cleanup on delete
wg_post_delete() {
    local iface="$1"
    # Remove existing peer sections for this interface
    local _drain_cnt=0
    while uci -q delete network.@wireguard_${iface}[0]; do
        _drain_cnt=$((_drain_cnt + 1))
        [ $_drain_cnt -gt 100 ] && break
    done
    uci commit network
}

# === ARGUMENT PARSING ===

case "$1" in
    -h|--help) usage ;;
    -v|--version|version) show_banner; exit 0 ;;
    commit)
        vpn_core_commit
        exit 0
        ;;
    reapply)
        vpn_core_reapply
        exit 0
        ;;
    status)
        # Check for status plugin
        PLUGIN_STATUS="$SCRIPT_DIR/plugins/status.sh"
        if [ -f "$PLUGIN_STATUS" ]; then
            . "$PLUGIN_STATUS"
            cmd_status_all "wireguard"
        else
            # Fallback to simple status
            echo "${VPN_PREFIX} VPN Interfaces:"
            echo "======================"
            db_list_interfaces | while read -r iface; do
                data=$(db_get_interface "$iface")
                type=$(echo "$data" | cut -d'|' -f2)
                running=$(echo "$data" | cut -d'|' -f14)
                committed=$(echo "$data" | cut -d'|' -f8)
                rt=$(echo "$data" | cut -d'|' -f4)
                targets=$(echo "$data" | cut -d'|' -f5)
                
                status="[STAGED]"
                [ "$committed" = "1" ] && status="[READY]"
                [ "$running" = "1" ] && status="[RUNNING]"
                
                printf "%-10s %-12s (%-9s) table=%-3s targets=%s\n" "$status" "$iface" "$type" "$rt" "$targets"
            done
        fi
        exit 0
        ;;
    delete)
        [ -z "$2" ] && echo "Error: Interface name required for delete" && exit 1
        vpn_core_delete "$2"
        exit 0
        ;;
esac

# Allow plugins to handle custom commands before normal setup parsing
if vpn_core_handle_command "$@"; then
    exit 0
fi

INTERFACE_NAME=""
CONFIG_FILE=""
VPN_IPS_OVERRIDE=""
SPLIT_DOMAINS=""
IPV6_MODE_OPTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--conf)
            [ -z "$2" ] && echo "Error: --conf requires a value" && usage
            CONFIG_FILE=$(trim "$2")
            shift 2
            ;;
        -t|--target-ips)
            [ -z "$2" ] && echo "Error: --target-ips requires a value" && usage
            VPN_IPS_OVERRIDE=$(trim "$2")
            shift 2
            ;;
        -d|--domains)
            [ -z "$2" ] && echo "Error: --domains requires a value" && usage
            SPLIT_DOMAINS=$(trim "$2")
            shift 2
            ;;
        --ipv6-mode)
            [ -z "$2" ] && echo "Error: --ipv6-mode requires a value" && usage
            IPV6_MODE_OPTION=$(trim "$2")
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$INTERFACE_NAME" ]; then
                INTERFACE_NAME=$(trim "$1")
            else
                echo "Error: Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Validate
[ -z "$INTERFACE_NAME" ] && echo "Error: Interface name required" && usage
[ ${#INTERFACE_NAME} -gt 11 ] && echo "Error: Interface name max 11 chars" && usage
[ -z "$CONFIG_FILE" ] && echo "Error: --conf required" && usage
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found: $CONFIG_FILE" && exit 1

# Reuse existing routing table for existing interfaces; auto-allocate for new ones.
db_init 2>/dev/null || true
existing_table=$(db_get_field "$INTERFACE_NAME" "routing_table" 2>/dev/null || true)
case "$existing_table" in
    ''|*[!0-9]*)
        ROUTING_TABLE_OVERRIDE=$(db_allocate_routing_table "$VPN_RT_START" "$VPN_RT_END")
        [ -z "$ROUTING_TABLE_OVERRIDE" ] && echo "Error: Routing table allocation failed" && exit 1
        echo "Allocated routing table: $ROUTING_TABLE_OVERRIDE"
        ;;
    *)
        ROUTING_TABLE_OVERRIDE="$existing_table"
        echo "Reusing routing table: $ROUTING_TABLE_OVERRIDE"
        ;;
esac

# Default targets
[ -z "$VPN_IPS_OVERRIDE" ] && VPN_IPS_OVERRIDE="none"

if [ -n "$SPLIT_DOMAINS" ]; then
    # Validate incompatibility
    if [ "$VPN_IPS_OVERRIDE" != "none" ]; then
        echo "Error: -d and -t are mutually exclusive."
        exit 1
    fi
    if [ -n "$IPV6_MODE_OPTION" ]; then
        echo "Error: routed-prefix IPv6 options are supported only with client-routing (-t) mode."
        exit 1
    fi
    
    # Split-Tunnel Setup
    wg_split_setup "$INTERFACE_NAME" "$CONFIG_FILE" "$SPLIT_DOMAINS" "$ROUTING_TABLE_OVERRIDE"

else
    # Standard Setup (stages in DB and generates configs)
    wg_setup "$INTERFACE_NAME" "$CONFIG_FILE" "$VPN_IPS_OVERRIDE" "$ROUTING_TABLE_OVERRIDE" "$IPV6_MODE_OPTION"
fi

echo ""
echo "WireGuard configuration staged for $INTERFACE_NAME"
echo "Run '$0 commit' to apply and start the interface."
