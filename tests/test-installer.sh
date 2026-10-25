#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

passed=0
failed=0

pass() {
    printf 'ok - %s\n' "$1"
    passed=$((passed + 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failed=$((failed + 1))
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        printf '  expected: %q\n  actual:   %q\n' "$expected" "$actual" >&2
        fail "$name"
    fi
}

assert_file_empty() {
    local name="$1" path="$2"
    if [[ ! -s "$path" ]]; then
        pass "$name"
    else
        printf '  unexpected contents:\n' >&2
        sed 's/^/    /' "$path" >&2
        fail "$name"
    fi
}

if [[ ! -f "$ROOT_DIR/installer.sh" ]]; then
    fail 'installer exists'
    exit 1
fi

export INSTALLER_TEST_MODE=1
# shellcheck source=../installer.sh
source "$ROOT_DIR/installer.sh"

test_source_urls() {
    assert_eq \
        'main resolves to the upstream HTTPS archive' \
        'https://github.com/ilysenko/codex-desktop-linux/archive/refs/heads/main.tar.gz' \
        "$(resolve_archive_url main)"

    assert_eq \
        'reviewed commit resolves to an immutable upstream archive' \
        'https://github.com/ilysenko/codex-desktop-linux/archive/fc533a9346095e74d47c506e3103b7282c5c54d9.tar.gz' \
        "$(resolve_archive_url "$REVIEWED_REF")"
}

test_progress_output_does_not_corrupt_results() {
    local stdout_file="$TEST_TMP/info-stdout"
    local stderr_file="$TEST_TMP/info-stderr"
    info 'downloading source' >"$stdout_file" 2>"$stderr_file"
    assert_file_empty 'progress messages do not contaminate function results' "$stdout_file"
    if grep -Fq 'downloading source' "$stderr_file"; then
        pass 'progress messages remain visible on stderr'
    else
        fail 'progress messages remain visible on stderr'
    fi
}

test_unsupported_architecture() {
    local fake_uname="$TEST_TMP/uname-arm"
    printf '#!/bin/sh\nprintf %s\\n aarch64\n' >"$fake_uname"
    chmod +x "$fake_uname"

    UNAME_BIN="$fake_uname"
    if validate_platform >/dev/null 2>&1; then
        fail 'non-Steam-Deck architecture is rejected'
    else
        pass 'non-Steam-Deck architecture is rejected'
    fi
    UNAME_BIN=uname
}

test_readonly_restoration() {
    local state="$TEST_TMP/readonly-state"
    local log="$TEST_TMP/readonly-log"
    local fake="$TEST_TMP/steamos-readonly"
    printf 'enabled\n' >"$state"
    : >"$log"
    cat >"$fake" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
case "${1:-status}" in
    status) cat "$FAKE_READONLY_STATE" ;;
    disable) printf 'disabled\n' >"$FAKE_READONLY_STATE"; printf 'disable\n' >>"$FAKE_READONLY_LOG" ;;
    enable) printf 'enabled\n' >"$FAKE_READONLY_STATE"; printf 'enable\n' >>"$FAKE_READONLY_LOG" ;;
esac
SCRIPT
    chmod +x "$fake"

    export FAKE_READONLY_STATE="$state" FAKE_READONLY_LOG="$log"
    STEAMOS_READONLY_BIN="$fake"
    SUDO_BIN=env
    READONLY_INITIAL=''
    READONLY_CHANGED=0

    capture_readonly_state
    ensure_writable_system
    false || true
    restore_readonly

    assert_eq 'read-only mode is restored after a failed operation' 'enabled' "$(cat "$state")"
    assert_eq 'read-only restoration performs one disable and one enable' $'disable\nenable' "$(cat "$log")"

    STEAMOS_READONLY_BIN=steamos-readonly
    SUDO_BIN=sudo
}

