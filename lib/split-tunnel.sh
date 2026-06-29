#!/bin/sh
# Route10 Split-Tunnel Library
# Handles configuration for Domain-Based Split-Tunneling
#
# This script is called by the protocol wrappers (wg.sh/ovpn.sh) when
# running in split-tunnel mode (-d/--domains).

# Source core library if not already sourced
if [ -z "$VPN_CORE_LOADED" ]; then
    SCRIPT_DIR="$(dirname "$0")"
    if [ -f "$SCRIPT_DIR/vpn-core.sh" ]; then
        . "$SCRIPT_DIR/vpn-core.sh"
    elif [ -f "$SCRIPT_DIR/../lib/vpn-core.sh" ]; then
        . "$SCRIPT_DIR/../lib/vpn-core.sh"
    fi
fi

# Log helper
log() {
    logger -t vpn-split-tunnel "[$INTERFACE] $1"
    echo "$1" >&2
}

# === MAIN ENTRY POINT ===

# Setup Split-Tunnel Interface
# Args: $1=interface, $2=config_file, $3=domains, $4=routing_table
split_tunnel_setup() {
    local interface="$1"
    local config="$2"
    local domains="$3"
    local table="$4"

    INTERFACE="$interface"
    
    log "Setting up Split-Tunnel for $interface..."
    log "Domains: $domains"
    log "Table: $table"

    # 1. Register in DB (Lifecycle: INIT)
    # Note: We pass 'none' for target_ips because this is domain-based
    # We pass 'split' as type (or store domains in a special field?)
    # vpn_core_init expects: iface, type, conf, table, targets, dns
    # We'll need to update DB to support domains or reuse a field.
    # For now, let's assume we use standard vpn_core_init but we might need to update 
    # the 'domains' field specifically if vpn_core_init doesn't handle it.
    
    # Parse config to get details
    # We need to detect protocol to parse correctly.
    # Assuming WireGuard for now since this was ported from wg-split-tunnel.sh.
    
    # For now, we'll delegate the actual config parsing back to the caller
    # OR we re-implement basic parsing here.

    # The legacy `wg-split-tunnel.sh` did everything including interface setup.
    # In this modular design, `vpn-core.sh` separates Lifecycle.
    # We should probably use `vpn_core` functions where possible.
    
    # BUT `vpn_core.sh`'s `vpn_core_configure` does PBR for IPs.
    # We need PBR for Domains.
    
    # Strategy:
    # 1. Initialize DB entry
    # 2. Setup Interface (IP link, addr, etc) - Generic or Protocol specific?
    # 3. Setup DNS (Stub + Dnsmasq)
    # 4. Setup Firewall
    # 5. Setup PBR (FWMark based on destination ipsets)
    # 6. Generate Hotplug
    
    # Let's start by just porting the core logic functions first.
}

# === DNS SETUP ===

setup_dns_stub() {
    local interface="$1"
    local domains="$2"
    local dns_port="$3"
    local v4_set="dst_vpn_${interface}"
    local v6_set="dst6_vpn_${interface}"

    # Ensure main dnsmasq includes /tmp/dnsmasq.d
    local confdir=$(uci -q get dhcp.@dnsmasq[0].confdir)
    if ! echo "$confdir" | grep -q "/tmp/dnsmasq.d"; then
         log "Configuring dnsmasq to include /tmp/dnsmasq.d..."
         uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
         uci commit dhcp
         SPLIT_TUNNEL_DNSMASQ_RESTART_REQUIRED=1
    fi

    mkdir -p "/tmp/dnsmasq.d"
    local stub_conf="/tmp/dnsmasq.d/${interface}-split-stub.conf"
    
    echo "# Auto-generated stub for $interface" > "$stub_conf"
    
    # Convert comma-separated domains to list
    local old_ifs="$IFS"
    IFS=","
    for entry in $domains; do
        # trim whitespace
        entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$entry" ] && continue
        
        # Forward to dedicated instance
        echo "server=/$entry/127.0.0.1#$dns_port" >> "$stub_conf"
        # Populate ipsets
        echo "ipset=/$entry/$v4_set,$v6_set" >> "$stub_conf"
    done
    IFS="$old_ifs"
}

