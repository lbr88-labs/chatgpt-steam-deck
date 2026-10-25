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


IDENTITY_RUST = r'''
use crate::state::{PersistedState, UpdateStatus};
use serde_json::Value;

// Compare installed provenance with freshly verified signed metadata.
pub fn reconcile(state: &mut PersistedState, version: &str, sha256: &str) {
    let Ok(bytes) = std::fs::read("/opt/codex-desktop/resources/codex-linux-build-info.json") else { return };
    let Ok(info) = serde_json::from_slice::<Value>(&bytes) else { return };
    reconcile_info(state, version, sha256, &info);
}

fn reconcile_info(state: &mut PersistedState, version: &str, sha256: &str, info: &Value) {
    if state.installed_version == "unknown" || state.manual_recovery_required || state.install_transaction.is_some() {
        return;
    }
    let upstream = &info["upstreamLinuxPackage"];
    if upstream["version"].as_str() != Some(version) || upstream["sha256"].as_str() != Some(sha256) {
        return;
    }
    state.installed_upstream_version = Some(version.to_owned());
    state.installed_upstream_sha256 = Some(sha256.to_owned());
    // Clear only an update bound to this exact already-installed payload.
    if state.candidate_version.as_deref() == Some(version)
        && state.upstream_package_sha256.as_deref() == Some(sha256) {
        state.candidate_version = None;
        state.candidate_architecture = None;
        state.candidate_repository_path = None;
        state.artifact_paths.package_path = None;
        state.artifact_paths.package_candidate_sha256 = None;
        state.waiting_for_app_exit_auto_install = false;
        state.install_after_app_exit_requested = false;
        state.error_message = None;
        state.status = UpdateStatus::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn installed() -> PersistedState {
        let mut state = PersistedState::default();
        state.installed_version = "local-package-timestamp".into();
        state
    }

    #[test]
    fn recognizes_external_install_and_clears_matching_duplicate() {
        let mut state = installed();
        state.candidate_version = Some("current".into());
        state.upstream_package_sha256 = Some("signed-hash".into());
        state.status = UpdateStatus::WaitingForAppExit;
        state.waiting_for_app_exit_auto_install = true;
        state.artifact_paths.package_path = Some("duplicate.pkg.tar.zst".into());
        reconcile_info(&mut state, "current", "signed-hash", &json!({
            "upstreamLinuxPackage": {"version": "current", "sha256": "signed-hash"}
        }));
        assert_eq!(state.installed_upstream_version.as_deref(), Some("current"));
        assert_eq!(state.installed_upstream_sha256.as_deref(), Some("signed-hash"));
        assert!(state.candidate_version.is_none());
        assert!(state.artifact_paths.package_path.is_none());
        assert!(!state.waiting_for_app_exit_auto_install);
        assert_eq!(state.status, UpdateStatus::Idle);
    }

    #[test]
    fn rejects_missing_mismatched_or_unregistered_installed_identity() {
        for info in [json!({}), json!({"upstreamLinuxPackage": {"version": "old", "sha256": "signed-hash"}}),
            json!({"upstreamLinuxPackage": {"version": "current", "sha256": "different"}})] {
            let mut state = installed();
            let before = state.clone();
            reconcile_info(&mut state, "current", "signed-hash", &info);
            assert_eq!(state, before);
        }
        let mut state = PersistedState::default();
        reconcile_info(&mut state, "current", "signed-hash", &json!({
            "upstreamLinuxPackage": {"version": "current", "sha256": "signed-hash"}
        }));
        assert!(state.installed_upstream_version.is_none());
    }

    #[test]
    fn preserves_unrelated_pending_candidate_and_manual_recovery() {
        for manual in [false, true] {
            let mut state = installed();
            state.manual_recovery_required = manual;
            state.candidate_version = Some("different".into());
            state.upstream_package_sha256 = Some("different-hash".into());
            reconcile_info(&mut state, "current", "signed-hash", &json!({
                "upstreamLinuxPackage": {"version": "current", "sha256": "signed-hash"}
            }));
            assert_eq!(state.candidate_version.as_deref(), Some("different"));
            assert_eq!(state.installed_upstream_version.is_none(), manual);
        }
    }
}
'''


def patch(source):
    root = pathlib.Path(source) / "updater/src"
    replacements = {
        "install.rs": (
            'run_install(&mut command).context("pacman -U failed")',
            'crate::steamos::with_writable_system(|| run_install(&mut command)).context("pacman -U failed")',
        ),
        "install_rollback.rs": (
            'run_install(&mut command).context("pacman rollback install failed")',
            'crate::steamos::with_writable_system(|| run_install(&mut command)).context("pacman rollback install failed")',
        ),
        "app.rs": (
            '    let already_installed = state.installed_upstream_version.as_deref()\n',
            '    crate::installed_identity::reconcile(state, &metadata.version, &metadata.sha256);\n'
            '    let already_installed = state.installed_upstream_version.as_deref()\n',
        ),
    }
    changed = {}
    main = (root / "main.rs").read_text()
    if main.count("mod install;\n") != 1:
        raise SystemExit("Cannot apply SteamOS updater integration: unexpected main.rs")
    for module in ("steamos", "installed_identity"):
        if f"mod {module};\n" not in main:
            main = main.replace("mod install;\n", f"mod install;\nmod {module};\n")
    changed["main.rs"] = main
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
    (root / "installed_identity.rs").write_text(IDENTITY_RUST)


if __name__ == "__main__":
    patch(sys.argv[1])
