# Linux

Choose the native deb on Ubuntu 24.04+ (GTK 4.14), or the x86_64 Flatpak
bundle using GNOME Platform 50. For shortcut setup, follow
[GNOME](README.gnome.md) or [KDE](README.kde.md); ordinary X11 and wlroots
manual shortcuts are below. Real compositor support still requires the
[owner checks](docs/platform/m7-acceptance.md).

**Automatic update checks default on at first versioned launch.** GitHub sees
your IP and app version. Settings → General can turn them off; Check Now works
while off. View release opens your browser and you install updates yourself.
Read [Privacy](PRIVACY.md#desktop-update-requests) and [Security](SECURITY.md).

## Native deb

Download `monkeyspaw_<deb-version>_amd64.deb` and its `.deb.sha256` from
[Releases](https://github.com/L-K-M/MonkeysPaw/releases). Replace the version
and verify before installing:

```sh
sha256sum -c monkeyspaw_<deb-version>_amd64.deb.sha256
sudo apt install ./monkeyspaw_<deb-version>_amd64.deb
monkeyspaw
```

Prerelease deb filenames use `~`, such as `0.1.0~beta.1`, while the app version
uses `0.1.0-beta.1`. An update uses the same verify/install procedure after
quitting the app. `libglib2.0-bin` supplies `gapplication`; recommended tools
include `libsecret-tools`, `ydotool`, `xdotool` and `x11-utils` (`xprop`).
Configure ydotoold/socket permissions for your distribution rather than running
the app as root. Native input injection has [security limits](SECURITY.md#desktop-input-and-sandbox-limits).

The default library is XDG Documents/MonkeysPaw, usually
`~/Documents/MonkeysPaw`. General can choose a folder. The app keeps native
config under `~/.config/monkeyspaw` and data under `~/.local/share/monkeyspaw`,
respecting absolute XDG_CONFIG_HOME/XDG_DATA_HOME overrides. Keys use Secret
Service, a read-only environment override or the labelled **unencrypted**
fallback when `secret-tool` is absent. A failing installed service does not
authorize a new plaintext save. See [credential tiers](SECURITY.md#credentials).

## First hotkey and desktop actions

Open Setup and assign/verify the picker action. Ctrl+Alt+P is the suggestion;
Repeat starts unbound. Where your desktop needs a manual binding, add a
shortcut in its own settings for each command you choose:

```sh
gapplication action ch.lkmc.monkeyspaw toggle
gapplication action ch.lkmc.monkeyspaw repeat
```

These work cold or resident. Additional desktop actions are `settings`,
`library` and `selftest`. Manual invocation does not verify portal/KDE bindings.
The launcher and tray provide Settings/Library access; a tray watcher is
optional. Setup, diagnostics and service startup do not install host shortcuts.

Search and select with Return. In Fill, Tab/Shift+Tab traverses fields;
Return delivers from a single-line field and edits a multiline field.
**Ctrl+Return** in Fill explicitly pastes with Ctrl+V;
**Ctrl+Shift+Return** explicitly selects Ctrl+Shift+V; **Alt+Return** copies.
Picker Ctrl+Return opens Edit. Escape cancels. The app sends no target Return
key, although a terminal can interpret newlines already in pasted content.

## X11 and terminal chords

Settings → Delivery chooses Standard (Ctrl+V) or Terminal (Ctrl+Shift+V) as
the Linux default. For the preferred action on native X11, a bounded WM_CLASS
probe recommends Ctrl+Shift+V only for these case-insensitive exact aliases:
`Gnome-terminal`, `gnome-terminal-server`, `konsole`, `Xfce4-terminal`,
`mate-terminal`, `Tilix`, `Alacritty`, `kitty`.

Other/unknown classes use your saved default; explicit paste/Copy choices win.
XTerm, URxvt, st and embedded VS Code are not allowlisted. The CI XTerm smoke
changes its paste binding, so it does not establish stock XTerm support. Each
alias needs its own real chord/readback evidence in the
[ledger](docs/platform/m7-acceptance.md#x11-alias-evidence).
Wayland and Flatpak do not inspect terminal identity.

Native GNOME tries portal → ydotool → Copy; native KDE tries ydotool → portal
→ Copy. Other X11 tries xdotool → ydotool → Copy. wlroots uses ydotool → Copy
and a manual compositor shortcut. Linux relies on compositor focus after
hide, with no confirmed target restoration. X11 clients and input tools are
not isolated from other software in your session.

## Flatpak

Use one active install route per user. Quit/remove competing native launcher
registrations before relying on sandbox activation: both routes share
`ch.lkmc.monkeyspaw`. This repository distributes a bundle and checksum on
GitHub Releases; Flathub supplies the GNOME runtime, not the app.

Download `monkeyspaw_<full-version>_x86_64.flatpak` and its `.flatpak.sha256`.
Keep prerelease hyphens. With Flatpak installed and Flathub configured for
your user, verify and install:

```sh
sha256sum -c monkeyspaw_<full-version>_x86_64.flatpak.sha256
flatpak install --user flathub org.gnome.Platform//50
flatpak install --user ./monkeyspaw_<full-version>_x86_64.flatpak
flatpak run ch.lkmc.monkeyspaw
```

The bundle declares the Flathub runtime repository. Review Flatpak's install
prompt. To update, quit the app, download the new bundle/checksum, verify and
run the bundle install command again, accepting replacement when offered.
A single-file bundle does not supply an app update feed; `flatpak update`
alone is not this app's release-install procedure. See
[Flatpak bundle documentation](https://docs.flatpak.org/en/latest/single-file-bundles.html).

Inspect `flatpak info --show-permissions ch.lkmc.monkeyspaw` and any user
overrides. The manifest grants network, IPC, Wayland/fallback-X11,
**read/write access to the whole home directory**, Secret Service and optional
`org.kde.StatusNotifierWatcher` access. There is no host dconf, unrestricted
bus, host-spawn, uinput or KGlobalAccel grant. Runtime `gsettings` availability
does not authorize host settings writes.

Sandbox state is separate under
`~/.var/app/ch.lkmc.monkeyspaw/{config,data}/monkeyspaw`. Native secrets/state
are not imported. The editable/watched library must be inside home, including
resolved symlink targets. Outside-home folders and document-portal paths are
refused without changing the current library. Choose a home folder or use
the native app; a filesystem override alone does not remove that app boundary.

Delivery is portal → Copy. Use portal consent or host manual shortcuts;
xdotool/ydotool injection, terminal detection and host autostart from inside
the sandbox are unavailable. Secret Service must work for saved keys in the
packaged runtime; a denied or locked service is not a plaintext downgrade.
Real consent, tray, browser association and clipboard behavior remain in the
[Flatpak procedure](docs/platform/flatpak.md).

## Troubleshooting

If paste fails, use Ctrl+V or your terminal's paste chord on the clipboard
result. Correct tools/consent, then use Settings → Delivery → Test paste to
reset cached backend failures. Always check real target text; `.sent` or a
zero tool exit is not readback proof. Restore defaults off; read the
[750 ms and simultaneous-copy caveats](PRIVACY.md#forget-repeat-and-clipboard).

Repeat needs a usable latest delivery; cold activation with none shows
Nothing to repeat. Reopen after a session-only restart or changed source.
Forget removes remembered/repeat values, not prompt history or OS clipboard
history. Settings → General also contains update results; errors and no
release remain distinct from up to date.

`monkeyspaw --selftest` reports backend readback without granting new consent.
The installed desktop handler stages `monkeyspaw://join` links for explicit
Accept. It does not set your MIME default. Read the
[argv/browser-history exposure](PRIVACY.md#invite-links) before sharing links.
Desktop Account, invites, sync status, groups and conflict resolution are
available on main. Automated device-token privacy fixtures passed native CI.
The dedicated sync guide and owner checks of installed apps, real keyrings
and deployed servers remain M6 Y34 work. See
[hosting](docs/platform/server.md#host-the-sync-server),
[Linux owner procedures](docs/platform/linux.md#m7-current-desktop-procedures)
and [local build prerequisites](CICD.md).
