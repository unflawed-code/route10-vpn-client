#!/bin/sh
# Default temp dir (shared with core)
WG_TMP_DIR="${WG_TMP_DIR:-/tmp/${VPN_PREFIX}}"

# Source utilities
if [ -f "$LIB_DIR/util/table.sh" ]; then
    . "$LIB_DIR/util/table.sh"
fi

status_print_table_row() {
    local label="$1"
    local value="$2"
    local val_width="${3:-50}"
    local label_width=16

    local extra=0
    if type get_visual_width >/dev/null 2>&1; then
        extra=$(get_visual_width "$value")
        : "${extra:=0}"
    fi
    local pad=$((val_width + extra))
    printf "│ %-${label_width}s │ %-${pad}s │\n" "$label" "$value" || true
}

status_print_table_header() {
    local text="$1"
    local total_width=69

    local extra=0
    if type get_visual_width >/dev/null 2>&1; then
        extra=$(get_visual_width "$text")
        : "${extra:=0}"
    fi
    local pad=$((total_width + extra))

    printf "│ %-${pad}s │\n" "$text" || true
}

_status_is_ipv4() {
    [ -n "$1" ] || return 1
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

_status_is_ipv6() {
    [ -n "$1" ] || return 1
    echo "$1" | grep -q ':' || return 1
    echo "$1" | grep -Eq '^[0-9A-Fa-f:]+$'
}

_status_get_iface_global_ipv6() {
    local iface="$1"
    ip -6 addr show dev "$iface" 2>/dev/null | \
        awk '/inet6 / && !/fe80/ {split($2, a, "/"); print a[1]; exit}'
}

_status_first_routed_client_ipv6() {
    local downstream_iface="$1"
    local routed_prefix="$2"
    [ -n "$downstream_iface" ] && [ -n "$routed_prefix" ] || return 1
    ip -6 neigh show to "$routed_prefix" dev "$downstream_iface" 2>/dev/null | \
        awk '{
            ip=$1
            state=$NF
            if (ip ~ /^fe80:/) next
            if (state == "FAILED" || state == "INCOMPLETE" || state == "NONE") next
            print ip
            exit
        }'
}

_status_try_public_ip() {
    if [ "${VPN_STATUS_NO_CURL:-0}" = "1" ]; then
        echo ""
        return 0
    fi
    local family="$1"
    local bind="$2"
    local out=""
    if [ "$family" = "4" ]; then
        out=$(curl -s -4 --max-time 2 --interface "$bind" ifconfig.me 2>/dev/null || true)
        _status_is_ipv4 "$out" || out=""
    else
        out=$(curl -s -6 --max-time 3 --interface "$bind" ifconfig.me 2>/dev/null || true)
        if ! _status_is_ipv6 "$out"; then
            out=$(curl -s -6 --max-time 3 --interface "$bind" api64.ipify.org 2>/dev/null || true)
            _status_is_ipv6 "$out" || out=""
        fi
    fi
    echo "$out"
}

