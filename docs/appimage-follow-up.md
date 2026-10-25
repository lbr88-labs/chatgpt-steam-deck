# AppImage follow-up

- [x] Verify SSD-backed build scratch space for SteamOS tmpfs quota failures (errno 122). Full AppImage build completed; deliberate failure confirmed scratch cleanup. Included in installer 2026.10.25.9.
- [x] Audit temporary-file cleanup. Removed 928 MB of updater test files and 1.7 GB of AppImage test extraction; /tmp usage fell from 3.1 GB to 570 MB.
- [x] Own runtime extraction cleanup in the launcher (2026.10.25.10). Use a short SSD-backed directory under ~/.cache/chatgpt-runtime, then remove it on exit. Actual startup, tray Quit, and removal verified; automated success/failure cleanup tests pass.

- [x] Reproduce Plasma's permission/not-permitted notification using the actual AppImage launcher.
- [x] Fix the cause in the installer and add a regression check.
- [x] Verify actual startup on SteamOS without removing the working native installation or using its profile.
- [x] Publish the fix and verify the desktop installer's download before asking the user to retry (installer 2026.10.25.8; GitHub main and immutable downloads verified).
- [x] Explain in the menu that the AppImage is built locally before installation.

The user subsequently requested independent installations after the original
menu failure recurred. Installer 2026.10.25.11 supports both types with separate
menu IDs and uninstall actions, and allows one type to run while installing the
other. It also restores SteamOS read-only mode before the completion dialog,
avoiding sudo expiry while that dialog waits for the user.

Important verification limit: the earlier permission rejection was reproduced
on a recreated test shortcut, not the user's removed original launcher. The
original Plasma menu failure was not conclusively reproduced. Do not equate
successful isolated tests with verification of the original migration flow.
Upstream's AppImage desktop hint was also found to reference its temporary,
non-executable embedded desktop file; the build now patches that hint to the
permanent installer-generated entry.

- [x] Complete real installer run and verify both installed entries and native package preservation. Ran installer.sh normally, selected option 1, and completed download/build/install without test stubs. Native package version and desktop-file SHA256 were unchanged. The AppImage desktop entry is deck-owned, mode 0755, independently named, and accepted by `kstart --application chatgpt-community-appimage`.

The native app remained running during installation. Since both editions use the
same user profile, launching the AppImage while native is open can forward to the
existing session; this launch check verifies the installed shortcut is accepted,
not that two independent app sessions run simultaneously.

Evidence (October 25): KDE rejected the actual generated launcher with the
diagnostic "not owned by root and executable flag not set." The launcher was
0644, while the AppImage was already 0755 and owned by deck. Changing the launcher
to 0755 allowed startup through `kioclient exec`. The actual AppImage process and
renderer ran from its mounted image with a visible primary window and separate
test profile. The native package and running session were preserved.

The initial simple launcher check was insufficient: it did not capture KDE's
trust rejection. The regression now checks executable permissions and current-user
ownership of the published launcher and AppImage. It failed before the fix and
passes after it. All 36 installer checks, 7 AppImage tests, and updater tests pass.

Both SIGTERM and normal tray Quit caused surviving Chromium helpers to receive
SIGBUS after the FUSE mount disappeared. Those Plasma crash notifications came
from the test instances. A third test used AppImage's extract-and-run mode:
startup reached the visible window and normal tray Quit completed with no new
core dumps. The launcher now selects that mode. Its cost is unpacking the image
at startup; it avoids FUSE teardown invalidating executable mappings.

Further cleanup audit: the embedded AppImage runtime retained extraction even
after a successful diagnostic run. The wrapper now owns that directory and
removes it on exit. The initial deep test path caused Chromium's "Socket path too
long" fatal check (test PID 130998); moving the temporary directory to a short
home-cache path fixed it. The subsequent real startup/normal-Quit test passed and
left no runtime directory or new core dump. There are now 8 AppImage tests.


## October 25: helper crash after forwarding to native

The real installed menu launch with the normal profile forwarded to the running
native session, then its zygotes crashed (TRAP, missing ICU data). Merely checking
KDE's launcher return status missed these crashes. Keeping the extraction on that
same launch path prevented the core dumps. The wrapper deleted resources while
helpers were still starting/exiting after their parent had returned.

The wrapper now waits for processes using its unique extraction path to exit
before deleting that directory. A regression fixture leaves a helper alive after
its parent exits and requires it to read a resource; this fails with immediate
cleanup and passes with the lifetime check.

- [x] Ran the real installer (normal menu choice 1, no test mode or fixture).
  Verified installed wrapper exactly matches its generated source. Launched the
  registered AppImage menu ID with the normal profile and native still open:
  forwarding completed, no new core dumps, no remaining extraction directory.
  Native package and desktop-file hash remained unchanged. This checks the
  reported forwarding crash; it does not claim a standalone normal-profile
  session was opened while that profile was already in use by native.
