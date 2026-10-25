# Unreleased

- Recover safely when a SteamOS upgrade removes the pacman-managed `dpkg`
  package but preserves its empty state files.
- Preserve recovered state in a protected system recovery directory and refuse
  automatic changes when the dpkg directory contains data or unexpected
  entries.

# Steam Deck installer v1.0.0

Initial public release of the ChatGPT Community Steam Deck helper.

- One downloadable `.desktop` launcher for Desktop Mode.
- Install/update from current upstream `main` by default.
- Optional reviewed upstream commit.
- Confirmed uninstall flow.
- Signed pacman keyring initialization when needed.
- Automatic SteamOS read-only restoration after success or failure.
