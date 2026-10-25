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
DPKG_STATE_DIR="${DPKG_STATE_DIR:-/var/lib/dpkg}"
APP_INSTALL_DIR="${APP_INSTALL_DIR:-/opt/codex-desktop}"
CACHE_HOME="${CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck}"

READONLY_INITIAL=''
READONLY_CHANGED=0
ORPHANED_APP_BACKUP=''

info() {
    printf '\033[1;34m[installer]\033[0m %s\n' "$*" >&2
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

cleanup() {
    restore_orphaned_app_tree || true
    restore_readonly
}

ensure_pacman_keyring() {
    [[ -s "$PACMAN_KEYRING_FILE" ]] && return 0
    info 'Initializing the signed Arch Linux and SteamOS package keyring.'
    run_root "$PACMAN_KEY_BIN" --init
    run_root "$PACMAN_KEY_BIN" --populate archlinux holo
}

recover_stale_dpkg_state() {
    local entry path query_output query_status backup_dir
    local found_available=0 found_status=0
    local restore_nullglob=0 restore_dotglob=0
    local -a state_entries=()

    if query_output="$(LC_ALL=C "$PACMAN_BIN" -Qq dpkg 2>&1)"; then
        return 0
    else
        query_status=$?
    fi
    if [[ "$query_status" -ne 1 || "$query_output" != "error: package 'dpkg' was not found" ]]; then
        die 'Could not verify whether dpkg is installed; refusing automatic recovery.'
        return 1
    fi

    if [[ -L "$DPKG_STATE_DIR" ]]; then
        die "Refusing to alter a symlinked dpkg state directory at $DPKG_STATE_DIR."
        return 1
    fi
    [[ -d "$DPKG_STATE_DIR" ]] || return 0

    if [[ ! -r "$DPKG_STATE_DIR" || ! -x "$DPKG_STATE_DIR" ]]; then
        die "Could not inspect dpkg state at $DPKG_STATE_DIR; refusing automatic recovery."
        return 1
    fi

    shopt -q nullglob && restore_nullglob=1
    shopt -q dotglob && restore_dotglob=1
    shopt -s nullglob dotglob
    state_entries=("$DPKG_STATE_DIR"/*)
    [[ "$restore_nullglob" -eq 1 ]] || shopt -u nullglob
    [[ "$restore_dotglob" -eq 1 ]] || shopt -u dotglob

    for path in "${state_entries[@]}"; do
        entry="${path##*/}"
        case "$entry" in
            available) found_available=1 ;;
            status) found_status=1 ;;
            *)
                die "Refusing to alter unexpected dpkg state left at $DPKG_STATE_DIR/$entry."
                return 1
                ;;
        esac
    done

    if [[ "$found_available" -ne 1 || "$found_status" -ne 1 ]]; then
        die "Refusing to alter incomplete dpkg state at $DPKG_STATE_DIR."
        return 1
    fi

    for entry in available status; do
        path="$DPKG_STATE_DIR/$entry"
        if [[ -L "$path" || ! -f "$path" || -s "$path" ]]; then
            die "Refusing to alter nonempty or non-regular dpkg state at $path."
            return 1
        fi
        if query_output="$(LC_ALL=C "$PACMAN_BIN" -Qo "$path" 2>&1)"; then
            die "Refusing to alter package-owned dpkg state at $path."
            return 1
        else
            query_status=$?
        fi
        if [[ "$query_status" -ne 1 || "$query_output" != "error: No package owns $path" ]]; then
            die "Could not verify package ownership for $path; refusing automatic recovery."
            return 1
        fi
    done

    if ! backup_dir="$(run_root mktemp -d "${DPKG_STATE_DIR}.chatgpt-steam-deck.XXXXXX")"; then
        die 'Could not allocate a protected dpkg recovery path.'
        return 1
    fi
    case "$backup_dir" in
        "${DPKG_STATE_DIR}.chatgpt-steam-deck."*) ;;
        *)
            die "Refusing unexpected dpkg recovery path: $backup_dir"
            return 1
            ;;
    esac
    if ! run_root rmdir -- "$backup_dir"; then
        die "Could not prepare protected dpkg recovery path at $backup_dir."
        return 1
    fi

    info 'Recovering empty dpkg state files preserved by a SteamOS upgrade.'
    if ! run_root mv -T -- "$DPKG_STATE_DIR" "$backup_dir"; then
        die "Could not preserve stale dpkg state at $backup_dir."
        return 1
    fi
    info "Preserved the stale dpkg state at $backup_dir."
}

