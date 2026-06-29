#!/bin/sh
# Route10 PBR Library - SQLite State Management
# Provides atomic operations for interface and MAC state tracking

# Load project-wide defaults/overrides when available.
if [ -z "${VPN_PROJECT_CONFIG_LOADED:-}" ] && [ -n "${LIB_DIR:-}" ] && [ -f "${LIB_DIR}/project-config.sh" ]; then
    . "${LIB_DIR}/project-config.sh"
fi

# Default database path (can be overridden before sourcing)
PBR_DB_PATH="${PBR_DB_PATH:-/tmp/${VPN_PREFIX}/pbr.db}"
PBR_DB_BUSY_TIMEOUT_MS="${PBR_DB_BUSY_TIMEOUT_MS:-${WG_DB_BUSY_TIMEOUT_MS:-5000}}"
WG_DB_BUSY_TIMEOUT_MS="${WG_DB_BUSY_TIMEOUT_MS:-$PBR_DB_BUSY_TIMEOUT_MS}"

normalize_ipv6_mode() {
    case "$1" in
        auto|"") echo "nat66" ;;
        nat66|routed-prefix|disabled) echo "$1" ;;
        *) echo "${VPN_IPV6_MODE_DEFAULT:-nat66}" ;;
    esac
}

# Add SQLite busy timeout for concurrent commit/hotplug writers.
# Do not override test harnesses that already provide a sqlite3 shell function.
_state_sqlite_type="$(type sqlite3 2>/dev/null || true)"
case "$_state_sqlite_type" in
    *"function"*) : ;;
    *)
        sqlite3() {
            command sqlite3 -cmd ".timeout ${PBR_DB_BUSY_TIMEOUT_MS}" "$@"
        }
        ;;
esac
unset _state_sqlite_type

# === DATABASE INITIALIZATION ===

