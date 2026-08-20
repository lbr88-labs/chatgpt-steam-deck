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
        'https://github.com/ilysenko/codex-desktop-linux/archive/1875dc2eaab6f9448617d18d0eda58902edf0f1a.tar.gz' \
        "$(resolve_archive_url 1875dc2eaab6f9448617d18d0eda58902edf0f1a)"
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

test_source_urls
test_unsupported_architecture
test_readonly_restoration
test_keyring_initialization
test_uninstall_cancellation

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
