# OpenVPN Guide

`ovpn.sh` is the OpenVPN wrapper for the shared Route10 VPN core.

Use it when you want to route selected clients through an OpenVPN profile while keeping the rest of the router on its normal WAN path.

## Stage And Commit

Most commands stage changes first. Nothing is fully applied until `commit` runs.

```bash
cd /cfg/vpn-client
./ovpn.sh ovproton1 -c conf/proton.udp.ovpn -a conf/proton-auth.conf -t 10.90.10.0/24
./ovpn.sh commit
```

Use `ovpn.sh commit` for OpenVPN staged changes so OpenVPN service reloads run through the OpenVPN wrapper path.

## Client Routing

Route one or more IPv4/IPv6 addresses, subnets, or MAC addresses through an OpenVPN interface:

```bash
./ovpn.sh ovproton1 -c conf/proton.udp.ovpn -a conf/proton-auth.conf -t 10.90.10.25,2001:db8:1::50,10.90.20.0/24,aa:bb:cc:dd:ee:ff
./ovpn.sh commit
```

MAC targets are useful for devices that roam between DHCP addresses.

## Authentication Files

For tunnels requiring username/password authentication, pass the `-a` or `--auth` argument targeting your credentials file. The wrapper supports two formats for this file:

### Format A (Standard OpenVPN line-based)
```text
your_username
your_password
```

### Format B (Key-value pairs)
```text
username=your_username
password=your_password
```

These files should ideally be placed in the `conf/` directory alongside your `.ovpn` profiles (e.g., `conf/puresyd-auth.conf`).

## Provider Route Protection

OpenVPN providers often push global routes. `ovpn.sh` generates a runtime config that ignores:

- `redirect-gateway`
- pushed `route` directives

This prevents the provider profile from taking over router-wide routing outside the selected policy targets.

The generated runtime config is written to:

```text
conf/.<VPN_PREFIX>_<iface>.ovpn
```

## Commands

```bash
./ovpn.sh status
./ovpn.sh commit
./ovpn.sh reapply
./ovpn.sh delete <iface>
./ovpn.sh version
```

## Target Management

```bash
./ovpn.sh assign-ips <iface> <ip-or-subnet-or-mac-list>
./ovpn.sh remove-ips <iface> <ip-or-subnet-or-mac-list>
./ovpn.sh commit
```

`assign-ips` and `remove-ips` can hot-reload routing changes without restarting the tunnel when only targets changed.

## Arguments

| Argument | Purpose |
| --- | --- |
| `<iface>` | OpenVPN interface name, maximum 11 characters |
| `-c`, `--conf` | Path to the OpenVPN `.ovpn` file |
| `-a`, `--auth` | Optional username/password auth file |
| `-t`, `--targets` | Comma-separated IPv4/IPv6 addresses, subnets, or MAC addresses |

## IPv6 Behavior

OpenVPN profiles with IPv6 support can use the shared IPv6 handling in the core. Profiles without IPv6 support are treated as IPv4-only for managed clients so IPv6 does not leak through the WAN path.
