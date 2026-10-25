import pathlib
import subprocess
import tempfile
import unittest

PATCH = pathlib.Path(__file__).resolve().parents[1] / 'scripts/patch-appimage-desktop.py'
TEMPLATE = '''codex_packaged_runtime_export_env() {
    export CHROME_DESKTOP="__PACKAGE_NAME__.desktop"
    if [ -n "${APPDIR:-}" ] && [ -f "$APPDIR/__PACKAGE_NAME__.desktop" ]; then
        export BAMF_DESKTOP_FILE_HINT="$APPDIR/__PACKAGE_NAME__.desktop"
    else
        export BAMF_DESKTOP_FILE_HINT="__PACKAGE_NAME__.desktop"
    fi
}
'''


class DesktopPatchTests(unittest.TestCase):
    def test_persistent_launcher_is_used_and_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            template = root / 'packaging/appimage/codex-appimage-runtime.sh'
            template.parent.mkdir(parents=True)
            template.write_text(TEMPLATE)
            for _ in range(2):
                subprocess.run(['python3', str(PATCH), tmp], check=True)
            desktop = root / 'chatgpt-community-appimage.desktop'
            desktop.touch()
            result = subprocess.check_output(['bash', '-c',
                'source "$1"; CODEX_APPIMAGE_DESKTOP_FILE="$2"; '
                'codex_packaged_runtime_export_env; '
                'printf "%s\\n%s" "$BAMF_DESKTOP_FILE_HINT" "$CHROME_DESKTOP"',
                'test', str(template), str(desktop)], text=True)
            self.assertEqual(result, str(desktop) + '\n' + desktop.name)

    def test_upstream_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'packaging/appimage/codex-appimage-runtime.sh'
            path.parent.mkdir(parents=True)
            path.write_text('changed upstream template\n')
            result = subprocess.run(['python3', str(PATCH), tmp], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), 'changed upstream template\n')


if __name__ == '__main__':
    unittest.main()
