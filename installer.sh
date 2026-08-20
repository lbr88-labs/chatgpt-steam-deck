#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME='ChatGPT Community'
PACKAGE_NAME='codex-desktop'
UPSTREAM_REPO="${UPSTREAM_REPO:-ilysenko/codex-desktop-linux}"
REVIEWED_REF="${REVIEWED_REF:-1875dc2eaab6f9448617d18d0eda58902edf0f1a}"

CURL_BIN="${CURL_BIN:-curl}"
MAKE_BIN="${MAKE_BIN:-make}"
PACMAN_BIN="${PACMAN_BIN:-pacman}"
PACMAN_KEY_BIN="${PACMAN_KEY_BIN:-pacman-key}"
SUDO_BIN="${SUDO_BIN:-sudo}"
TAR_BIN="${TAR_BIN:-tar}"
UNAME_BIN="${UNAME_BIN:-uname}"
STEAMOS_READONLY_BIN="${STEAMOS_READONLY_BIN:-steamos-readonly}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
PACMAN_KEYRING_FILE="${PACMAN_KEYRING_FILE:-/etc/pacman.d/gnupg/pubring.gpg}"
CACHE_HOME="${CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck}"

READONLY_INITIAL=''
READONLY_CHANGED=0

info() {
    printf '\033[1;34m[installer]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[installer][warning]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31m[installer][error]\033[0m %s\n' "$*" >&2
    return 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        "$SUDO_BIN" "$@"
    fi
}