recover_orphaned_app_tree() {
    local query_output query_status backup_dir

    if query_output="$(LC_ALL=C "$PACMAN_BIN" -Qq "$PACKAGE_NAME" 2>&1)"; then
        if [[ "$query_output" != "$PACKAGE_NAME" ]]; then
            die "Unexpected pacman result while checking $PACKAGE_NAME."
            return 1
        fi
        return 0
    else
        query_status=$?
    fi
    if [[ "$query_status" -ne 1 || "$query_output" != "error: package '$PACKAGE_NAME' was not found" ]]; then
        die "Could not verify whether $PACKAGE_NAME is installed; refusing automatic recovery."
        return 1
    fi

    [[ -e "$APP_INSTALL_DIR" || -L "$APP_INSTALL_DIR" ]] || return 0
    if [[ -L "$APP_INSTALL_DIR" || ! -d "$APP_INSTALL_DIR" ]]; then
        die "Refusing to alter a non-directory application path at $APP_INSTALL_DIR."
        return 1
    fi

    if query_output="$(LC_ALL=C "$PACMAN_BIN" -Qo "$APP_INSTALL_DIR" 2>&1)"; then
        die "Refusing to alter a package-owned application tree at $APP_INSTALL_DIR."
        return 1
    else
        query_status=$?
    fi
    if [[ "$query_status" -ne 1 || "$query_output" != "error: No package owns $APP_INSTALL_DIR" ]]; then
        die "Could not verify package ownership for $APP_INSTALL_DIR; refusing automatic recovery."
        return 1
    fi

    if ! backup_dir="$(run_root mktemp -d "${APP_INSTALL_DIR}.chatgpt-steam-deck.XXXXXX")"; then
        die 'Could not allocate a protected application recovery path.'
        return 1
    fi
    case "$backup_dir" in
        "${APP_INSTALL_DIR}.chatgpt-steam-deck."*) ;;
        *)
            die "Refusing unexpected application recovery path: $backup_dir"
            return 1
            ;;
    esac
    if ! run_root rmdir -- "$backup_dir"; then
        die "Could not prepare protected application recovery path at $backup_dir."
        return 1
    fi

    info 'Preserving the application tree orphaned by a SteamOS upgrade.'
    if ! run_root mv -T -- "$APP_INSTALL_DIR" "$backup_dir"; then
        die "Could not preserve the orphaned application tree at $backup_dir."
        return 1
    fi
    ORPHANED_APP_BACKUP="$backup_dir"
    info "Preserved the orphaned application tree at $backup_dir."
}

restore_orphaned_app_tree() {
    [[ -n "$ORPHANED_APP_BACKUP" ]] || return 0
    if [[ -e "$APP_INSTALL_DIR" || -L "$APP_INSTALL_DIR" ]]; then
        warn "Could not restore the previous application tree automatically; it remains at $ORPHANED_APP_BACKUP."
        return 1
    fi
    info 'Restoring the previous application tree after installation failure.'
    if ! run_root mv -T -- "$ORPHANED_APP_BACKUP" "$APP_INSTALL_DIR"; then
        warn "Could not restore the previous application tree automatically; it remains at $ORPHANED_APP_BACKUP."
        return 1
    fi
    ORPHANED_APP_BACKUP=''
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

patch_steamos_updater() {
    local source_dir="$1" patch_script
    patch_script="$CACHE_HOME/patch-steamos-updater.py"
    info 'Applying SteamOS support to automatic updater installation and rollback.'
    "$CURL_BIN" --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --output "$patch_script" \
        https://raw.githubusercontent.com/lbr88-labs/chatgpt-steam-deck/main/scripts/patch-steamos-updater.py
    python3 "$patch_script" "$source_dir"
}

install_or_update() {
    local ref="$1" source_dir
    validate_platform
    require_commands "$CURL_BIN" "$TAR_BIN" "$SUDO_BIN" "$PACMAN_BIN"
    mkdir -p "$CACHE_HOME"
    source_dir="$(download_source "$ref")"

    capture_readonly_state
    ensure_writable_system
    recover_stale_dpkg_state
    ensure_pacman_keyring

    info 'Installing the build dependencies declared by the upstream project.'
    (cd "$source_dir" && bash scripts/install-deps.sh)
    ensure_rust_toolchain
    patch_steamos_updater "$source_dir"

    info "Building $APP_NAME. This can take several minutes."
    (cd "$source_dir" && PATH="$HOME/.cargo/bin:$PATH" \
        "$MAKE_BIN" build-native-feature-helpers build-app package)

    recover_orphaned_app_tree
    info "Installing $APP_NAME."
    if ! (cd "$source_dir" && PATH="$HOME/.cargo/bin:$PATH" "$MAKE_BIN" install); then
        restore_orphaned_app_tree || true
        return 1
    fi
    ORPHANED_APP_BACKUP=''
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
    trap cleanup EXIT
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
