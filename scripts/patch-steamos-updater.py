#!/usr/bin/env python3
"""Apply the Steam Deck privileged-updater integration before building."""

import pathlib
import sys

RUST = r'''
use std::{fs, io, process::Command};

pub fn with_writable_system<T, E: From<io::Error>>(
    operation: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    let os = fs::read_to_string("/etc/os-release")?;
    let steamos = os.lines().any(|line| {
        line.strip_prefix("ID=").map(|id| id.trim_matches(['\'', '"'])) == Some("steamos")
    });
    with_readonly_control(steamos, &mut control, operation)
}

fn control(action: &str) -> io::Result<String> {
    let output = Command::new("/usr/bin/steamos-readonly").arg(action).output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "steamos-readonly {action} failed: {}", String::from_utf8_lossy(&output.stderr)
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn with_readonly_control<T, E: From<io::Error>>(
    steamos: bool,
    control: &mut impl FnMut(&str) -> io::Result<String>,
    operation: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    if !steamos {
        return operation();
    }
    let enabled = match control("status")?.as_str() {
        "enabled" => true,
        "disabled" => false,
        other => return Err(io::Error::other(format!("Unknown SteamOS read-only status: {other}")).into()),
    };
    if !enabled {
        return operation();
    }
    control("disable")?;
    let result = operation();
    // Attempt restoration even when pacman failed; report both failures.
    if let Err(error) = control("enable") {
        eprintln!("Failed to restore SteamOS read-only mode: {error}");
        if result.is_ok() {
            return Err(error.into());
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_after_success_and_failure() {
        for fail in [false, true] {
            let mut actions = Vec::new();
            let result: io::Result<()> = with_readonly_control(true, &mut |action| {
                actions.push(action.to_owned());
                Ok("enabled".into())
            }, || if fail { Err(io::Error::other("pacman failed")) } else { Ok(()) });
            assert_eq!(result.is_err(), fail);
            assert_eq!(actions, ["status", "disable", "enable"]);
        }
    }

    #[test]
    fn preserves_writable_state_and_ignores_other_distros() {
        for steamos in [false, true] {
            let mut actions = Vec::new();
            let result: io::Result<()> = with_readonly_control(steamos, &mut |action| {
                actions.push(action.to_owned());
                Ok("disabled".into())
            }, || Ok(()));
            result.unwrap();
            assert_eq!(actions, if steamos { vec!["status"] } else { vec![] });
        }
    }

    #[test]
    fn refuses_install_when_status_or_disable_fails() {
        for failure in ["status", "disable"] {
            let result: io::Result<()> = with_readonly_control(true, &mut |action| {
                if action == failure { Err(io::Error::other("control failed")) }
                else { Ok("enabled".into()) }
            }, || panic!("must not run pacman"));
            assert!(result.is_err());
        }
    }

    #[test]
    fn reports_restore_failure() {
        let result: io::Result<()> = with_readonly_control(true, &mut |action| {
            if action == "enable" { Err(io::Error::other("restore failed")) }
            else { Ok("enabled".into()) }
        }, || Ok(()));
        assert!(result.unwrap_err().to_string().contains("restore failed"));
    }
}
'''


def patch(source):
    root = pathlib.Path(source) / "updater/src"
    replacements = {
        "main.rs": ("mod install;\n", "mod install;\nmod steamos;\n"),
        "install.rs": (
            'run_install(&mut command).context("pacman -U failed")',
            'crate::steamos::with_writable_system(|| run_install(&mut command)).context("pacman -U failed")',
        ),
        "install_rollback.rs": (
            'run_install(&mut command).context("pacman rollback install failed")',
            'crate::steamos::with_writable_system(|| run_install(&mut command)).context("pacman rollback install failed")',
        ),
    }
    changed = {}
    for name, (before, after) in replacements.items():
        text = (root / name).read_text()
        if after in text:
            continue
        if text.count(before) != 1:
            raise SystemExit(f"Cannot apply SteamOS updater integration: unexpected {name}; refusing an unpatched build")
        changed[name] = text.replace(before, after)
    for name, text in changed.items():
        (root / name).write_text(text)
    (root / "steamos.rs").write_text(RUST)


if __name__ == "__main__":
    patch(sys.argv[1])
