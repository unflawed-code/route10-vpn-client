#!/bin/sh
# Route10 VPN Core - Protocol-Agnostic Lifecycle Manager
# Provides lifecycle management, hooks, UCI configuration, and hotplug generation
# for VPN clients (WireGuard, OpenVPN) without knowing protocol specifics.

# === PATHS ===

# Base directory discovery
if [ -z "$VPN_BASE_DIR" ]; then
    # When sourced, $0 is the calling script. Assume it sits in the project root.
    VPN_BASE_DIR="$(dirname "$(readlink -f "$0")")"
    # If the calling script is in a subdirectory (like tests), adjust or fallback
    if [ ! -d "$VPN_BASE_DIR/lib" ]; then
        VPN_BASE_DIR="/cfg/vpn-custom"
    fi
fi

# Load project-wide defaults/overrides (project.conf)
PROJECT_CONFIG_LIB="$VPN_BASE_DIR/lib/project-config.sh"
[ -f "$PROJECT_CONFIG_LIB" ] && . "$PROJECT_CONFIG_LIB"

# Normalized fallbacks (if loader not found)
VPN_PREFIX="${VPN_PREFIX:-vpnx1}"
VPN_RT_START="${VPN_RT_START:-1000}"
VPN_RT_END="${VPN_RT_END:-1499}"
PBR_DB_BUSY_TIMEOUT_MS="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
WG_DB_BUSY_TIMEOUT_MS="${WG_DB_BUSY_TIMEOUT_MS:-$PBR_DB_BUSY_TIMEOUT_MS}"
VPN_IPV6_MODE_DEFAULT="${VPN_IPV6_MODE_DEFAULT:-nat66}"
VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC="${VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC:-5}"
VPN_IPV6_ROUTED_VERIFY_RETRIES="${VPN_IPV6_ROUTED_VERIFY_RETRIES:-3}"
VPN_IPV6_ROUTED_PROBE_ADDR="${VPN_IPV6_ROUTED_PROBE_ADDR:-2606:4700:4700::1111}"
VPN_IPV6_FORCE_TAKEOVER="${VPN_IPV6_FORCE_TAKEOVER:-0}"

VPN_TMP_DIR="${VPN_TMP_DIR:-/tmp/${VPN_PREFIX}}"
LIB_DIR="$VPN_BASE_DIR/lib"
PLUGIN_DIR="${PLUGIN_DIR:-$VPN_BASE_DIR/plugins}"
HOTPLUG_IFACE_DIR="${HOTPLUG_IFACE_DIR:-/etc/hotplug.d/iface}"
HOTPLUG_DHCP_DIR="${HOTPLUG_DHCP_DIR:-/etc/hotplug.d/dhcp}"
MASTER_DHCP_HOTPLUG="$HOTPLUG_DHCP_DIR/99-${VPN_PREFIX}-master-pbr"
VPN_DNSMASQ_SERVICE="${VPN_DNSMASQ_SERVICE:-/etc/init.d/dnsmasq}"

mkdir -p "$VPN_TMP_DIR" 2>/dev/null || true

# Source dependencies
[ -f "$LIB_DIR/common.sh" ] && . "$LIB_DIR/common.sh"
[ -f "$LIB_DIR/state.sh" ] && . "$LIB_DIR/state.sh"

# Source routing engine
ROUTING_ENGINE="$LIB_DIR/routing/pbr.sh"
[ -f "$ROUTING_ENGINE" ] && . "$ROUTING_ENGINE"

# === HOOK SYSTEM ===

# Registered hooks (space-separated list per phase)
_VPN_HOOKS_pre_init=""
_VPN_HOOKS_post_init=""
_VPN_HOOKS_pre_configure=""
_VPN_HOOKS_post_configure=""
_VPN_HOOKS_pre_start=""
_VPN_HOOKS_post_start=""
_VPN_HOOKS_pre_stop=""
_VPN_HOOKS_post_stop=""
_VPN_HOOKS_pre_teardown=""
_VPN_HOOKS_post_teardown=""
_VPN_HOOKS_pre_delete=""
_VPN_HOOKS_post_delete=""
_VPN_HOOKS_pre_commit=""
_VPN_HOOKS_post_commit=""
_VPN_HOOKS_fw_reload=""

# Current interface type (set by wg.sh or ovpn.sh)
VPN_CURRENT_TYPE="${VPN_CURRENT_TYPE:-}"

# Register a hook function for a phase
vpn_core_register_hook() {
    local phase="$1"
    local func="$2"
    eval "_VPN_HOOKS_${phase}=\"\$_VPN_HOOKS_${phase} $func\""
}

# Run all hooks for a phase
vpn_core_run_hooks() {
    local phase="$1"
    local iface="${2:-}"
    if [ $# -ge 2 ]; then
        shift 2
    else
        shift $#
    fi
    
    local hooks
    eval "hooks=\"\$_VPN_HOOKS_${phase}\""
    
    for hook_func in $hooks; do
        if type "$hook_func" >/dev/null 2>&1; then
            if ! "$hook_func" "$iface" "$VPN_CURRENT_TYPE" "$@"; then
                case "$phase" in
                    pre_*) return 1 ;;
                    *) echo "Warning: Hook $hook_func failed" ;;
                esac
            fi
        fi
    done
    
    _vpn_core_run_plugin_dir "$PLUGIN_DIR" "$phase" "$iface" "$VPN_CURRENT_TYPE" "$@"
    
    case "$VPN_CURRENT_TYPE" in
        wireguard) _vpn_core_run_plugin_dir "$PLUGIN_DIR/wg" "$phase" "$iface" "$VPN_CURRENT_TYPE" "$@" ;;
        openvpn)   _vpn_core_run_plugin_dir "$PLUGIN_DIR/ovpn" "$phase" "$iface" "$VPN_CURRENT_TYPE" "$@" ;;
    esac
    
    return 0
}

