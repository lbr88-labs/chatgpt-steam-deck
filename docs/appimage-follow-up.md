# AppImage follow-up

- [x] Verify SSD-backed build scratch space for SteamOS tmpfs quota failures (errno 122). Full AppImage build completed; deliberate failure confirmed scratch cleanup. Included in installer 2026.10.25.9.

- [x] Reproduce Plasma's permission/not-permitted notification using the actual AppImage launcher.
- [x] Fix the cause in the installer and add a regression check.
- [x] Verify actual startup on SteamOS without removing the working native installation or using its profile.
- [x] Publish the fix and verify the desktop installer's download before asking the user to retry (installer 2026.10.25.8; GitHub main and immutable downloads verified).
- [x] Explain in the menu that the AppImage is built locally before installation.

Keeping both installations at once was cancelled by the user after successful
AppImage startup and normal-Quit verification. Retain the existing choice of
AppImage or standard installation, with switching replacing the previous method.

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