# Keep split DNS ports stable within the configured routing table range.
calculate_split_dns_port() {
    local routing_table="$1"
    local range_start="${VPN_RT_START:-1000}"
    local base_port="${VPN_SPLIT_DNS_PORT_BASE:-5300}"
    local port=$((base_port + routing_table - range_start))
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        port=$((base_port + routing_table))
    fi
    echo "$port"
}

split_calculate_mark() {
    local table="$1"
    if command -v calculate_mark >/dev/null 2>&1; then
        calculate_mark "$table"
        return $?
    fi
    echo "$((0x10000 + table))"
}

start_dedicated_dnsmasq() {
    local interface="$1"
    local dns_servers="$2"
    local routing_table="$3"
    
    local dns_port
    dns_port=$(calculate_split_dns_port "$routing_table")
    
    local conf_dir="${VPN_TMP_DIR:-/tmp/${VPN_PREFIX}}"
    mkdir -p "$conf_dir"
    local ded_conf="${conf_dir}/${interface}-split-dnsmasq.conf"
    local ded_pid="${conf_dir}/${interface}-split-dnsmasq.pid"
    
    echo "# Dedicated Resolver for $interface" > "$ded_conf"
    echo "port=$dns_port" >> "$ded_conf"
    echo "bind-interfaces" >> "$ded_conf"
    echo "listen-address=127.0.0.1" >> "$ded_conf"
    echo "no-resolv" >> "$ded_conf"
    echo "no-hosts" >> "$ded_conf"
    
    # Upstream servers (bound to interface)
    for dns in $dns_servers; do
        echo "server=$dns@$interface" >> "$ded_conf"
    done
    
    # Cleanup old process
    if [ -f "$ded_pid" ]; then
        local old_pid=$(cat "$ded_pid")
        [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null && kill "$old_pid"
        rm -f "$ded_pid"
    fi
    
    # Check port conflict
    local port_pid=$(netstat -nlp 2>/dev/null | grep ":$dns_port " | awk '{print $NF}' | cut -d'/' -f1)
    [ -n "$port_pid" ] && kill "$port_pid"
    
    # Start
    if dnsmasq -C "$ded_conf" -x "$ded_pid"; then
        log "Dedicated dnsmasq started on port $dns_port"
        echo "$dns_port"
        return 0
    else
        log "Failed to start dedicated dnsmasq"
        return 1
    fi
}

# === PBR SETUP (Global Mode) ===

setup_split_pbr() {
    local interface="$1"
    local table="$2"
    local ipv6_supported="$3"
    local dns_servers="$4"
    
    local mark
    mark=$(split_calculate_mark "$table") || return 1
    local split_chain="split_${interface}"
    local v4_set="dst_vpn_${interface}"
    local v6_set="dst6_vpn_${interface}"
    
    # Create ipsets
    ipset create "$v4_set" hash:ip family inet 2>/dev/null || ipset flush "$v4_set"
    ipset create "$v6_set" hash:ip family inet6 2>/dev/null || ipset flush "$v6_set"
    
    # 1. Routing Table
    ip route flush table "$table" 2>/dev/null
    ip route add default dev "$interface" table "$table"
    
    if [ "$ipv6_supported" = "1" ]; then
        ip -6 route flush table "$table" 2>/dev/null
        ip -6 route add default dev "$interface" table "$table"
    fi
    
    # 2. IP Rules (mark based)
    ip rule del fwmark "$mark/$mark" table "$table" 2>/dev/null
    ip rule add fwmark "$mark/$mark" table "$table" priority 50
    
    if [ "$ipv6_supported" = "1" ]; then
        ip -6 rule del fwmark "$mark/$mark" table "$table" 2>/dev/null
        ip -6 rule add fwmark "$mark/$mark" table "$table" priority 50
    fi
    
    # 3. Mangle Chain
    iptables -w -t mangle -N "$split_chain" 2>/dev/null || iptables -w -t mangle -F "$split_chain"
    # Ensure chain is hooked
    iptables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null
    iptables -w -t mangle -I PREROUTING 1 -j "$split_chain"
    
    # Basic Flow:
    # 1. Skip return traffic
    iptables -w -t mangle -A "$split_chain" -i "$interface" -j RETURN
    
    # 2. Skip other VPN source sets to prevent cross-manager capture.
    # Exclude split destination sets (dst_vpn_*) from source bypass.
    for set in $(ipset list -n | grep '^vpn_' | grep -v '^dst_vpn_'); do
         iptables -w -t mangle -A "$split_chain" -m set --match-set "$set" src -j RETURN
    done

    # 3. Restore Mark
    iptables -w -t mangle -A "$split_chain" -m connmark --mark "$mark" -j CONNMARK --restore-mark
    iptables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j ACCEPT
    
    # 4. Mark destination ipset (The Core Split Tunnel Logic)
    iptables -w -t mangle -A "$split_chain" -m set --match-set "$v4_set" dst -j MARK --set-mark "$mark"
    
    # 5. Mark DNS queries to VPN DNS (so dedicated dnsmasq traffic goes thru tunnel)
    # Both PREROUTING (clients) and OUTPUT (router/dnsmasq itself)
    for dns in $dns_servers; do
        if ! echo "$dns" | grep -q ":"; then
             iptables -w -t mangle -A "$split_chain" -p udp -d "$dns" --dport 53 -j MARK --set-mark "$mark"
             iptables -w -t mangle -I OUTPUT 1 -p udp -d "$dns" --dport 53 -j MARK --set-mark "$mark"
        fi
    done

    # 6. Save Mark
    iptables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j CONNMARK --save-mark
    iptables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j ACCEPT
    
    # IPv6 Logic (Similar)
    if [ "$ipv6_supported" = "1" ]; then
        ip6tables -w -t mangle -N "$split_chain" 2>/dev/null || ip6tables -w -t mangle -F "$split_chain"
        ip6tables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null
        ip6tables -w -t mangle -I PREROUTING 1 -j "$split_chain"
        
        ip6tables -w -t mangle -A "$split_chain" -i "$interface" -j RETURN
        # Skip clients owned by any VPN manager (IPv6 source sets).
        for set in $(ipset list -n | grep '^vpn6_'); do
            ip6tables -w -t mangle -A "$split_chain" -m set --match-set "$set" src -j RETURN
        done
        # Skip clients by MAC detected in mark chains from both managers.
        for mac in $(ip6tables -w -t mangle -S 2>/dev/null | grep -E 'mark_ipv6_|mark_' | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | sort -u); do
            ip6tables -w -t mangle -A "$split_chain" -m mac --mac-source "$mac" -j RETURN
        done
        ip6tables -w -t mangle -A "$split_chain" -m connmark --mark "$mark" -j CONNMARK --restore-mark
        ip6tables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j ACCEPT
        ip6tables -w -t mangle -A "$split_chain" -m set --match-set "$v6_set" dst -j MARK --set-mark "$mark"
        
        ip6tables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j CONNMARK --save-mark
        ip6tables -w -t mangle -A "$split_chain" -m mark --mark "$mark" -j ACCEPT
    fi
}

split_tunnel_apply() {
    local interface="$1"
    local table="$2"
    local domains="$3"
    local dns_servers="$4"
    local ipv6_supported="${5:-0}"
    
    INTERFACE="$interface"
    dns_servers=$(echo "$dns_servers" | tr ',' ' ')
    
    local dns_port
    dns_port=$(start_dedicated_dnsmasq "$interface" "$dns_servers" "$table") || return 1
    [ -n "$dns_port" ] || return 1
    
    setup_dns_stub "$interface" "$domains" "$dns_port"
    setup_split_pbr "$interface" "$table" "$ipv6_supported" "$dns_servers"
    
    return 0
}

split_tunnel_cleanup() {
    local interface="$1"
    local table="$2"
    local dns_servers="${3:-}"
    local ipv6_supported="${4:-0}"
    local mark
    mark=$(split_calculate_mark "$table") || mark=$((0x10000 + table))
    local split_chain="split_${interface}"
    local v4_set="dst_vpn_${interface}"
    local v6_set="dst6_vpn_${interface}"
    local conf_dir="${VPN_TMP_DIR:-/tmp/${VPN_PREFIX}}"
    local ded_conf="${conf_dir}/${interface}-split-dnsmasq.conf"
    local ded_pid="${conf_dir}/${interface}-split-dnsmasq.pid"
    local stub_conf="/tmp/dnsmasq.d/${interface}-split-stub.conf"
    
    if [ -f "$ded_pid" ]; then
        local old_pid
        old_pid=$(cat "$ded_pid")
        [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
        rm -f "$ded_pid"
    fi
    rm -f "$ded_conf"
    
    iptables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -D PREROUTING -j "$split_chain" 2>/dev/null || true
    
    for dns in $(echo "$dns_servers" | tr ',' ' '); do
        [ -z "$dns" ] && continue
        if echo "$dns" | grep -q ":"; then
            while ip6tables -w -t mangle -D OUTPUT -p udp -d "$dns" --dport 53 -j MARK --set-mark "$mark" 2>/dev/null; do :; done
            while ip6tables -w -t mangle -D OUTPUT -p tcp -d "$dns" --dport 53 -j MARK --set-mark "$mark" 2>/dev/null; do :; done
        else
            while iptables -w -t mangle -D OUTPUT -p udp -d "$dns" --dport 53 -j MARK --set-mark "$mark" 2>/dev/null; do :; done
            while iptables -w -t mangle -D OUTPUT -p tcp -d "$dns" --dport 53 -j MARK --set-mark "$mark" 2>/dev/null; do :; done
        fi
    done
    
    iptables -w -t mangle -F "$split_chain" 2>/dev/null || true
    iptables -w -t mangle -X "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -F "$split_chain" 2>/dev/null || true
    ip6tables -w -t mangle -X "$split_chain" 2>/dev/null || true
    
    ip rule del fwmark "$mark/$mark" table "$table" 2>/dev/null || true
    ip -6 rule del fwmark "$mark/$mark" table "$table" 2>/dev/null || true
    
    ipset flush "$v4_set" 2>/dev/null || true
    ipset destroy "$v4_set" 2>/dev/null || true
    ipset flush "$v6_set" 2>/dev/null || true
    ipset destroy "$v6_set" 2>/dev/null || true
    
    rm -f "$stub_conf"
    
    if [ -x "$VPN_DNSMASQ_SERVICE" ]; then
        "$VPN_DNSMASQ_SERVICE" restart >/dev/null 2>&1 || true
    else
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
    
    return 0
}

# === HOTPLUG GENERATION ===

# Generate Hotplug Script for Split Tunnel
# Args: $1=interface, $2=table, $3=domains, $4=dns_servers, $5=ipv6_supported
split_tunnel_generate_hotplug() {
    local iface="$1"
    local table="$2"
    local domains="$3"
    local dns_servers="$4"
    local ipv6="${5:-0}"
    local hotplug_dir="${HOTPLUG_IFACE_DIR:-/etc/hotplug.d/iface}"
    local db_path="${PBR_DB_PATH:-${VPN_TMP_DIR:-/tmp/${VPN_PREFIX}}/pbr.db}"
    local split_lib="${LIB_DIR:-${VPN_BASE_DIR}/lib}/split-tunnel.sh"
    local dnsmasq_service="${VPN_DNSMASQ_SERVICE:-/etc/init.d/dnsmasq}"
    local sqlite_timeout="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
    case "$sqlite_timeout" in
        ''|*[!0-9]*) sqlite_timeout=5000 ;;
    esac
    
    mkdir -p "$hotplug_dir"
    local script_path="$hotplug_dir/99-${VPN_PREFIX}-${iface}-split"
    
    if [ ! -f "$split_lib" ] && [ -n "$VPN_BASE_DIR" ]; then
        split_lib="${VPN_BASE_DIR}/lib/split-tunnel.sh"
    fi
    
cat > "$script_path" << 'EOF_SPLIT'
#!/bin/sh
[ "$INTERFACE" = "IFACE_PLACEHOLDER" ] || exit 0

INTERFACE="IFACE_PLACEHOLDER"
TABLE="TABLE_PLACEHOLDER"
DOMAINS="DOMAINS_PLACEHOLDER"
DNS="DNS_PLACEHOLDER"
IPV6="IPV6_PLACEHOLDER"
PBR_DB_PATH="DB_PATH_PLACEHOLDER"
VPN_TMP_DIR="VPN_TMP_DIR_PLACEHOLDER"
VPN_DNSMASQ_SERVICE="DNSMASQ_SERVICE_PLACEHOLDER"
SPLIT_LIB="SPLIT_LIB_PLACEHOLDER"
mkdir -p "$VPN_TMP_DIR" 2>/dev/null || true
LOCK_FILE="${VPN_TMP_DIR}/split_hotplug_${INTERFACE}.lock"
exec 202>"$LOCK_FILE"
flock -x 202 || exit 1
trap 'flock -u 202' EXIT

# Per-interface hotplug storm guard.
GUARD_STATE="${VPN_TMP_DIR}/split_${INTERFACE}.guard"
GUARD_LAST="${VPN_TMP_DIR}/split_${INTERFACE}.last"
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
    logger -t vpn-split-tunnel "[$INTERFACE] Hotplug storm guard active; skipping $ACTION"
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
    logger -t vpn-split-tunnel "[$INTERFACE] Hotplug storm detected (count=$COUNT window=${WINDOW}s); cooling down ${COOLDOWN}s"
    exit 0
fi
printf "%s|%s|0\n" "$WIN_START" "$COUNT" > "$GUARD_STATE"

[ -f "$SPLIT_LIB" ] || exit 0
. "$SPLIT_LIB"
SQLITE_TIMEOUT_MS="SQLITE_TIMEOUT_MS_PLACEHOLDER"
db_sqlite() {
    command sqlite3 -cmd ".timeout ${SQLITE_TIMEOUT_MS}" "$@"
}

case "$ACTION" in
    ifup|fw-reload)
        split_tunnel_apply "$INTERFACE" "$TABLE" "$DOMAINS" "$DNS" "$IPV6" || exit 1
        if [ -f "$PBR_DB_PATH" ]; then
            db_sqlite "$PBR_DB_PATH" "UPDATE interfaces SET running = 1, start_time = $(cut -d. -f1 /proc/uptime 2>/dev/null || date +%s) WHERE name = '$INTERFACE';" 2>/dev/null
        fi
        ;;
    ifdown)
        split_tunnel_cleanup "$INTERFACE" "$TABLE" "$DNS" "$IPV6" || true
        if [ -f "$PBR_DB_PATH" ]; then
            db_sqlite "$PBR_DB_PATH" "UPDATE interfaces SET running = 0 WHERE name = '$INTERFACE';" 2>/dev/null
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF_SPLIT
    
    sed -i "s|IFACE_PLACEHOLDER|$iface|g" "$script_path"
    sed -i "s|TABLE_PLACEHOLDER|$table|g" "$script_path"
    sed -i "s|DOMAINS_PLACEHOLDER|$domains|g" "$script_path"
    sed -i "s|DNS_PLACEHOLDER|$dns_servers|g" "$script_path"
    sed -i "s|IPV6_PLACEHOLDER|$ipv6|g" "$script_path"
    sed -i "s|DB_PATH_PLACEHOLDER|$db_path|g" "$script_path"
    sed -i "s|VPN_TMP_DIR_PLACEHOLDER|${VPN_TMP_DIR:-/tmp/${VPN_PREFIX}}|g" "$script_path"
    sed -i "s|DNSMASQ_SERVICE_PLACEHOLDER|$dnsmasq_service|g" "$script_path"
    sed -i "s|SPLIT_LIB_PLACEHOLDER|$split_lib|g" "$script_path"
    sed -i "s|SQLITE_TIMEOUT_MS_PLACEHOLDER|$sqlite_timeout|g" "$script_path"
    
    chmod +x "$script_path"
    echo "$script_path"
}