_vpn_core_run_plugin_dir() {
    local plugin_dir="$1"
    local hook_name="$2"
    if [ $# -ge 2 ]; then
        shift 2
    else
        shift $#
    fi
    [ -d "$plugin_dir" ] || return 0
    for plugin in "$plugin_dir"/*.sh; do
        [ -f "$plugin" ] || continue
        unset -f "${hook_name}" 2>/dev/null || true
        . "$plugin"
        if type "${hook_name}" >/dev/null 2>&1; then
            "${hook_name}" "$@" || echo "Warning: Hook ${hook_name} in $(basename "$plugin") failed"
        fi
        unset -f "${hook_name}" 2>/dev/null || true
    done
}

# Run command-oriented hooks from plugins.
# For "handle_command", returns 0 if a plugin handled the command, 1 otherwise.
_vpn_core_run_command_hook_dir() {
    local plugin_dir="$1"
    local hook_name="$2"
    if [ $# -ge 2 ]; then
        shift 2
    else
        shift $#
    fi
    [ -d "$plugin_dir" ] || return 1
    
    for plugin in "$plugin_dir"/*.sh; do
        [ -f "$plugin" ] || continue
        
        unset -f "${hook_name}" 2>/dev/null || true
        . "$plugin"
        
        if type "${hook_name}" >/dev/null 2>&1; then
            if [ "$hook_name" = "handle_command" ]; then
                if "${hook_name}" "$@"; then
                    unset -f "${hook_name}" 2>/dev/null || true
                    return 0
                fi
            else
                "${hook_name}" "$@" || echo "Warning: Hook ${hook_name} in $(basename "$plugin") failed"
            fi
        fi
        
        unset -f "${hook_name}" 2>/dev/null || true
    done
    
    [ "$hook_name" = "handle_command" ] && return 1 || return 0
}

# Show plugin-provided help lines.
vpn_core_show_plugin_help() {
    _vpn_core_run_command_hook_dir "$PLUGIN_DIR" "show_plugin_help"
    
    case "$VPN_CURRENT_TYPE" in
        wireguard) _vpn_core_run_command_hook_dir "$PLUGIN_DIR/wg" "show_plugin_help" ;;
        openvpn)   _vpn_core_run_command_hook_dir "$PLUGIN_DIR/ovpn" "show_plugin_help" ;;
    esac
    
    return 0
}

# Dispatch command to plugin handlers.
# Returns 0 when handled, 1 when unhandled.
vpn_core_handle_command() {
    _vpn_core_run_command_hook_dir "$PLUGIN_DIR" "handle_command" "$@" && return 0
    
    case "$VPN_CURRENT_TYPE" in
        wireguard) _vpn_core_run_command_hook_dir "$PLUGIN_DIR/wg" "handle_command" "$@" && return 0 ;;
        openvpn)   _vpn_core_run_command_hook_dir "$PLUGIN_DIR/ovpn" "handle_command" "$@" && return 0 ;;
    esac
    
    return 1
}

vpn_core_set_type() {
    VPN_CURRENT_TYPE="$1"
}

# === UCI CONFIGURATION ===

vpn_core_setup_uci_interface() {
    local iface="$1"
    uci set network.$iface=interface
    uci set network.$iface.ipv6='0'
    uci set network.$iface.delegate='0'
    uci set network.$iface.ra='0'               
    uci set network.$iface.route_allowed_ips='0' 
}

vpn_core_setup_uci_firewall() {
    local iface="$1"
    local zone_name=$(echo "$iface" | cut -c1-11)
    uci set firewall.${iface}_zone=zone
    uci set firewall.${iface}_zone.name="$zone_name"
    uci set firewall.${iface}_zone.input='REJECT'
    uci set firewall.${iface}_zone.output='ACCEPT'
    uci set firewall.${iface}_zone.forward='ACCEPT'
    uci set firewall.${iface}_zone.masq='1'
    uci set firewall.${iface}_zone.mtu_fix='1'
    uci add_list firewall.${iface}_zone.network="$iface"
    uci set firewall.${iface}_fwd=forwarding
    uci set firewall.${iface}_fwd.src='lan'
    uci set firewall.${iface}_fwd.dest="$zone_name"
}

vpn_core_cleanup_uci() {
    local iface="$1"
    uci delete network.$iface 2>/dev/null || true
    uci delete firewall.${iface}_zone 2>/dev/null || true
    uci delete firewall.${iface}_fwd 2>/dev/null || true
}

# === KILL SWITCH ===

vpn_core_create_killswitch() {
    local iface="$1"
    local ks_chain="${iface}_killswitch"
    iptables -w -N "$ks_chain" 2>/dev/null || iptables -w -F "$ks_chain"
    iptables -w -C FORWARD -j "$ks_chain" 2>/dev/null || iptables -w -I FORWARD 1 -j "$ks_chain"
    ip6tables -w -N "$ks_chain" 2>/dev/null || ip6tables -w -F "$ks_chain"
    ip6tables -w -C FORWARD -j "$ks_chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$ks_chain"
}

vpn_core_enable_killswitch() {
    local iface="$1"
    local targets="$2"
    local ks_chain="${iface}_killswitch"
    iptables -w -F "$ks_chain" 2>/dev/null || true
    ip6tables -w -F "$ks_chain" 2>/dev/null || true
    for target in $targets; do
        local actual_ip=$(get_ip_from_target "$target")
        case "$actual_ip" in
            *:*) ip6tables -w -A "$ks_chain" -s "$actual_ip" -j DROP || true ;;
            *)   iptables -w -A "$ks_chain" -s "$actual_ip" -j DROP || true ;;
        esac
    done
}

vpn_core_disable_killswitch() {
    local iface="$1"
    local ks_chain="${iface}_killswitch"
    iptables -w -F "$ks_chain" 2>/dev/null || true
    ip6tables -w -F "$ks_chain" 2>/dev/null || true
}

vpn_core_remove_killswitch() {
    local iface="$1"
    local ks_chain="${iface}_killswitch"
    iptables -w -D FORWARD -j "$ks_chain" 2>/dev/null || true
    iptables -w -F "$ks_chain" 2>/dev/null || true
    iptables -w -X "$ks_chain" 2>/dev/null || true
    ip6tables -w -D FORWARD -j "$ks_chain" 2>/dev/null || true
    ip6tables -w -F "$ks_chain" 2>/dev/null || true
    ip6tables -w -X "$ks_chain" 2>/dev/null || true
}

# === HOTPLUG SCRIPT GENERATION ===

vpn_core_generate_ifup_script() {
    local iface="$1"
    local table="$2"
    local targets="$3"
    local dns="$4"
    local ipv6="${5:-0}"
    local ip6_subnets="${6:-}"
    local nat66="${7:-0}"
    local script_path="$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-routing"
    mkdir -p "$HOTPLUG_IFACE_DIR"
    cat > "$script_path" << 'EOF_ROUTING'
#!/bin/sh
[ "$ACTION" = "ifup" ] || [ "$ACTION" = "fw-reload" ] || exit 0
[ "$INTERFACE" = "IFACE_PLACEHOLDER" ] || exit 0
VPN_TMP_DIR="VPN_TMP_DIR_PLACEHOLDER"
mkdir -p "$VPN_TMP_DIR" 2>/dev/null || true
LOCK_FILE="${VPN_TMP_DIR}/iface_routing.lock"
exec 201>"$LOCK_FILE"
flock -x 201 || exit 1
trap 'flock -u 201' EXIT
VPN_INTERFACE="IFACE_PLACEHOLDER"
ROUTING_TABLE="TABLE_PLACEHOLDER"
VPN_IPS="TARGETS_PLACEHOLDER"
VPN_DNS="DNS_PLACEHOLDER"
IPV6_SUPPORTED="IPV6_PLACEHOLDER"
VPN_IP6_SUBNETS="IP6SUBNETS_PLACEHOLDER"
VPN_IP6_NEEDS_NAT66="NAT66_PLACEHOLDER"
IPSET_NAME="vpn_${VPN_INTERFACE}"
MARK_VALUE="$((0x10000 + ROUTING_TABLE))"
KS_CHAIN="${VPN_INTERFACE}_killswitch"
# Per-interface hotplug storm guard.
GUARD_STATE="${VPN_TMP_DIR}/iface_${VPN_INTERFACE}.guard"
GUARD_LAST="${VPN_TMP_DIR}/iface_${VPN_INTERFACE}.last"
NOW=$(date +%s 2>/dev/null)
[ -n "$NOW" ] || NOW=0
WINDOW=15
BURST=20
COOLDOWN=30
DEDUP=2
EVENT_KEY="${ACTION}|${INTERFACE}"
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
    logger -t vpn-core "[$VPN_INTERFACE] Hotplug storm guard active; skipping $ACTION"
    exit 0
fi
if [ -f "$GUARD_LAST" ]; then
    IFS='|' read -r LAST_TS LAST_KEY < "$GUARD_LAST"
    case "$LAST_TS" in ''|*[!0-9]*) LAST_TS=0 ;; esac
    if [ "$LAST_KEY" = "$EVENT_KEY" ] && [ $((NOW - LAST_TS)) -lt "$DEDUP" ]; then
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
    logger -t vpn-core "[$VPN_INTERFACE] Hotplug storm detected (count=$COUNT window=${WINDOW}s); cooling down ${COOLDOWN}s"
    exit 0
fi
printf "%s|%s|0\n" "$WIN_START" "$COUNT" > "$GUARD_STATE"
logger -t vpn-core "[$VPN_INTERFACE] Interface UP - applying routing"
iptables -w -F $KS_CHAIN 2>/dev/null
ip6tables -w -F $KS_CHAIN 2>/dev/null
ip route flush table $ROUTING_TABLE 2>/dev/null
ip route add default dev $VPN_INTERFACE table $ROUTING_TABLE
[ "$IPV6_SUPPORTED" = "1" ] && ip -6 route add default dev $VPN_INTERFACE table $ROUTING_TABLE
# IPv4-only tunnels: block IPv6 from target subnets on their LAN interface.
if [ "$IPV6_SUPPORTED" != "1" ]; then
    IPV4_ONLY_CHAIN="${VPN_INTERFACE}_ipv4_only_block"
    ip6tables -w -N "$IPV4_ONLY_CHAIN" 2>/dev/null || ip6tables -w -F "$IPV4_ONLY_CHAIN"
    ip6tables -w -C FORWARD -j "$IPV4_ONLY_CHAIN" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$IPV4_ONLY_CHAIN"
    ip6tables -w -C INPUT -j "$IPV4_ONLY_CHAIN" 2>/dev/null || ip6tables -w -I INPUT 1 -j "$IPV4_ONLY_CHAIN"
    for target in $VPN_IPS; do
        case "$target" in
            */*)
                lan_dev=$(ip -4 route show "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                if [ -n "$lan_dev" ]; then
                    if echo "$target" | grep -q ':'; then
                        ip6tables -w -C "$IPV4_ONLY_CHAIN" -i "$lan_dev" -s "$target" -j DROP 2>/dev/null || \
                            ip6tables -w -A "$IPV4_ONLY_CHAIN" -i "$lan_dev" -s "$target" -j DROP
                    else
                        ip6tables -w -C "$IPV4_ONLY_CHAIN" -i "$lan_dev" -j DROP 2>/dev/null || \
                            ip6tables -w -A "$IPV4_ONLY_CHAIN" -i "$lan_dev" -j DROP
                    fi
                fi
                ;;
        esac
    done
fi
# Keep router-originated traffic on LAN from being captured by source-based PBR.
# This prevents local DNS replies from routing into the VPN.
for target in $VPN_IPS; do
    case "$target" in
        */*)
            lan_dev=$(ip -4 route show "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
            if [ -n "$lan_dev" ]; then
                gw_ip=$(ip -4 addr show dev "$lan_dev" 2>/dev/null | awk '/inet / {print $2}' | head -1 | cut -d'/' -f1)
                [ -n "$gw_ip" ] && ip rule add from "${gw_ip}/32" lookup main priority 40 2>/dev/null || true
            fi
            ;;
    esac
done
if [ "$VPN_IP6_NEEDS_NAT66" = "1" ]; then
    # Discover VPN IPv6 address (skip link-local)
    VPN_V6_ADDR=$(ip -6 addr show "$VPN_INTERFACE" 2>/dev/null | awk '/inet6 / && !/fe80/ {split($2,a,"/"); print a[1]}' | head -1)
    if [ -z "$VPN_V6_ADDR" ]; then
        # OpenVPN can assign tunnel IPv6 slightly after ifup event.
        NAT66_WAIT=0
        while [ $NAT66_WAIT -lt 15 ]; do
            sleep 1
            VPN_V6_ADDR=$(ip -6 addr show "$VPN_INTERFACE" 2>/dev/null | awk '/inet6 / && !/fe80/ {split($2,a,"/"); print a[1]}' | head -1)
            [ -n "$VPN_V6_ADDR" ] && break
            NAT66_WAIT=$((NAT66_WAIT + 1))
        done
    fi
    if [ -n "$VPN_V6_ADDR" ]; then
        logger -t vpn-core "[$VPN_INTERFACE] Enabling NAT66 SNAT -> $VPN_V6_ADDR"
        CHAIN="nat66_${VPN_INTERFACE}"
        ip6tables -w -t nat -N "$CHAIN" 2>/dev/null || ip6tables -w -t nat -F "$CHAIN"
        ip6tables -w -t nat -A "$CHAIN" -o "$VPN_INTERFACE" -j SNAT --to-source "$VPN_V6_ADDR"
        ip6tables -w -t nat -C POSTROUTING -j "$CHAIN" 2>/dev/null || ip6tables -w -t nat -I POSTROUTING 1 -j "$CHAIN"
    else
        logger -t vpn-core "[$VPN_INTERFACE] NAT66 enabled but no global IPv6 found on tunnel (timeout)"
    fi
fi
DB_PATH="${VPN_TMP_DIR}/pbr.db"
if [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "UPDATE interfaces SET running = 1, start_time = $(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s) WHERE name = '$VPN_INTERFACE';" 2>/dev/null
fi
logger -t vpn-core "[$VPN_INTERFACE] Routing applied successfully"
EOF_ROUTING
    sed -i "s|IFACE_PLACEHOLDER|$iface|g" "$script_path"
    sed -i "s|TABLE_PLACEHOLDER|$table|g" "$script_path"
    sed -i "s|TARGETS_PLACEHOLDER|$targets|g" "$script_path"
    sed -i "s|DNS_PLACEHOLDER|$dns|g" "$script_path"
    sed -i "s|IPV6_PLACEHOLDER|$ipv6|g" "$script_path"
    sed -i "s|IP6SUBNETS_PLACEHOLDER|$ip6_subnets|g" "$script_path"
    sed -i "s|NAT66_PLACEHOLDER|$nat66|g" "$script_path"
    sed -i "s|VPN_TMP_DIR_PLACEHOLDER|$VPN_TMP_DIR|g" "$script_path"
    chmod +x "$script_path"
    echo "$script_path"
}

vpn_core_generate_ifdown_script() {
    local iface="$1"
    local table="$2"
    local targets="$3"
    local sqlite_timeout="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
    case "$sqlite_timeout" in
        ''|*[!0-9]*) sqlite_timeout=5000 ;;
    esac
    local script_path="$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-cleanup"
    mkdir -p "$HOTPLUG_IFACE_DIR"
    cat > "$script_path" << 'EOF_CLEANUP'
#!/bin/sh
[ "$ACTION" = "ifdown" ] || exit 0
[ "$INTERFACE" = "IFACE_PLACEHOLDER" ] || exit 0
VPN_INTERFACE="IFACE_PLACEHOLDER"
ROUTING_TABLE="TABLE_PLACEHOLDER"
VPN_IPS="TARGETS_PLACEHOLDER"
KS_CHAIN="${VPN_INTERFACE}_killswitch"
VPN_TMP_DIR="VPN_TMP_DIR_PLACEHOLDER"
DB_PATH="${VPN_TMP_DIR}/pbr.db"
logger -t vpn-core "[$VPN_INTERFACE] Interface DOWN - enabling kill switch"
iptables -w -F $KS_CHAIN 2>/dev/null
ip6tables -w -F $KS_CHAIN 2>/dev/null
for target in $(echo "$VPN_IPS" | tr ',' ' '); do
    case "$target" in
        *:*) ip6tables -w -A $KS_CHAIN -s "$target" -j DROP ;;
        *)   iptables -w -A $KS_CHAIN -s "$target" -j DROP ;;
    esac
done
if [ -f "$DB_PATH" ]; then
    SQLITE_TIMEOUT_MS="SQLITE_TIMEOUT_MS_PLACEHOLDER"
    command sqlite3 -cmd ".timeout ${SQLITE_TIMEOUT_MS}" "$DB_PATH" "UPDATE interfaces SET running = 0 WHERE name = '$VPN_INTERFACE';" 2>/dev/null
fi
logger -t vpn-core "[$VPN_INTERFACE] Kill switch enabled"
EOF_CLEANUP
    sed -i "s|IFACE_PLACEHOLDER|$iface|g" "$script_path"
    sed -i "s|TABLE_PLACEHOLDER|$table|g" "$script_path"
    sed -i "s|TARGETS_PLACEHOLDER|$targets|g" "$script_path"
    sed -i "s|VPN_TMP_DIR_PLACEHOLDER|$VPN_TMP_DIR|g" "$script_path"
    sed -i "s|SQLITE_TIMEOUT_MS_PLACEHOLDER|$sqlite_timeout|g" "$script_path"
    chmod +x "$script_path"
    echo "$script_path"
}

vpn_core_remove_hotplug_scripts() {
    local iface="$1"
    rm -f "$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-routing" 2>/dev/null
    rm -f "$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-cleanup" 2>/dev/null
    rm -f "$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-split" 2>/dev/null
}

# === DHCP HOTPLUG ===

vpn_core_setup_dhcp_handling() {
    local src_script="$LIB_DIR/vpn-dhcp-handler.sh"
    local lib_path="$LIB_DIR/vpn-core.sh"
    mkdir -p "$HOTPLUG_DHCP_DIR"
    if [ -f "$src_script" ]; then
        local tmp_hotplug="${VPN_TMP_DIR}/${VPN_PREFIX}-dhcp-hotplug.tmp"
        cat "$src_script" > "$tmp_hotplug"
        sed -i "s|VPN_CORE_LIB_PLACEHOLDER|$lib_path|g" "$tmp_hotplug"
        sed -i "s|VPN_TMP_DIR_PLACEHOLDER|$VPN_TMP_DIR|g" "$tmp_hotplug"
        if [ ! -f "$MASTER_DHCP_HOTPLUG" ] || ! cmp -s "$tmp_hotplug" "$MASTER_DHCP_HOTPLUG"; then
            cp "$tmp_hotplug" "$MASTER_DHCP_HOTPLUG"
            chmod +x "$MASTER_DHCP_HOTPLUG"
        fi
        rm -f "$tmp_hotplug"
    fi
}

vpn_core_setup_dnsmasq_hook() {
    local dhcp_hook="/etc/${VPN_PREFIX}-dnsmasq-dhcp-hook.sh"
    local src_hook="$LIB_DIR/dnsmasq-dhcp-hook.sh"
    if [ -f "$src_hook" ]; then
        if [ ! -f "$dhcp_hook" ] || ! cmp -s "$src_hook" "$dhcp_hook"; then
            cp "$src_hook" "$dhcp_hook"
            chmod +x "$dhcp_hook"
        fi
    fi
    local current_hook=$(uci -q get dhcp.@dnsmasq[0].dhcpscript || true)
    if [ "$current_hook" != "$dhcp_hook" ]; then
        uci set dhcp.@dnsmasq[0].dhcpscript="$dhcp_hook"
        uci commit dhcp
        return 0
    fi
    return 1
}

_vpn_core_is_routed_prefix_mode() {
    [ "$1" = "routed-prefix" ]
}

_vpn_core_routed_prefix_gateway_cidr() {
    local prefix="$1"
    local base="${prefix%/*}"
    local plen="${prefix##*/}"
    echo "${base}1/${plen}"
}

