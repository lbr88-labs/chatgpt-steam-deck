# Steam Deck Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a double-clickable Steam Deck launcher that installs, updates, or removes ChatGPT Community without requiring users to run Git commands.

**Architecture:** A small `.desktop` bootstrap downloads this repository's helper script over HTTPS into a user-owned cache directory and executes it with terminal input attached. The helper presents a terminal menu, downloads an upstream source archive, delegates verified package handling to `codex-desktop-linux`, and guarantees SteamOS read-only restoration after privileged work.

**Tech Stack:** Bash, freedesktop desktop entry, curl, tar, pacman, SteamOS utilities

**Spec:** `docs/design.md`

## Global Constraints

- Support SteamOS on `x86_64` only.
- Default to the current upstream `main`; also offer a reviewed commit.
- Never disable pacman signature checks or upstream OpenAI package verification.
- Never store or pipe a sudo password.
- Restore the initial SteamOS read-only state on success, failure, and interruption.
- Identify the installed application as **ChatGPT Community** and the package as `codex-desktop`.

---

### Task 1: Test harness and installer behavior

**Files:**
- Create: `tests/test-installer.sh`
- Create: `installer.sh`

**Interfaces:**
- Consumes: environment overrides `STEAMOS_READONLY`, `PACMAN`, `CURL`, `TAR`, `MAKE`, `SUDO`, `UNAME`, `UPSTREAM_REF`, `UPSTREAM_REPO`, and `CACHE_HOME` for deterministic tests.
- Produces: `main`, `install_or_update`, `uninstall_app`, `restore_readonly`, and exit statuses suitable for the desktop bootstrap.

- [ ] **Step 1: Write failing shell tests**

Create a no-dependency Bash harness that provides mocked commands and verifies: unsupported architecture fails before sudo; cancellation makes no mutation; main and reviewed source URLs resolve correctly; keyring initialization occurs only when missing; uninstall requires confirmation; and the read-only state is restored after a forced build failure.

- [ ] **Step 2: Run tests to verify failure**

Run: `bash tests/test-installer.sh`

Expected: FAIL because `installer.sh` does not exist or required behaviors are absent.

- [ ] **Step 3: Implement the helper**

Implement strict Bash mode, command wrappers, SteamOS/architecture checks, disk and network preflight, a numbered menu with install/update from `main` as the default, reviewed-ref installation, confirmed uninstall, secure temporary extraction, dependency installation, pacman keyring initialization, upstream `make install-native`, and an EXIT/INT/TERM cleanup trap that restores the initial read-only state.

- [ ] **Step 4: Run behavior and syntax tests**

Run: `bash -n installer.sh tests/test-installer.sh && bash tests/test-installer.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add -- installer.sh tests/test-installer.sh && git commit -m "feat: add Steam Deck install helper"`

### Task 2: Desktop bootstrap

**Files:**
- Create: `Install ChatGPT Community.desktop`
- Modify: `tests/test-installer.sh`

**Interfaces:**
- Consumes: the raw HTTPS URL for `installer.sh` on `LBR88/chatgpt-steam-deck/main`.
- Produces: a freedesktop launcher opening a visible terminal and executing the downloaded helper.

- [ ] **Step 1: Add failing desktop-entry assertions**

Assert the launcher declares `Type=Application`, `Terminal=true`, the ChatGPT Community name, and an HTTPS-only bootstrap that uses `curl --fail --location --proto '=https' --tlsv1.2`.

- [ ] **Step 2: Run tests to verify failure**

Run: `bash tests/test-installer.sh`

Expected: FAIL because the desktop entry does not exist.

- [ ] **Step 3: Implement the launcher**

Create the `.desktop` entry with a Bash `Exec` command that downloads `installer.sh` into a user-owned cache directory and executes it with stdin attached. Keep the terminal open so success or failure remains readable.

- [ ] **Step 4: Validate the launcher**

Run: `bash tests/test-installer.sh`; if available, also run `desktop-file-validate 'Install ChatGPT Community.desktop'`.

Expected: PASS with no desktop validation errors.

- [ ] **Step 5: Commit**

Run: `git add -- 'Install ChatGPT Community.desktop' tests/test-installer.sh && git commit -m "feat: add double-click Steam Deck launcher"`

### Task 3: Documentation, license, and release packaging

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `RELEASE_NOTES.md`
- Create: `scripts/package-release.sh`
- Modify: `tests/test-installer.sh`

**Interfaces:**
- Consumes: launcher and installer from Tasks 1-2.
- Produces: clear download instructions and `dist/Install-ChatGPT-Community.desktop` as the release asset.

- [ ] **Step 1: Add failing documentation and packaging assertions**

Assert the README includes SteamOS Desktop Mode, download, execute permission fallback, double-click, install/update/uninstall, disk-space warning, community/unofficial status, upstream attribution, and removal instructions. Assert the packaging script emits an executable launcher with the expected filename.

- [ ] **Step 2: Run tests to verify failure**

Run: `bash tests/test-installer.sh`

Expected: FAIL because documentation and packaging are absent.

- [ ] **Step 3: Write documentation and packaging**

Write a concise Steam Deck guide, MIT license, first-release notes, and deterministic packaging script that copies the desktop launcher into `dist/` and marks it executable without embedding third-party payloads.

- [ ] **Step 4: Run complete verification**

Run: `bash -n installer.sh tests/test-installer.sh scripts/package-release.sh && bash tests/test-installer.sh && ./scripts/package-release.sh && git diff --check`.

Expected: all commands exit zero and the release asset exists with executable mode.

- [ ] **Step 5: Commit**

Run: `git add -- README.md LICENSE RELEASE_NOTES.md scripts/package-release.sh tests/test-installer.sh && git commit -m "docs: publish Steam Deck installation guide"`

### Task 4: Publish the public repository and release

**Files:**
- No source-file changes expected.

**Interfaces:**
- Consumes: verified commits and `dist/Install-ChatGPT-Community.desktop`.
- Produces: public `main` branch and a GitHub release with the downloadable launcher.

- [ ] **Step 1: Verify repository state**

Run: `git status --short && git log --oneline --decorate -5 && gh repo view LBR88/chatgpt-steam-deck --json nameWithOwner,visibility,url`.

Expected: clean tree, public repository, intended commits only.

- [ ] **Step 2: Rename and push the default branch**

Run: `git branch -M main && git push -u origin main`.

Expected: GitHub receives the verified source state.

- [ ] **Step 3: Create the first release**

Run: `gh release create v1.0.0 dist/Install-ChatGPT-Community.desktop --repo LBR88/chatgpt-steam-deck --title "Steam Deck installer v1.0.0" --notes-file RELEASE_NOTES.md`.

Expected: a public release with one downloadable `.desktop` installer.

- [ ] **Step 4: Verify publication**

Run: `gh repo view LBR88/chatgpt-steam-deck --json defaultBranchRef,url,visibility && gh release view v1.0.0 --repo LBR88/chatgpt-steam-deck --json url,assets`.

Expected: default branch `main`, public visibility, and the executable launcher asset listed.
