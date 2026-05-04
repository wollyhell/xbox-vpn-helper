# Release v0.1.0

`Xbox VPN Helper` is now available as an open-source macOS utility for routing an Xbox through a Mac's active VPN connection over USB Ethernet.

This first public release packages a real-world internal workflow into a standalone desktop app with:

- a simple one-button mode for normal use
- an advanced diagnostics mode for visibility and debugging
- automatic `utunX` detection
- automatic Ethernet interface detection
- `pf` / NAT setup for Xbox traffic
- recovery logic for stale interface/IP conflicts after adapter reconnects

The app is meant for users who already know the pain of making `Mac -> VPN -> Ethernet -> Xbox` work reliably when native Internet Sharing falls short.

This release focuses on practical usability, explicit status reporting, and reproducible recovery over magical abstraction.
