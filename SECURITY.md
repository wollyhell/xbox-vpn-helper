# Security Notes

`Xbox VPN Helper` is a local macOS networking utility. It intentionally performs privileged operations to configure a Mac as a temporary VPN-backed gateway for an Xbox.

## What the app changes

- Starts `caffeinate` to reduce sleep-related disconnects.
- Changes `pmset` power-management values.
- Enables IPv4 forwarding.
- Reconfigures a local Ethernet interface with `10.0.0.1/24`.
- Flushes and re-applies `pf`/NAT rules to route Xbox traffic through the active `utunX` VPN interface.

## Important implications

- The app uses administrator privileges through a standard macOS authorization prompt.
- The current compatibility-oriented flow uses `pfctl -F all` and `pfctl -F nat`, which may interfere with other local `pf` rules on the machine.
- This project is intended for personal developer or home-lab use on Macs you control.
- Review the scripts before use if your machine relies on custom firewall, VPN, or routing policies.

## Recommended usage

- Run on a Mac dedicated to this Xbox/VPN workflow, or at least one without unrelated `pf` customization.
- Keep the app source local and review the generated script in advanced mode before first use.
- Disconnect and reconnect the USB Ethernet adapter if macOS renames or re-enumerates the interface.

## Reporting

If you find a security-sensitive issue in the app logic, document the scenario, your macOS version, VPN client, and Ethernet adapter model when reporting it.
