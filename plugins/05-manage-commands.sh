#!/bin/sh
# 05-manage-commands.sh - Management commands plugin
# Provides: assign-ips/remove-ips/assign-domains/remove-domains

# Source database helpers
if [ -f "${LIB_DIR:-./lib}/state.sh" ]; then
    . "${LIB_DIR:-./lib}/state.sh"
elif [ -f "/cfg/vpn-custom/lib/state.sh" ]; then
    . "/cfg/vpn-custom/lib/state.sh"
fi

# Source common utilities for MAC helpers
if [ -f "${LIB_DIR:-./lib}/common.sh" ]; then
    . "${LIB_DIR:-./lib}/common.sh"
elif [ -f "/cfg/vpn-custom/lib/common.sh" ]; then
    . "/cfg/vpn-custom/lib/common.sh"
fi

show_plugin_help() {
    if type tbl_row >/dev/null 2>&1; then
        tbl_row "assign-ips <iface> <ips>" "Add target IPs (comma-separated)"
        tbl_row "remove-ips <iface> <ips>" "Remove target IPs (comma-separated)"
        tbl_row "assign-domains <iface> <domains>" "Add split-tunnel domains (comma-separated)"
        tbl_row "remove-domains <iface> <domains>" "Remove split-tunnel domains (comma-separated)"
    else
        echo ""
        echo "Management Commands (via plugin):"
        echo "  $0 assign-ips <iface> <ips>         Add target IPs (comma-separated)"
        echo "  $0 remove-ips <iface> <ips>         Remove target IPs (comma-separated)"
        echo "  $0 assign-domains <iface> <domains> Add split-tunnel domains (comma-separated)"
        echo "  $0 remove-domains <iface> <domains> Remove split-tunnel domains (comma-separated)"
    fi
}

handle_command() {
    case "$1" in
        assign-ips)
            [ -z "$2" ] || [ -z "$3" ] && echo "Error: assign-ips requires interface and IP(s)" && return 1
            cmd_assign_ip "$2" "$3"
            return $?
            ;;
        remove-ips)
            [ -z "$2" ] || [ -z "$3" ] && echo "Error: remove-ips requires interface and IP(s)" && return 1
            cmd_remove_ip "$2" "$3"
            return $?
            ;;
        assign-domains)
            [ -z "$2" ] || [ -z "$3" ] && echo "Error: assign-domains requires interface and domain(s)" && return 1
            cmd_assign_domains "$2" "$3"
            return $?
            ;;
        remove-domains)
            [ -z "$2" ] || [ -z "$3" ] && echo "Error: remove-domains requires interface and domain(s)" && return 1
            cmd_remove_domains "$2" "$3"
            return $?
            ;;
    esac
    return 1
}

_find_interface_for_ip() {
    local ip="$1"
    db_find_interface_by_ip "$ip" 2>/dev/null | head -1
}

_is_interface_committed() {
    local iface="$1"
    db_is_committed "$iface" 2>/dev/null
}

_commit_hint_for_type() {
    local iface_type="$1"
    case "$iface_type" in
        wireguard) echo "./wg.sh commit" ;;
        openvpn)   echo "./ovpn.sh commit" ;;
        *)         echo "./wg.sh commit or ./ovpn.sh commit" ;;
    esac
}

_entry_ipv6_mode() {
    local db_entry="$1"
    local mode
    mode=$(echo "$db_entry" | cut -d'|' -f15)
    [ -z "$mode" ] && mode="nat66"
    [ "$mode" = "auto" ] && mode="nat66"
    echo "$mode"
}

_count_subnet_targets() {
    local targets="$1"
    local count=0
    local item resolved
    [ -z "$targets" ] && echo 0 && return 0
    [ "$targets" = "none" ] && echo 0 && return 0
    for item in $(echo "$targets" | tr ',' ' '); do
        [ -z "$item" ] && continue
        resolved=$(get_ip_from_target "$item")
        echo "$resolved" | grep -q '/' && count=$((count + 1))
    done
    echo "$count"
}

_validate_routed_prefix_targets_after_change() {
    local iface="$1"
    local mode="$2"
    local _old_targets="$3"
    local new_targets="$4"
    
    [ "$mode" = "routed-prefix" ] || return 0

    if ! targets_are_single_subnet_only "$new_targets"; then
        echo "Error: routed-prefix interface $iface requires exactly one subnet target only."
        return 1
    fi
    
    return 0
}

