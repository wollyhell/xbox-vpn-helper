# Contributing

Thanks for looking at `Xbox VPN Helper`.

## Development

```bash
swift build
./run.sh
```

## Release build

```bash
./build_app.sh
./open_app.sh
```

## Contribution guidelines

- Keep the app macOS-only unless there is a strong reason to generalize.
- Prefer explicit logging over hidden automation when touching privileged networking behavior.
- Avoid adding background daemons or silent persistence without a clear user-facing explanation.
- Document any change that alters `pf`, routing, interface selection, or power-management behavior.

## Pull requests

- Explain the exact user scenario being improved.
- Mention the tested macOS version, VPN client, and Ethernet adapter if relevant.
- Include before/after behavior for networking or interface-detection fixes.
