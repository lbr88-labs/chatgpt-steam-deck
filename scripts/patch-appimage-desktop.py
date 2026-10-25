#!/usr/bin/env python3
"""Keep Plasma's launcher hint on the installed desktop entry, not scratch files."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "packaging/appimage/codex-appimage-runtime.sh"
text = path.read_text()
anchor = '    if [ -n "${APPDIR:-}" ] && [ -f "$APPDIR/__PACKAGE_NAME__.desktop" ]; then'
replacement = '''    if [ -n "${CODEX_APPIMAGE_DESKTOP_FILE:-}" ] && [ -f "$CODEX_APPIMAGE_DESKTOP_FILE" ]; then
        export CHROME_DESKTOP="$(basename "$CODEX_APPIMAGE_DESKTOP_FILE")"
        export BAMF_DESKTOP_FILE_HINT="$CODEX_APPIMAGE_DESKTOP_FILE"
    elif [ -n "${APPDIR:-}" ] && [ -f "$APPDIR/__PACKAGE_NAME__.desktop" ]; then'''
if 'export BAMF_DESKTOP_FILE_HINT="$CODEX_APPIMAGE_DESKTOP_FILE"' not in text:
    if text.count(anchor) != 1:
        raise SystemExit("Upstream AppImage launcher changed; refusing an unverified patch")
    path.write_text(text.replace(anchor, replacement))