_vpn_core_routed_prefix_chain_name() {
    local iface="$1"
    echo "${iface}_routed6_guard"
}

_vpn_core_clear_routed_prefix_guard() {
    local iface="$1"
    local chain
    chain=$(_vpn_core_routed_prefix_chain_name "$iface")
    ip6tables -w -D FORWARD -j "$chain" 2>/dev/null || true
    ip6tables -w -F "$chain" 2>/dev/null || true
    ip6tables -w -X "$chain" 2>/dev/null || true
}

_vpn_core_apply_routed_prefix_guard() {
    local iface="$1"
    local table="$2"
    local prefix="$3"
    local downstream_iface="$4"
    local degraded="${5:-0}"
    local chain
    local mark
    chain=$(_vpn_core_routed_prefix_chain_name "$iface")
    mark=$(calculate_mark "$table")
    
    [ -n "$prefix" ] && [ -n "$downstream_iface" ] || return 1
    ip6tables -w -N "$chain" 2>/dev/null || ip6tables -w -F "$chain"
    ip6tables -w -C FORWARD -j "$chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$chain"
    # Preserve link-local and multicast control traffic.
    ip6tables -w -A "$chain" -i "$downstream_iface" -s fe80::/10 -j RETURN
    ip6tables -w -A "$chain" -i "$downstream_iface" -s ff00::/8 -j RETURN
    if [ "$degraded" = "1" ]; then
        # Degraded path: fail closed for all downstream IPv6.
        ip6tables -w -A "$chain" -i "$downstream_iface" -j DROP
    else
        # Isolation: prevent non-VPN prefixes from bypassing routed-prefix policy.
        ip6tables -w -A "$chain" -i "$downstream_iface" ! -s "$prefix" -j DROP
        ip6tables -w -A "$chain" -i "$downstream_iface" -s "$prefix" -m mark ! --mark "$mark" -j DROP
    fi
}

