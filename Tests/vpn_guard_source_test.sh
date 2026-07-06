#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/XboxVPNHelper/VPNService.swift"

assert_contains() {
  local expected="$1"
  if ! /usr/bin/grep -Fq "$expected" "$SOURCE_FILE"; then
    echo "missing expected source text: $expected" >&2
    exit 1
  fi
}

assert_contains '/sbin/route -n get 1.1.1.1'
assert_contains 'route_if'
assert_contains 'if [[ "$route_if" == utun* ]]; then'
assert_contains '/^[^[:space:]].*: flags=/ { iface=$1; sub(":", "", iface) }'
assert_contains 'local.openclaw.xbox-vpn-guard'
assert_contains '/Library/LaunchDaemons/local.openclaw.xbox-vpn-guard.plist'
