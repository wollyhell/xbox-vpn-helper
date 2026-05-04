#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$ROOT_DIR/dist/Xbox VPN Helper.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Приложение ещё не собрано. Сначала запусти ./build_app.sh"
  exit 1
fi

open "$APP_PATH"
