# OpenVPN Migration Todo List

This file tracks the required fixes and feature parities to be ported from the WireGuard implementation to the OpenVPN client.

## Safety & Critical Fixes

- [ ] **UCI Loop Safety**: Add `ovpn_post_delete` hook with safety counters to prevent infinite configuration loops.
- [ ] **SQLite Full Protection**: Ensure any mock environments used for testing don't generate runaway logs.

## Feature Parity (Port from wg.sh/vpn-core.sh)

- [ ] **NAT66 Threshold**: Update `analyze_ipv6` logic (in `lib/common.sh`) to support prefixes <= /64 for OpenVPN interfaces.
- [ ] **Dynamic IPv6 Discovery**: Verify `vpn_core_discover_client_ipv6` works with OpenVPN's `tun_` interface naming.
- [ ] **Status Reporting**: Verify field indexing in `plugins/status.sh` handles OpenVPN entries correctly.
- [ ] **Interface Specific SNAT**: Ensure `setup_nat66` is correctly triggered for OpenVPN global IPv6 addresses in `ifup` hotplugs.

## Lifecycle Enhancements

- [ ] **Post-Commit Service Restart**: Refine `/etc/init.d/openvpn restart` logic to be more granular if possible.
- [ ] **DNS Parsing**: Improve `.ovpn` parser to extract DNS servers more robustly.
- [ ] **IPv6 Support Detection**: Improve detection of IPv6 support in config files.
