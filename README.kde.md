# KDE Plasma

Install the [native Ubuntu 24.04+ deb](README.linux.md#native-deb) or the
[x86_64 Flatpak bundle](README.linux.md#flatpak). Keep one active installation
route per user; both use `ch.lkmc.monkeyspaw`. Read the default-on
[update request disclosure](PRIVACY.md#desktop-update-requests) before launch.

## Shortcuts and mechanism choice

Start the native app and open Setup or Settings → Shortcuts. The app uses
KGlobalAccel or an explicitly attached GlobalShortcuts portal session.
Availability depends on actual portal capabilities. A fresh native KDE
assignment can be unbound; **Ctrl+Alt+P** is a suggestion, and Repeat starts
unbound. Assign keys in System Settings → Shortcuts → Monkey's Paw, then
verify each real action in the app. Native key handling requires the app to
remain resident and fires on release.

Saved native custom keys, alternatives, multi-chord sequences and deliberate
unbinding are preserved. Portal attachment is explicit. The app suspends
native routing before attachment and closes portal routing before returning
to native. It can refuse a transition when foreign actions/contexts or changed
settings make preservation uncertain. Follow the displayed recovery guidance;
do not reset unrelated KDE shortcuts. Denying portal consent does not silently
resume native handling. A saved portal choice needs explicit attachment after
restart.

Manual launcher commands work cold and resident, but do not verify either
native or portal assignments:

```sh
gapplication action ch.lkmc.monkeyspaw toggle
gapplication action ch.lkmc.monkeyspaw repeat
```

Flatpak has no direct KGlobalAccel grant. Use its portal route or configure
host manual commands, avoiding duplicate bindings and another active native
instance. Portal assignments and host activation need real installed tests.

## Paste, Repeat and settings

Focus a browser field, release the picker shortcut, search and select a
prompt. Return uses the preferred chord. **Ctrl+Shift+Return** explicitly
chooses Ctrl+Shift+V for Konsole or another terminal; Fill's **Ctrl+Return**
explicitly chooses Ctrl+V, and **Alt+Return** copies only. Ordinary Return
inside a multiline field inserts a newline. The app sends no Return key to
the target; inspect shell input before using it.

Native KDE tries ydotool, a short lazy RemoteDesktop portal attempt, then
Copy. Configure tools/permissions through Setup and run Test paste; a zero
tool exit does not prove receipt. Flatpak tries only portal, then Copy.
Linux relies on KWin refocus after hiding and does not confirm target focus.
If delivery fails, paste the clipboard result yourself and rerun Test paste
after correcting consent/tools to reset the session failure cache.

Settings → Delivery selects the default Standard/Terminal chord. Wayland and
Flatpak cannot detect a terminal. Native X11 can recommend Ctrl+Shift+V for
exact [terminal class aliases](README.linux.md#x11-and-terminal-chords).
Clipboard restore defaults off, preserves text only and uses a guarded 750 ms
delay; read its [limits](PRIVACY.md#forget-repeat-and-clipboard) before enabling it.

Repeat uses your current target and exact latest field values; non-remembered
values require reopening after restart. Changed/inaccessible source requires
review. Forget clears corresponding repeat data. General offers automatic
update checks, Check Now and browser-only View release; install updates yourself.

Run the [KDE owner procedure](docs/platform/kde.md#m7-current-desktop-procedures)
for both actions and mechanism races, and the [Flatpak procedure](docs/platform/flatpak.md)
for sandbox consent, tray and URI behavior. Record results in the
[M7 ledger](docs/platform/m7-acceptance.md). See [Linux troubleshooting](README.linux.md#troubleshooting).