_vpn_core_apply_routed_prefix_ra() {
    local iface="$1"
    local downstream_iface="$2"
    local prefix="$3"
    local current_state=""
    local old_ip6addr="" old_ip6class="" old_ip6assign="" old_ra="" old_dhcpv6="" old_ra_mgmt=""
    local gw_cidr=""
    local route_metric="${VPN_IPV6_ROUTED_DOWNSTREAM_METRIC:-64}"
    local net_section=""
    local dhcp_section=""
    
    [ -n "$downstream_iface" ] && [ -n "$prefix" ] || return 1
    gw_cidr=$(_vpn_core_routed_prefix_gateway_cidr "$prefix")
    iface_exists "$downstream_iface" || return 1
    net_section=$(uci -q show network 2>/dev/null | awk -F. -v dev="$downstream_iface" '
        $1=="network" && $3 ~ /^ifname=/ {
            val=$3
            sub(/^ifname='\''/,"",val); sub(/'\''$/,"",val)
            if (val==dev) { print $2; exit }
        }
        $1=="network" && $3 ~ /^device=/ {
            val=$3
            sub(/^device='\''/,"",val); sub(/'\''$/,"",val)
            if (val==dev) { print $2; exit }
        }')
    [ -n "$net_section" ] || return 1
    dhcp_section="$net_section"
    
    current_state=$(db_get_ra_state "$iface" "$downstream_iface")
    if [ -z "$current_state" ]; then
        old_ip6addr=$(uci -q get "network.${net_section}.ip6addr" 2>/dev/null || true)
        old_ip6class=$(uci -q get "network.${net_section}.ip6class" 2>/dev/null || true)
        old_ip6assign=$(uci -q get "network.${net_section}.ip6assign" 2>/dev/null || true)
        old_ra=$(uci -q get "dhcp.${dhcp_section}.ra" 2>/dev/null || true)
        old_dhcpv6=$(uci -q get "dhcp.${dhcp_section}.dhcpv6" 2>/dev/null || true)
        old_ra_mgmt=$(uci -q get "dhcp.${dhcp_section}.ra_management" 2>/dev/null || true)
        
        if [ "${VPN_IPV6_FORCE_TAKEOVER:-0}" != "1" ]; then
            if [ -n "$old_ip6addr" ] && [ "$old_ip6addr" != "$gw_cidr" ]; then
                logger -t vpn-core "[$iface] Refusing routed-prefix RA takeover on $net_section/$downstream_iface (network.ip6addr already set)"
                return 1
            fi
        fi
        
        db_save_ra_state "$iface" "$downstream_iface" "$old_ip6addr" "$old_ip6class" "$old_ip6assign" "$old_ra" "$old_dhcpv6" "$old_ra_mgmt"
    fi
    
    uci set "network.${net_section}.ip6addr=${gw_cidr}"
    # Disable WAN PD inheritance on this downstream while routed-prefix mode is active.
    uci -q delete "network.${net_section}.ip6class" 2>/dev/null || true
    uci set "network.${net_section}.ip6assign=0"
    uci set "dhcp.${dhcp_section}=dhcp"
    uci set "dhcp.${dhcp_section}.interface=${net_section}"
    uci set "dhcp.${dhcp_section}.ra=server"
    uci set "dhcp.${dhcp_section}.dhcpv6=server"
    uci set "dhcp.${dhcp_section}.ra_management=1"
    uci commit network 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    ifup "$net_section" 2>/dev/null || true
    # Remove any stale global prefixes that are not the routed-prefix gateway.
    ip -6 addr show dev "$downstream_iface" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | while read -r cidr; do
        [ -z "$cidr" ] && continue
        [ "$cidr" = "$gw_cidr" ] && continue
        ip -6 addr del "$cidr" dev "$downstream_iface" 2>/dev/null || true
    done
    ip -6 addr show dev "$downstream_iface" 2>/dev/null | grep -q "$gw_cidr" || \
        ip -6 addr add "$gw_cidr" dev "$downstream_iface" 2>/dev/null || true
    # Ensure return-path to delegated clients resolves to downstream, not WG.
    # Some providers ship WG /64 addresses that can create competing connected routes.
    ip -6 route replace "$prefix" dev "$downstream_iface" metric "$route_metric" 2>/dev/null || true
    "$VPN_DNSMASQ_SERVICE" restart 2>/dev/null || true
    /etc/init.d/odhcpd restart 2>/dev/null || true
    return 0
}

_vpn_core_restore_routed_prefix_ra() {
    local iface="$1"
    local profile
    local mode=""
    local prefix=""
    local downstream=""
    local state=""
    local old_ip6addr="" old_ip6class="" old_ip6assign="" old_ra="" old_dhcpv6="" old_ra_mgmt=""
    local route_metric="${VPN_IPV6_ROUTED_DOWNSTREAM_METRIC:-64}"
    local net_section=""
    local dhcp_section=""
    
    profile=$(db_get_ipv6_profile "$iface" 2>/dev/null || true)
    mode=$(echo "$profile" | cut -d'|' -f1)
    prefix=$(echo "$profile" | cut -d'|' -f2)
    downstream=$(echo "$profile" | cut -d'|' -f3)
    
    _vpn_core_is_routed_prefix_mode "$mode" || return 0
    [ -n "$downstream" ] || return 0
    net_section=$(uci -q show network 2>/dev/null | awk -F. -v dev="$downstream" '
        $1=="network" && $3 ~ /^ifname=/ {
            val=$3
            sub(/^ifname='\''/,"",val); sub(/'\''$/,"",val)
            if (val==dev) { print $2; exit }
        }
        $1=="network" && $3 ~ /^device=/ {
            val=$3
            sub(/^device='\''/,"",val); sub(/'\''$/,"",val)
            if (val==dev) { print $2; exit }
        }')
    [ -n "$net_section" ] || return 0
    dhcp_section="$net_section"
    
    state=$(db_get_ra_state "$iface" "$downstream")
    [ -n "$state" ] || return 0
    
    old_ip6addr=$(echo "$state" | cut -d'|' -f3)
    old_ip6class=$(echo "$state" | cut -d'|' -f4)
    old_ip6assign=$(echo "$state" | cut -d'|' -f5)
    old_ra=$(echo "$state" | cut -d'|' -f6)
    old_dhcpv6=$(echo "$state" | cut -d'|' -f7)
    old_ra_mgmt=$(echo "$state" | cut -d'|' -f8)
    
    if [ -n "$old_ip6addr" ]; then
        uci set "network.${net_section}.ip6addr=${old_ip6addr}"
        ip -6 addr show dev "$downstream" 2>/dev/null | grep -q "$old_ip6addr" || \
            ip -6 addr add "$old_ip6addr" dev "$downstream" 2>/dev/null || true
    else
        uci -q delete "network.${net_section}.ip6addr" 2>/dev/null || true
        local current_gw
        current_gw=$( _vpn_core_routed_prefix_gateway_cidr "$prefix" )
        ip -6 addr del "$current_gw" dev "$downstream" 2>/dev/null || true
    fi
    if [ -n "$old_ip6class" ]; then
        uci set "network.${net_section}.ip6class=${old_ip6class}"
    else
        uci -q delete "network.${net_section}.ip6class" 2>/dev/null || true
    fi
    if [ -n "$old_ip6assign" ]; then
        uci set "network.${net_section}.ip6assign=${old_ip6assign}"
    else
        uci -q delete "network.${net_section}.ip6assign" 2>/dev/null || true
    fi
    if [ -n "$old_ra" ]; then
        uci set "dhcp.${dhcp_section}.ra=${old_ra}"
    else
        uci -q delete "dhcp.${dhcp_section}.ra" 2>/dev/null || true
    fi
    if [ -n "$old_dhcpv6" ]; then
        uci set "dhcp.${dhcp_section}.dhcpv6=${old_dhcpv6}"
    else
        uci -q delete "dhcp.${dhcp_section}.dhcpv6" 2>/dev/null || true
    fi
    if [ -n "$old_ra_mgmt" ]; then
        uci set "dhcp.${dhcp_section}.ra_management=${old_ra_mgmt}"
    else
        uci -q delete "dhcp.${dhcp_section}.ra_management" 2>/dev/null || true
    fi
    
    uci commit network 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    ifup "$net_section" 2>/dev/null || true
    # Remove routed-prefix return-path override installed during apply.
    [ -n "$prefix" ] && ip -6 route del "$prefix" dev "$downstream" metric "$route_metric" 2>/dev/null || true
    "$VPN_DNSMASQ_SERVICE" restart 2>/dev/null || true
    /etc/init.d/odhcpd restart 2>/dev/null || true
    db_delete_ra_state "$iface" "$downstream"
    _vpn_core_clear_routed_prefix_guard "$iface"
}

_vpn_core_verify_routed_prefix() {
    local iface="$1"
    local table="$2"
    local prefix="$3"
    local downstream="$4"
    local gw_cidr=""
    local gw_addr=""
    local src_rule_prio=48
    local retry=0
    local max_retry="${VPN_IPV6_ROUTED_VERIFY_RETRIES:-3}"
    local timeout_sec="${VPN_IPV6_ROUTED_VERIFY_TIMEOUT_SEC:-5}"
    local probe="${VPN_IPV6_ROUTED_PROBE_ADDR:-2606:4700:4700::1111}"
    local ping_cmd=""
    
    [ -n "$iface" ] && [ -n "$prefix" ] && [ -n "$downstream" ] || return 1
    gw_cidr=$(_vpn_core_routed_prefix_gateway_cidr "$prefix")
    gw_addr="${gw_cidr%/*}"
    
    if command -v ping >/dev/null 2>&1; then
        ping_cmd="ping -6"
    elif command -v ping6 >/dev/null 2>&1; then
        ping_cmd="ping6"
    else
        return 1
    fi
    
    while [ "$retry" -lt "$max_retry" ]; do
        ip -6 addr show dev "$iface" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2; exit}' | grep -q . || {
            retry=$((retry + 1))
            sleep 1
            continue
        }
        ip -6 addr show dev "$downstream" 2>/dev/null | grep -q "$gw_cidr" || {
            retry=$((retry + 1))
            sleep 1
            continue
        }
        ip -6 rule add from "${gw_addr}/128" table "$table" priority "$src_rule_prio" 2>/dev/null || true
        if $ping_cmd -c 1 -W "$timeout_sec" -I "$gw_addr" "$probe" >/dev/null 2>&1; then
            ip -6 rule del from "${gw_addr}/128" table "$table" priority "$src_rule_prio" 2>/dev/null || true
            return 0
        fi
        ip -6 rule del from "${gw_addr}/128" table "$table" priority "$src_rule_prio" 2>/dev/null || true
        retry=$((retry + 1))
        sleep 1
    done
    
    return 1
}

_vpn_core_apply_ipv6_profile() {
    local iface="$1"
    local table=""
    local profile=""
    local mode="" prefix="" downstream="" health="" reason=""
    
    profile=$(db_get_ipv6_profile "$iface" 2>/dev/null || true)
    mode=$(echo "$profile" | cut -d'|' -f1)
    prefix=$(echo "$profile" | cut -d'|' -f2)
    downstream=$(echo "$profile" | cut -d'|' -f3)
    table=$(db_get_field "$iface" "routing_table")
    
    _vpn_core_is_routed_prefix_mode "$mode" || {
        _vpn_core_clear_routed_prefix_guard "$iface"
        return 0
    }
    
    if ! _vpn_core_apply_routed_prefix_ra "$iface" "$downstream" "$prefix"; then
        db_set_ipv6_health "$iface" "degraded" "ra-ownership-failed"
        _vpn_core_apply_routed_prefix_guard "$iface" "$table" "$prefix" "$downstream" 1 2>/dev/null || true
        return 1
    fi
    
    if _vpn_core_verify_routed_prefix "$iface" "$table" "$prefix" "$downstream"; then
        _vpn_core_apply_routed_prefix_guard "$iface" "$table" "$prefix" "$downstream" 0
        db_set_ipv6_health "$iface" "ok" ""
        return 0
    fi
    
    _vpn_core_apply_routed_prefix_guard "$iface" "$table" "$prefix" "$downstream" 1 2>/dev/null || true
    db_set_ipv6_health "$iface" "degraded" "verification-failed"
    return 1
}

# === LIFECYCLE FUNCTIONS ===

vpn_core_init() {
    local iface="$1"
    local type="$2"
    local config="$3"
    local table="$4"
    local targets="$5"
    local dns="${6:-}"
    vpn_core_run_hooks pre_init "$iface" || return 1
    db_init 2>/dev/null || true
    db_stage_interface "$iface" "$type" "$config" "$table" "$targets" "$dns"
    vpn_core_run_hooks post_init "$iface"
    return 0
}