_status_fetch_public_ipv6() {
    if [ "${VPN_STATUS_NO_CURL:-0}" = "1" ]; then
        echo ""
        return 0
    fi
    local iface="$1"
    local rt="$2"
    local ipv6_mode="${3:-nat66}"
    local ipv6_routed_prefix="${4:-}"
    local ipv6_downstream_iface="${5:-}"
    local pub_ip6=""
    local src6=""
    local tmp_prio=48
    local gw_addr=""

    if [ "$ipv6_mode" = "routed-prefix" ]; then
        # Routed-prefix has per-client IPv6 egress; show a live routed client address when available.
        pub_ip6=$(_status_first_routed_client_ipv6 "$ipv6_downstream_iface" "$ipv6_routed_prefix")
        if _status_is_ipv6 "$pub_ip6"; then
            echo "$pub_ip6"
            return 0
        fi

        # Fallback to downstream gateway probe for health visibility; avoid WG /128 address reporting.
        if [ -n "$ipv6_routed_prefix" ] && [ -n "$rt" ]; then
            gw_addr="${ipv6_routed_prefix%/*}1"
            ip -6 rule add from "${gw_addr}/128" table "$rt" priority "$tmp_prio" 2>/dev/null || true
            pub_ip6=$(_status_try_public_ip "6" "$gw_addr")
            ip -6 rule del from "${gw_addr}/128" table "$rt" priority "$tmp_prio" 2>/dev/null || true
            if _status_is_ipv6 "$pub_ip6"; then
                echo "$pub_ip6"
                return 0
            fi
        fi
        return 1
    fi

    pub_ip6=$(_status_try_public_ip "6" "$iface")
    if _status_is_ipv6 "$pub_ip6"; then
        echo "$pub_ip6"
        return 0
    fi

    src6=$(_status_get_iface_global_ipv6 "$iface")
    if [ -z "$src6" ] || [ -z "$rt" ]; then
        return 1
    fi

    # Router-origin probes are not fwmarked; add a narrow temporary source rule.
    ip -6 rule add from "${src6}/128" table "$rt" priority "$tmp_prio" 2>/dev/null || true
    pub_ip6=$(_status_try_public_ip "6" "$src6")
    ip -6 rule del from "${src6}/128" table "$rt" priority "$tmp_prio" 2>/dev/null || true

    if _status_is_ipv6 "$pub_ip6"; then
        echo "$pub_ip6"
        return 0
    fi
    return 1
}

