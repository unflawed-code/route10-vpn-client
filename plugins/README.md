# Route10 VPN Plugin System

## Overview

Plugins extend VPN client functionality by hooking into specific execution points. Each plugin is a shell script that defines functions matching hook names.

## Plugin Directory Structure

```sh
plugins/
├── *.sh           # Generic plugins (run for ALL VPN types)
├── wg/
│   └── *.sh       # WireGuard-specific plugins (only run for WireGuard)
└── ovpn/
    └── *.sh       # OpenVPN-specific plugins (only run for OpenVPN)
```

## Available Hooks

### Command Handlers (run before workflow)

| Hook | When Called | Arguments |
| ---- | ----------- | --------- |
| `show_plugin_help` | When usage/help is displayed | (none) |
| `handle_command` | Before arg parsing | `$@`: all CLI arguments |

> **Note**: `handle_command` should return 0 if the command was handled, or 1 to continue normal argument parsing.

### Workflow Hooks (in execution order)

| # | Hook | When Called | Arguments |
| - | ---- | ----------- | --------- |
| 1 | `pre_init` | Before DB registration | `$1`: interface, `$2`: type |
| 2 | `post_init` | After DB registration | `$1`: interface, `$2`: type |
| 3 | `pre_configure` | Before PBR setup | `$1`: interface, `$2`: type |
| 4 | `post_configure` | After PBR setup | `$1`: interface, `$2`: type |
| 5 | `pre_start` | Before interface up | `$1`: interface, `$2`: type |
| 6 | `post_start` | After interface up | `$1`: interface, `$2`: type |
| 7 | `pre_stop` | Before interface down | `$1`: interface, `$2`: type |
| 8 | `post_stop` | After interface down | `$1`: interface, `$2`: type |
| 9 | `pre_teardown` | Before cleanup | `$1`: interface, `$2`: type |
| 10 | `post_teardown` | After cleanup | `$1`: interface, `$2`: type |
| 11 | `pre_delete` | Before permanent delete workflow | `$1`: interface, `$2`: type |
| 12 | `post_delete` | After permanent delete workflow | `$1`: interface, `$2`: type |

> **Note**: `$2` (type) is always `"wireguard"` or `"openvpn"`.

### Commit Hooks

| # | Hook | When Called | Arguments |
| - | ---- | ----------- | --------- |
| 1 | `pre_commit` | Before batch commit | (none) |
| 2 | `post_commit` | After batch commit | (none) |

### Other Hooks

| Hook | When Called | Arguments |
| ---- | ----------- | --------- |
| `fw_reload` | When firewall rules are reapplied | `$1`: interface, `$2`: type |

## Creating a Plugin

1. Create a `.sh` file in the appropriate directory:
   - `plugins/` for generic plugins
   - `plugins/wg/` for WireGuard-specific plugins
   - `plugins/ovpn/` for OpenVPN-specific plugins
2. Define one or more hook functions
3. Functions are called automatically when the hook point is reached

### Example: Generic Plugin

```sh
#!/bin/sh
# plugins/logging.sh - Logs all lifecycle events

post_init() {
    local iface="$1"
    local type="$2"
    logger -t "vpn-plugin" "[$iface] Initialized ($type)"
}

post_start() {
    local iface="$1"
    local type="$2"
    logger -t "vpn-plugin" "[$iface] Started ($type)"
}
```

### Example: WireGuard-Specific Plugin

```sh
#!/bin/sh
# plugins/wg/split-tunnel.sh - WireGuard split-tunnel support

post_configure() {
    local iface="$1"
    local type="$2"  # Always "wireguard" for plugins in plugins/wg/
    
    # Split-tunnel logic specific to WireGuard
    echo "Setting up split-tunnel for $iface"
}
```

### Example: Generic Plugin with Type Check

```sh
#!/bin/sh
# plugins/notify.sh - Different behavior per VPN type

post_start() {
    local iface="$1"
    local type="$2"
    
    case "$type" in
        wireguard)
            echo "WireGuard interface $iface started"
            ;;
        openvpn)
            echo "OpenVPN interface $iface started"
            ;;
    esac
}
```

## Plugin Guidelines

- **Naming**: Use descriptive names. Prefix with numbers for execution order: `00-first.sh`, `10-second.sh`
- **Return values**: `pre_*` hooks can return non-zero to abort; `post_*` logs warnings but continues
- **Logging**: Use `echo` for user-facing output, `logger -t vpn-plugin` for system logs
- **Idempotent**: Plugins may be called multiple times; design accordingly
- **No side effects**: Don't modify global variables or call `exit`