# Initialize database with required tables
# Creates 'interfaces' and 'mac_state' tables
db_init() {
    local db="$PBR_DB_PATH"
    mkdir -p "$(dirname "$db")"
    
    sqlite3 "$db" <<EOF
CREATE TABLE IF NOT EXISTS interfaces (
    name TEXT PRIMARY KEY,
    type TEXT,                    -- 'wireguard' or 'openvpn'
    conf TEXT,                    -- Path to config file
    routing_table INTEGER,
    target_ips TEXT,              -- Comma-separated IPs/subnets/MACs
    domains TEXT,                 -- For split-tunnel (comma-separated)
    dns_servers TEXT,             -- VPN DNS servers
    committed INTEGER DEFAULT 0,
    target_only INTEGER DEFAULT 0,
    ipv6_support INTEGER DEFAULT 0,
    ipv6_subnets TEXT,
    nat66 INTEGER DEFAULT 0,
    start_time INTEGER,
    running INTEGER DEFAULT 0,
    ipv6_mode TEXT DEFAULT 'nat66',
    ipv6_routed_prefix TEXT DEFAULT '',
    ipv6_downstream_iface TEXT DEFAULT '',
    ipv6_health TEXT DEFAULT 'unknown',
    ipv6_health_reason TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS mac_state (
    mac TEXT,
    interface TEXT,
    ip TEXT,
    routing_table INTEGER,
    ipv6_support INTEGER,
    PRIMARY KEY (mac, interface, ip)
);

CREATE TABLE IF NOT EXISTS ipv6_ra_state (
    iface TEXT,
    downstream_iface TEXT,
    network_ip6addr_old TEXT,
    network_ip6class_old TEXT,
    network_ip6assign_old TEXT,
    dhcp_ra_old TEXT,
    dhcp_dhcpv6_old TEXT,
    dhcp_ra_management_old TEXT,
    PRIMARY KEY (iface, downstream_iface)
);
EOF
    # Migrations for existing DBs (ignore "duplicate column" errors)
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN type TEXT;" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN domains TEXT;" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN dns_servers TEXT;" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN target_only INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN ipv6_mode TEXT DEFAULT 'nat66';" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN ipv6_routed_prefix TEXT DEFAULT '';" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN ipv6_downstream_iface TEXT DEFAULT '';" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN ipv6_health TEXT DEFAULT 'unknown';" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE interfaces ADD COLUMN ipv6_health_reason TEXT DEFAULT '';" 2>/dev/null || true
    sqlite3 "$db" <<EOF
CREATE TABLE IF NOT EXISTS ipv6_ra_state (
    iface TEXT,
    downstream_iface TEXT,
    network_ip6addr_old TEXT,
    network_ip6class_old TEXT,
    network_ip6assign_old TEXT,
    dhcp_ra_old TEXT,
    dhcp_dhcpv6_old TEXT,
    dhcp_ra_management_old TEXT,
    PRIMARY KEY (iface, downstream_iface)
);
EOF
    sqlite3 "$db" "ALTER TABLE ipv6_ra_state ADD COLUMN network_ip6class_old TEXT;" 2>/dev/null || true
    sqlite3 "$db" "ALTER TABLE ipv6_ra_state ADD COLUMN network_ip6assign_old TEXT;" 2>/dev/null || true
}

# === INTERFACE FUNCTIONS ===

# Stage an interface configuration
# Usage: db_stage_interface <name> <type> <conf> <routing_table> <target_ips> [dns_servers]
db_stage_interface() {
    local name="$1"
    local type="$2"
    local conf="$3"
    local rt="$4"
    local targets="$5"
    local dns="${6:-}"
    
    sqlite3 "$PBR_DB_PATH" <<EOF
INSERT OR REPLACE INTO interfaces (
    name, type, conf, routing_table, target_ips, domains, dns_servers,
    committed, target_only, ipv6_support, ipv6_subnets, nat66, start_time, running,
    ipv6_mode, ipv6_routed_prefix, ipv6_downstream_iface, ipv6_health, ipv6_health_reason
)
VALUES (
    '$name', '$type', '$conf', $rt, '$targets',
    COALESCE((SELECT domains FROM interfaces WHERE name = '$name'), ''),
    '$dns',
    0,
    COALESCE((SELECT target_only FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_support FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_subnets FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT nat66 FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT start_time FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT running FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_mode FROM interfaces WHERE name = '$name'), '${VPN_IPV6_MODE_DEFAULT:-nat66}'),
    COALESCE((SELECT ipv6_routed_prefix FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_downstream_iface FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_health FROM interfaces WHERE name = '$name'), 'unknown'),
    COALESCE((SELECT ipv6_health_reason FROM interfaces WHERE name = '$name'), '')
);
EOF
}

# Commit a staged interface
# Usage: db_commit_interface <name>
db_commit_interface() {
    local name="$1"
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET committed = 1 WHERE name = '$name';"
}

# Mark interface as running
# Usage: db_set_running <name> <running> [start_time]
db_set_running() {
    local name="$1"
    local running="$2"
    local start_time="${3:-}"
    
    if [ -z "$start_time" ]; then
        if [ -f /proc/uptime ]; then
            start_time=$(cut -d. -f1 /proc/uptime)
        else
            start_time=$(date +%s)
        fi
    fi
    
    if [ "$running" = "1" ]; then
        sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET running = 1, start_time = $start_time WHERE name = '$name';"
    else
        sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET running = 0 WHERE name = '$name';"
    fi
}

# Update IPv6 settings
# Usage: db_set_ipv6 <name> <ipv6_support> <ipv6_subnets> <nat66>
db_set_ipv6() {
    local name="$1"
    local ipv6="$2"
    local subnets="$3"
    local nat66="$4"
    
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET ipv6_support = $ipv6, ipv6_subnets = '$subnets', nat66 = $nat66 WHERE name = '$name';"
}

# Update DNS servers
# Usage: db_set_dns_servers <name> <dns_servers>
db_set_dns_servers() {
    local name="$1"
    local dns="$2"
    local dns_escaped
    dns_escaped=$(echo "$dns" | sed "s/'/''/g")
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET dns_servers = '$dns_escaped' WHERE name = '$name';"
}

# Persist IPv6 profile settings for an interface.
# Usage: db_set_ipv6_profile <name> <mode> <routed_prefix> <downstream_iface>
db_set_ipv6_profile() {
    local name="$1"
    local mode="$2"
    local routed_prefix="${3:-}"
    local downstream_iface="${4:-}"
    
    mode=$(normalize_ipv6_mode "$mode")
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET ipv6_mode = '$mode', ipv6_routed_prefix = '$routed_prefix', ipv6_downstream_iface = '$downstream_iface' WHERE name = '$name';"
}

# Read IPv6 profile settings.
# Usage: db_get_ipv6_profile <name>
# Returns: ipv6_mode|ipv6_routed_prefix|ipv6_downstream_iface|ipv6_health|ipv6_health_reason
db_get_ipv6_profile() {
    local name="$1"
    local raw
    raw=$(sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT COALESCE(ipv6_mode,'${VPN_IPV6_MODE_DEFAULT:-nat66}'), COALESCE(ipv6_routed_prefix,''), COALESCE(ipv6_downstream_iface,''), COALESCE(ipv6_health,'unknown'), COALESCE(ipv6_health_reason,'') FROM interfaces WHERE name = '$name';")
    [ -z "$raw" ] && return 0
    local mode
    mode=$(echo "$raw" | cut -d'|' -f1)
    mode=$(normalize_ipv6_mode "$mode")
    echo "${mode}|$(echo "$raw" | cut -d'|' -f2-)"
}

# Update IPv6 health marker.
# Usage: db_set_ipv6_health <name> <health> [reason]
db_set_ipv6_health() {
    local name="$1"
    local health="$2"
    local reason="${3:-}"
    [ -z "$health" ] && health="unknown"
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET ipv6_health = '$health', ipv6_health_reason = '$reason' WHERE name = '$name';"
}

# Update target IPs
# Usage: db_update_targets <name> <target_ips>
db_update_targets() {
    local name="$1"
    local targets="$2"
    
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET target_ips = '$targets' WHERE name = '$name';"
}

# Get interface data (pipe-delimited)
# Usage: db_get_interface <name>
# Returns: name|type|conf|routing_table|target_ips|domains|dns_servers|committed|target_only|ipv6_support|ipv6_subnets|nat66|start_time|running|ipv6_mode|ipv6_routed_prefix|ipv6_downstream_iface|ipv6_health|ipv6_health_reason
db_get_interface() {
    local name="$1"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT * FROM interfaces WHERE name = '$name';"
}

# Check if interface exists
# Usage: db_interface_exists <name>
db_interface_exists() {
    local name="$1"
    local count=$(sqlite3 "$PBR_DB_PATH" "SELECT COUNT(*) FROM interfaces WHERE name = '$name';")
    [ "$count" -gt 0 ]
}

# Check if interface is committed
# Usage: db_is_committed <name>
db_is_committed() {
    local name="$1"
    local committed=$(sqlite3 "$PBR_DB_PATH" "SELECT committed FROM interfaces WHERE name = '$name';")
    [ "$committed" = "1" ]
}

# Check if interface is running
# Usage: db_is_running <name>
db_is_running() {
    local name="$1"
    local running=$(sqlite3 "$PBR_DB_PATH" "SELECT running FROM interfaces WHERE name = '$name';")
    [ "$running" = "1" ]
}

# Get a specific field
# Usage: db_get_field <name> <field>
db_get_field() {
    local name="$1"
    local field="$2"
    sqlite3 "$PBR_DB_PATH" "SELECT $field FROM interfaces WHERE name = '$name';"
}

# List all interfaces (optional filter by type)
# Usage: db_list_interfaces [type]
db_list_interfaces() {
    local type="$1"
    if [ -n "$type" ]; then
        sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE type = '$type' ORDER BY running DESC, name ASC;"
    else
        sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces ORDER BY running DESC, name ASC;"
    fi
}

# List running interfaces
# Usage: db_list_running
db_list_running() {
    sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE running = 1;"
}

# List interfaces by type
# Usage: db_list_by_type <type>
db_list_by_type() {
    local type="$1"
    sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE type = '$type' ORDER BY name;"
}

# Delete interface
# Usage: db_delete_interface <name>
db_delete_interface() {
    local name="$1"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM interfaces WHERE name = '$name';"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM ipv6_ra_state WHERE iface = '$name';"
}

# Find interface by IP
# Usage: db_find_interface_by_ip <ip>
db_find_interface_by_ip() {
    local ip="$1"
    sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE target_ips = '$ip' OR target_ips LIKE '$ip,%' OR target_ips LIKE '%,$ip' OR target_ips LIKE '%,$ip,%';"
}

# Get registry entry format
# Usage: db_get_registry_entry <name>
# Returns: name|routing_table|target_ips|ipv6_support|ipv6_subnets|nat66|start_time
db_get_registry_entry() {
    local name="$1"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT name, routing_table, target_ips, COALESCE(ipv6_support,0), COALESCE(ipv6_subnets,''), COALESCE(nat66,0), COALESCE(start_time,0) FROM interfaces WHERE name = '$name';"
}

# List all committed interfaces in registry format
# Usage: db_list_registry_entries
db_list_registry_entries() {
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT name, routing_table, target_ips, COALESCE(ipv6_support,0), COALESCE(ipv6_subnets,''), COALESCE(nat66,0), COALESCE(start_time,0) FROM interfaces WHERE committed = 1;"
}

# Full registry update
# Usage: db_update_registry <name> <rt> <targets> <ipv6> <ipv6_subnets> <nat66> <start_time>
db_update_registry() {
    local name="$1"
    local rt="$2"
    local targets="$3"
    local ipv6="${4:-0}"
    local ipv6_subnets="${5:-}"
    local nat66="${6:-0}"
    local start_time="${7:-}"
    
    if [ -z "$start_time" ]; then
        if [ -f /proc/uptime ]; then
            start_time=$(cut -d. -f1 /proc/uptime)
        else
            start_time=$(date +%s)
        fi
    fi
    
    sqlite3 "$PBR_DB_PATH" <<EOF
UPDATE interfaces SET 
    routing_table = $rt,
    target_ips = '$targets',
    ipv6_support = $ipv6,
    ipv6_subnets = '$ipv6_subnets',
    nat66 = $nat66,
    start_time = $start_time,
    committed = 1,
    running = 1
WHERE name = '$name';
EOF
}

# Get all used routing tables
# Usage: db_get_all_routing_tables
db_get_all_routing_tables() {
    sqlite3 "$PBR_DB_PATH" "SELECT routing_table FROM interfaces WHERE routing_table IS NOT NULL;"
}

# === IPV6 RA STATE FUNCTIONS ===

# Save previous downstream IPv6 RA/DHCPv6 ownership state for rollback.
# Usage: db_save_ra_state <iface> <downstream_iface> <network_ip6addr_old> <network_ip6class_old> <network_ip6assign_old> <dhcp_ra_old> <dhcp_dhcpv6_old> <dhcp_ra_management_old>
db_save_ra_state() {
    local iface="$1"
    local downstream_iface="$2"
    local network_ip6addr_old="${3:-}"
    local network_ip6class_old="${4:-}"
    local network_ip6assign_old="${5:-}"
    local dhcp_ra_old="${6:-}"
    local dhcp_dhcpv6_old="${7:-}"
    local dhcp_ra_management_old="${8:-}"
    
    sqlite3 "$PBR_DB_PATH" <<EOF
INSERT OR REPLACE INTO ipv6_ra_state (
    iface, downstream_iface, network_ip6addr_old, network_ip6class_old, network_ip6assign_old, dhcp_ra_old, dhcp_dhcpv6_old, dhcp_ra_management_old
) VALUES (
    '$iface', '$downstream_iface', '$network_ip6addr_old', '$network_ip6class_old', '$network_ip6assign_old', '$dhcp_ra_old', '$dhcp_dhcpv6_old', '$dhcp_ra_management_old'
);
EOF
}

# Read saved downstream IPv6 RA/DHCPv6 ownership state.
# Usage: db_get_ra_state <iface> <downstream_iface>
# Returns: iface|downstream_iface|network_ip6addr_old|network_ip6class_old|network_ip6assign_old|dhcp_ra_old|dhcp_dhcpv6_old|dhcp_ra_management_old
db_get_ra_state() {
    local iface="$1"
    local downstream_iface="$2"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT iface, downstream_iface, COALESCE(network_ip6addr_old,''), COALESCE(network_ip6class_old,''), COALESCE(network_ip6assign_old,''), COALESCE(dhcp_ra_old,''), COALESCE(dhcp_dhcpv6_old,''), COALESCE(dhcp_ra_management_old,'') FROM ipv6_ra_state WHERE iface = '$iface' AND downstream_iface = '$downstream_iface';"
}

# Delete saved downstream IPv6 RA/DHCPv6 ownership state.
# Usage: db_delete_ra_state <iface> <downstream_iface>
db_delete_ra_state() {
    local iface="$1"
    local downstream_iface="$2"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM ipv6_ra_state WHERE iface = '$iface' AND downstream_iface = '$downstream_iface';"
}

# === MAC STATE FUNCTIONS ===

# Set MAC state
# Usage: db_set_mac_state <mac> <interface> <ip> <routing_table> <ipv6_support>
db_set_mac_state() {
    local mac="$1"
    local iface="$2"
    local ip="$3"
    local rt="$4"
    local ipv6="$5"
    
    sqlite3 "$PBR_DB_PATH" <<EOF
DELETE FROM mac_state WHERE mac = '$mac';
INSERT INTO mac_state (mac, interface, ip, routing_table, ipv6_support)
VALUES ('$mac', '$iface', '$ip', $rt, $ipv6);
EOF
}

# Get MAC state by interface and IP
# Usage: db_get_mac_state <interface> <ip>
db_get_mac_state() {
    local iface="$1"
    local ip="$2"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT * FROM mac_state WHERE interface = '$iface' AND ip = '$ip';"
}

# Get MAC state by MAC address (for roaming detection)
# Usage: db_get_mac_by_mac <mac>
# Returns: mac|interface|ip|routing_table|ipv6_support
db_get_mac_by_mac() {
    local mac="$1"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT * FROM mac_state WHERE mac = '$mac';"
}

# Delete MAC state by interface and IP
# Usage: db_delete_mac_state <interface> <ip>
db_delete_mac_state() {
    local iface="$1"
    local ip="$2"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM mac_state WHERE interface = '$iface' AND ip = '$ip';"
}

# Delete all MAC state for interface
# Usage: db_delete_mac_state_for_interface <interface>
db_delete_mac_state_for_interface() {
    local iface="$1"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM mac_state WHERE interface = '$iface';"
}

# List MAC state for interface
# Usage: db_list_mac_state <interface>
db_list_mac_state() {
    local iface="$1"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT * FROM mac_state WHERE interface = '$iface';"
}

# Get MACs for interface
# Usage: db_get_macs_for_interface <interface>
db_get_macs_for_interface() {
    local iface="$1"
    sqlite3 "$PBR_DB_PATH" "SELECT mac FROM mac_state WHERE interface = '$iface';"
}

# Delete MAC by MAC address
# Usage: db_delete_mac_by_mac <mac>
db_delete_mac_by_mac() {
    local mac="$1"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM mac_state WHERE mac = '$mac';"
}

# Delete MAC by interface and MAC
# Usage: db_delete_mac_by_iface_mac <interface> <mac>
db_delete_mac_by_iface_mac() {
    local iface="$1"
    local mac="$2"
    sqlite3 "$PBR_DB_PATH" "DELETE FROM mac_state WHERE interface = '$iface' AND mac = '$mac';"
}

# === STAGING FUNCTIONS ===

# Stage with full details (supports split-tunnel)
# Usage: db_set_staged <name> <type> <conf> <rt> <targets> <committed> <target_only> [domains]
db_set_staged() {
    local name="$1"
    local type="$2"
    local conf="$3"
    local rt="$4"
    local targets="$5"
    local committed="${6:-0}"
    local target_only="${7:-0}"
    local domains="${8:-}"
    
    sqlite3 "$PBR_DB_PATH" <<EOF
INSERT OR REPLACE INTO interfaces (
    name, type, conf, routing_table, target_ips, domains, dns_servers,
    committed, target_only, ipv6_support, ipv6_subnets, nat66, start_time, running,
    ipv6_mode, ipv6_routed_prefix, ipv6_downstream_iface, ipv6_health, ipv6_health_reason
)
VALUES (
    '$name', '$type', '$conf', $rt, '$targets', '$domains',
    COALESCE((SELECT dns_servers FROM interfaces WHERE name = '$name'), ''),
    $committed, $target_only,
    COALESCE((SELECT ipv6_support FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_subnets FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT nat66 FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT start_time FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT running FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_mode FROM interfaces WHERE name = '$name'), '${VPN_IPV6_MODE_DEFAULT:-nat66}'),
    COALESCE((SELECT ipv6_routed_prefix FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_downstream_iface FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_health FROM interfaces WHERE name = '$name'), 'unknown'),
    COALESCE((SELECT ipv6_health_reason FROM interfaces WHERE name = '$name'), '')
);
EOF
}

# Stage a split-tunnel interface (domain mode)
# Usage: db_set_staged_split_tunnel <name> <conf> <rt> <domains> [type] [dns_servers]
db_set_staged_split_tunnel() {
    local name="$1"
    local conf="$2"
    local rt="$3"
    local domains="$4"
    local type="${5:-}"
    local dns="${6:-}"
    
    if [ -z "$type" ]; then
        type=$(sqlite3 "$PBR_DB_PATH" "SELECT type FROM interfaces WHERE name = '$name';")
        [ -z "$type" ] && type="wireguard"
    fi
    
    if [ -z "$dns" ]; then
        dns=$(sqlite3 "$PBR_DB_PATH" "SELECT dns_servers FROM interfaces WHERE name = '$name';")
    fi
    
    sqlite3 "$PBR_DB_PATH" <<EOF
INSERT OR REPLACE INTO interfaces (
    name, type, conf, routing_table, target_ips, domains, dns_servers,
    committed, target_only, ipv6_support, ipv6_subnets, nat66, start_time, running,
    ipv6_mode, ipv6_routed_prefix, ipv6_downstream_iface, ipv6_health, ipv6_health_reason
)
VALUES (
    '$name', '$type', '$conf', $rt, 'none', '$domains', '$dns',
    0, 0,
    COALESCE((SELECT ipv6_support FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_subnets FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT nat66 FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT start_time FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT running FROM interfaces WHERE name = '$name'), 0),
    COALESCE((SELECT ipv6_mode FROM interfaces WHERE name = '$name'), '${VPN_IPV6_MODE_DEFAULT:-nat66}'),
    COALESCE((SELECT ipv6_routed_prefix FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_downstream_iface FROM interfaces WHERE name = '$name'), ''),
    COALESCE((SELECT ipv6_health FROM interfaces WHERE name = '$name'), 'unknown'),
    COALESCE((SELECT ipv6_health_reason FROM interfaces WHERE name = '$name'), '')
);
EOF
}

# Get staged interface
# Usage: db_get_staged <name>
db_get_staged() {
    local name="$1"
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT name, type, conf, routing_table, target_ips, committed, target_only FROM interfaces WHERE name = '$name';"
}

# List all staged
# Usage: db_list_staged
db_list_staged() {
    sqlite3 -separator '|' "$PBR_DB_PATH" "SELECT name, type, conf, routing_table, target_ips, committed, target_only, COALESCE(domains,'') FROM interfaces ORDER BY name;"
}

# List uncommitted (pending)
# Usage: db_list_uncommitted
db_list_uncommitted() {
    sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE committed = 0;"
}

# Update staged targets (for hot-reload)
# Usage: db_update_staged_targets <name> <targets> <target_only>
db_update_staged_targets() {
    local name="$1"
    local targets="$2"
    local target_only="${3:-0}"
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET target_ips = '$targets', target_only = $target_only WHERE name = '$name';"
}

# Set target-only flag (for hot-reload)
# Usage: db_set_target_only <name> <target_only>
db_set_target_only() {
    local name="$1"
    local target_only="$2"
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET target_only = $target_only WHERE name = '$name';"
}

# Update staged domains (for split-tunnel hot-reload)
# Usage: db_update_staged_domains <name> <domains> <target_only>
db_update_staged_domains() {
    local name="$1"
    local domains="$2"
    local target_only="${3:-0}"
    sqlite3 "$PBR_DB_PATH" "UPDATE interfaces SET domains = '$domains', target_only = $target_only WHERE name = '$name';"
}

# Reconstruct wrapper command from DB state
# Usage: db_reconstruct_command <name> [script_path]
db_reconstruct_command() {
    local name="$1"
    local script_path="${2:-}"
    local entry=$(db_get_interface "$name")
    [ -z "$entry" ] && return 1
    
    local type=$(echo "$entry" | cut -d'|' -f2)
    local conf=$(echo "$entry" | cut -d'|' -f3)
    local targets=$(echo "$entry" | cut -d'|' -f5)
    local domains=$(echo "$entry" | cut -d'|' -f6)
    
    if [ -z "$script_path" ]; then
        case "$type" in
            openvpn) script_path="./ovpn.sh" ;;
            *)       script_path="./wg.sh" ;;
        esac
    fi
    
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        echo "$script_path $name --conf $conf --domains $domains"
    else
        echo "$script_path $name --conf $conf --target-ips $targets"
    fi
}