vpn_core_configure() {
    local iface="$1"
    local table="$2"
    local targets="$3"
    local dns="$4"
    local ipv6="${5:-0}"
    local ip6_subnets="${6:-}"
    local nat66="${7:-0}"
    local ipv6_mode="${8:-${VPN_IPV6_MODE_DEFAULT:-nat66}}"
    local ipv6_routed_prefix="${9:-}"
    local ipv6_downstream_iface="${10:-}"
    vpn_core_run_hooks pre_configure "$iface" || return 1
    pbr_setup "$iface" "$table" "$targets" "$dns" "$ipv6" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface"
    vpn_core_create_killswitch "$iface"
    db_set_ipv6 "$iface" "$ipv6" "$ip6_subnets" "$nat66"
    db_set_ipv6_profile "$iface" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface"
    db_set_ipv6_health "$iface" "unknown" ""
    vpn_core_run_hooks post_configure "$iface"
    return 0
}

vpn_core_stage_assets() {
    local iface="$1"
    local table="$2"
    local targets="$3"
    local dns="$4"
    local ipv6="${5:-0}"
    local ip6_subnets="${6:-}"
    local nat66="${7:-0}"
    local ipv6_mode="${8:-${VPN_IPV6_MODE_DEFAULT:-nat66}}"
    local ipv6_routed_prefix="${9:-}"
    local ipv6_downstream_iface="${10:-}"
    
    # Check if this is a split-tunnel interface
    local domains=$(db_get_field "$iface" "domains")
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        # Split-Tunnel Mode
        if type split_tunnel_generate_hotplug >/dev/null 2>&1; then
            split_tunnel_generate_hotplug "$iface" "$table" "$domains" "$dns" "$ipv6"
        else
            # Try to source the library if function missing
             local SPLIT_LIB="$LIB_DIR/split-tunnel.sh"
             if [ -f "$SPLIT_LIB" ]; then
                . "$SPLIT_LIB"
                split_tunnel_generate_hotplug "$iface" "$table" "$domains" "$dns" "$ipv6"
             else
                echo "Error: split-tunnel.sh not found, cannot generate hotplug for $iface"
                return 1
             fi
        fi
        # Split hotplug handles both ifup/fw-reload and ifdown cleanup.
    else
        # Standard Mode
        vpn_core_generate_ifup_script "$iface" "$table" "$targets" "$dns" "$ipv6" "$ip6_subnets" "$nat66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface"
        vpn_core_generate_ifdown_script "$iface" "$table" "$targets"
    fi
    return 0
}

vpn_core_start() {
    local iface="$1"
    local table="$2"
    local targets="$3"
    local dns="$4"
    local ipv6="${5:-0}"
    local ip6_subnets="${6:-}"
    local nat66="${7:-0}"
    local ipv6_mode="${8:-${VPN_IPV6_MODE_DEFAULT:-nat66}}"
    local ipv6_routed_prefix="${9:-}"
    local ipv6_downstream_iface="${10:-}"
    vpn_core_run_hooks pre_start "$iface" || return 1
    
    vpn_core_stage_assets "$iface" "$table" "$targets" "$dns" "$ipv6" "$ip6_subnets" "$nat66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || return 1
    vpn_core_setup_dhcp_handling
    if vpn_core_setup_dnsmasq_hook; then
        "$VPN_DNSMASQ_SERVICE" restart 2>/dev/null || echo "Warning: dnsmasq restart failed"
    fi
    
    db_set_running "$iface" 1
    db_commit_interface "$iface"
    _vpn_core_apply_ipv6_profile "$iface" 2>/dev/null || true
    vpn_core_run_hooks post_start "$iface"
    return 0
}

vpn_core_stop() {
    local iface="$1"
    vpn_core_run_hooks pre_stop "$iface" || return 1
    local targets=$(db_get_field "$iface" "target_ips")
    vpn_core_enable_killswitch "$iface" "$targets"
    db_set_running "$iface" 0
    vpn_core_run_hooks post_stop "$iface"
    return 0
}

vpn_core_teardown() {
    local iface="$1"
    vpn_core_run_hooks pre_teardown "$iface" || return 1
    local table=$(db_get_field "$iface" "routing_table")
    local targets=$(db_get_field "$iface" "target_ips")
    local domains=$(db_get_field "$iface" "domains")
    local dns=$(db_get_field "$iface" "dns_servers")
    local ipv6=$(db_get_field "$iface" "ipv6_support")
    local ipset_name="vpn_${iface}"
    local mark=$((0x10000 + table))
    if _vpn_core_is_split_mode "$domains"; then
        _vpn_core_cleanup_split_tunnel "$iface" "$table" "$dns" "${ipv6:-0}" 2>/dev/null || true
    else
        pbr_teardown "$iface" "$table" "$targets" "$ipset_name" "$mark" 2>/dev/null || true
    fi
    _vpn_core_cleanup_residual_artifacts "$iface" 2>/dev/null || true
    _vpn_core_restore_routed_prefix_ra "$iface" 2>/dev/null || true
    vpn_core_remove_killswitch "$iface"
    vpn_core_remove_hotplug_scripts "$iface"
    vpn_core_cleanup_uci "$iface"
    rm -f "${VPN_TMP_DIR}/discover_${iface}_"*.token 2>/dev/null || true
    db_delete_mac_state_for_interface "$iface"
    db_delete_interface "$iface"
    vpn_core_run_hooks post_teardown "$iface"
    return 0
}

vpn_core_up() {
    local iface="$1"
    local type="$2"
    local config="$3"
    local table="$4"
    local targets="$5"
    local dns="$6"
    local ipv6="${7:-0}"
    local ip6_subnets="${8:-}"
    local nat66="${9:-0}"
    local ipv6_mode="${10:-${VPN_IPV6_MODE_DEFAULT:-nat66}}"
    local ipv6_routed_prefix="${11:-}"
    local ipv6_downstream_iface="${12:-}"
    vpn_core_init "$iface" "$type" "$config" "$table" "$targets" "$dns" || return 1
    vpn_core_configure "$iface" "$table" "$targets" "$dns" "$ipv6" "$ip6_subnets" "$nat66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || return 1
    vpn_core_start "$iface" "$table" "$targets" "$dns" "$ipv6" "$ip6_subnets" "$nat66" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || return 1
    return 0
}

vpn_core_down() {
    local iface="$1"
    vpn_core_stop "$iface"
    vpn_core_teardown "$iface"
    return 0
}

vpn_core_delete() {
    local iface="$1"
    
    # 1. Validation
    if [ -z "$(db_get_interface "$iface" 2>/dev/null)" ]; then
        echo "Error: Interface '$iface' is not managed by this client."
        return 1
    fi
    
    echo "Deleting VPN interface: $iface"
    
    # 2. Stop interface if running
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "  Bringing down interface $iface..."
        ifdown "$iface" >/dev/null 2>&1 || true
        # Give it a second to run hotplug
        sleep 1
    fi
    
    # 3. Lifecycle Hooks
    vpn_core_run_hooks pre_delete "$iface"
    
    # 4. Teardown (Handles PBR, UCI, DB, Hotplugs)
    vpn_core_teardown "$iface"
    
    # 5. Force Link Deletion
    if ip link show "$iface" >/dev/null 2>&1; then
         echo "  Forcefully removing kernel link $iface..."
         ip link delete "$iface" 2>/dev/null || true
    fi
    
    vpn_core_run_hooks post_delete "$iface"
    
    # Persist UCI cleanup changes from core + post-delete hooks.
    uci commit network 2>/dev/null || true
    uci commit firewall 2>/dev/null || true
    
    echo "Done - $iface deleted and cleaned up"
    return 0
}

vpn_core_reload_targets() {
    local iface="$1"
    local new_targets="$2"
    local ipset_name="vpn_${iface}"
    ipset flush "$ipset_name" 2>/dev/null
    for target in $(echo "$new_targets" | tr ',' ' '); do
        local actual_ip=$(get_ip_from_target "$target")
        ipset add "$ipset_name" "$actual_ip" 2>/dev/null
    done
    db_update_targets "$iface" "$new_targets"
}

_vpn_core_is_split_mode() {
    local domains="$1"
    [ -n "$domains" ] && [ "$domains" != "none" ]
}

_vpn_core_queue_deferred_targets() {
    local targets="$1"
    local deferred_file="$2"
    [ -z "$targets" ] && return 0
    [ "$targets" = "none" ] && return 0
    mkdir -p "$(dirname "$deferred_file")" 2>/dev/null || true
    for target in $(echo "$targets" | tr ',' ' '); do
        [ -z "$target" ] && continue
        [ "$target" = "none" ] && continue
        echo "$target" >> "$deferred_file"
    done
}

_vpn_core_apply_split_tunnel() {
    local iface="$1"
    local table="$2"
    local domains="$3"
    local dns="$4"
    local ipv6="${5:-0}"
    local split_lib="$LIB_DIR/split-tunnel.sh"
    
    if ! type split_tunnel_apply >/dev/null 2>&1; then
        [ -f "$split_lib" ] && . "$split_lib"
    fi
    
    if ! type split_tunnel_apply >/dev/null 2>&1; then
        echo "Error: split_tunnel_apply() is unavailable for $iface"
        return 1
    fi
    
    split_tunnel_apply "$iface" "$table" "$domains" "$dns" "$ipv6"
}

_vpn_core_cleanup_split_tunnel() {
    local iface="$1"
    local table="$2"
    local dns="$3"
    local ipv6="${4:-0}"
    local split_lib="$LIB_DIR/split-tunnel.sh"
    
    if ! type split_tunnel_cleanup >/dev/null 2>&1; then
        [ -f "$split_lib" ] && . "$split_lib"
    fi
    
    if type split_tunnel_cleanup >/dev/null 2>&1; then
        split_tunnel_cleanup "$iface" "$table" "$dns" "$ipv6"
    fi
}