cmd_remove_ip() {
    local iface="$1"
    local input_list="$2"
    
    local db_entry
    db_entry=$(db_get_interface "$iface" 2>/dev/null)
    if [ -z "$db_entry" ]; then
        echo "Error: Interface $iface not found in database"
        return 1
    fi
    
    local domains
    local iface_type
    local commit_hint
    domains=$(echo "$db_entry" | cut -d'|' -f6)
    iface_type=$(echo "$db_entry" | cut -d'|' -f2)
    commit_hint=$(_commit_hint_for_type "$iface_type")
    local ipv6_mode
    ipv6_mode=$(_entry_ipv6_mode "$db_entry")
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        echo "Error: Cannot remove IPs from split-tunnel interface $iface"
        echo "Split-tunnel routes by domain, not client IP."
        return 1
    fi
    
    local current_targets
    local current_targets_raw
    current_targets_raw=$(echo "$db_entry" | cut -d'|' -f5)
    current_targets=$(echo "$current_targets_raw" | tr ',' ' ')
    [ "$current_targets" = "none" ] && current_targets=""
    
    local new_targets=""
    local removal_list
    removal_list=$(echo "$input_list" | tr ',' ' ')

    if [ "$ipv6_mode" = "routed-prefix" ]; then
        for to_remove in $removal_list; do
            if ! echo "$to_remove" | grep -q '/'; then
                echo "Error: routed-prefix interface $iface accepts subnet targets only."
                return 1
            fi
        done

        for target in $current_targets; do
            local should_remove=0
            for to_remove in $removal_list; do
                if [ "$target" = "$to_remove" ]; then
                    should_remove=1
                    echo "Removing $to_remove from $iface"
                    break
                fi
            done

            if [ "$should_remove" = "0" ]; then
                [ -n "$new_targets" ] && new_targets="${new_targets},"
                new_targets="${new_targets}${target}"
            fi
        done

        if [ -z "$new_targets" ]; then
            echo "Note: No targets remaining for $iface"
            new_targets="none"
        fi

        _validate_routed_prefix_targets_after_change "$iface" "$ipv6_mode" "$current_targets" "$new_targets" || return 1

        db_update_targets "$iface" "$new_targets"
        local target_only=0
        _is_interface_committed "$iface" && target_only=1
        db_set_target_only "$iface" "$target_only"

        echo "Staged updated configuration for $iface"
        echo "Run '$commit_hint' to apply changes"
        return 0
    fi
    
    for target in $current_targets; do
        local should_remove=0
        for to_remove in $removal_list; do
            local match_key="$to_remove"
            if is_mac "$to_remove" 2>/dev/null; then
                match_key=$(normalize_mac "$to_remove")
            fi
            case "$target" in
                *=*)
                    local target_mac="${target%%=*}"
                    if [ "$target_mac" = "$match_key" ]; then
                        should_remove=1
                        echo "Removing MAC $target_mac from $iface"
                        break
                    fi
                    ;;
                *)
                    if [ "$target" = "$to_remove" ]; then
                        should_remove=1
                        echo "Removing $to_remove from $iface"
                        break
                    fi
                    ;;
            esac
        done
        
        if [ "$should_remove" = "0" ]; then
            [ -n "$new_targets" ] && new_targets="${new_targets},"
            new_targets="${new_targets}${target}"
        fi
    done
    
    for to_remove in $removal_list; do
        local found=0
        local match_key="$to_remove"
        if is_mac "$to_remove" 2>/dev/null; then
            match_key=$(normalize_mac "$to_remove")
        fi
        for target in $current_targets; do
            case "$target" in
                *=*)
                    local target_mac="${target%%=*}"
                    [ "$target_mac" = "$match_key" ] && found=1 && break
                    ;;
                *)
                    [ "$target" = "$to_remove" ] && found=1 && break
                    ;;
            esac
        done
        if [ "$found" = "0" ]; then
            if is_mac "$to_remove" 2>/dev/null; then
                echo "WARN: MAC $match_key not found in targets (was it added as IP instead?)"
            else
                echo "WARN: $to_remove not found in targets"
            fi
        fi
    done
    
    if [ -z "$new_targets" ]; then
        echo "Note: No targets remaining for $iface"
        new_targets="none"
    fi
    
    _validate_routed_prefix_targets_after_change "$iface" "$ipv6_mode" "$current_targets" "$new_targets" || return 1
    
    db_update_targets "$iface" "$new_targets"
    local target_only=0
    _is_interface_committed "$iface" && target_only=1
    db_set_target_only "$iface" "$target_only"
    
    echo "Staged updated configuration for $iface"
    echo "Run '$commit_hint' to apply changes"
}

