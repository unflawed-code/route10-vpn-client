#!/bin/sh
# ${VPN_PREFIX} VPN Client - OpenVPN Implementation
# OpenVPN-specific setup that uses the VPN core lifecycle manager

OVPN_VERSION="v1.0.0"

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

# Source VPN core library
if [ -f "$VPN_CORE_LIB" ]; then
    . "$VPN_CORE_LIB"
    vpn_core_set_type "openvpn"
    VPN_TABLE_LIB="$SCRIPT_DIR/lib/util/table.sh"
    if [ -f "$VPN_TABLE_LIB" ]; then
        . "$VPN_TABLE_LIB"
    fi
else
    exit 1
fi

# === USAGE ===

show_banner() {
    local title="${VPN_PREFIX} OpenVPN Client ${OVPN_VERSION}"
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
    tbl_row "<iface_name>" "OpenVPN interface name (max 11 chars)"
    tbl_row "-c, --conf" "Path to OpenVPN .ovpn file"
    tbl_row "-a, --auth" "Auth file (username/password)"
    tbl_row "-t, --targets" "Comma-sep list of IPs/subnets/MACs"
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

# === OPENVPN CONFIG PARSER ===

ovpn_runtime_config_path() {
    local iface="$1"
    echo "$SCRIPT_DIR/conf/.${VPN_PREFIX}_${iface}.ovpn"
}

prepare_runtime_ovpn_config() {
    local iface="$1"
    local source_conf="$2"
    local runtime_conf
    runtime_conf="$(ovpn_runtime_config_path "$iface")"

    mkdir -p "$(dirname "$runtime_conf")" 2>/dev/null || true
    cp "$source_conf" "$runtime_conf" || return 1

    # Prevent provider-pushed redirect/routes from hijacking global router policy.
    sed -i '/^[[:space:]]*pull-filter[[:space:]]\+ignore[[:space:]]\+"redirect-gateway"[[:space:]]*$/d' "$runtime_conf"
    sed -i '/^[[:space:]]*pull-filter[[:space:]]\+ignore[[:space:]]\+"route "[[:space:]]*$/d' "$runtime_conf"
    {
        echo ""
        echo "# Route10 managed directives"
        echo "pull-filter ignore \"redirect-gateway\""
        echo "pull-filter ignore \"route \""
        # Capture pushed DNS on OpenVPN up/route-up.
        local up_script="$SCRIPT_DIR/lib/ovpn-up.sh"
        if ! grep -q "$up_script" "$runtime_conf"; then
            local up_directive="up"
            if grep -qE '^[[:space:]]*up[[:space:]]+' "$runtime_conf"; then
                up_directive="route-up"
            fi
            if ! grep -qE '^[[:space:]]*script-security[[:space:]]+' "$runtime_conf"; then
                echo "script-security 2"
            fi
            echo "${up_directive} \"$up_script\""
        fi
    } >> "$runtime_conf"

    echo "$runtime_conf"
    return 0
}

parse_ovpn_auth_credentials() {
    local config_file="$1"
    local auth_override="${2:-}"
    OVPN_AUTH_USERNAME=""
    OVPN_AUTH_PASSWORD=""

    local auth_path=""
    if [ -n "$auth_override" ]; then
        auth_path="$auth_override"
    else
        auth_path=$(awk '
            /^[[:space:]]*[#;]/ { next }
            {
                line=$0
                sub(/[[:space:]]*#.*/, "", line)
                if (line ~ /^[[:space:]]*auth-user-pass([[:space:]]+|$)/) {
                    n=split(line, a, /[[:space:]]+/)
                    if (n >= 2) print a[2]
                    exit
                }
            }
        ' "$config_file")
    fi

    [ -n "$auth_path" ] || return 0
    auth_path=$(echo "$auth_path" | sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//')
    case "$auth_path" in
        /*) ;;
        *) auth_path="$(dirname "$config_file")/$auth_path" ;;
    esac
    [ -f "$auth_path" ] || return 0

    local line1 line2
    line1=$(awk 'NF && $0 !~ /^[[:space:]]*[#;]/ { print; exit }' "$auth_path" | tr -d '\r')
    line2=$(awk 'NF && $0 !~ /^[[:space:]]*[#;]/ { c++; if (c == 2) { print; exit } }' "$auth_path" | tr -d '\r')
    [ -n "$line1" ] || return 0
    [ -n "$line2" ] || return 0

    case "$line1" in
        [Uu][Ss][Ee][Rr][Nn][Aa][Mm][Ee]=*) OVPN_AUTH_USERNAME="${line1#*=}" ;;
        *) OVPN_AUTH_USERNAME="$line1" ;;
    esac
    case "$line2" in
        [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=*) OVPN_AUTH_PASSWORD="${line2#*=}" ;;
        *) OVPN_AUTH_PASSWORD="$line2" ;;
    esac

    OVPN_AUTH_USERNAME=$(echo "$OVPN_AUTH_USERNAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    OVPN_AUTH_PASSWORD=$(echo "$OVPN_AUTH_PASSWORD" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}

parse_ovpn_config() {
    local config_file="$1"
    DNS_SERVERS=""
    IPV6_SUPPORTED=0
    OVPN_AUTH_USERNAME=""
    OVPN_AUTH_PASSWORD=""
    
    # Simple parser for DNS pushed from config or manual entries
    # In practice, OpenVPN gets DNS via DHCP/pushed options at runtime,
    # but we can look for 'dhcp-option DNS' or similar for static parsing.
    DNS_SERVERS=$(grep -E '^dhcp-option DNS' "$config_file" | awk '{print $3}' | tr '\n' ' ')
    
    # Check for IPv6 support declarations in config.
    # Proton profiles request IPv6 via "setenv UV_IPV6 1".
    if grep -qE '^tun-ipv6|ifconfig-ipv6|route-ipv6' "$config_file" || \
       grep -qE '^[[:space:]]*setenv[[:space:]]+UV_IPV6[[:space:]]+1([[:space:]]|$)' "$config_file"; then
        IPV6_SUPPORTED=1
    fi
    
    # Trim whitespace
    DNS_SERVERS=$(echo "$DNS_SERVERS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    parse_ovpn_auth_credentials "$config_file" "${AUTH_FILE_OVERRIDE:-}"
}

# === UCI CONFIGURATION ===

ovpn_find_pids() {
    local iface="$1"
    ps w | awk -v iface="$iface" '
        /[o]penvpn/ && (
            index($0, "openvpn(" iface ")") ||
            index($0, "--dev " iface) ||
            index($0, "openvpn." iface ".") ||
            index($0, iface ".ovpn")
        ) { print $1 }
    '
}

ovpn_stop_processes() {
    local iface="$1"
    local sig="${2:-TERM}"
    local pid
    local seen=0

    for pid in $(ovpn_find_pids "$iface"); do
        kill "-$sig" "$pid" 2>/dev/null || true
        seen=1
    done

    [ "$seen" -eq 1 ]
}

ovpn_wait_for_exit() {
    local iface="$1"
    local attempts="${2:-10}"
    local delay="${3:-1}"
    local n=0

    while [ "$n" -lt "$attempts" ]; do
        if ! ovpn_find_pids "$iface" | grep -q .; then
            return 0
        fi
        sleep "$delay"
        n=$((n + 1))
    done

    return 1
}

setup_uci_interface() {
    local iface="$1"
    local config="$2"
    local tun_dev="$iface"
    
    # Base UCI setup (protocol-agnostic)
    vpn_core_setup_uci_interface "$iface"
    
    # OpenVPN-specific settings
    uci set network.$iface.proto='none' # Handled by openvpn process
    # Keep device IPv6 enabled so pushed ifconfig-ipv6 can be applied at runtime.
    # Client leak prevention is still governed by PBR ipv6_support rules.
    uci set network.$iface.ipv6='1'
    uci set network.$iface.device="$tun_dev"
    
    # Configure OpenVPN service
    uci set openvpn.$iface=openvpn
    uci set openvpn.$iface.enabled='1'
    uci set openvpn.$iface.config="$config"
    uci set openvpn.$iface.dev="$tun_dev"
    uci set openvpn.$iface.dev_type='tun'
    uci delete openvpn.$iface.username 2>/dev/null || true
    uci delete openvpn.$iface.password 2>/dev/null || true
    if [ -n "$OVPN_AUTH_USERNAME" ] && [ -n "$OVPN_AUTH_PASSWORD" ]; then
        uci set openvpn.$iface.username="$OVPN_AUTH_USERNAME"
        uci set openvpn.$iface.password="$OVPN_AUTH_PASSWORD"
    fi
}

# === MAIN SETUP ===

ovpn_setup() {
    local iface="$1"
    local config="$2"
    local targets="$3"
    local table="$4"
    local nat66_enabled=0
    local runtime_config=""
    
    echo "Setting up OpenVPN interface: $iface"
    
    # Parse config
    parse_ovpn_config "$config"
    if [ "$IPV6_SUPPORTED" = "1" ]; then
        # OpenVPN providers commonly assign a single /112-/128 style tunnel IPv6,
        # so routed clients require NAT66 for functional egress IPv6.
        nat66_enabled=1
    fi
    runtime_config="$(prepare_runtime_ovpn_config "$iface" "$config")" || {
        echo "Error: failed to prepare runtime OpenVPN config for $iface"
        return 1
    }
    
    # Normalize comma-separated lists to space-separated for internal use
    targets=$(echo "$targets" | tr ',' ' ')
    DNS_SERVERS=$(echo "$DNS_SERVERS" | tr ',' ' ')

    # 1. Lifecycle: Init
    vpn_core_init "$iface" "openvpn" "$config" "$table" "$targets" "$DNS_SERVERS" || return 1
    
    # 2. UCI Setup
    echo "Configuring UCI for $iface..."
    setup_uci_interface "$iface" "$runtime_config"
    vpn_core_setup_uci_firewall "$iface"
    
    # 3. Lifecycle: Configure
    echo "Setting up policy-based routing..."
    vpn_core_configure "$iface" "$table" "$targets" "$DNS_SERVERS" "$IPV6_SUPPORTED" "" "$nat66_enabled" || return 1
    
    # 4. Lifecycle: Stage Assets (Generates hotplugs)
    vpn_core_stage_assets "$iface" "$table" "$targets" "$DNS_SERVERS" "$IPV6_SUPPORTED" "" "$nat66_enabled" || return 1
    
    echo "OpenVPN setup complete for $iface"
}

# === HOOKS ===

ovpn_pre_delete() {
    local iface="$1"

    if uci -q get "openvpn.${iface}" >/dev/null 2>&1; then
        uci set "openvpn.${iface}.enabled='0'" 2>/dev/null || true
        uci commit openvpn 2>/dev/null || true
        if [ -x /etc/init.d/openvpn ]; then
            /etc/init.d/openvpn reload >/dev/null 2>&1 || true
        fi
    fi

    if ovpn_stop_processes "$iface" TERM; then
        if ! ovpn_wait_for_exit "$iface" 5 1; then
            ovpn_stop_processes "$iface" KILL || true
            ovpn_wait_for_exit "$iface" 3 1 || true
        fi
    fi
}

# OpenVPN-specific cleanup on delete
ovpn_post_delete() {
    local iface="$1"
    local runtime_config
    runtime_config="$(ovpn_runtime_config_path "$iface")"
    
    # Remove openvpn configuration section
    uci delete openvpn.$iface 2>/dev/null || true
    rm -f "$runtime_config" 2>/dev/null || true
    rm -f "/var/run/openvpn.${iface}.status" 2>/dev/null || true
    rm -f "/var/run/openvpn.${iface}.userpass" 2>/dev/null || true
    rm -f "/var/run/openvpn.${iface}.pass" 2>/dev/null || true
    
    # Remove existing peer/client sections if any (safety counter)
    local _drain_cnt=0
    while uci -q delete network.@openvpn_${iface}[0]; do
        _drain_cnt=$((_drain_cnt + 1))
        [ $_drain_cnt -gt 100 ] && break
    done
    
    uci commit network
    uci commit openvpn
    if [ -x /etc/init.d/openvpn ]; then
        /etc/init.d/openvpn reload >/dev/null 2>&1 || true
    fi
}

vpn_core_register_hook pre_delete ovpn_pre_delete
vpn_core_register_hook post_delete ovpn_post_delete

# === ARGUMENT PARSING ===

case "$1" in
    -h|--help) usage ;;
    -v|--version|version) show_banner; exit 0 ;;
    commit)
        vpn_core_commit
        # OpenVPN needs a special reload
        /etc/init.d/openvpn restart
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
            cmd_status_all "openvpn"
        else
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
AUTH_FILE_OVERRIDE=""
VPN_IPS_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--conf)
            [ -z "$2" ] && echo "Error: --conf requires a value" && usage
            CONFIG_FILE=$(echo "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            shift 2
            ;;
        -a|--auth)
            [ -z "$2" ] && echo "Error: --auth requires a value" && usage
            AUTH_FILE_OVERRIDE=$(echo "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            shift 2
            ;;
        -t|--target-ips)
            [ -z "$2" ] && echo "Error: --target-ips requires a value" && usage
            VPN_IPS_OVERRIDE=$(echo "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$INTERFACE_NAME" ]; then
                INTERFACE_NAME=$(echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
[ -z "$CONFIG_FILE" ] && echo "Error: --conf required" && usage
[ ! -f "$CONFIG_FILE" ] && echo "Error: Config file not found: $CONFIG_FILE" && exit 1
if [ -n "$AUTH_FILE_OVERRIDE" ] && [ ! -f "$AUTH_FILE_OVERRIDE" ]; then
    echo "Error: Auth file not found: $AUTH_FILE_OVERRIDE"
    exit 1
fi
CONFIG_FILE=$(readlink -f "$CONFIG_FILE" 2>/dev/null || echo "$CONFIG_FILE")
[ -n "$AUTH_FILE_OVERRIDE" ] && AUTH_FILE_OVERRIDE=$(readlink -f "$AUTH_FILE_OVERRIDE" 2>/dev/null || echo "$AUTH_FILE_OVERRIDE")

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

# Setup the interface
ovpn_setup "$INTERFACE_NAME" "$CONFIG_FILE" "$VPN_IPS_OVERRIDE" "$ROUTING_TABLE_OVERRIDE"

echo ""
echo "OpenVPN configuration staged for $INTERFACE_NAME"
echo "Run '$0 commit' to apply and start the interface."