_vpn_core_cleanup_residual_artifacts() {
    local iface="$1"
    local mark_chain="mark_${iface}"
    local split_chain="split_${iface}"
    local block_chain="${iface}_ipv6_block"
    local ipv4_only_chain="${iface}_ipv4_only_block"
    local dns_v6_chain="${iface}_v6_dns_in"
    local ks_chain="${iface}_killswitch"
    local nat66_chain="nat66_${iface}"
    local routed_guard_chain="${iface}_routed6_guard"
    local ipset_v4="vpn_${iface}"
    local ipset_v6="vpn6_${iface}"
    local split_v4="dst_vpn_${iface}"
    local split_v6="dst6_vpn_${iface}"
    
    iptables -w -t mangle -D PREROUTING -j "$mark_chain" 2>/dev/null || true
    ip6tables -w -t mangle -D PREROUTING -j "$mark_chain" 2>/dev/null || true
    iptables -w -t mangle -F "$mark_chain" 2>/dev/null || true
    ip6tables -w -t mangle -F "$mark_chain" 2>/dev/null || true
    iptables -w -t mangle -X "$mark_chain" 2>/dev/null || true
    ip6tables -w -t mangle -X "$mark_chain" 2>/dev/null || true
    
    iptables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null || true
    iptables -w -t mangle -F "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -F "$split_chain" 2>/dev/null || true
    iptables -w -t mangle -X "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -X "$split_chain" 2>/dev/null || true
    
    ip6tables -w -D FORWARD -j "$block_chain" 2>/dev/null || true
    ip6tables -w -F "$block_chain" 2>/dev/null || true
    ip6tables -w -X "$block_chain" 2>/dev/null || true
    
    ip6tables -w -D FORWARD -j "$ipv4_only_chain" 2>/dev/null || true
    ip6tables -w -D INPUT -j "$ipv4_only_chain" 2>/dev/null || true
    ip6tables -w -F "$ipv4_only_chain" 2>/dev/null || true
    ip6tables -w -X "$ipv4_only_chain" 2>/dev/null || true
    
    ip6tables -w -D INPUT -j "$dns_v6_chain" 2>/dev/null || true
    ip6tables -w -F "$dns_v6_chain" 2>/dev/null || true
    ip6tables -w -X "$dns_v6_chain" 2>/dev/null || true
    
    iptables -w -D FORWARD -j "$ks_chain" 2>/dev/null || true
    ip6tables -w -D FORWARD -j "$ks_chain" 2>/dev/null || true
    iptables -w -F "$ks_chain" 2>/dev/null || true
    ip6tables -w -F "$ks_chain" 2>/dev/null || true
    iptables -w -X "$ks_chain" 2>/dev/null || true
    ip6tables -w -X "$ks_chain" 2>/dev/null || true
    
    ip6tables -w -t nat -D POSTROUTING -j "$nat66_chain" 2>/dev/null || true
    ip6tables -w -t nat -F "$nat66_chain" 2>/dev/null || true
    ip6tables -w -t nat -X "$nat66_chain" 2>/dev/null || true
    ip6tables -w -D FORWARD -j "$routed_guard_chain" 2>/dev/null || true
    ip6tables -w -F "$routed_guard_chain" 2>/dev/null || true
    ip6tables -w -X "$routed_guard_chain" 2>/dev/null || true
    
    ipset flush "$ipset_v4" 2>/dev/null || true
    ipset destroy "$ipset_v4" 2>/dev/null || true
    ipset flush "$ipset_v6" 2>/dev/null || true
    ipset destroy "$ipset_v6" 2>/dev/null || true
    ipset flush "$split_v4" 2>/dev/null || true
    ipset destroy "$split_v4" 2>/dev/null || true
    ipset flush "$split_v6" 2>/dev/null || true
    ipset destroy "$split_v6" 2>/dev/null || true
    
    rm -f "${VPN_TMP_DIR}/${iface}-split-dnsmasq.conf" 2>/dev/null
    rm -f "${VPN_TMP_DIR}/${iface}-split-dnsmasq.pid" 2>/dev/null
    rm -f "/tmp/dnsmasq.d/${iface}-split-stub.conf" 2>/dev/null
    rm -f "${VPN_TMP_DIR}/prefix_${iface}_"* 2>/dev/null
    rm -f "${VPN_TMP_DIR}/ip_${iface}_"* 2>/dev/null
    rm -f "/tmp/dnsmasq.d/99-${iface}-dns.conf" 2>/dev/null
}

