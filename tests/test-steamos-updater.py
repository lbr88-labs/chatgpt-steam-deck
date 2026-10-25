#!/usr/bin/env python3
"""Exercise the installer integration without touching the system."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("patcher", ROOT / "scripts/patch-steamos-updater.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class UpdaterTests(unittest.TestCase):
    def test_patch_and_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "updater/src"
            source.mkdir(parents=True)
            fixtures = {
                "main.rs": "mod install;\n",
                "install.rs": 'run_install(&mut command).context("pacman -U failed")',
                "install_rollback.rs": 'run_install(&mut command).context("pacman rollback install failed")',
                "app.rs": '    let already_installed = state.installed_upstream_version.as_deref()\n',
            }
            for name, text in fixtures.items():
                (source / name).write_text(text)
            patcher.patch(root)
            first = {p.name: p.read_text() for p in source.iterdir()}
            patcher.patch(root)
            self.assertEqual(first, {p.name: p.read_text() for p in source.iterdir()})
            self.assertIn("with_writable_system", first["install.rs"])
            self.assertIn("with_writable_system", first["install_rollback.rs"])
            self.assertIn("installed_identity::reconcile", first["app.rs"])
            # Upgrading a previously patched updater must not duplicate modules.
            (source / "main.rs").write_text("mod install;\nmod steamos;\n")
            patcher.patch(root)
            self.assertEqual((source / "main.rs").read_text().count("mod steamos;"), 1)
            self.assertEqual((source / "main.rs").read_text().count("mod installed_identity;"), 1)
            subprocess.run(["rustc", "--edition=2021", "--test", str(source / "steamos.rs"), "-o", str(root / "test")], check=True)
            subprocess.run([str(root / "test")], check=True)

    def test_upstream_drift_fails_before_modifying_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "updater/src"
            source.mkdir(parents=True)
            for name in ["main.rs", "install.rs", "install_rollback.rs"]:
                (source / name).write_text("changed upstream")
            with self.assertRaises(SystemExit):
                patcher.patch(root)
            self.assertEqual((source / "main.rs").read_text(), "changed upstream")


if __name__ == "__main__":
    unittest.main()
