# Release History

## v1.0.0 - (2026-06-21)

First stable release of the unified Route10 VPN Client, introducing a protocol-wrapper + shared-core architecture that supports robust dual-stack IPv4/IPv6 policy-based routing, automatic roaming, and leak prevention for WireGuard and OpenVPN.

### Key Features

#### 🛡️ Protocol-Wrapper + Shared-Core Architecture
- Decouples VPN protocol-specific parsing from routing logic.
- Built-in SQLite state database for staging and committing routing changes.
- Hot-reloads targets without bouncing interfaces when only IP/domain lists change.

#### 🌐 Dual-Stack IPv4 & IPv6 Policy-Based Routing (PBR)
- Multi-client routing modes supporting IPv4, IPv6, subnet, or MAC address targets.
- Supports provider-style NAT66 IPv6 tunnels.
- Supports delegated routed-prefix mode for public routable IPv6, assigning globally routable IPv6 addresses to your clients if your VPN provider supports it.
- Domain-based split tunneling (WireGuard) integrates with local DNS resolution.

#### 🔄 Automatic DHCP Roaming
- Automatically adapts MAC-based client routing to new IP allocations when clients roam on the LAN.
- Serialized DHCP hotplug execution with storm guard controls to prevent race conditions.

#### 🔒 Leak Prevention & Dual-Stack DNS Protection
- Internet kill-switch prevents unencrypted traffic bypass if the assigned VPN tunnel drops.
- Dual-stack DNS leak protection redirects client DNS queries through the VPN and blocks unauthorized WAN-side DNS replies.
- Proactive IPv6 leak prevention blocks WAN IPv6 routes for routed clients on IPv4-only tunnels.

#### 🔌 Extensible Plugin System
- Allows custom scripts to hook into lifecycle events, firewall reloads, and extend command line interface support.
- Fully supports WireGuard (`wg.sh`) and OpenVPN (`ovpn.sh`) clients.

Refer to [README.md](README.md) for more info.