validate_platform() {
    local os_id=''
    if [[ -r "$OS_RELEASE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$OS_RELEASE_FILE"
        os_id="${ID:-}"
    fi

    [[ "$os_id" == 'steamos' ]] || die 'This helper supports SteamOS only.'
    [[ "$($UNAME_BIN -m)" == 'x86_64' ]] || die 'Steam Deck x86_64 is required.'
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command_exists "$command_name" || die "Required command is missing: $command_name"
    done
}

resolve_archive_url() {
    local ref="$1"
    if [[ "$ref" == 'main' ]]; then
        printf 'https://github.com/%s/archive/refs/heads/main.tar.gz\n' "$UPSTREAM_REPO"
    elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'https://github.com/%s/archive/%s.tar.gz\n' "$UPSTREAM_REPO" "$ref"
    else
        die "Refusing unsupported upstream revision: $ref"
    fi
}

capture_readonly_state() {
    [[ -n "$READONLY_INITIAL" ]] && return 0
    if command_exists "$STEAMOS_READONLY_BIN"; then
        READONLY_INITIAL="$($STEAMOS_READONLY_BIN status 2>/dev/null || true)"
    else
        READONLY_INITIAL='unavailable'
    fi
}

ensure_writable_system() {
    capture_readonly_state
    if [[ "$READONLY_INITIAL" == 'enabled' && "$READONLY_CHANGED" -eq 0 ]]; then
        info 'Temporarily disabling SteamOS read-only mode.'
        run_root "$STEAMOS_READONLY_BIN" disable
        READONLY_CHANGED=1
    fi
}

restore_readonly() {
    if [[ "$READONLY_CHANGED" -eq 1 && "$READONLY_INITIAL" == 'enabled' ]]; then
        info 'Restoring SteamOS read-only mode.'
        run_root "$STEAMOS_READONLY_BIN" enable || warn 'Could not restore read-only mode automatically. Run: sudo steamos-readonly enable'
        READONLY_CHANGED=0
    fi
}

ensure_pacman_keyring() {
    [[ -s "$PACMAN_KEYRING_FILE" ]] && return 0
    info 'Initializing the signed Arch Linux and SteamOS package keyring.'
    run_root "$PACMAN_KEY_BIN" --init
    run_root "$PACMAN_KEY_BIN" --populate archlinux holo
}

check_disk_space() {
    local available_kib required_kib=$((6 * 1024 * 1024))
    available_kib="$(df -Pk "$CACHE_HOME" 2>/dev/null | awk 'NR == 2 {print $4}')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] || return 0
    ((available_kib >= required_kib)) || die 'At least 6 GiB of free space is required for the build.'
}

safe_remove_cache_path() {
    local path="$1"
    case "$path" in
        "$CACHE_HOME"/*) rm -rf -- "$path" ;;
        *) die "Refusing to remove path outside installer cache: $path" ;;
    esac
}

download_source() {
    local ref="$1" url archive staging destination suffix
    url="$(resolve_archive_url "$ref")"
    suffix="${ref:0:12}"
    destination="$CACHE_HOME/upstream-$suffix"

    mkdir -p "$CACHE_HOME"
    check_disk_space
    archive="$(mktemp "$CACHE_HOME/.source.XXXXXX.tar.gz")"
    staging="$(mktemp -d "$CACHE_HOME/.source.XXXXXX")"

    info "Downloading upstream source: $url"
    if ! "$CURL_BIN" --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --output "$archive" "$url"; then
        safe_remove_cache_path "$archive"
        safe_remove_cache_path "$staging"
        die 'Could not download the upstream source archive.'
        return 1
    fi

    if ! "$TAR_BIN" -xzf "$archive" --strip-components=1 -C "$staging"; then
        safe_remove_cache_path "$archive"
        safe_remove_cache_path "$staging"
        die 'The upstream source archive could not be extracted.'
        return 1
    fi
    safe_remove_cache_path "$archive"

    [[ -x "$staging/install.sh" && -f "$staging/scripts/install-deps.sh" ]] || {
        safe_remove_cache_path "$staging"
        die 'The upstream source archive is incomplete.'
        return 1
    }

    safe_remove_cache_path "$destination"
    mv -- "$staging" "$destination"
    printf '%s\n' "$destination"
}

ensure_rust_toolchain() {
    if cargo --version >/dev/null 2>&1; then
        return 0
    fi
    command_exists rustup || die 'Rustup was not installed by the upstream dependency bootstrap.'
    info 'Installing the stable Rust toolchain required by the update manager.'
    rustup toolchain install stable --profile minimal
    rustup default stable
}

install_or_update() {
    local ref="$1" source_dir
    validate_platform
    require_commands "$CURL_BIN" "$TAR_BIN" "$SUDO_BIN" "$PACMAN_BIN"
    mkdir -p "$CACHE_HOME"
    source_dir="$(download_source "$ref")"

    capture_readonly_state
    ensure_writable_system
    ensure_pacman_keyring

    info 'Installing the build dependencies declared by the upstream project.'
    (cd "$source_dir" && bash scripts/install-deps.sh)
    ensure_rust_toolchain

    info "Building and installing $APP_NAME. This can take several minutes."
    (cd "$source_dir" && PATH="$HOME/.cargo/bin:$PATH" "$MAKE_BIN" install-native)
    info "$APP_NAME is installed. Find it in the application launcher under Internet."
}

uninstall_app() {
    local answer
    printf 'Remove %s and its package-managed files? [y/N] ' "$APP_NAME"
    read -r answer || answer=''
    case "$answer" in
        y|Y|yes|YES)
            validate_platform
            require_commands "$SUDO_BIN" "$PACMAN_BIN"
            capture_readonly_state
            ensure_writable_system
            run_root "$PACMAN_BIN" -Rns --noconfirm "$PACKAGE_NAME"
            info "$APP_NAME was removed. User profile data was left untouched."
            ;;
        *) info 'Uninstall cancelled.' ;;
    esac
}

show_menu() {
    printf '\n%s Steam Deck helper\n\n' "$APP_NAME"
    printf '  1) Install or update from upstream main (default)\n'
    printf '  2) Install or update from reviewed commit %.12s\n' "$REVIEWED_REF"
    printf '  3) Uninstall\n'
    printf '  4) Exit\n\n'
    printf 'Choose [1]: '
}

main() {
    local choice
    trap restore_readonly EXIT
    trap 'exit 130' INT TERM

    show_menu
    read -r choice || choice='4'
    choice="${choice:-1}"
    case "$choice" in
        1) install_or_update main ;;
        2) install_or_update "$REVIEWED_REF" ;;
        3) uninstall_app ;;
        4) info 'No changes made.' ;;
        *) die 'Choose 1, 2, 3, or 4.' ;;
    esac
}

if [[ "${INSTALLER_TEST_MODE:-0}" != '1' ]]; then
    main "$@"
fi