cmd_status() {
    local iface="$1"
    
    # Try SQLite database
    local db_entry=$(db_get_interface "$iface" 2>/dev/null)
    
    if [ -z "$db_entry" ]; then
        echo "Interface $iface not found in database"
        return 1
    fi
    
    # Parse SQLite entry
    local type=$(echo "$db_entry" | cut -d'|' -f2)
    local conf=$(echo "$db_entry" | cut -d'|' -f3)
    # Ensure absolute path (handle relative paths starting with conf/ or similar)
    if [ -n "$conf" ] && [ "${conf#/}" = "$conf" ]; then
         # If relative, prepend standard path or PWD
         if [ -f "/cfg/vpn-custom/$conf" ]; then
             conf="/cfg/vpn-custom/$conf"
         else
             conf="$PWD/$conf"
         fi
    fi
    local rt=$(echo "$db_entry" | cut -d'|' -f4)
    local targets=$(echo "$db_entry" | cut -d'|' -f5)
    local domains=$(echo "$db_entry" | cut -d'|' -f6)
    local dns=$(echo "$db_entry" | cut -d'|' -f7)
    local committed=$(echo "$db_entry" | cut -d'|' -f8)
    local target_only=$(echo "$db_entry" | cut -d'|' -f9)
    local ipv6=$(echo "$db_entry" | cut -d'|' -f10)
    local ip6_subs=$(echo "$db_entry" | cut -d'|' -f11)
    local nat66=$(echo "$db_entry" | cut -d'|' -f12)
    local start_time=$(echo "$db_entry" | cut -d'|' -f13)
    local running=$(echo "$db_entry" | cut -d'|' -f14)
    local ipv6_mode_raw=$(echo "$db_entry" | cut -d'|' -f15)
    local ipv6_mode="$ipv6_mode_raw"
    local ipv6_routed_prefix=$(echo "$db_entry" | cut -d'|' -f16)
    local ipv6_downstream_iface=$(echo "$db_entry" | cut -d'|' -f17)
    local ipv6_health=$(echo "$db_entry" | cut -d'|' -f18)
    local ipv6_health_reason=$(echo "$db_entry" | cut -d'|' -f19)
    [ -z "$ipv6_mode" ] && ipv6_mode="nat66"
    [ "$ipv6_mode" = "auto" ] && ipv6_mode="nat66"
    [ -z "$ipv6_health" ] && ipv6_health="unknown"
    
    # Determine Mode
    local mode_display="Client Routing 🌐"
    local is_split=0
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        mode_display="Split-Tunnel 🛡️"
        is_split=1
    fi
    
    # Determine Status
    local status_display="Inactive ❌"
    local pub_ip=""
    local pub_ip6=""
    
    local bind_iface="$iface"
    if [ "$type" = "openvpn" ]; then
        local ovpn_dev
        ovpn_dev=$(uci -q get "openvpn.${iface}.dev" 2>/dev/null || true)
        [ -n "$ovpn_dev" ] || ovpn_dev="tun_${iface}"
        bind_iface="$ovpn_dev"
    fi

    local actual_state="DOWN"
    if ip link show "$bind_iface" 2>/dev/null | grep -q "UP"; then
        actual_state="UP"
    elif [ "$type" = "openvpn" ] && ps ww 2>/dev/null | grep -F "openvpn(${iface})" | grep -vq grep; then
        actual_state="PROCESS_UP"
    fi

    if [ "$actual_state" = "UP" ]; then
        status_display="Active ✅"
        if [ "$running" != "1" ]; then
             status_display="Untracked ⚠️"
        fi
    elif [ "$actual_state" = "PROCESS_UP" ]; then
        status_display="Active ⚠️ (Connecting)"
    else
        status_display="Inactive ❌"
    fi
    
    if [ "$actual_state" = "UP" ]; then
        
        # Check for handshake if it's wireguard
        # Check for handshake if it's wireguard
        if [ "$type" = "wireguard" ]; then
             local last_hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -n1)
             if [ -z "$last_hs" ] || [ "$last_hs" -eq 0 ]; then
                 status_display="Active ⚠️ (No Handshake)"
             else
                 # Optional: Check staleness (> 180s ago)
                 local now_epoch=$(date +%s)
                 if [ "$((now_epoch - last_hs))" -gt 180 ]; then
                      status_display="Active ⚠️ (Stale Handshake)"
                 fi
             fi
        fi

        # Try to get public IPs from temp file or fetch it
        local tmp_ip="${WG_TMP_DIR}/wg_pub_ip_${iface}"
        if [ -s "$tmp_ip" ]; then
            local cached_ip
            cached_ip=$(cat "$tmp_ip")
            if _status_is_ipv4 "$cached_ip"; then
                pub_ip="$cached_ip"
            fi
        else
            pub_ip=$(_status_try_public_ip "4" "$bind_iface")
        fi
        
        # Try to get public IPv6, including source-rule fallback for client-routing mode.
        local tmp_ip6="${WG_TMP_DIR}/wg_pub_ip6_${iface}"
        if [ -s "$tmp_ip6" ] && [ "$ipv6_mode" != "routed-prefix" ]; then
            local cached_ip6
            cached_ip6=$(cat "$tmp_ip6")
            if _status_is_ipv6 "$cached_ip6"; then
                pub_ip6="$cached_ip6"
            fi
        fi
        if [ -z "$pub_ip6" ]; then
            pub_ip6=$(_status_fetch_public_ipv6 "$bind_iface" "$rt" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || true)
        else
            :
        fi
    fi

    # Backward-compatible IPv6 detection:
    # staged DB rows can have ipv6_support=0 even when runtime/config indicate IPv6 capability.
    if [ "$ipv6" != "1" ]; then
        local iface_v6=""
        iface_v6=$(_status_get_iface_global_ipv6 "$bind_iface")
        if [ -n "$pub_ip6" ] || [ -n "$iface_v6" ] || \
           grep -Eq '^[[:space:]]*Address[[:space:]]*=.*:' "$conf" 2>/dev/null || \
           grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=.*::' "$conf" 2>/dev/null || \
           grep -Eq '^[[:space:]]*setenv[[:space:]]+UV_IPV6[[:space:]]+1([[:space:]]|$)' "$conf" 2>/dev/null; then
            ipv6="1"
        fi
    fi
    
    # Calculate Uptime
    local uptime_str="-"
    if [ "$actual_state" != "DOWN" ] && [ -n "$start_time" ] && [ "$start_time" -gt 0 ] 2>/dev/null; then
        local now
        if [ "$start_time" -gt 1000000000 ] 2>/dev/null; then
            now=$(date +%s)
        else
            if [ -f /proc/uptime ]; then
                now=$(cut -d. -f1 /proc/uptime)
            else
                now=$(date +%s)
            fi
        fi
        local diff=$((now - start_time))
        local d=$((diff / 86400))
        local h=$(((diff % 86400) / 3600))
        local m=$(((diff % 3600) / 60))
        local s=$((diff % 60))
        
        uptime_str=""
        [ $d -gt 0 ] && uptime_str="${d}d "
        [ $h -gt 0 ] || [ $d -gt 0 ] && uptime_str="${uptime_str}${h}h "
        [ $m -gt 0 ] || [ $h -gt 0 ] || [ $d -gt 0 ] && uptime_str="${uptime_str}${m}m "
        uptime_str="${uptime_str}${s}s ⏱️"
    fi
    
    # Print Table
    echo "┌───────────────────────────────────────────────────────────────────────┐"
    status_print_table_header "$iface 🔗"
    echo "├──────────────────┬────────────────────────────────────────────────────┤"
    
    status_print_table_row "Status" "$status_display"
    status_print_table_row "Mode" "$mode_display"
    status_print_table_row "Uptime" "$uptime_str"
    
    local staged="$([ "$committed" = "1" ] && echo "Committed ✅" || echo "Pending ⏳")"
    status_print_table_row "Staged" "$staged"
    
    status_print_table_row "Routing Table" "$rt (${iface}_rt)"
    
    local v6_disp="$([ "$ipv6" = "1" ] && echo "Yes ✅" || echo "No ❌")"
    status_print_table_row "IPv6 Support" "$v6_disp"
    
    local ipv6_mode_disp="$ipv6_mode"
    if [ "$ipv6" != "1" ] && [ "$nat66" != "1" ] && \
       [ "$ipv6_mode" != "routed-prefix" ] && \
       [ -z "$ipv6_routed_prefix" ] && [ -z "$ipv6_downstream_iface" ]; then
        ipv6_mode_disp="Disabled ❌"
    else
    case "$ipv6_mode" in
        routed-prefix) ipv6_mode_disp="Routed Prefix ✅" ;;
        disabled)      ipv6_mode_disp="Disabled ❌" ;;
        *)             ipv6_mode_disp="NAT66" ;;
    esac
    fi
    status_print_table_row "IPv6 Mode" "$ipv6_mode_disp"

    if [ "$nat66" = "1" ]; then
        status_print_table_row "NAT66" "Enabled ✅"
    fi
    if [ "$ipv6_mode" = "routed-prefix" ] || [ -n "$ipv6_routed_prefix" ] || [ -n "$ipv6_downstream_iface" ]; then
        status_print_table_row "Delegated Prefix" "${ipv6_routed_prefix:--}"
        status_print_table_row "Downstream Iface" "${ipv6_downstream_iface:--}"
        if [ "$ipv6_health" = "ok" ]; then
            status_print_table_row "IPv6 Health" "OK ✅"
        elif [ "$ipv6_health" = "degraded" ]; then
            local reason_disp="degraded"
            [ -n "$ipv6_health_reason" ] && reason_disp="$ipv6_health_reason"
            status_print_table_row "IPv6 Health" "Degraded ⚠️ (${reason_disp})"
        else
            status_print_table_row "IPv6 Health" "Unknown"
        fi
    fi
    
    # Show public IP rows even if unavailable
    local pub_ip_disp="${pub_ip:--}"
    local pub_ip6_disp="${pub_ip6:--}"
    status_print_table_row "Public IPv4" "$pub_ip_disp"
    status_print_table_row "Public IPv6" "$pub_ip6_disp"
    
    # Targets
    if [ "$is_split" = "1" ]; then
        local first=1
        for d in $(echo "$domains" | tr ',' ' '); do
            if [ $first -eq 1 ]; then
                status_print_table_row "Domains" "$d"
                first=0
            else
                status_print_table_row "" "$d"
            fi
        done
        [ $first -eq 1 ] && status_print_table_row "Domains" "-"
    else
        if [ "$targets" != "none" ] && [ -n "$targets" ]; then
            local first=1
            for t in $(echo "$targets" | tr ',' ' '); do
                local display_target="$t"
                local target_mac=""
                local target_ip=""
                
                # Extract IP and MAC if possible
                case "$t" in
                    *=*)
                        target_mac="${t%%=*}"
                        target_ip="${t#*=}"
                        display_target="${target_mac} -> ${target_ip}"
                        ;;
                    *)
                        if is_mac "$t" 2>/dev/null; then
                            target_mac=$(normalize_mac "$t")
                            target_ip=$(resolve_mac_to_ip "$target_mac")
                            if [ -n "$target_ip" ]; then
                                display_target="${target_mac} -> ${target_ip}"
                            else
                                display_target="${target_mac} -> -"
                            fi
                        else
                            target_ip="$t"
                            if type db_get_mac_state >/dev/null 2>&1; then
                                target_mac=$(db_get_mac_state "$iface" "$target_ip" 2>/dev/null | cut -d'|' -f1)
                            fi
                            if [ -z "$target_mac" ]; then
                                target_mac=$(ip neigh show "$target_ip" 2>/dev/null | grep -o '[0-9a-f:]\{17\}' | head -1)
                            fi
                            [ -n "$target_mac" ] && is_mac "$target_mac" 2>/dev/null && target_mac=$(normalize_mac "$target_mac" 2>/dev/null || echo "$target_mac") || target_mac=""
                        fi
                        ;;
                esac
                
                if [ $first -eq 1 ]; then
                    status_print_table_row "Targets" "$display_target"
                    first=0
                else
                    status_print_table_row "" "$display_target"
                fi
            done
        else
            status_print_table_row "Targets" "-"
        fi
    fi
    
    # Config File
    if [ -n "$conf" ]; then
        local val_w=50
        if [ ${#conf} -le $val_w ]; then
            status_print_table_row "Config" "$conf"
        else
            # Wrap long path
            local start=1
            while [ $start -le ${#conf} ]; do
                local chunk=$(echo "$conf" | cut -c $start-$((start + val_w - 1)))
                if [ $start -eq 1 ]; then
                    status_print_table_row "Config" "$chunk"
                else
                    status_print_table_row "" "$chunk"
                fi
                start=$((start + val_w))
            done
        fi
    fi
    
    # Subnets
    if [ -n "$ip6_subs" ] && [ "$ip6_subs" != "" ]; then
         status_print_table_row "IPv6 Subnets" "$ip6_subs"
    fi
    
    echo "└──────────────────┴────────────────────────────────────────────────────┘"
}

cmd_status_all() {
    local type="$1"
    # Ensure DB exists
    db_init 2>/dev/null

    # Parallel fetch public IPs
    db_list_interfaces "$type" | while read -r iface; do
        local bind_iface="$iface"
        if [ "$type" = "openvpn" ]; then
            local ovpn_dev
            ovpn_dev=$(uci -q get "openvpn.${iface}.dev" 2>/dev/null || true)
            [ -n "$ovpn_dev" ] || ovpn_dev="tun_${iface}"
            bind_iface="$ovpn_dev"
        fi
        if ip link show "$bind_iface" >/dev/null 2>&1; then
            # Fetch IPv4 (max 2s)
            (curl -s -4 --max-time 2 --interface "$bind_iface" ifconfig.me > "${WG_TMP_DIR}/wg_pub_ip_${iface}" 2>/dev/null) &
            # Fetch IPv6 (max 2s)
            local mode rt prefix down_iface
            mode=$(db_get_field "$iface" "ipv6_mode" 2>/dev/null || true)
            rt=$(db_get_field "$iface" "routing_table" 2>/dev/null || true)
            prefix=$(db_get_field "$iface" "ipv6_routed_prefix" 2>/dev/null || true)
            down_iface=$(db_get_field "$iface" "ipv6_downstream_iface" 2>/dev/null || true)
            (
                local p6
                p6=$(_status_fetch_public_ipv6 "$bind_iface" "$rt" "$mode" "$prefix" "$down_iface" 2>/dev/null || true)
                echo -n "$p6" > "${WG_TMP_DIR}/wg_pub_ip6_${iface}"
            ) &
        fi
    done
    wait
    
    local interfaces=$(db_list_interfaces "$type")
    if [ -z "$interfaces" ]; then
        if [ -n "$type" ]; then
            echo "No managed $type interfaces found in database."
        else
            echo "No managed interfaces found in database."
        fi
        return 
    fi
    
    echo "$interfaces" | while read -r iface; do
        cmd_status "$iface"
        echo ""
    done
}

cmd_status_json() {
    local iface="$1"
    
    local db_entry=$(db_get_interface "$iface" 2>/dev/null)
    if [ -z "$db_entry" ]; then
        echo "{}"
        return 1
    fi
    
    local type=$(echo "$db_entry" | cut -d'|' -f2)
    local conf=$(echo "$db_entry" | cut -d'|' -f3)
    if [ -n "$conf" ] && [ "${conf#/}" = "$conf" ]; then
         if [ -f "/cfg/vpn-custom/$conf" ]; then
             conf="/cfg/vpn-custom/$conf"
         else
             conf="$PWD/$conf"
         fi
    fi
    local rt=$(echo "$db_entry" | cut -d'|' -f4)
    local targets=$(echo "$db_entry" | cut -d'|' -f5)
    local domains=$(echo "$db_entry" | cut -d'|' -f6)
    local committed=$(echo "$db_entry" | cut -d'|' -f8)
    local ipv6=$(echo "$db_entry" | cut -d'|' -f10)
    local ip6_subs=$(echo "$db_entry" | cut -d'|' -f11)
    local nat66=$(echo "$db_entry" | cut -d'|' -f12)
    local start_time=$(echo "$db_entry" | cut -d'|' -f13)
    local running=$(echo "$db_entry" | cut -d'|' -f14)
    local ipv6_mode_raw=$(echo "$db_entry" | cut -d'|' -f15)
    local ipv6_mode="$ipv6_mode_raw"
    local ipv6_routed_prefix=$(echo "$db_entry" | cut -d'|' -f16)
    local ipv6_downstream_iface=$(echo "$db_entry" | cut -d'|' -f17)
    [ -z "$ipv6_mode" ] && ipv6_mode="nat66"
    [ "$ipv6_mode" = "auto" ] && ipv6_mode="nat66"
    [ -z "$running" ] && running=0
    
    local mode_display="Client Routing"
    local is_split=0
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        mode_display="Split-Tunnel"
        is_split=1
    fi
    
    local status_display="Inactive"
    local pub_ip=""
    local pub_ip6=""
    
    local bind_iface="$iface"
    if [ "$type" = "openvpn" ]; then
        local ovpn_dev
        ovpn_dev=$(uci -q get "openvpn.${iface}.dev" 2>/dev/null || true)
        [ -n "$ovpn_dev" ] || ovpn_dev="tun_${iface}"
        bind_iface="$ovpn_dev"
    fi

    local actual_state="DOWN"
    if ip link show "$bind_iface" 2>/dev/null | grep -q "UP"; then
        actual_state="UP"
    elif [ "$type" = "openvpn" ] && ps ww 2>/dev/null | grep -F "openvpn(${iface})" | grep -vq grep; then
        actual_state="PROCESS_UP"
    fi

    if [ "$actual_state" = "UP" ]; then
        status_display="Active"
        if [ "$running" != "1" ]; then
             status_display="Untracked"
        fi
    elif [ "$actual_state" = "PROCESS_UP" ]; then
        status_display="Connecting"
    else
        status_display="Inactive"
    fi
    
    if [ "$actual_state" = "UP" ]; then
        if [ "$type" = "wireguard" ]; then
             local last_hs=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -n1)
             if [ -z "$last_hs" ] || [ "$last_hs" -eq 0 ]; then
                 status_display="No Handshake"
             else
                 local now_epoch=$(date +%s)
                 if [ "$((now_epoch - last_hs))" -gt 180 ]; then
                      status_display="Stale Handshake"
                 fi
             fi
        fi

        local tmp_ip="${WG_TMP_DIR}/wg_pub_ip_${iface}"
        if [ -s "$tmp_ip" ]; then
            local cached_ip
            cached_ip=$(cat "$tmp_ip")
            if _status_is_ipv4 "$cached_ip"; then
                pub_ip="$cached_ip"
            fi
        else
            pub_ip=$(_status_try_public_ip "4" "$bind_iface")
        fi
        
        local tmp_ip6="${WG_TMP_DIR}/wg_pub_ip6_${iface}"
        if [ -s "$tmp_ip6" ] && [ "$ipv6_mode" != "routed-prefix" ]; then
            local cached_ip6
            cached_ip6=$(cat "$tmp_ip6")
            if _status_is_ipv6 "$cached_ip6"; then
                pub_ip6="$cached_ip6"
            fi
        fi
        if [ -z "$pub_ip6" ]; then
            pub_ip6=$(_status_fetch_public_ipv6 "$bind_iface" "$rt" "$ipv6_mode" "$ipv6_routed_prefix" "$ipv6_downstream_iface" || true)
        fi
    fi

    if [ "$ipv6" != "1" ]; then
        local iface_v6=""
        iface_v6=$(_status_get_iface_global_ipv6 "$bind_iface")
        if [ -n "$pub_ip6" ] || [ -n "$iface_v6" ] || \
           grep -Eq '^[[:space:]]*Address[[:space:]]*=.*:' "$conf" 2>/dev/null || \
           grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=.*::' "$conf" 2>/dev/null || \
           grep -Eq '^[[:space:]]*setenv[[:space:]]+UV_IPV6[[:space:]]+1([[:space:]]|$)' "$conf" 2>/dev/null; then
            ipv6="1"
        fi
    fi
    
    local uptime_str="-"
    if [ "$actual_state" != "DOWN" ] && [ -n "$start_time" ] && [ "$start_time" -gt 0 ] 2>/dev/null; then
        local now
        if [ "$start_time" -gt 1000000000 ] 2>/dev/null; then
            now=$(date +%s)
        else
            if [ -f /proc/uptime ]; then
                now=$(cut -d. -f1 /proc/uptime)
            else
                now=$(date +%s)
            fi
        fi
        local diff=$((now - start_time))
        local d=$((diff / 86400))
        local h=$(((diff % 86400) / 3600))
        local m=$(((diff % 3600) / 60))
        local s=$((diff % 60))
        uptime_str=""
        [ $d -gt 0 ] && uptime_str="${d}d "
        [ $h -gt 0 ] || [ $d -gt 0 ] && uptime_str="${uptime_str}${h}h "
        [ $m -gt 0 ] || [ $h -gt 0 ] || [ $d -gt 0 ] && uptime_str="${uptime_str}${m}m "
        uptime_str="${uptime_str}${s}s"
    fi
    
    local staged="$([ "$committed" = "1" ] && echo "Committed" || echo "Pending")"
    local v6_disp="$([ "$ipv6" = "1" ] && echo "Yes" || echo "No")"
    
    local ipv6_mode_disp="$ipv6_mode"
    if [ "$ipv6" != "1" ] && [ "$nat66" != "1" ] && \
       [ "$ipv6_mode" != "routed-prefix" ] && \
       [ -z "$ipv6_routed_prefix" ] && [ -z "$ipv6_downstream_iface" ]; then
        ipv6_mode_disp="Disabled"
    else
        case "$ipv6_mode" in
            routed-prefix) ipv6_mode_disp="Routed Prefix" ;;
            disabled)      ipv6_mode_disp="Disabled" ;;
            *)             ipv6_mode_disp="NAT66" ;;
        esac
    fi
    
    local clean_targets=""
    if [ "$is_split" = "1" ]; then
        clean_targets=$(echo "$domains" | tr ',' ' ')
    else
        if [ "$targets" != "none" ] && [ -n "$targets" ]; then
            clean_targets=$(echo "$targets" | tr ',' ' ')
        else
            clean_targets="-"
        fi
    fi

    local conf_escaped=$(echo -n "$conf" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr -d '\n\r')
    local targets_escaped=$(echo -n "$clean_targets" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr -d '\n\r')
    local ip6_subs_escaped=$(echo -n "$ip6_subs" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr -d '\n\r')

    printf '{"status":"%s","mode":"%s","uptime":"%s","staged":"%s","routing_table":"%s","ipv6_support":"%s","ipv6_mode":"%s","public_ipv4":"%s","public_ipv6":"%s","targets":"%s","config":"%s","ipv6_subnets":"%s"}' \
           "$status_display" "$mode_display" "$uptime_str" "$staged" "$rt" "$v6_disp" "$ipv6_mode_disp" "${pub_ip:--}" "${pub_ip6:--}" "$targets_escaped" "$conf_escaped" "$ip6_subs_escaped"
}

