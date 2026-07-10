# Xbox VPN Helper

`Xbox VPN Helper` is a macOS utility for routing an Xbox through a Mac's active VPN connection using USB Ethernet.

It is designed for the setup:

`Mac -> Wi‑Fi -> VPN -> USB Ethernet -> Xbox`

The app wraps a fragile manual workflow into a small desktop tool with a simple mode, an advanced diagnostics mode, and automatic recovery for common interface conflicts.

Maintained as an open-source utility by `wolly_well_games`.

## Overview

`Xbox VPN Helper` turns a messy networking workaround into a repeatable desktop workflow.

Instead of manually hunting for the current `utunX`, reassigning `10.0.0.1`, resetting `pf`, checking whether the USB Ethernet adapter came back as `en5` or some other `enX`, and then rebooting the console at the right moment, the app guides the process from one place.

The project was built from a real-world internal setup at `wolly_well_games` and then cleaned up into a standalone open-source app. The goal is not to hide how macOS networking works, but to make a difficult, failure-prone sequence easier to run, debug, and recover.

## Features

- Detects the active `utunX` VPN interface automatically.
- Detects the current USB/Ethernet interface used for Xbox.
- Applies the common Mac-side setup for `10.0.0.1/24`, IPv4 forwarding, and `pf` NAT.
- Applies the Xbox 360 Live compatibility path used by GTA IV: VPN MTU `1380`, static-port NAT, and explicit TCP/UDP `3074` forwarding to the console.
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

## How it works

At a high level, the app does four things:

1. Detects the current VPN tunnel and the current Ethernet interface connected to the Xbox.
2. Prepares the Mac-side network state:
   - power-management tweaks
   - IPv4 forwarding
   - local `10.0.0.1/24` address
3. Rebuilds `pf` NAT rules so Xbox traffic goes out through the active `utunX`.
4. Keeps the Xbox 360 Live path open for backward-compatible games that rely on UDP `3074`.
5. Verifies the route again after the Xbox is rebooted.

It also detects one of the nastiest real-world failure cases: when `10.0.0.1` is still attached to an old interface after the USB adapter reconnects. In that case, the app can clean up the stale interface assignment before reapplying the intended configuration.

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

## Open-source notes

- License: [MIT](./LICENSE)
- Contribution guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- Security notes: [SECURITY.md](./SECURITY.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)

## Project status

This is an open-source utility extracted from a real-world internal workflow at `wolly_well_games` and hardened into a standalone app. It is useful, but still intentionally transparent and somewhat low-level: the goal is reproducible control rather than pretending macOS networking is simpler than it is.
