#!/usr/bin/env bash
# Sourced by installer.sh; the AppImage itself always runs on the host.

APPIMAGE_HOME="${APPIMAGE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/chatgpt-community-appimage}"
APPIMAGE_DESKTOP_FILE="${APPIMAGE_DESKTOP_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/applications/codex-desktop.desktop}"
DISTROBOX_BIN="${DISTROBOX_BIN:-distrobox}"
PODMAN_BIN="${PODMAN_BIN:-podman}"
BUILD_BOX='chatgpt-appimage-builder'
APPIMAGE_TRANSACTION=0
APPIMAGE_HAD_PREVIOUS=0
APPIMAGE_HAD_DESKTOP=0
APPIMAGE_PUBLISHED=0
APPIMAGE_DESKTOP_PUBLISHED=0
APPIMAGE_CANDIDATE_DIR=''
APPIMAGE_DESKTOP_STAGE=''
UPDATER_WAS_ACTIVE=0
UPDATER_WAS_ENABLED=0
MODE_COMMITTED=0

appimage_is_installed() {
    [[ -f "$APPIMAGE_HOME/.managed-by-installer" && -x "$APPIMAGE_HOME/ChatGPT-Community.AppImage" ]]
}

native_is_installed() {
    "$PACMAN_BIN" -Qq "$PACKAGE_NAME" >/dev/null 2>&1 || [[ -d "$APP_INSTALL_DIR" ]]
}

detect_installation_mode() {
    INSTALLATION_MODE='Not installed'
    APPIMAGE_ACTION='Install or update — AppImage (recommended)'
    NATIVE_ACTION='Install or update — standard installation'
    if appimage_is_installed; then
        INSTALLATION_MODE='AppImage'
        NATIVE_ACTION='Switch to standard installation — removes AppImage'
    elif native_is_installed; then
        INSTALLATION_MODE='Standard installation'
        APPIMAGE_ACTION='Switch to AppImage — removes standard installation'
    fi
}

ensure_package_manager_idle() {
    if [[ -e /var/lib/pacman/db.lck ]]; then
        die 'A system update or another package installation is running. Let it finish, then run this installer again.'
        return 1
    fi
}

wait_for_app_exit() {
    if pgrep -u "$(id -u)" -x ChatGPT >/dev/null; then
        if [[ "$GUI_MODE" -eq 1 ]]; then
            "$ZENITY_BIN" --info --title='Please close ChatGPT Community' \
                --text='Please close ChatGPT Community before installing, updating, switching methods, or uninstalling. Then run this desktop installer again. Nothing has been changed.'
        else
            warn 'Please close ChatGPT Community, then run this desktop installer again. Nothing has been changed.'
        fi
        return 1
    fi
}

pause_native_updater() {
    if systemctl --user is-active --quiet codex-update-manager.service 2>/dev/null; then
        UPDATER_WAS_ACTIVE=1
    fi
    if systemctl --user is-enabled --quiet codex-update-manager.service 2>/dev/null; then
        UPDATER_WAS_ENABLED=1
    fi
    if [[ "$UPDATER_WAS_ACTIVE" -eq 1 || "$UPDATER_WAS_ENABLED" -eq 1 ]]; then
        systemctl --user disable --now codex-update-manager.service
    fi
}

remove_managed_appimage_dir() {
    local directory="$1"
    [[ -e "$directory" || -L "$directory" ]] || return 0
    if [[ -L "$directory" || ! -f "$directory/.managed-by-installer" ||
        "$(cat "$directory/.managed-by-installer")" != 'chatgpt-steam-deck appimage v1' ]]; then
        die "Refusing to remove an unmanaged AppImage directory: $directory"
        return 1
    fi
    rm -rf -- "$directory"
}

