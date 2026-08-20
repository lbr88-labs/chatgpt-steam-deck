#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ASSET="$DIST_DIR/Install-ChatGPT-Community.desktop"

mkdir -p "$DIST_DIR"
install -m 0755 "$ROOT_DIR/Install ChatGPT Community.desktop" "$ASSET"
desktop-file-validate "$ASSET"
printf '%s\n' "$ASSET"
