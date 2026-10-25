#!/usr/bin/env bash
set -Eeuo pipefail

# Build only. The resulting AppImage runs on the host, outside this container.
[[ -e /run/.containerenv || -e /.dockerenv ]] || {
    echo 'This build helper must run inside the installer build container.' >&2
    exit 1
}
source_dir="$(realpath "$1")"
# SteamOS /tmp is a quota-limited tmpfs. ASAR repacking needs substantial scratch
# space, so keep this build's temporary files beside the source on the SSD.
build_tmp="$(mktemp -d "$(dirname "$source_dir")/.appimage-build-tmp.XXXXXX")"
export TMPDIR="$build_tmp"
trap 'rm -rf -- "$build_tmp"' EXIT
unset SUDO_ASKPASS
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

sudo pacman -Syu --noconfirm --needed \
    ca-certificates curl dpkg git gnupg make nodejs npm python \
    squashfs-tools desktop-file-utils fuse2 file util-linux zstd

python3 "$(dirname "$0")/patch-appimage-desktop.py" "$source_dir"

tool_dir="$HOME/.cache/chatgpt-appimagetool-1.9.1"
mkdir -p "$tool_dir"
tool="$tool_dir/appimagetool.AppImage"
tool_hash=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
if ! printf '%s  %s\n' "$tool_hash" "$tool" | sha256sum --check --status; then
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --output "$tool" \
        https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
    printf '%s  %s\n' "$tool_hash" "$tool" | sha256sum --check
fi
chmod 700 "$tool"
if [[ ! -x "$tool_dir/squashfs-root/AppRun" ]]; then
    (cd "$tool_dir" && "$tool" --appimage-extract >/dev/null)
fi
export APPIMAGETOOL="$tool_dir/squashfs-root/AppRun"
cd "$source_dir"
make build-app appimage PACKAGE_WITH_UPDATER=0 MAX_BUILD_THREADS=4
