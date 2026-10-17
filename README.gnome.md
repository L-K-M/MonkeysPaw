# GNOME

Install the [native Ubuntu 24.04+ deb](README.linux.md#native-deb) or the
[x86_64 Flatpak bundle](README.linux.md#flatpak). Use one active installation
route per user: both use `ch.lkmc.monkeyspaw`. Read the default-on
[update request disclosure](PRIVACY.md#desktop-update-requests) before launch.

## Set your shortcuts

Start Monkey's Paw and open Setup. The app probes GlobalShortcuts and
RemoteDesktop capabilities; your GNOME version alone does not establish
support. Starting the app, refreshing Settings and running diagnostics do
not request shortcut consent or install custom bindings.

Where GlobalShortcuts is supported, use Setup's explicit portal action and
choose keys. **Ctrl+Alt+P** is the picker suggestion; Repeat starts unbound.
Settings → Shortcuts shows both actions and their live assignments. Verify
each with its real shortcut. A manual launcher action does not verify a
portal binding. Configure/change guidance depends on the portal interface
version. Cancelling consent does not install a fallback.

If GlobalShortcuts is unavailable, the native app offers explicit GNOME
custom-binding installation. It touches only its owned `Monkey's Paw: toggle`
and `Monkey's Paw: repeat` rows, preserving other and edited rows. Assign
Repeat explicitly. You can instead add these commands in GNOME Settings →
Keyboard → Custom Shortcuts:

```sh
gapplication action ch.lkmc.monkeyspaw toggle
gapplication action ch.lkmc.monkeyspaw repeat
```

The commands support cold and resident activation. Remove duplicate manual
bindings before enabling the portal route. Flatpak cannot inspect or edit
host dconf; configure its portal/manual shortcut yourself.

## Deliver and recover

Focus a harmless browser field, release the picker shortcut, search and choose
a prompt. Return uses the preferred chord; **Ctrl+Shift+Return** explicitly
selects terminal paste. In Fill, **Ctrl+Return** explicitly selects Ctrl+V;
ordinary Return in multiline fields edits text. **Alt+Return** copies only.

On native GNOME, paste tries RemoteDesktop portal, then ydotool, then Copy.
Flatpak tries portal, then Copy. Use Setup to allow keyboard access and run
Test paste. A successful tool/portal call does not prove target receipt.
Denied permission or a failed backend can leave the result on the clipboard;
paste manually, fix consent/tools and rerun Test paste to reset the session
failure cache. Linux relies on compositor refocus after hiding.

Wayland cannot identify terminals. Choose Standard/Terminal in Settings →
Delivery or use the explicit terminal chord. Native GNOME X11 can recommend
the terminal chord for its exact class allowlist; see [X11 limits](README.linux.md#x11-and-terminal-chords).
The app sends no Return key to your target. Check pasted newlines before
using a shell.

Delivery also offers opt-in previous-text clipboard restore, Test paste and
Open Setup. Restore defaults off; its 750 ms delay and simultaneous-copy
limit are described in [Privacy](PRIVACY.md#forget-repeat-and-clipboard).
Repeat's session/restart and Forget rules apply to both shortcut routes.

Use the [GNOME owner procedure](docs/platform/gnome.md#m7-current-desktop-procedures)
and [Flatpak procedure](docs/platform/flatpak.md) for consent persistence,
revocation, focus and real readback. Without a tray extension, use the launcher
and desktop Settings/Library actions. See [Linux troubleshooting](README.linux.md#troubleshooting)
and the [acceptance ledger](docs/platform/m7-acceptance.md).
