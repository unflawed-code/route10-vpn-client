# WireGuard Guide

`wg.sh` is the WireGuard wrapper for the shared Route10 VPN core.

Use it when you want to route selected clients through WireGuard, route selected domains through WireGuard, or provide public routable IPv6 to routed clients when the WireGuard server delegates a prefix.

## Stage And Commit

Most commands stage changes first. Nothing is fully applied until `commit` runs.

```bash
cd /cfg/vpn-client
./wg.sh wgproton1 -c conf/wgproton1.conf -t 10.90.15.0/24
./wg.sh commit
```

## Client Routing

Route one or more IPv4/IPv6 addresses, subnets, or MAC addresses through a WireGuard interface:

```bash
./wg.sh wgproton1 -c conf/wgproton1.conf -t 10.90.15.25,2001:db8:1::50,10.90.16.0/24,aa:bb:cc:dd:ee:ff
./wg.sh commit
```

MAC targets are useful for devices that roam between DHCP addresses.

## Domain Split Tunneling

Route selected domains through WireGuard while leaving other traffic on the normal gateway:

```bash
./wg.sh wgsplit1 -c conf/wgsplit1.conf -d ipleak.net,example.com
./wg.sh commit
```

Split-tunnel mode is exclusive for that interface. Do not combine `-d` with `-t`.

Clients already routed through another VPN are not captured by the split-tunnel domain path.

## Public Routed-Prefix IPv6

NAT66 is supported for the common commercial-VPN case where the tunnel only provides a single IPv6 address. Routed-prefix mode is separate: use it when your WireGuard server delegates a real routed IPv6 prefix to the router and you want LAN clients to receive public routable IPv6 without NAT66.

```bash
./wg.sh wgrouted1 -c conf/wgrouted1.conf -t 10.90.15.0/24 --ipv6-mode routed-prefix
./wg.sh commit
```

`routed-prefix` mode accepts exactly one subnet target. Host IP and MAC targets are not supported in this mode.

## Commands

```bash
./wg.sh status
./wg.sh commit
./wg.sh reapply
./wg.sh delete <iface>
./wg.sh version
```

## Target Management

```bash
./wg.sh assign-ips <iface> <ip-or-subnet-or-mac-list>
./wg.sh remove-ips <iface> <ip-or-subnet-or-mac-list>
./wg.sh assign-domains <iface> <domain-list>
./wg.sh remove-domains <iface> <domain-list>
./wg.sh commit
```

`assign-ips` and `remove-ips` can hot-reload routing changes without restarting the tunnel when only targets changed.

## Arguments

| Argument | Purpose |
| --- | --- |
| `<iface>` | WireGuard interface name, maximum 11 characters |
| `-c`, `--conf` | Path to the WireGuard `.conf` file |
| `-t`, `--targets` | Comma-separated IPv4/IPv6 addresses, subnets, or MAC addresses |
| `-d`, `--domains` | Comma-separated domains for split tunneling |
| `--ipv6-mode` | `nat66`, `routed-prefix`, or `disabled` |

## IPv6 Behavior

- `nat66`: default mode for provider-style single-address IPv6 tunnels.
- `routed-prefix`: public routable IPv6 for LAN clients when the WireGuard server delegates a routed prefix to your router.
- `disabled`: force IPv4-only behavior and block IPv6 for managed clients.