test_keyring_initialization() {
    local log="$TEST_TMP/keyring-log"
    local fake="$TEST_TMP/pacman-key"
    : >"$log"
    cat >"$fake" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_KEYRING_LOG"
SCRIPT
    chmod +x "$fake"

    export FAKE_KEYRING_LOG="$log"
    PACMAN_KEY_BIN="$fake"
    SUDO_BIN=env
    PACMAN_KEYRING_FILE="$TEST_TMP/missing-pubring.gpg"
    ensure_pacman_keyring

    assert_eq 'missing keyring is initialized and populated' $'--init\n--populate archlinux holo' "$(cat "$log")"

    printf 'initialized\n' >"$PACMAN_KEYRING_FILE"
    : >"$log"
    ensure_pacman_keyring
    assert_file_empty 'existing keyring is left unchanged' "$log"

    PACMAN_KEY_BIN=pacman-key
    SUDO_BIN=sudo
    PACMAN_KEYRING_FILE=/etc/pacman.d/gnupg/pubring.gpg
}

test_stale_dpkg_state_recovery() {
    local state_dir="$TEST_TMP/dpkg-state"
    local cache_dir="$TEST_TMP/recovery-cache"
    local fake_pacman="$TEST_TMP/pacman-unowned"
    mkdir -p "$state_dir" "$cache_dir"
    : >"$state_dir/available"
    : >"$state_dir/status"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ] && [ "$2" = dpkg ]; then' \
        '    printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        '    exit 1' \
        'fi' \
        'if [ "$1" = -Qo ]; then' \
        '    printf "error: No package owns %s\\n" "$2" >&2' \
        '    exit 1' \
        'fi' \
        'exit 2' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    recover_stale_dpkg_state

    if [[ ! -e "$state_dir" ]]; then
        pass 'stale dpkg state directory is removed from the pacman target path'
    else
        fail 'stale dpkg state directory is removed from the pacman target path'
    fi

    local backup_dir
    backup_dir="$(find "$TEST_TMP" -mindepth 1 -maxdepth 1 -type d -name 'dpkg-state.chatgpt-steam-deck.*' -print -quit)"
    if [[ -n "$backup_dir" && -f "$backup_dir/available" && -f "$backup_dir/status" ]]; then
        pass 'stale dpkg state is preserved beside the original system state'
    else
        fail 'stale dpkg state is preserved beside the original system state'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_dpkg_recovery_refuses_nonempty_state() {
    local state_dir="$TEST_TMP/dpkg-nonempty"
    local cache_dir="$TEST_TMP/nonempty-cache"
    local fake_pacman="$TEST_TMP/pacman-unowned-nonempty"
    mkdir -p "$state_dir" "$cache_dir"
    printf 'important package state\n' >"$state_dir/status"
    : >"$state_dir/available"
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    if recover_stale_dpkg_state >/dev/null 2>&1; then
        fail 'nonempty dpkg state is never moved automatically'
    else
        pass 'nonempty dpkg state is never moved automatically'
    fi
    if [[ -s "$state_dir/status" ]]; then
        pass 'refused dpkg state remains untouched'
    else
        fail 'refused dpkg state remains untouched'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_dpkg_recovery_refuses_unexpected_entries() {
    local state_dir="$TEST_TMP/dpkg-unexpected"
    local cache_dir="$TEST_TMP/unexpected-cache"
    local fake_pacman="$TEST_TMP/pacman-unowned-unexpected"
    mkdir -p "$state_dir" "$cache_dir"
    : >"$state_dir/available"
    : >"$state_dir/status"
    : >"$state_dir/unexpected"
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    if recover_stale_dpkg_state >/dev/null 2>&1; then
        fail 'unexpected dpkg entries prevent automatic recovery'
    else
        pass 'unexpected dpkg entries prevent automatic recovery'
    fi
    if [[ -e "$state_dir/unexpected" ]]; then
        pass 'unexpected dpkg entries remain untouched'
    else
        fail 'unexpected dpkg entries remain untouched'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_dpkg_recovery_refuses_symlinked_state_directory() {
    local real_dir="$TEST_TMP/dpkg-real"
    local state_dir="$TEST_TMP/dpkg-symlink"
    local cache_dir="$TEST_TMP/symlink-cache"
    local fake_pacman="$TEST_TMP/pacman-unowned-symlink"
    mkdir -p "$real_dir" "$cache_dir"
    : >"$real_dir/available"
    : >"$real_dir/status"
    ln -s "$real_dir" "$state_dir"
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    if recover_stale_dpkg_state >/dev/null 2>&1; then
        fail 'symlinked dpkg state directory is never moved automatically'
    else
        pass 'symlinked dpkg state directory is never moved automatically'
    fi
    if [[ -L "$state_dir" && -f "$real_dir/status" ]]; then
        pass 'symlinked dpkg state remains untouched'
    else
        fail 'symlinked dpkg state remains untouched'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_dpkg_recovery_refuses_pacman_query_errors() {
    local state_dir="$TEST_TMP/dpkg-query-error"
    local cache_dir="$TEST_TMP/query-error-cache"
    local fake_pacman="$TEST_TMP/pacman-query-error"
    mkdir -p "$state_dir" "$cache_dir"
    : >"$state_dir/available"
    : >"$state_dir/status"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ]; then' \
        '    printf "error: local package database is unreadable\\n" >&2' \
        '    printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        '    exit 1' \
        'fi' \
        'printf "error: No package owns %s\\n" "$2" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    if recover_stale_dpkg_state >/dev/null 2>&1; then
        fail 'pacman query errors prevent automatic recovery'
    else
        pass 'pacman query errors prevent automatic recovery'
    fi
    if [[ -d "$state_dir" && -f "$state_dir/status" ]]; then
        pass 'pacman query errors leave dpkg state untouched'
    else
        fail 'pacman query errors leave dpkg state untouched'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_dpkg_recovery_refuses_newline_filename() {
    local state_dir="$TEST_TMP/dpkg-newline-name"
    local cache_dir="$TEST_TMP/newline-name-cache"
    local fake_pacman="$TEST_TMP/pacman-unowned-newline-name"
    mkdir -p "$state_dir" "$cache_dir"
    : >"$state_dir/available"
    : >"$state_dir/status"
    : >"$state_dir/"$'available\nstatus'
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ]; then' \
        '    printf "error: package '\''dpkg'\'' was not found\\n" >&2' \
        '    exit 1' \
        'fi' \
        'printf "error: No package owns %s\\n" "$2" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    DPKG_STATE_DIR="$state_dir"
    CACHE_HOME="$cache_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    if recover_stale_dpkg_state >/dev/null 2>&1; then
        fail 'newline-containing dpkg entries prevent automatic recovery'
    else
        pass 'newline-containing dpkg entries prevent automatic recovery'
    fi
    if [[ -e "$state_dir/"$'available\nstatus' ]]; then
        pass 'newline-containing dpkg entries remain untouched'
    else
        fail 'newline-containing dpkg entries remain untouched'
    fi

    DPKG_STATE_DIR=/var/lib/dpkg
    CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-steam-deck"
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_orphaned_app_tree_recovery() {
    local app_dir="$TEST_TMP/codex-desktop"
    local fake_pacman="$TEST_TMP/pacman-orphaned-app"
    mkdir -p "$app_dir"
    printf 'old app\n' >"$app_dir/version"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ] && [ "$2" = codex-desktop ]; then' \
        '    printf "error: package '\''codex-desktop'\'' was not found\\n" >&2' \
        '    exit 1' \
        'fi' \
        'if [ "$1" = -Qo ]; then' \
        '    printf "error: No package owns %s\\n" "$2" >&2' \
        '    exit 1' \
        'fi' \
        'exit 2' >"$fake_pacman"
    chmod +x "$fake_pacman"

    APP_INSTALL_DIR="$app_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    recover_orphaned_app_tree

    if [[ ! -e "$app_dir" ]]; then
        pass 'orphaned application tree is removed from the package target path'
    else
        fail 'orphaned application tree is removed from the package target path'
    fi

    local backup_dir
    backup_dir="$(find "$TEST_TMP" -mindepth 1 -maxdepth 1 -type d -name 'codex-desktop.chatgpt-steam-deck.*' -print -quit)"
    if [[ -n "$backup_dir" && "$(cat "$backup_dir/version")" == 'old app' ]]; then
        pass 'orphaned application tree is preserved beside the install path'
    else
        fail 'orphaned application tree is preserved beside the install path'
    fi

    APP_INSTALL_DIR=/opt/codex-desktop
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_registered_app_tree_is_not_recovered() {
    local app_dir="$TEST_TMP/registered-codex-desktop"
    local fake_pacman="$TEST_TMP/pacman-registered-app"
    mkdir -p "$app_dir"
    printf 'installed app\n' >"$app_dir/version"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ] && [ "$2" = codex-desktop ]; then' \
        '    printf "codex-desktop\\n"' \
        '    exit 0' \
        'fi' \
        'exit 2' >"$fake_pacman"
    chmod +x "$fake_pacman"

    APP_INSTALL_DIR="$app_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env

    recover_orphaned_app_tree

    if [[ "$(cat "$app_dir/version")" == 'installed app' ]]; then
        pass 'registered application tree remains in place'
    else
        fail 'registered application tree remains in place'
    fi

    APP_INSTALL_DIR=/opt/codex-desktop
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
}

test_orphaned_app_tree_restore_after_install_failure() {
    local app_dir="$TEST_TMP/restore-codex-desktop"
    local fake_pacman="$TEST_TMP/pacman-restore-app"
    mkdir -p "$app_dir"
    printf 'working old app\n' >"$app_dir/version"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = -Qq ]; then' \
        '    printf "error: package '\''codex-desktop'\'' was not found\\n" >&2' \
        '    exit 1' \
        'fi' \
        'printf "error: No package owns %s\\n" "$2" >&2' \
        'exit 1' >"$fake_pacman"
    chmod +x "$fake_pacman"

    APP_INSTALL_DIR="$app_dir"
    PACMAN_BIN="$fake_pacman"
    SUDO_BIN=env
    ORPHANED_APP_BACKUP=''

    recover_orphaned_app_tree
    restore_orphaned_app_tree

    if [[ "$(cat "$app_dir/version")" == 'working old app' ]]; then
        pass 'failed installation restores the preserved application tree'
    else
        fail 'failed installation restores the preserved application tree'
    fi

    APP_INSTALL_DIR=/opt/codex-desktop
    PACMAN_BIN=pacman
    SUDO_BIN=sudo
    ORPHANED_APP_BACKUP=''
}

test_cleanup_restores_orphaned_app_tree() {
    local app_dir="$TEST_TMP/cleanup-codex-desktop"
    local backup_dir="$TEST_TMP/cleanup-codex-desktop.chatgpt-steam-deck.saved"
    mkdir -p "$backup_dir"
    printf 'working old app\n' >"$backup_dir/version"

    APP_INSTALL_DIR="$app_dir"
    ORPHANED_APP_BACKUP="$backup_dir"
    SUDO_BIN=env

    if cleanup && [[ "$(cat "$app_dir/version")" == 'working old app' ]]; then
        pass 'exit cleanup restores a preserved application tree'
    else
        fail 'exit cleanup restores a preserved application tree'
    fi

    APP_INSTALL_DIR=/opt/codex-desktop
    ORPHANED_APP_BACKUP=''
    SUDO_BIN=sudo
}

test_uninstall_cancellation() {
    local log="$TEST_TMP/sudo-log"
    local fake="$TEST_TMP/sudo"
    : >"$log"
    cat >"$fake" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
SCRIPT
    chmod +x "$fake"

    export FAKE_SUDO_LOG="$log"
    SUDO_BIN="$fake"
    PACMAN_BIN=pacman
    printf 'n\n' | uninstall_app >/dev/null
    assert_file_empty 'cancelled uninstall makes no privileged change' "$log"
    SUDO_BIN=sudo
}

test_gui_auth_and_cancel() {
    local fake_zenity="$TEST_TMP/gui-zenity" fake_sudo="$TEST_TMP/gui-sudo"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$fake_sudo"
    printf '#!/bin/sh\nexit 1\n' >"$fake_zenity"
    chmod +x "$fake_sudo" "$fake_zenity"

    local args
    args="$(
        CACHE_HOME="$TEST_TMP/gui-cache"
        SUDO_BIN="$fake_sudo"
        ZENITY_BIN="$fake_zenity"
        load_version_summary() { :; }
        configure_gui_auth
        sudo --version
        cleanup
    )"
    assert_eq 'upstream sudo calls use graphical authentication' $'-A\n--version' "$args"

    if (
        DISPLAY=:test
        ZENITY_BIN="$fake_zenity"
        load_version_summary() { :; }
        install_or_update() { return 99; }
        uninstall_app() { return 99; }
        main </dev/null
    ) >/dev/null; then
        pass 'closing the dialog cancels without a keyboard or installation'
    else
        fail 'closing the dialog cancels without a keyboard or installation'
    fi
}

