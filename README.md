# ChatGPT Community for Steam Deck

A double-clickable SteamOS helper for installing, updating, or removing
**ChatGPT Community**. You do not need to clone a repository or type Git
commands.

This is an independent community installer. It is not an official OpenAI
project and it does not redistribute the ChatGPT application.

## Related project

After installing the app, optionally install
**[ChatGPT Community for Decky](https://github.com/LBR88/decky-chatgpt-community)**
to open ChatGPT, start new chats, check for updates, and control Voice Mode from
Steam Deck's Gaming Mode Quick Access menu. This repository installs the app;
the related Decky repository installs only the Quick Access integration.

## Install on Steam Deck

1. Switch the Steam Deck to **Desktop Mode**.
2. Download **[Install-ChatGPT-Community.desktop][download]**.
3. Open Dolphin and find the downloaded file.
4. If SteamOS asks, right-click the file, choose **Properties → Permissions**,
   enable **Is executable**, and select **OK**.
5. Double-click the file and choose **Execute**.
6. Close ChatGPT Community if it is running. In the dialog, select the first
   **AppImage** option and click
   **Continue**.

Keep the terminal open while it works. A fresh build can take several minutes,
uses at least 6 GiB of temporary/build space (plus the reusable build environment), and asks for the Deck user’s sudo
password in a graphical popup when SteamOS needs system changes. The menu,
uninstall confirmation, and completion/error messages are clickable dialogs;
the terminal remains visible for build output. Outside a graphical desktop,
the installer falls back to its terminal menu.

## Menu choices

- **Build and install AppImage** — default. Builds in a reusable Distrobox
  environment and installs in your home folder, together with its application
  menu entry. Normal SteamOS upgrades preserve both. Run this installer again
  to update it; AppImage deliberately has no automatic updater. The finished app
  runs directly on SteamOS, outside the build container, without an added runtime
  sandbox. The launcher uses AppImage's extract-and-run mode to prevent crashes
  in Chromium helpers during FUSE teardown. Startup includes an unpacking step
  into a private SSD-backed cache directory, which the launcher removes on exit.
- **Standard installation — tested build code** — retains the original pacman
  installation with the automatic updater, using the source revision reviewed
  after the successful Steam Deck installation on October 25, 2026
  (`fc533a9346095e74d47c506e3103b7282c5c54d9`).
- **Standard installation — latest build code** — uses the newest packaging
  fixes, including changes that may not yet be tested on Steam Deck.
- Both types may be installed together. The standard entry is **ChatGPT Community**;
  the separate entry is **ChatGPT Community (AppImage)**. Installing or updating
  one leaves the other installation and its shortcut intact. The native updater
  remains enabled. A running copy only blocks changes to that installation type.
- **Uninstall AppImage** and **Uninstall standard installation** remove only the
  selected type after confirmation and leave the shared user profile untouched.
  Both types use that profile, so launching the second while the first is open
  may activate the existing app rather than open a separate session.

Run the same desktop file again whenever you want to update or uninstall.
The opening menu shows the running installer's version, release date, file
download/modification time, and a short SHA-256 fingerprint of the actual script.
It also shows the installed upstream app version and the target version from
verified signed stable metadata. If a version check is unavailable, it says so
and verifies the target during installation instead.

## What the helper does

For the standard method, the helper downloads the upstream source automatically, temporarily disables
SteamOS read-only mode, initializes the signed Arch/SteamOS pacman keyring when
necessary, installs build dependencies, and invokes the upstream project’s
native installer. It restores the Deck’s original read-only state on success,
failure, or interruption.

The AppImage method uses SteamOS's Distrobox and Podman tools to keep build
dependencies in a container. Its app and metadata live under
`~/.local/share/chatgpt-community-appimage/`; its persistent menu entry is
`~/.local/share/applications/codex-desktop.desktop`. The installer validates the
finished AppImage on the host before switching, retains the previous AppImage
for rollback, and restores the previous app/menu if removing the native package
fails. It never removes the shared Codex profile or credentials. The app must be
closed before installation, update, switching, or removal.
Both methods appear under **Development**. Each switch explicitly rebuilds
KDE's application-menu cache so it launches the new location, including when
rolling back a failed switch.

SteamOS upgrades can remove the locally installed `dpkg` package while leaving
its two empty state files behind. Before reinstalling build dependencies, the
helper recognizes only that exact unowned, empty state and preserves it in an
adjacent protected recovery directory under `/var/lib` so pacman can
reinstall `dpkg` normally. Nonempty state, package-owned files, symbolic links,
or any unexpected entry are never moved automatically.

A SteamOS upgrade can also forget the installed `codex-desktop` package while
leaving its application files under `/opt`. The helper builds the replacement
first, then preserves that exact unowned application tree immediately before
installation so pacman can register the new package normally. If installation
fails before creating the replacement, the previous tree is restored. A
registered or package-owned installation is never moved and is upgraded in
place by pacman as usual.

The standard app package includes upstream's automatic updater. Before building, this
helper applies a small SteamOS integration to its privileged installation and
rollback paths: temporarily disable read-only mode only when enabled, then
restore it whether pacman succeeds or fails. Automatic rebuilds carry forward
the installed updater binary, including this integration. Run this desktop
installer once to install the corrected updater; an already staged update uses
the updater currently installed on the system.

The integration also recognizes an app installed through this helper by matching
its installed upstream version and hash against freshly verified signed metadata.
It clears a staged duplicate of that exact payload, avoiding an unnecessary
same-version rebuild and update notification after a manual installation.

The upstream project verifies OpenAI’s signed stable APT metadata and package
hashes, extracts only the verified data payload, and packages it independently
as `codex-desktop`. This helper does not disable those checks, execute OpenAI
maintainer scripts, or treat a `latest` URL as a package trust root.

## Security notes

- The desktop launcher downloads this repository’s current `installer.sh` over
  HTTPS when opened. When Git is available, it resolves the latest commit first
  and downloads that exact revision, including the matching updater integration.
  This avoids stale copies of the moving branch URL. Without Git it uses the
  full branch-reference URL with a timestamp parameter.
- The default option follows upstream `main`, so its source can change between
  runs. Choose the reviewed-commit option for a fixed upstream snapshot.
- Review the small [desktop launcher](./Install%20ChatGPT%20Community.desktop)
  and [helper script](./installer.sh) before running them if you prefer.
- SteamOS system updates can remove locally installed packages. If that happens,
  run the desktop installer again.

## Manual removal

The menu is the easiest removal method for either installation type. For a
standard system package, the terminal equivalent is:

```bash
sudo steamos-readonly disable
sudo pacman -Rns codex-desktop
sudo steamos-readonly enable
```

## Credits and license

The verified build and packaging work is provided by
[`ilysenko/codex-desktop-linux`](https://github.com/ilysenko/codex-desktop-linux).
This helper’s original code is available under the [MIT License](./LICENSE).

[download]: https://github.com/LBR88/chatgpt-steam-deck/releases/latest/download/Install-ChatGPT-Community.desktop
