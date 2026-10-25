#!/usr/bin/env python3
"""Test switching and rollback using disposable app/package-manager fixtures."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class AppImageTests(unittest.TestCase):
    def prepare(self, base):
        source = base / "source"
        for folder in ["codex-app/resources", "assets", "scripts/lib"]:
            (source / folder).mkdir(parents=True, exist_ok=True)
        (source / "codex-app/resources/codex-linux-build-info.json").write_text('{"upstreamLinuxPackage":{"version":"test"}}')
        (source / "assets/codex-linux.png").write_text("test icon")
        (source / "assets/openai-codex-linux-repository-key.gpg.base64").write_text("test key")
        (source / "scripts/lib/upstream-linux-package.js").write_text("// test verifier")
        artifact = base / "candidate.AppImage"
        artifact.write_text('#!/bin/sh\n[ "$1" = --appimage-extract-and-run ] && [ "$2" = --diagnose ] || exit 1\n: "${TMPDIR:?}"\nprintf "%s" "$TMPDIR" > "$TEST_BASE/runtime-path"\nmkdir -p "$TMPDIR/appimage-extracted-test"\nexit "${APPIMAGE_TEST_FAIL:-0}"\n')
        artifact.chmod(0o755)
        (base / "registered").touch()
        (base / "profile").write_text("keep chats and settings")
        pacman = base / "pacman"
        pacman.write_text('''#!/bin/sh
case "$1" in
    -Qq) test -f "$TEST_BASE/registered" ;;
    -R|-Rns)
        touch "$TEST_BASE/removal-attempted"
        test "${FAIL_REMOVE:-0}" = 0 || exit 1
        rm "$TEST_BASE/registered"
        ;;
    *) exit 2 ;;
esac
''')
        pacman.chmod(0o755)
        tools = base / "tools"
        tools.mkdir()
        refresh = tools / "kbuildsycoca6"
        refresh.write_text('''#!/bin/sh
echo refresh >> "$TEST_BASE/menu-refreshes"
test "${FAIL_MENU_REFRESH:-0}" = 0 || exit 1
if test -f "$APPIMAGE_DESKTOP_FILE"; then
    cp "$APPIMAGE_DESKTOP_FILE" "$TEST_BASE/cached-menu"
else
    rm -f "$TEST_BASE/cached-menu"
fi
''')
        refresh.chmod(0o755)
        return source, artifact, pacman

    def run_shell(self, base, command, fail=False, fail_menu=False):
        env = dict(os.environ, HOME=str(base), TEST_BASE=str(base), TEST_ROOT=str(ROOT),
                   FAIL_REMOVE="1" if fail else "0", FAIL_MENU_REFRESH="1" if fail_menu else "0",
                   PATH=str(base / "tools") + os.pathsep + os.environ["PATH"])
        script = r'''
set -Eeuo pipefail
export INSTALLER_TEST_MODE=1
source "$TEST_ROOT/installer.sh"
APPIMAGE_HOME="$TEST_BASE/installed"
export APPIMAGE_DESKTOP_FILE="$TEST_BASE/applications/chatgpt-community-appimage.desktop"
APP_INSTALL_DIR="$TEST_BASE/opt-codex"
PACMAN_BIN="$TEST_BASE/pacman"
source "$TEST_ROOT/scripts/appimage-mode.sh"
trap cleanup EXIT
ensure_writable_system() { :; }
pause_native_updater() { :; }
wait_for_app_exit() { :; }
ensure_package_manager_idle() { :; }
run_root() { "$@"; }
systemctl() { :; }
''' + command
        return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def test_appimage_install_and_removal_preserve_native_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
detect_installation_mode
test "$INSTALLATION_MODE" = 'Standard installation'
test "$APPIMAGE_ACTION" = 'Build and install AppImage (recommended)'
publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"
test -f "$TEST_BASE/registered"
appimage_is_installed
test -x "$APPIMAGE_DESKTOP_FILE"
test -O "$APPIMAGE_DESKTOP_FILE"
test -O "$APPIMAGE_HOME/ChatGPT-Community.AppImage"
grep -q 'launch-appimage.sh' "$APPIMAGE_DESKTOP_FILE"
grep -q 'launch-appimage.sh' "$TEST_BASE/cached-menu"
test -x "$APPIMAGE_HOME/launch-appimage.sh"
test ! -e "$(cat "$TEST_BASE/runtime-path")"
grep -q '^Categories=Development;' "$APPIMAGE_DESKTOP_FILE"
detect_installation_mode
test "$INSTALLATION_MODE" = 'AppImage and standard installation'
test "$NATIVE_ACTION" = 'Install or update — standard installation'
# A successful native installer calls this only after installing its package.
touch "$TEST_BASE/registered"
remove_appimage_installation
test ! -e "$APPIMAGE_HOME"
test ! -e "$APPIMAGE_DESKTOP_FILE"
test ! -e "$TEST_BASE/cached-menu"
test -f "$TEST_BASE/registered"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((base / "profile").read_text(), "keep chats and settings")

    def test_cleanup_waits_for_remaining_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"
cat >"$APPIMAGE_HOME/ChatGPT-Community.AppImage" <<'APP'
#!/bin/bash
printf '%s' "$TMPDIR" > "$TEST_BASE/runtime-path"
touch "$TMPDIR/needed-resource"
cat >"$TMPDIR/helper.sh" <<'HELPER'
#!/bin/bash
sleep 0.4
if test -f "$TMPDIR/needed-resource"; then
    touch "$TEST_BASE/helper-succeeded"
else
    touch "$TEST_BASE/helper-failed"
fi
HELPER
bash "$TMPDIR/helper.sh" >/dev/null 2>&1 &
APP
"$APPIMAGE_HOME/launch-appimage.sh"
test -f "$TEST_BASE/helper-succeeded"
test ! -f "$TEST_BASE/helper-failed"
test ! -e "$(cat "$TEST_BASE/runtime-path")"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_runtime_failure_removes_extracted_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"
status=0
APPIMAGE_TEST_FAIL=23 "$APPIMAGE_HOME/launch-appimage.sh" --diagnose || status=$?
test "$status" -eq 23
test ! -e "$(cat "$TEST_BASE/runtime-path")"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_menu_refresh_preserves_native_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"', fail_menu=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / "registered").exists())
            self.assertFalse((base / "removal-attempted").exists())

    def test_failed_menu_refresh_restores_previous_appimage_and_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            old = base / "installed"
            old.mkdir()
            (old / ".managed-by-installer").write_text("chatgpt-steam-deck appimage v1\n")
            image = old / "ChatGPT-Community.AppImage"
            image.write_text("old working app")
            image.chmod(0o755)
            (base / "applications").mkdir()
            desktop = base / "applications/chatgpt-community-appimage.desktop"
            desktop.write_text("previous menu entry")
            result = self.run_shell(base, r'publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"', fail_menu=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / "removal-attempted").exists(), result.stdout + result.stderr)
            self.assertEqual(image.read_text(), "old working app")
            self.assertEqual(desktop.read_text(), "previous menu entry")
            self.assertTrue((base / "registered").exists())

    def test_running_app_blocks_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
# Use the actual preflight function with a simulated running app.
source "$TEST_ROOT/scripts/appimage-mode.sh"
GUI_MODE=0
pgrep() { echo 999999; }
wait_for_app_exit
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / "registered").exists())
            self.assertFalse((base / "installed").exists())

    def test_uninstall_action_handles_each_installation_method(self):
        for appimage in [False, True]:
            with self.subTest(appimage=appimage), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                self.prepare(base)
                setup = 'publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"\n' if appimage else ''
                result = self.run_shell(base, setup + r'''
validate_platform() { :; }
printf 'y\n' | uninstall_app
test ! -e "$APPIMAGE_HOME"
test ! -e "$APPIMAGE_DESKTOP_FILE"
''')
                self.assertEqual((base / "registered").exists(), appimage)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((base / "profile").read_text(), "keep chats and settings")

    def test_native_update_preserves_appimage_on_success_and_failure(self):
        for succeeds in [False, True]:
            with self.subTest(succeeds=succeeds), tempfile.TemporaryDirectory() as directory:
                base = pathlib.Path(directory)
                source, _, _ = self.prepare(base)
                deps = source / "scripts/install-deps.sh"
                deps.write_text("#!/bin/sh\nexit 0\n")
                make = base / "make"
                make.write_text('#!/bin/sh\nif [ "$1" = install ]; then\n' +
                                ('touch "$TEST_BASE/registered"\n' if succeeds else 'exit 1\n') + 'fi\n')
                make.chmod(0o755)
                result = self.run_shell(base, r'''
publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"
download_source() { printf '%s' "$TEST_BASE/source"; }
validate_platform() { :; }
require_commands() { :; }
capture_readonly_state() { :; }
recover_stale_dpkg_state() { :; }
ensure_pacman_keyring() { :; }
ensure_rust_toolchain() { :; }
patch_steamos_updater() { :; }
recover_orphaned_app_tree() { :; }
MAKE_BIN="$TEST_BASE/make"
install_or_update main
''')
                self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
                self.assertEqual((base / "installed/ChatGPT-Community.AppImage").exists(), True)
                self.assertEqual((base / "applications/chatgpt-community-appimage.desktop").exists(), True)
                self.assertEqual((base / "registered").exists(), True)

    def test_unmanaged_directory_is_never_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            (base / "installed").mkdir()
            (base / "installed/user-file").write_text("keep")
            result = self.run_shell(base, 'remove_managed_appimage_dir "$APPIMAGE_HOME"')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((base / "installed/user-file").read_text(), "keep")

    def test_running_native_app_allows_appimage_install_but_blocks_native_update(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
source "$TEST_ROOT/scripts/appimage-mode.sh"
GUI_MODE=0
pgrep() { echo 123; }
readlink() { printf '%s' "$APP_INSTALL_DIR/ChatGPT"; }
TARGET_INSTALLATION=appimage
wait_for_app_exit
TARGET_INSTALLATION=native
if wait_for_app_exit; then exit 9; fi
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_uninstall_keeps_appimage(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            self.prepare(base)
            result = self.run_shell(base, r'''
publish_appimage "$TEST_BASE/source" "$TEST_BASE/candidate.AppImage"
validate_platform() { :; }
printf 'y\n' | uninstall_app native
appimage_is_installed
test -f "$APPIMAGE_DESKTOP_FILE"
test ! -f "$TEST_BASE/registered"
''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