_vpn_core_replay_deferred_dhcp() {
    local deferred_file="$1"
    [ -f "$deferred_file" ] || return 0
    [ -s "$deferred_file" ] || { rm -f "$deferred_file"; return 0; }
    [ -x "$MASTER_DHCP_HOTPLUG" ] || { rm -f "$deferred_file"; return 0; }
    
    # Shared seen file across all targets to prevent double-replay when a
    # client IP appears both inside a subnet target and as an individual target.
    local seen_file="${VPN_TMP_DIR}/deferred_replay_${$}.seen"
    touch "$seen_file" 2>/dev/null || true

    sort -u "$deferred_file" | while IFS= read -r target; do
        [ -z "$target" ] && continue
        
        # If target is a subnet, expand using DHCP leases and neighbor table
        # so MAC-based IPv6 rules apply even for static clients.
        if echo "$target" | grep -q "/"; then
            local lease_file
            lease_file=$(get_dhcp_lease_file 2>/dev/null || true)
            if [ -n "$lease_file" ] && [ -f "$lease_file" ]; then
                while read -r _exp mac ip _rest; do
                    [ -z "$mac" ] && continue
                    [ -z "$ip" ] && continue
                    [ "$mac" = "<incomplete>" ] && continue
                    if is_in_subnet "$ip" "$target" 2>/dev/null; then
                        if ! grep -Fq "${mac}|${ip}" "$seen_file" 2>/dev/null; then
                            echo "${mac}|${ip}" >> "$seen_file"
                        else
                            continue
                        fi
                        logger -t vpn-core "Replaying deferred DHCP subnet $target for $ip ($mac)"
                        ACTION="add" MACADDR="$mac" IPADDR="$ip" "$MASTER_DHCP_HOTPLUG" </dev/null 2>/dev/null || true
                    fi
                done < "$lease_file"
            fi
            
            # Neighbor table fallback (static clients without DHCP leases).
            if command -v ip >/dev/null 2>&1; then
                ip neigh show 2>/dev/null | awk '$4=="lladdr" {print $1,$5,$6}' | while read -r ip mac state; do
                    [ -z "$mac" ] && continue
                    [ -z "$ip" ] && continue
                    case "$state" in
                        INCOMPLETE|FAILED) continue ;;
                    esac
                    if is_in_subnet "$ip" "$target" 2>/dev/null; then
                        if ! grep -Fq "${mac}|${ip}" "$seen_file" 2>/dev/null; then
                            echo "${mac}|${ip}" >> "$seen_file"
                            logger -t vpn-core "Replaying deferred neighbor subnet $target for $ip ($mac)"
                            ACTION="add" MACADDR="$mac" IPADDR="$ip" "$MASTER_DHCP_HOTPLUG" </dev/null 2>/dev/null || true
                        fi
                    fi
                done
            fi
            continue
        fi
        
        local ip=""
        local mac=""
        
        if type is_mac >/dev/null 2>&1 && is_mac "$target"; then
            mac=$(normalize_mac "$target" 2>/dev/null || echo "$target")
            if type resolve_mac_to_ip >/dev/null 2>&1; then
                ip=$(resolve_mac_to_ip "$mac" 2>/dev/null || true)
            fi
        else
            ip=$(get_ip_from_target "$target")
            case "$target" in
                *=*) mac="${target%%=*}" ;;
                *)
                    if type discover_mac_for_ip >/dev/null 2>&1; then
                        mac=$(discover_mac_for_ip "$ip" 1 2>/dev/null || true)
                    fi
                    [ -z "$mac" ] && mac=$(ip neigh show "$ip" 2>/dev/null | awk '{print $5}' | head -1)
                    ;;
            esac
        fi
        
        case "$ip" in
            ""|*/*) continue ;;
        esac
        
        [ -n "$mac" ] || continue
        [ "$mac" = "<incomplete>" ] && continue
        
        # Skip if already replayed by a subnet expansion above.
        if grep -Fq "${mac}|${ip}" "$seen_file" 2>/dev/null; then
            continue
        fi
        echo "${mac}|${ip}" >> "$seen_file"
        
        logger -t vpn-core "Replaying deferred DHCP target $ip ($mac)"
        ACTION="add" MACADDR="$mac" IPADDR="$ip" "$MASTER_DHCP_HOTPLUG" </dev/null 2>/dev/null || true
    done
    
    rm -f "$seen_file" 2>/dev/null || true
    rm -f "$deferred_file"
}

vpn_core_commit() {
    vpn_core_run_hooks pre_commit || return 1
    db_init 2>/dev/null || true
    
    local staged_list
    staged_list=$(db_list_staged)
    if [ -z "$staged_list" ]; then
        echo "No staged configurations found."
        return 0
    fi
    
    local actionable
    actionable=$(echo "$staged_list" | awk -F'|' '$6 == "0" || $7 == "1" { print 1; exit }')
    if [ -z "$actionable" ]; then
        echo "No staged configurations found."
        return 0
    fi
    
    echo "Committing staged configurations..."
    
    local new_ifaces_file="${VPN_TMP_DIR}/new_ifaces.tmp"
    local hot_reload_file="${VPN_TMP_DIR}/hot_reload_ifaces.tmp"
    local split_file="${VPN_TMP_DIR}/split_ifaces.tmp"
    local ipv6_profile_file="${VPN_TMP_DIR}/ipv6_profile_ifaces.tmp"
    local deferred_file="${VPN_TMP_DIR}/deferred_dhcp.tmp"
    local dnsmasq_restart_needed=0
    
    rm -f "$new_ifaces_file" "$hot_reload_file" "$split_file" "$ipv6_profile_file" "$deferred_file"
    
    # Pass 1: target-IP interfaces first so split mode can safely RETURN on VPN source sets.
    while IFS='|' read -r iface type conf rt targets committed target_only domains; do
        [ -z "$iface" ] && continue
        _vpn_core_is_split_mode "$domains" && continue
        
        local dns
        dns=$(db_get_field "$iface" "dns_servers")
        
        if [ "$committed" = "1" ] && [ "$target_only" = "1" ]; then
            echo "Hot-reloading targets for $iface..."
            if type pbr_hot_reload >/dev/null 2>&1; then
                pbr_hot_reload "$iface" "$targets" "$rt" "$dns" </dev/null || echo "Warning: target hot-reload failed for $iface"
            else
                vpn_core_reload_targets "$iface" "$targets" </dev/null
            fi
            db_set_target_only "$iface" 0
            _vpn_core_queue_deferred_targets "$targets" "$deferred_file"
            echo "$iface" >> "$hot_reload_file"
            echo "$iface" >> "$ipv6_profile_file"
        elif [ "$committed" != "1" ]; then
            db_commit_interface "$iface"
            _vpn_core_queue_deferred_targets "$targets" "$deferred_file"
            echo "$iface" >> "$new_ifaces_file"
            echo "$iface" >> "$ipv6_profile_file"
        fi
    done <<EOF
$staged_list
EOF
    
    # Pass 2: split-tunnel interfaces.
    while IFS='|' read -r iface type conf rt targets committed target_only domains; do
        [ -z "$iface" ] && continue
        _vpn_core_is_split_mode "$domains" || continue
        
        local dns
        local ipv6
        dns=$(db_get_field "$iface" "dns_servers")
        ipv6=$(db_get_field "$iface" "ipv6_support")
        
        if [ "$committed" = "1" ] && [ "$target_only" = "1" ]; then
            echo "Hot-reloading domains for $iface..."
            if _vpn_core_apply_split_tunnel "$iface" "$rt" "$domains" "$dns" "${ipv6:-0}" </dev/null; then
                db_set_target_only "$iface" 0
                echo "$iface" >> "$split_file"
                echo "$iface" >> "$ipv6_profile_file"
                dnsmasq_restart_needed=1
            else
                echo "Warning: split hot-reload failed for $iface"
            fi
        elif [ "$committed" != "1" ]; then
            echo "Applying split-tunnel for $iface..."
            if _vpn_core_apply_split_tunnel "$iface" "$rt" "$domains" "$dns" "${ipv6:-0}" </dev/null; then
                db_commit_interface "$iface"
                echo "$iface" >> "$new_ifaces_file"
                echo "$iface" >> "$split_file"
                echo "$iface" >> "$ipv6_profile_file"
                dnsmasq_restart_needed=1
            else
                echo "Warning: split apply failed for $iface"
            fi
        fi
    done <<EOF
$staged_list
EOF
    
    if [ -f "$new_ifaces_file" ] && [ -s "$new_ifaces_file" ]; then
        uci commit network
        uci commit firewall
        
        for iface in $(sort -u "$new_ifaces_file"); do
            [ -z "$iface" ] && continue
            echo "Bringing up $iface..."
            if ifup "$iface"; then
                db_set_running "$iface" 1
            else
                echo "Warning: failed to bring up $iface"
            fi
        done
    fi
    
    vpn_core_setup_dhcp_handling
    
    if vpn_core_setup_dnsmasq_hook; then
        dnsmasq_restart_needed=1
    fi
    
    if [ "$dnsmasq_restart_needed" = "1" ]; then
        "$VPN_DNSMASQ_SERVICE" restart 2>/dev/null || echo "Warning: dnsmasq restart failed"
    fi
    
    if [ -f "$ipv6_profile_file" ] && [ -s "$ipv6_profile_file" ]; then
        for iface in $(sort -u "$ipv6_profile_file"); do
            [ -z "$iface" ] && continue
            _vpn_core_apply_ipv6_profile "$iface" 2>/dev/null || true
        done
    fi
    
    _vpn_core_replay_deferred_dhcp "$deferred_file"
    
    rm -f "$new_ifaces_file" "$hot_reload_file" "$split_file" "$ipv6_profile_file"
    
    vpn_core_run_hooks post_commit
    echo "Commit complete."
    return 0
}

vpn_core_reapply() {
    echo "Re-applying firewall rules..."
    local running=$(db_list_running)
    for iface in $running; do
        local routing_script="$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-routing"
        local split_script="$HOTPLUG_IFACE_DIR/99-${VPN_PREFIX}-${iface}-split"
        if [ -f "$routing_script" ] && [ -x "$routing_script" ]; then
            echo "Re-applying: $iface"
            ACTION="fw-reload" INTERFACE="$iface" "$routing_script" 2>/dev/null || \
                echo "Warning: Failed to re-apply rules for $iface"
            _vpn_core_apply_ipv6_profile "$iface" 2>/dev/null || true
            vpn_core_run_hooks fw_reload "$iface"
        elif [ -f "$split_script" ] && [ -x "$split_script" ]; then
            echo "Re-applying: $iface"
            ACTION="fw-reload" INTERFACE="$iface" "$split_script" 2>/dev/null || \
                echo "Warning: Failed to re-apply split rules for $iface"
            _vpn_core_apply_ipv6_profile "$iface" 2>/dev/null || true
            vpn_core_run_hooks fw_reload "$iface"
        fi
    done
}

# === DHCP EVENT HANDLING ===

# Build per-client discovery token path used to invalidate stale IPv6 discovery workers.
_vpn_core_discovery_token_file() {
    local iface="$1"
    local mac="$2"
    local mac_clean
    mac_clean=$(echo "$mac" | tr 'A-F' 'a-f' | tr -d ':')
    echo "${VPN_TMP_DIR}/discover_${iface}_${mac_clean}.token"
}

# Discover and route client global IPv6 addresses (port of legacy apply_ipv6_rules)
# This handles the case where clients use global IPv6 addresses from the VPN subnet
# but aren't explicitly registered as targets.
# Args: $1=iface, $2=rt, $3=mac, $4=ipv6_subnets, $5=nat66 (0/1)
vpn_core_discover_client_ipv6() {
    local iface="$1"
    local rt="$2"
    local mac="$3"
    local subnets="$4"
    local nat66="${5:-0}"
    local token_file=""
    local run_id=""
    
    [ -z "$subnets" ] && return 0

    if type normalize_mac >/dev/null 2>&1; then
        mac=$(normalize_mac "$mac" 2>/dev/null || echo "$mac" | tr 'A-F' 'a-f')
    else
        mac=$(echo "$mac" | tr 'A-F' 'a-f')
    fi
    token_file=$(_vpn_core_discovery_token_file "$iface" "$mac")
    run_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-$(date +%s)")
    echo "$run_id" > "$token_file"
    
    logger -t vpn-core "[$iface] Starting IPv6 discovery for $mac"
    
    # Run in background to avoid blocking DHCP handler
    (
        trap '
            current_run=$(cat "$token_file" 2>/dev/null || true)
            [ "$current_run" = "$run_id" ] && rm -f "$token_file"
        ' EXIT
        local max_retries=45
        local retry=0
        local mac_key
        mac_key=$(echo "$mac" | tr -d ':')
        local state_file="$VPN_TMP_DIR/prefix_${iface}_${mac_key}"
        local ipset_v6="vpn6_${iface}"
        
        while [ $retry -lt $max_retries ]; do
            # Abort stale workers if this MAC is no longer mapped to this interface.
            local current_run
            current_run=$(cat "$token_file" 2>/dev/null || true)
            [ "$current_run" = "$run_id" ] || exit 0
            local map_state
            map_state=$(db_get_mac_by_mac "$mac" 2>/dev/null || true)
            local map_iface
            map_iface=$(echo "$map_state" | cut -d'|' -f2)
            [ "$map_iface" = "$iface" ] || exit 0

            sleep 2
            # Find global IPv6 addresses for this MAC in neighbor table
            local ipv6_addrs=$(ip -6 neigh show | grep -i "$mac" | grep -v "fe80:" | awk '{print $1}')
            
            if [ -n "$ipv6_addrs" ]; then
                for ipv6_addr in $ipv6_addrs; do
                    local matched_subnet=""
                    for subnet in $subnets; do
                        [ "$subnet" = "::/0" ] && { matched_subnet="::/0"; break; }
                        
                        local prefix_len="${subnet##*/}"
                        local network="${subnet%/*}"
                        
                        # Dynamic prefix matching
                        local hex_count=$((prefix_len / 16))
                        local rem=$((prefix_len % 16))
                        [ $rem -gt 0 ] && hex_count=$((hex_count + 1))
                        
                        # More robust prefix extraction: handle compressed zeros and leading/trailing colons
                        local vpn_prefix=$(echo "$network" | sed 's/::/:0:0:0:0:0:0:/g' | cut -d: -f1-$hex_count)
                        local client_prefix=$(echo "$ipv6_addr" | sed 's/::/:0:0:0:0:0:0:/g' | cut -d: -f1-$hex_count)
                        
                        if [ -n "$vpn_prefix" ] && [ "$vpn_prefix" = "$client_prefix" ]; then
                            matched_subnet="$subnet"
                            break
                        fi
                    done
                    
                    # If NAT66 is active, we can be more permissive if no specific subnet matched.
                    # (Fallback to routing any discovered global IP if the interface supports IPv6)
                    if [ -z "$matched_subnet" ] && [ "$nat66" = "1" ] && [ -n "$ipv6_addr" ]; then
                        matched_subnet="auto"
                    fi
                    
                    if [ -n "$matched_subnet" ]; then
                        # Re-check mapping right before adding to avoid roam races.
                        current_run=$(cat "$token_file" 2>/dev/null || true)
                        [ "$current_run" = "$run_id" ] || exit 0
                        map_state=$(db_get_mac_by_mac "$mac" 2>/dev/null || true)
                        map_iface=$(echo "$map_state" | cut -d'|' -f2)
                        [ "$map_iface" = "$iface" ] || exit 0

                        local new_rule="${ipv6_addr}/128"
                        
                        # Check if rule already exists to avoid log spam/redundant calls
                        if ! ip -6 rule show | grep -q "$new_rule"; then
                            logger -t vpn-core "[$iface] Routing client IPv6 $new_rule (matched $matched_subnet)"
                            ip -6 rule add from "$new_rule" lookup "$rt" priority "$rt" 2>/dev/null
                            
                            # Also add to ipset for firewall marking/matching
                            ipset add "$ipset_v6" "$ipv6_addr" 2>/dev/null
                            
                            if ! grep -q "$new_rule" "$state_file" 2>/dev/null; then
                                echo "$new_rule" >> "$state_file"
                            fi
                        fi
                    fi
                done
            fi
            retry=$((retry + 1))
        done
        logger -t vpn-core "[$iface] IPv6 discovery finished for $mac"
    ) &
}