cmd_assign_ip() {
    local iface="$1"
    local input_list="$2"
    
    local db_entry
    db_entry=$(db_get_interface "$iface" 2>/dev/null)
    if [ -z "$db_entry" ]; then
        echo "Error: Interface $iface not found in database"
        return 1
    fi
    
    local domains
    local iface_type
    local commit_hint
    domains=$(echo "$db_entry" | cut -d'|' -f6)
    iface_type=$(echo "$db_entry" | cut -d'|' -f2)
    commit_hint=$(_commit_hint_for_type "$iface_type")
    local ipv6_mode
    ipv6_mode=$(_entry_ipv6_mode "$db_entry")
    if [ -n "$domains" ] && [ "$domains" != "none" ]; then
        echo "Error: Cannot assign IPs to split-tunnel interface $iface"
        echo "Split-tunnel routes by domain, not client IP."
        return 1
    fi
    
    local current_targets
    local current_targets_raw
    current_targets_raw=$(echo "$db_entry" | cut -d'|' -f5)
    current_targets=$(echo "$current_targets_raw" | tr ',' ' ')
    [ "$current_targets" = "none" ] && current_targets=""

    local new_targets_list="$current_targets_raw"
    [ "$new_targets_list" = "none" ] && new_targets_list=""

    if [ "$ipv6_mode" = "routed-prefix" ]; then
        for input_target in $(echo "$input_list" | tr ',' ' '); do
            [ -z "$input_target" ] && continue
            if ! echo "$input_target" | grep -q '/'; then
                echo "Error: routed-prefix interface $iface accepts subnet targets only."
                return 1
            fi
            case ",$new_targets_list," in
                *,"$input_target",*)
                    echo "INFO: $input_target already in target list (duplicate), skipping"
                    ;;
                *)
                    [ -n "$new_targets_list" ] && new_targets_list="${new_targets_list},"
                    new_targets_list="${new_targets_list}${input_target}"
                    ;;
            esac
        done
    else
        local current_resolved_ips=""
        for target in $current_targets; do
            case "$target" in
                *=*) current_resolved_ips="$current_resolved_ips ${target#*=}" ;;
                *) current_resolved_ips="$current_resolved_ips $target" ;;
            esac
        done

        for input_target in $(echo "$input_list" | tr ',' ' '); do
            local store_format=""
            local resolved_ip=""
            
            if is_mac "$input_target" 2>/dev/null; then
                local mac
                mac=$(normalize_mac "$input_target")
                if [ -z "$mac" ]; then
                    echo "WARN: Invalid MAC address: $input_target, skipping"
                    continue
                fi
                resolved_ip=$(resolve_mac_to_ip "$mac")
                if [ -z "$resolved_ip" ]; then
                    echo "WARN: MAC $mac not found in ARP table, skipping"
                    continue
                fi
                echo "Resolved MAC $mac -> $resolved_ip"
                store_format="${mac}=${resolved_ip}"
            else
                resolved_ip="$input_target"
                store_format="$input_target"
            fi
            
            local current_owner
            current_owner=$(_find_interface_for_ip "$resolved_ip" 2>/dev/null)
            if [ -n "$current_owner" ] && [ "$current_owner" != "$iface" ]; then
                echo "Moving $resolved_ip from $current_owner to $iface"
                local other_targets
                other_targets=$(db_get_field "$current_owner" "target_ips" 2>/dev/null | tr ',' ' ')
                for other_target in $other_targets; do
                    local other_resolved=""
                    case "$other_target" in
                        *=*) other_resolved="${other_target#*=}" ;;
                        *) other_resolved="$other_target" ;;
                    esac
                    if [ "$other_resolved" = "$resolved_ip" ]; then
                        cmd_remove_ip "$current_owner" "$other_target"
                        break
                    fi
                done
            fi
            
            local is_dupe=0
            for existing_resolved in $current_resolved_ips; do
                if [ "$existing_resolved" = "$resolved_ip" ]; then
                    echo "INFO: $resolved_ip already in target list (duplicate), skipping"
                    is_dupe=1
                    break
                fi
            done
            
            if [ "$is_dupe" = "0" ]; then
                [ -n "$new_targets_list" ] && new_targets_list="${new_targets_list},"
                new_targets_list="${new_targets_list}${store_format}"
                current_resolved_ips="$current_resolved_ips $resolved_ip"
            fi
        done
    fi

    [ -z "$new_targets_list" ] && new_targets_list="none"
    _validate_routed_prefix_targets_after_change "$iface" "$ipv6_mode" "$current_targets" "$new_targets_list" || return 1
    echo "Assigning targets to $iface: $new_targets_list"
    
    db_update_targets "$iface" "$new_targets_list"
    local target_only=0
    _is_interface_committed "$iface" && target_only=1
    db_set_target_only "$iface" "$target_only"
    
    echo "Staged updated configuration for $iface"
    echo "Run '$commit_hint' to apply changes"
}

