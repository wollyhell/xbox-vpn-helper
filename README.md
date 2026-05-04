# Xbox VPN Helper

`Xbox VPN Helper` is a macOS utility for routing an Xbox through a Mac's active VPN connection using USB Ethernet.

It is designed for the setup:

`Mac -> Wi‑Fi -> VPN -> USB Ethernet -> Xbox`

The app wraps a fragile manual workflow into a small desktop tool with a simple mode, an advanced diagnostics mode, and automatic recovery for common interface conflicts.

## Features

- Detects the active `utunX` VPN interface automatically.
- Detects the current USB/Ethernet interface used for Xbox.
- Applies the common Mac-side setup for `10.0.0.1/24`, IPv4 forwarding, and `pf` NAT.
- Offers a simple one-button flow plus an advanced status and script preview mode.
- Detects and cleans stale `10.0.0.1` assignments on the wrong `enX` interface.
- Guides the user through the “configure Mac -> reboot Xbox -> verify again” loop.

## Why this exists

On some macOS + VPN + USB Ethernet combinations, Apple's built-in Internet Sharing is unreliable for Xbox traffic. This app focuses on the practical workaround many people end up doing by hand:

- keep the Mac awake
- enable forwarding
- configure a local Ethernet subnet
- bind NAT to the currently active VPN tunnel
- recover when macOS re-enumerates the adapter

## Requirements

- macOS 13+
- A VPN client that creates a usable `utunX` interface with IPv4
- A USB Ethernet adapter connected to the Xbox
- Administrator access on the Mac

## Development

```bash
swift build
./run.sh
```

## Build the app bundle

```bash
./build_app.sh
./open_app.sh
```

The built app bundle is created at:

`dist/Xbox VPN Helper.app`

## Safety notes

- `Check` is read-only.
- `Enable` / `Reconnect` request administrator privileges.
- The current compatibility flow modifies `pmset`, enables IP forwarding, and flushes/rebuilds `pf` rules.
- Read [SECURITY.md](./SECURITY.md) before using this on a machine with custom firewall or routing setup.

## Project status

This is an open-source utility extracted from a real-world internal workflow and hardened into a standalone app. It is useful, but still intentionally transparent and somewhat low-level: the goal is reproducible control rather than pretending macOS networking is simpler than it is.