vpn_core_find_interface_for_ip() {
    local ipaddr="$1"
    local interfaces=$(db_list_registry_entries)
    echo "$interfaces" | while IFS='|' read -r name rt targets ipv6 subs nat66 start; do
        [ -z "$name" ] && continue
        local targets_spaced=$(echo "$targets" | tr ',' ' ')
        if is_in_list "$ipaddr" "$targets_spaced"; then
            echo "$name|$rt|$(db_get_field "$name" "dns_servers")|$ipv6|$nat66|$(db_get_field "$name" "ipv6_mode")"
            return 0
        fi
    done
    return 1
}

_vpn_core_tunnel_is_up() {
    local iface="$1"
    ip link show "$iface" >/dev/null 2>&1 || return 1
    ip link show "$iface" 2>/dev/null | grep -q "state DOWN" && return 1
    return 0
}

_vpn_core_apply_tunnel_down_killswitch() {
    local iface="$1"
    local ip="$2"
    local mac="$3"
    local ks_chain="${iface}_killswitch"
    
    iptables -w -N "$ks_chain" 2>/dev/null || true
    ip6tables -w -N "$ks_chain" 2>/dev/null || true
    iptables -w -C FORWARD -j "$ks_chain" 2>/dev/null || iptables -w -I FORWARD 1 -j "$ks_chain"
    ip6tables -w -C FORWARD -j "$ks_chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$ks_chain"
    
    iptables -w -D "$ks_chain" -s "$ip" -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
    ip6tables -w -D "$ks_chain" -m mac --mac-source "$mac" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
    
    iptables -w -A "$ks_chain" -s "$ip" -j REJECT --reject-with icmp-host-prohibited
    ip6tables -w -A "$ks_chain" -m mac --mac-source "$mac" -j REJECT --reject-with icmp6-adm-prohibited
}

_vpn_core_remove_client_killswitch() {
    local iface="$1"
    local ip="$2"
    local mac="$3"
    local ks_chain="${iface}_killswitch"
    iptables -w -D "$ks_chain" -s "$ip" -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
    ip6tables -w -D "$ks_chain" -m mac --mac-source "$mac" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
}

vpn_core_handle_dhcp() {
    local action="${ACTION:-}"
    local mac="${MACADDR:-}"
    local ip="${IPADDR:-}"
    [ "$action" = "add" ] || [ "$action" = "new" ] || [ "$action" = "old" ] || [ "$action" = "update" ] || return 0
    [ -n "$mac" ] && [ -n "$ip" ] || return 0

    if type normalize_mac >/dev/null 2>&1; then
        mac=$(normalize_mac "$mac" 2>/dev/null || echo "$mac" | tr 'A-F' 'a-f')
    else
        mac=$(echo "$mac" | tr 'A-F' 'a-f')
    fi
    
    local iface_data=$(vpn_core_find_interface_for_ip "$ip")
    local matched_iface="" matched_rt="" matched_dns="" matched_ipv6="" matched_nat66="" matched_ipv6_mode=""
    
    if [ -n "$iface_data" ]; then
        matched_iface=$(echo "$iface_data" | cut -d'|' -f1)
        matched_rt=$(echo "$iface_data" | cut -d'|' -f2)
        matched_dns=$(echo "$iface_data" | cut -d'|' -f3)
        matched_ipv6=$(echo "$iface_data" | cut -d'|' -f4)
        matched_nat66=$(echo "$iface_data" | cut -d'|' -f5)
        matched_ipv6_mode=$(echo "$iface_data" | cut -d'|' -f6)
    fi
    
    local old_state=$(db_get_mac_by_mac "$mac")
    local old_iface=$(echo "$old_state" | cut -d'|' -f2)
    local old_ip=$(echo "$old_state" | cut -d'|' -f3)
    local old_rt=$(echo "$old_state" | cut -d'|' -f4)
    
    # Cleanup stale rules before applying a new mapping.
    if [ -n "$old_iface" ] && { [ "$old_iface" != "$matched_iface" ] || [ -n "$old_ip" ] && [ "$old_ip" != "$ip" ]; }; then
        logger -t vpn-core "Client $mac roaming: $old_iface -> ${matched_iface:-direct}"
        [ -n "$old_ip" ] && pbr_remove_client "$old_iface" "$old_rt" "$old_ip" "$mac"
    fi
    
    if [ -z "$matched_iface" ]; then
        db_delete_mac_by_mac "$mac"
        ip route flush cache
        return 0
    fi
    
    if ! _vpn_core_tunnel_is_up "$matched_iface"; then
        logger -t vpn-core "[$matched_iface] Client $ip ($mac) detected while tunnel is down; enforcing kill switch."
        _vpn_core_apply_tunnel_down_killswitch "$matched_iface" "$ip" "$mac"
        db_set_mac_state "$mac" "$matched_iface" "$ip" "$matched_rt" "$matched_ipv6"
        ip route flush cache
        return 0
    fi
    
    _vpn_core_remove_client_killswitch "$matched_iface" "$ip" "$mac"
    
    logger -t vpn-core "[$matched_iface] Applying VPN routing for $ip ($mac)"
    local pbr_ipv6_flag="$matched_ipv6"
    _vpn_core_is_routed_prefix_mode "$matched_ipv6_mode" && pbr_ipv6_flag=0
    pbr_add_client "$matched_iface" "$matched_rt" "$ip" "$matched_dns" "$pbr_ipv6_flag"
    db_set_mac_state "$mac" "$matched_iface" "$ip" "$matched_rt" "$matched_ipv6"
    
    # Add MAC-based IPv6 fwmark for roaming support.
    # Ordering is block-first then mark to avoid brief leak windows.
    if [ "$matched_ipv6" = "1" ] && ! _vpn_core_is_routed_prefix_mode "$matched_ipv6_mode"; then
        local mark_chain="mark_${matched_iface}"
        local mark
        mark=$(calculate_mark "$matched_rt")
        local block_chain="${matched_iface}_ipv6_block"
        local table_name="${matched_iface}_rt"
        local client_lan_if=""
        local lan_ifaces
        lan_ifaces=$(get_lan_ifaces)
        client_lan_if=$(ip -4 route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [ -z "$client_lan_if" ] && client_lan_if=$(ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        
        # Ensure chains are present and connected.
        ip6tables -w -t mangle -N "$mark_chain" 2>/dev/null || true
        ip6tables -w -N "$block_chain" 2>/dev/null || true
        ip6tables -w -C FORWARD -j "$block_chain" 2>/dev/null || ip6tables -w -I FORWARD 1 -j "$block_chain"
        if [ -n "$client_lan_if" ]; then
            ip6tables -w -t mangle -C PREROUTING -i "$client_lan_if" -j "$mark_chain" 2>/dev/null || \
                ip6tables -w -t mangle -A PREROUTING -i "$client_lan_if" -j "$mark_chain"
        else
            for lan_if in $lan_ifaces; do
                ip6tables -w -t mangle -C PREROUTING -i "$lan_if" -j "$mark_chain" 2>/dev/null || \
                    ip6tables -w -t mangle -A PREROUTING -i "$lan_if" -j "$mark_chain"
            done
        fi

        # Keep local link and multicast traffic untouched.
        ip6tables -w -t mangle -C "$mark_chain" -d fe80::/10 -j RETURN 2>/dev/null || \
            ip6tables -w -t mangle -I "$mark_chain" 1 -d fe80::/10 -j RETURN
        ip6tables -w -t mangle -C "$mark_chain" -d ff00::/8 -j RETURN 2>/dev/null || \
            ip6tables -w -t mangle -I "$mark_chain" 2 -d ff00::/8 -j RETURN

        # Block first: drop unmarked traffic from this MAC.
        # Remove any old broad rules before adding scoped ones.
        for lan_if in $lan_ifaces; do
            while ip6tables -w -D "$block_chain" -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP 2>/dev/null; do :; done
        done
        if [ -n "$client_lan_if" ]; then
            ip6tables -w -I "$block_chain" 1 -i "$client_lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP
        else
            for lan_if in $lan_ifaces; do
                ip6tables -w -I "$block_chain" 1 -i "$lan_if" -m mac --mac-source "$mac" -m mark ! --mark "$mark" -j DROP
            done
        fi

        # Then mark traffic from this MAC.
        while ip6tables -w -t mangle -D "$mark_chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
        for lan_if in $lan_ifaces; do
            while ip6tables -w -t mangle -D "$mark_chain" -i "$lan_if" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; do :; done
        done
        if [ -n "$client_lan_if" ]; then
            if ! ip6tables -w -t mangle -C "$mark_chain" -i "$client_lan_if" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; then
                ip6tables -w -t mangle -A "$mark_chain" -i "$client_lan_if" -m mac --mac-source "$mac" -j MARK --set-mark "$mark"
                logger -t vpn-core "[$matched_iface] Added IPv6 fwmark for MAC $mac on $client_lan_if (roaming support)"
            fi
        elif ! ip6tables -w -t mangle -C "$mark_chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null; then
            ip6tables -w -t mangle -A "$mark_chain" -m mac --mac-source "$mac" -j MARK --set-mark "$mark"
            logger -t vpn-core "[$matched_iface] Added IPv6 fwmark for MAC $mac (roaming support)"
        fi
        
        if ! ip -6 rule show | grep -q "fwmark 0x$(printf '%x' "$mark") lookup $table_name"; then
            ip -6 rule add fwmark "$mark" table "$table_name" priority "$matched_rt" 2>/dev/null || true
        fi
        
        # Trigger dynamic IPv6 discovery.
        local vpn_ip6_subs
        vpn_ip6_subs=$(db_get_field "$matched_iface" "ipv6_subnets")
        vpn_core_discover_client_ipv6 "$matched_iface" "$matched_rt" "$mac" "$vpn_ip6_subs" "$matched_nat66"
    fi
    
    ip route flush cache
}
