# Hardening changes in this fork

Personal fork of [hbashton/DS4Windows](https://github.com/hbashton/DS4Windows),
kept close to upstream. Everything here is a security fix; no features were
added or removed. Upstream is GPL-3.0 and so is this.

## Listeners no longer reachable from the LAN

| Where | Was | Now |
| --- | --- | --- |
| OSC listener (`ControlService.cs`) | `IPAddress.Any:9000` | `127.0.0.1:9000` |
| OpenRGB SDK (`OpenRGBServer.cs`) | `IPAddress.Any:6743` | `127.0.0.1:6743` |
| VIIPER USB/IP (`viiper.exe`) | `:3241`, no auth | `127.0.0.1:3241` |
| VIIPER control API (`viiper.exe`) | `:3242` | `127.0.0.1:3242` |

The OSC one mattered most: its command surface writes synthetic controller
input, and DS4Windows maps controller input to keyboard and mouse, so an
interface-wide bind handed remote input injection to anything on the LAN. It
had no listen-address setting, and SharpOSC's `UDPListener` takes only a port
and always binds every interface — hence `LoopbackOscListener`, which binds
loopback and reuses SharpOSC for packet parsing only.

VIIPER's USB/IP port has no authentication at all (its control API does
require a password for non-loopback clients, but the USB/IP port does not), so
both are now pinned to loopback via `--usb.addr` / `--api.addr` at every
launch. The arguments live in `ViiperSetupManager.ServerArguments` and the
matching `$script:ServerArguments` in the setup script.

Both listeners are off by default upstream too — this makes enabling them safe
rather than relying on the Windows Firewall to catch the mistake.

## Downloads are verified before they run

`extras/install-viiper-backend.ps1` asked the GitHub API for the newest
non-draft release (prereleases included), took the first `.exe`/`.zip` asset it
found, and ran it as Administrator. There was no hash or signature check
anywhere in the repo — the only validation was "non-empty and over 64 KB". The
usbip-win2 **kernel driver** was installed the same way.

Now both artifacts are pinned by URL and SHA-256, and nothing executes unless
the hash matches. To move to a newer version, download the asset, run
`Get-FileHash -Algorithm SHA256`, and update the constant next to the URL.

Currently pinned:

- VIIPER `v0.0.5` — `3AD872D006DF2FC282E381A68B5A5B3C51E4DA3614D250AB3FDA1C272EF745D0`
- usbip-win2 `0.9.7.7` — `51620FA5F9F8BE5932BC9D786DEEE557CE06D5407A99CAB490DCFAC71F185FEA`

Note that the app's own auto-updater (`MainWindowsViewModel.RunUpdaterCheck`)
still downloads and runs `DS4Updater.exe` unverified. That path is inherited
from upstream and is untouched here; it only triggers if you use the in-app
update button.

## The elevated logon task no longer points at a writable file

Setup registers a scheduled task `RunVIIPER` that runs `viiper.exe server` at
every sign-in with `RunLevel Highest` — elevated, with no UAC prompt. Upstream
installed that binary to `%LOCALAPPDATA%\VIIPER`, which any process running as
you can write, so replacing it bought silent Administrator execution at the
next login.

`viiper.exe` now installs to `%ProgramFiles%\VIIPER` (administrator-only ACL by
default), and setup deletes a leftover `%LOCALAPPDATA%\VIIPER` if it finds one.
DS4Windows prefers the Program Files copy and falls back to the old path only
if an install predates this change.

## There is an uninstall path

Upstream ships none, so removing DS4Windows left `RunVIIPER` starting an
elevated backend forever. `extras/uninstall-viiper-backend.ps1` unregisters the
task and removes both install directories. usbip-win2 is a shared kernel driver
and is left alone unless you pass `-RemoveUsbip`.

## Still worth knowing

- **Not yet tested on real hardware.** CI builds it and the unit tests pass,
  but the loopback pinning of VIIPER's USB/IP port is the one change that could
  affect function: usbip-win2 attaches to the literal host `localhost`, and if
  that resolves to `::1` before `127.0.0.1`, attach could fail against an
  IPv4-only bind. If virtual controllers stop appearing, `ServerArguments` in
  both files is the first thing to revert.
- Releases are unsigned, here and upstream. SmartScreen will complain.
- The fork's git history was squashed upstream into a single commit, so there
  is no way to diff it against the original DS4Windows by history.
