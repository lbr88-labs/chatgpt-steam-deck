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
6. In the terminal menu, press Enter for the default **install or update from
   upstream main** option.

Keep the terminal open while it works. A fresh build can take several minutes,
uses roughly 6 GiB of temporary/build space, and asks for the Deck user’s sudo
password when SteamOS needs system changes.

## Menu choices

- **Install or update from upstream main** — recommended default; downloads the
  current source from `ilysenko/codex-desktop-linux`.
- **Install or update from reviewed commit** — uses the source revision reviewed
  after the successful Steam Deck installation on October 25, 2026
  (`fc533a9346095e74d47c506e3103b7282c5c54d9`).
- **Uninstall** — removes the `codex-desktop` system package after confirmation.
  It deliberately leaves the shared Codex user profile untouched.

Run the same desktop file again whenever you want to update or uninstall.
The opening menu shows the running installer's version, release date, file
download/modification time, and a short SHA-256 fingerprint of the actual script.

## What the helper does

The helper downloads the upstream source automatically, temporarily disables
SteamOS read-only mode, initializes the signed Arch/SteamOS pacman keyring when
necessary, installs build dependencies, and invokes the upstream project’s
native installer. It restores the Deck’s original read-only state on success,
failure, or interruption.

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

The app package includes upstream's automatic updater. Before building, this
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
  HTTPS when opened.
- The default option follows upstream `main`, so its source can change between
  runs. Choose the reviewed-commit option for a fixed upstream snapshot.
- Review the small [desktop launcher](./Install%20ChatGPT%20Community.desktop)
  and [helper script](./installer.sh) before running them if you prefer.
- SteamOS system updates can remove locally installed packages. If that happens,
  run the desktop installer again.

## Manual removal

The menu is the easiest removal method. From a terminal, the equivalent command
is:

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
