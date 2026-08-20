# ChatGPT Community Steam Deck Installer Design

## Goal

Provide a Steam Deck-native, double-clickable installer for ChatGPT Community
without requiring users to clone repositories or type Git commands.

## User experience

Users download `Install ChatGPT Community.desktop` from this repository and
double-click it in SteamOS Desktop Mode. The launcher opens Konsole, downloads
the current helper script from this repository over HTTPS, and presents four
choices:

1. Install or update from the current upstream `main` branch (default).
2. Install or update from a reviewed upstream commit.
3. Uninstall ChatGPT Community.
4. Exit.

The helper prints each significant action and leaves the terminal open on
failure so errors are readable.

## Architecture

The `.desktop` file is a small bootstrapper. It downloads `installer.sh` to a
temporary directory and executes it. The helper downloads a source archive of
`ilysenko/codex-desktop-linux`, rather than asking the user to install or use
Git directly.

The upstream project remains responsible for resolving and verifying OpenAI's
signed stable Linux package, preserving the official application payload, and
building the native pacman package. This repository does not redistribute the
OpenAI package or duplicate its verification logic.

## SteamOS handling

The helper:

- supports SteamOS on `x86_64` only;
- checks free disk space and network availability before system changes;
- temporarily disables SteamOS read-only mode when required;
- initializes and populates the Arch/SteamOS pacman keyring if absent;
- installs the upstream project's declared build dependencies;
- restores read-only mode through an exit trap, including after failures;
- uses visible `sudo` prompts and never stores a password;
- caches downloaded source archives under the user's XDG cache directory;
- offers uninstall through `pacman -Rns codex-desktop` with confirmation.

## Source selection

The default path downloads the current archive for upstream `main`, matching
the requested easy-update behavior. The reviewed path uses a commit SHA stored
in this repository. Both choices display the resolved source URL and revision
before execution.

## Safety boundaries

- Downloads require HTTPS and fail closed on HTTP or transfer errors.
- The bootstrapper and helper clearly identify this as a community project,
  not an official OpenAI installer.
- No upstream maintainer scripts are run; the upstream project extracts only
  the verified data payload.
- The helper never disables pacman signature checks or OpenAI package checks.
- SteamOS read-only mode is restored after any attempted system mutation.
- Existing source caches are replaced atomically rather than edited in place.

## Repository contents

- `Install ChatGPT Community.desktop` — downloadable Steam Deck entry point.
- `installer.sh` — menu, checks, source download, install/update, and removal.
- `tests/installer.bats` — shell-level tests with mocked system commands.
- `README.md` — short download-and-double-click guide and security explanation.
- `LICENSE` — MIT license for this helper's original code.

## Validation

Validation covers shell syntax, ShellCheck, mocked success/failure paths,
read-only restoration, keyring initialization, source selection, cancellation,
and uninstall confirmation. The `.desktop` file is parsed with
`desktop-file-validate` when available. A final manual smoke test runs the
launcher in SteamOS Desktop Mode.