# === UTILITY FUNCTIONS ===

# Find interface containing subnet for IP
# Usage: db_find_subnet_for_ip <ip>
# Returns: interface_name|subnet (or empty)
db_find_subnet_for_ip() {
    local ip="$1"
    local interfaces=$(sqlite3 "$PBR_DB_PATH" "SELECT name, target_ips FROM interfaces WHERE target_ips LIKE '%/%';")
    
    echo "$interfaces" | while IFS='|' read -r iface targets; do
        [ -z "$iface" ] && continue
        for target in $(echo "$targets" | tr ',' ' '); do
            case "$target" in
                */*)
                    if is_in_subnet "$ip" "$target" 2>/dev/null; then
                        echo "$iface|$target"
                        return 0
                    fi
                    ;;
            esac
        done
    done
}

# Check for IP conflicts across all interfaces
# Usage: db_check_ip_conflict <ip> <exclude_interface>
# Returns: conflicting interface name, or empty
db_check_ip_conflict() {
    local ip="$1"
    local exclude="$2"
    
    # Check exact match
    local match=$(sqlite3 "$PBR_DB_PATH" "SELECT name FROM interfaces WHERE name != '$exclude' AND (target_ips = '$ip' OR target_ips LIKE '$ip,%' OR target_ips LIKE '%,$ip' OR target_ips LIKE '%,$ip,%');")
    [ -n "$match" ] && echo "$match" && return 0
    
    # Check subnet containment
    db_find_subnet_for_ip "$ip" | cut -d'|' -f1
}

# Allocate routing table avoiding conflicts
# Usage: db_allocate_routing_table <start> <end>
db_allocate_routing_table() {
    local start="${1:-${VPN_RT_START:-1000}}"
    local end="${2:-${VPN_RT_END:-1499}}"
    
    local used_tables=$(db_get_all_routing_tables)
    
    # Also check /etc/iproute2/rt_tables
    if [ -f "/etc/iproute2/rt_tables" ]; then
        local sys_tables=$(awk '{print $1}' /etc/iproute2/rt_tables 2>/dev/null | grep -E '^[0-9]+$')
        used_tables="$used_tables $sys_tables"
    fi
    
    # Also inspect active policy rules from unmanaged interfaces.
    # This catches tables already in use even when they are not in SQLite
    # and not explicitly registered in /etc/iproute2/rt_tables.
    if command -v ip >/dev/null 2>&1; then
        local ip4_rule_tables=$(ip rule show 2>/dev/null | awk '
            {
                for (i=1; i<=NF; i++) {
                    if (($i == "lookup" || $i == "table") && (i+1) <= NF && $(i+1) ~ /^[0-9]+$/) {
                        print $(i+1)
                    }
                }
            }')
        local ip6_rule_tables=$(ip -6 rule show 2>/dev/null | awk '
            {
                for (i=1; i<=NF; i++) {
                    if (($i == "lookup" || $i == "table") && (i+1) <= NF && $(i+1) ~ /^[0-9]+$/) {
                        print $(i+1)
                    }
                }
            }')
        
        # Rules can also use named lookups (e.g. "lookup wg0_rt").
        # Resolve those names to numeric IDs via /etc/iproute2/rt_tables.
        local ip4_rule_table_names=$(ip rule show 2>/dev/null | awk '
            {
                for (i=1; i<=NF; i++) {
                    if (($i == "lookup" || $i == "table") && (i+1) <= NF && $(i+1) !~ /^[0-9]+$/) {
                        print $(i+1)
                    }
                }
            }')
        local ip6_rule_table_names=$(ip -6 rule show 2>/dev/null | awk '
            {
                for (i=1; i<=NF; i++) {
                    if (($i == "lookup" || $i == "table") && (i+1) <= NF && $(i+1) !~ /^[0-9]+$/) {
                        print $(i+1)
                    }
                }
            }')
        local named_tables="$ip4_rule_table_names $ip6_rule_table_names"
        local resolved_named_tables=""
        for table_name in $named_tables; do
            case "$table_name" in
                local|main|default|unspec) continue ;;
            esac
            if [ -f "/etc/iproute2/rt_tables" ]; then
                local table_num=$(awk -v n="$table_name" '$2 == n { print $1; exit }' /etc/iproute2/rt_tables 2>/dev/null)
                [ -n "$table_num" ] && resolved_named_tables="$resolved_named_tables $table_num"
            fi
        done
        
        used_tables="$used_tables $ip4_rule_tables $ip6_rule_tables $resolved_named_tables"
    fi
    
    local i=$start
    while [ $i -le $end ]; do
        if ! echo "$used_tables" | grep -qw "$i"; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
    
    echo ""
    return 1
}