cleanup_installation_mode() {
    if [[ "$APPIMAGE_TRANSACTION" -eq 1 ]]; then
        if [[ "$APPIMAGE_PUBLISHED" -eq 1 ]]; then remove_managed_appimage_dir "$APPIMAGE_HOME" || true; fi
        if [[ "$APPIMAGE_HAD_PREVIOUS" -eq 1 ]]; then
            mv -T -- "$APPIMAGE_HOME.previous" "$APPIMAGE_HOME" || warn 'Could not restore the previous AppImage.'
        fi
        if [[ "$APPIMAGE_DESKTOP_PUBLISHED" -eq 1 ]]; then
            if [[ "$APPIMAGE_HAD_DESKTOP" -eq 1 ]]; then
                mv -T -- "$APPIMAGE_HOME.previous.desktop" "$APPIMAGE_DESKTOP_FILE" || warn 'Could not restore the previous menu entry.'
            else
                rm -f -- "$APPIMAGE_DESKTOP_FILE"
            fi
        fi
        APPIMAGE_TRANSACTION=0
    fi
    if [[ -n "$APPIMAGE_CANDIDATE_DIR" && -d "$APPIMAGE_CANDIDATE_DIR" ]]; then
        remove_managed_appimage_dir "$APPIMAGE_CANDIDATE_DIR" || true
    fi
    if [[ -n "$APPIMAGE_DESKTOP_STAGE" ]]; then rm -f -- "$APPIMAGE_DESKTOP_STAGE"; fi
    if [[ "$MODE_COMMITTED" -eq 0 ]]; then
        if [[ "$UPDATER_WAS_ENABLED" -eq 1 ]]; then
            systemctl --user enable codex-update-manager.service || true
        fi
        if [[ "$UPDATER_WAS_ACTIVE" -eq 1 ]]; then
            systemctl --user start codex-update-manager.service || true
        fi
    fi
}

download_helper_asset() {
    "$CURL_BIN" --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --output "$2" \
        "https://raw.githubusercontent.com/lbr88-labs/chatgpt-steam-deck/${CHATGPT_INSTALLER_REF:-refs/heads/main}/scripts/$1?ts=$(date +%s)"
}

build_appimage() {
    local source_dir="$1" status
    require_commands "$DISTROBOX_BIN" "$PODMAN_BIN"
    if "$PODMAN_BIN" container exists "$BUILD_BOX"; then
        :
    else
        status=$?
        [[ "$status" -eq 1 ]] || { die 'Could not inspect the AppImage build container.'; return 1; }
        info 'Creating the reusable AppImage build environment. This does not install build dependencies on SteamOS.'
        DBX_CONTAINER_MANAGER=podman "$DISTROBOX_BIN" create --name "$BUILD_BOX" \
            --image docker.io/library/archlinux:base-devel --yes --no-entry \
            --home "$CACHE_HOME/appimage-builder-home" --volume "$CACHE_HOME:$CACHE_HOME:rw"
    fi
    download_helper_asset build-appimage-container.sh "$CACHE_HOME/appimage-build-helper.sh"
    info 'Building the AppImage inside its build environment. The finished app runs directly on SteamOS.'
    DBX_CONTAINER_MANAGER=podman "$DISTROBOX_BIN" enter --name "$BUILD_BOX" \
        --no-tty --clean-path -- bash "$CACHE_HOME/appimage-build-helper.sh" "$source_dir"
}

