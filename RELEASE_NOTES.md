# Unreleased

- Use clickable Zenity dialogs for the action menu, uninstall confirmation, and
  completion/error messages on the desktop; retain terminal build output.
- Route sudo authentication, including upstream scripts, through a graphical
  password popup using sudo's askpass mechanism.
- Show installed and target app versions alongside installer identity, with
  target information checked against signed upstream metadata.
- Recognize externally installed upstream payloads and clear matching staged
  duplicates instead of repeatedly offering the already-installed app version.
- Display the installer's own version, release date, file timestamp, and script
  fingerprint in the menu.
- Refresh the reviewed upstream choice to the October 24 source revision used
  by the successful October 25 Steam Deck installation.
- Integrate SteamOS read-only handling into the bundled automatic updater's
  privileged pacman installation and rollback paths, preserving the initial
  read-only state after successful or failed package transactions.
- Recover safely when a SteamOS upgrade removes the pacman-managed `dpkg`
  package but preserves its empty state files.
- Preserve recovered state in a protected system recovery directory and refuse
  automatic changes when the dpkg directory contains data or unexpected
  entries.
- Recover when SteamOS forgets the installed `codex-desktop` package but leaves
  its unowned application tree behind, while preserving the old tree until the
  replacement is ready to install.
- Restore the preserved application tree automatically if package installation
  fails before creating its replacement.

# Steam Deck installer v1.0.0

Initial public release of the ChatGPT Community Steam Deck helper.

- One downloadable `.desktop` launcher for Desktop Mode.
- Install/update from current upstream `main` by default.
- Optional reviewed upstream commit.
- Confirmed uninstall flow.
- Signed pacman keyring initialization when needed.
- Automatic SteamOS read-only restoration after success or failure.