cmd_assign_domains() {
    local iface="$1"
    local input_list="$2"
    
    local db_entry
    db_entry=$(db_get_interface "$iface" 2>/dev/null)
    if [ -z "$db_entry" ]; then
        echo "Error: Interface $iface not found in database"
        return 1
    fi
    
    local targets
    local iface_type
    local commit_hint
    targets=$(echo "$db_entry" | cut -d'|' -f5)
    iface_type=$(echo "$db_entry" | cut -d'|' -f2)
    commit_hint=$(_commit_hint_for_type "$iface_type")
    local current_domains
    current_domains=$(echo "$db_entry" | cut -d'|' -f6)
    
    if [ "$targets" != "none" ] && [ -n "$targets" ]; then
        echo "Error: Cannot assign domains to IP-routing interface $iface"
        echo "This interface is configured to route by IP/MAC: $targets"
        return 1
    fi
    
    [ "$current_domains" = "none" ] && current_domains=""
    
    local new_list="$current_domains"
    local input_domains
    input_domains=$(echo "$input_list" | tr ',' ' ')
    
    for domain in $input_domains; do
        local domain_clean
        domain_clean=$(echo "$domain" | tr A-Z a-z)
        domain_clean="${domain_clean#"${domain_clean%%[![:space:]]*}"}"
        domain_clean="${domain_clean%"${domain_clean##*[![:space:]]}"}"
        [ -z "$domain_clean" ] && continue
        
        case ",$new_list," in
            *",${domain_clean},"*)
                echo "Info: $domain_clean already in list."
                ;;
            *)
                if [ -n "$new_list" ]; then
                    new_list="${new_list},${domain_clean}"
                else
                    new_list="${domain_clean}"
                fi
                echo "Staging addition: $domain_clean"
                ;;
        esac
    done
    
    local target_only=0
    _is_interface_committed "$iface" && target_only=1
    db_update_staged_domains "$iface" "$new_list" "$target_only"
    
    echo "Staged updated domain configuration for $iface"
    echo "Run '$commit_hint' to apply changes"
}

cmd_remove_domains() {
    local iface="$1"
    local input_list="$2"
    
    local db_entry
    db_entry=$(db_get_interface "$iface" 2>/dev/null)
    if [ -z "$db_entry" ]; then
        echo "Error: Interface $iface not found in database"
        return 1
    fi
    
    local targets
    local iface_type
    local commit_hint
    targets=$(echo "$db_entry" | cut -d'|' -f5)
    iface_type=$(echo "$db_entry" | cut -d'|' -f2)
    commit_hint=$(_commit_hint_for_type "$iface_type")
    if [ "$targets" != "none" ] && [ -n "$targets" ]; then
        echo "Error: Cannot remove domains from IP-routing interface $iface"
        echo "This interface is configured to route by IP/MAC: $targets"
        return 1
    fi
    
    local current_domains
    current_domains=$(echo "$db_entry" | cut -d'|' -f6)
    if [ -z "$current_domains" ] || [ "$current_domains" = "none" ]; then
        echo "Error: No domains configured for $iface"
        return 1
    fi
    
    local removed_count=0
    local to_remove_list
    to_remove_list=$(echo "$input_list" | tr ',' ' ')
    local keep_list=""
    
    for current in $(echo "$current_domains" | tr ',' ' '); do
        local keep=1
        for remove_item in $to_remove_list; do
            local clean_remove
            clean_remove=$(echo "$remove_item" | tr A-Z a-z)
            clean_remove="${clean_remove#"${clean_remove%%[![:space:]]*}"}"
            clean_remove="${clean_remove%"${clean_remove##*[![:space:]]}"}"
            if [ "$current" = "$clean_remove" ]; then
                keep=0
                removed_count=$((removed_count + 1))
                echo "Staging removal: $current"
                break
            fi
        done
        
        if [ "$keep" -eq 1 ]; then
            if [ -n "$keep_list" ]; then
                keep_list="${keep_list},${current}"
            else
                keep_list="${current}"
            fi
        fi
    done
    
    if [ "$removed_count" -eq 0 ]; then
        echo "Warning: None of the specified domains were found in $iface"
        return 0
    fi
    
    local target_only=0
    _is_interface_committed "$iface" && target_only=1
    db_update_staged_domains "$iface" "$keep_list" "$target_only"
    
    echo "Staged updated domain configuration for $iface ($removed_count removed)"
    echo "Run '$commit_hint' to apply changes"
}