test_gui_reviewed_choice() {
    local fake_zenity="$TEST_TMP/gui-menu"
    printf '#!/bin/sh\nif [ "$1" = --list ]; then printf "2\\n"; fi\n' >"$fake_zenity"
    chmod +x "$fake_zenity"
    local selected
    selected="$(
        DISPLAY=:test
        ZENITY_BIN="$fake_zenity"
        CACHE_HOME="$TEST_TMP/gui-choice-cache"
        load_version_summary() { :; }
        install_or_update() { printf '%s' "$1"; }
        main </dev/null
    )"
    assert_eq 'clicking reviewed choice selects the pinned revision without terminal input' "$REVIEWED_REF" "$selected"
}

test_desktop_launcher() {
    local desktop_file="$ROOT_DIR/Install ChatGPT Community.desktop"
    if [[ ! -f "$desktop_file" ]]; then
        fail 'desktop launcher exists'
        return
    fi

    if command -v desktop-file-validate >/dev/null 2>&1; then
        if desktop-file-validate "$desktop_file"; then
            pass 'desktop launcher is a valid freedesktop entry'
        else
            fail 'desktop launcher is a valid freedesktop entry'
        fi
    fi

    local name terminal exec_line
    name="$(sed -n 's/^Name=//p' "$desktop_file")"
    terminal="$(sed -n 's/^Terminal=//p' "$desktop_file")"
    exec_line="$(sed -n 's/^Exec=//p' "$desktop_file")"
    assert_eq 'desktop launcher uses the community product name' 'Install ChatGPT Community' "$name"
    assert_eq 'desktop launcher opens a visible terminal' 'true' "$terminal"
    if [[ "$exec_line" == *'| bash'* ]]; then
        fail 'desktop launcher preserves terminal input for the interactive menu'
    else
        pass 'desktop launcher preserves terminal input for the interactive menu'
    fi
}