publish_appimage() {
    local source_dir="$1" artifact="$2" stage desktop_stage
    [[ ! -L "$APPIMAGE_HOME" ]] || { die 'The AppImage install directory must not be a symbolic link.'; return 1; }
    mkdir -p "$(dirname "$APPIMAGE_HOME")" "$(dirname "$APPIMAGE_DESKTOP_FILE")"
    stage="$(mktemp -d "${APPIMAGE_HOME}.candidate.XXXXXX")"
    APPIMAGE_CANDIDATE_DIR="$stage"
    printf '%s\n' 'chatgpt-steam-deck appimage v1' >"$stage/.managed-by-installer"
    cp -- "$artifact" "$stage/ChatGPT-Community.AppImage"
    chmod 755 "$stage/ChatGPT-Community.AppImage"
    cp -- "$source_dir/codex-app/resources/codex-linux-build-info.json" "$stage/build-info.json"
    cp -- "$source_dir/assets/codex-linux.png" "$stage/icon.png"
    mkdir -p "$stage/metadata-helper/scripts/lib" "$stage/metadata-helper/assets"
    cp -- "$source_dir/scripts/lib/upstream-linux-package.js" "$stage/metadata-helper/scripts/lib/"
    cp -- "$source_dir/assets/openai-codex-linux-repository-key.gpg.base64" "$stage/metadata-helper/assets/"
    # Mount and diagnose without starting another app instance.
    "$stage/ChatGPT-Community.AppImage" --diagnose
    desktop_stage="$(mktemp --suffix=.desktop "$(dirname "$APPIMAGE_DESKTOP_FILE")/.codex-desktop.XXXXXX")"
    APPIMAGE_DESKTOP_STAGE="$desktop_stage"
    printf '[Desktop Entry]\nType=Application\nName=ChatGPT Community\nComment=ChatGPT Community — update using the Steam Deck installer\nExec="%s/ChatGPT-Community.AppImage" %%U\nIcon=%s/icon.png\nTerminal=false\nCategories=Network;\nStartupWMClass=codex-desktop\nMimeType=x-scheme-handler/codex;x-scheme-handler/codex-browser-sidebar;\n' \
        "$APPIMAGE_HOME" "$APPIMAGE_HOME" >"$desktop_stage"
    chmod 644 "$desktop_stage"
    if command_exists desktop-file-validate; then desktop-file-validate "$desktop_stage"; fi

    pause_native_updater
    wait_for_app_exit
    ensure_package_manager_idle
    # Everything needed for the new install is ready before the old one moves.
    remove_managed_appimage_dir "$APPIMAGE_HOME.previous"
    if [[ -e "$APPIMAGE_HOME" ]] && [[ "$(cat "$APPIMAGE_HOME/.managed-by-installer" 2>/dev/null)" != 'chatgpt-steam-deck appimage v1' ]]; then
        die 'The AppImage directory is not managed by this installer.'
        return 1
    fi
    if [[ -e "$APPIMAGE_DESKTOP_FILE" ]]; then
        cp -p -- "$APPIMAGE_DESKTOP_FILE" "$APPIMAGE_HOME.previous.desktop"
        APPIMAGE_HAD_DESKTOP=1
    fi
    APPIMAGE_TRANSACTION=1
    if [[ -e "$APPIMAGE_HOME" ]]; then
        mv -T -- "$APPIMAGE_HOME" "$APPIMAGE_HOME.previous"
        APPIMAGE_HAD_PREVIOUS=1
    fi
    APPIMAGE_PUBLISHED=1
    mv -T -- "$stage" "$APPIMAGE_HOME"
    APPIMAGE_DESKTOP_PUBLISHED=1
    mv -T -- "$desktop_stage" "$APPIMAGE_DESKTOP_FILE"
    if "$PACMAN_BIN" -Qq "$PACKAGE_NAME" >/dev/null 2>&1; then
        ensure_writable_system
        if ! run_root "$PACMAN_BIN" -R --noconfirm "$PACKAGE_NAME"; then
            cleanup_installation_mode
            return 1
        fi
    elif [[ -d "$APP_INSTALL_DIR" ]]; then
        ensure_writable_system
        recover_orphaned_app_tree
    fi
    APPIMAGE_TRANSACTION=0
    MODE_COMMITTED=1
    ORPHANED_APP_BACKUP=''
    command_exists update-desktop-database && update-desktop-database "$(dirname "$APPIMAGE_DESKTOP_FILE")" || true
    info 'AppImage installed. Open ChatGPT Community from the application menu. Run this desktop installer again to update it.'
}

install_appimage() {
    local source_dir artifact
    local -a artifacts
    validate_platform
    require_commands "$CURL_BIN" "$TAR_BIN" "$DISTROBOX_BIN" "$PODMAN_BIN"
    source_dir="$(download_source main)"
    build_appimage "$source_dir"
    shopt -s nullglob
    artifacts=("$source_dir"/dist/codex-desktop-*.AppImage)
    shopt -u nullglob
    [[ "${#artifacts[@]}" -eq 1 ]] || { die 'Expected one finished AppImage.'; return 1; }
    artifact="${artifacts[0]}"
    publish_appimage "$source_dir" "$artifact"
}

remove_appimage_installation() {
    appimage_is_installed || return 0
    remove_managed_appimage_dir "$APPIMAGE_HOME"
    remove_managed_appimage_dir "$APPIMAGE_HOME.previous"
    rm -f -- "$APPIMAGE_HOME.previous.desktop"
    # Only delete the menu override installed by this mode.
    if [[ -f "$APPIMAGE_DESKTOP_FILE" ]] && grep -Fq "$APPIMAGE_HOME/ChatGPT-Community.AppImage" "$APPIMAGE_DESKTOP_FILE"; then
        rm -f -- "$APPIMAGE_DESKTOP_FILE"
    fi
    command_exists update-desktop-database && update-desktop-database "$(dirname "$APPIMAGE_DESKTOP_FILE")" || true
}
