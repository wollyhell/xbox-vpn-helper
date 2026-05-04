# Changelog

All notable changes to this project will be documented in this file.

## v0.1.0

Initial open-source release.

### Highlights

- Added a standalone macOS SwiftUI app for Xbox-over-VPN routing.
- Added simple and advanced operating modes.
- Added automatic detection of active `utunX` VPN interfaces.
- Added automatic detection of the active USB Ethernet interface used for Xbox.
- Added one-click setup flow for:
  - `caffeinate`
  - `pmset`
  - IPv4 forwarding
  - local `10.0.0.1/24`
  - `pf` NAT routing
- Added post-reboot verification flow for Xbox.
- Added recovery logic for stale `10.0.0.1` assignments on the wrong `enX` interface.
- Added app bundle build scripts and app icon packaging.