test_release_packaging() {
    local package_script="$ROOT_DIR/scripts/package-release.sh"
    local dist_dir="$TEST_TMP/release-dist"
    local asset="$dist_dir/Install-ChatGPT-Community.desktop"

    if [[ ! -x "$package_script" ]]; then
        fail 'release packaging script exists and is executable'
        return
    fi

    DIST_DIR="$dist_dir" "$package_script" >/dev/null
    if [[ -x "$asset" ]]; then
        pass 'release packaging emits an executable desktop launcher'
    else
        fail 'release packaging emits an executable desktop launcher'
    fi

    if desktop-file-validate "$asset"; then
        pass 'packaged desktop launcher remains valid'
    else
        fail 'packaged desktop launcher remains valid'
    fi
}

test_source_urls
test_progress_output_does_not_corrupt_results
test_unsupported_architecture
test_readonly_restoration
test_keyring_initialization
test_stale_dpkg_state_recovery
test_dpkg_recovery_refuses_nonempty_state
test_dpkg_recovery_refuses_unexpected_entries
test_dpkg_recovery_refuses_symlinked_state_directory
test_dpkg_recovery_refuses_pacman_query_errors
test_dpkg_recovery_refuses_newline_filename
test_orphaned_app_tree_recovery
test_registered_app_tree_is_not_recovered
test_orphaned_app_tree_restore_after_install_failure
test_cleanup_restores_orphaned_app_tree
test_uninstall_cancellation
test_gui_auth_and_cancel
test_gui_reviewed_choice
test_desktop_launcher
test_release_packaging

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
