# GNOME portal owner checks

Status: **NOT RUN**. The M1c coding slice has private-bus fixtures and CI
checks; this host has no real GNOME/Wayland session or packaged flatpak.
M1c acceptance stays open until these results are recorded. Never include
restore tokens, activation tokens, prompt content or raw portal error bodies.

Record the date, distribution, GNOME Shell version, Wayland/Xorg session,
xdg-desktop-portal version and selected desktop backend. Record the installed
app/desktop-file identity (`ch.lkmc.monkeyspaw`) and the GlobalShortcuts and
RemoteDesktop interface versions and available device types. Probe actual
capabilities, rather than inferring them from the GNOME version.

- [ ] Launch the installed app. Confirm startup, service activation and
  `--selftest` neither bind shortcuts nor write gsettings or open consent
  dialogs. Setup should describe the current grant and hotkey state.
- [ ] In Setup, Allow the shortcut and choose its keys. Confirm the actual
  trigger description and changes from system configuration are displayed.
  The v2 configuration action should remain available after verification.
  A manual D-Bus toggle must open the picker without verifying this portal
  shortcut or consume a pending portal activation token. Press the real
  shortcut to turn its verification row green. Duplicate Activated events
  with the same timestamp must not toggle twice; obsolete callbacks after
  reconfiguration must not supply verification.
- [ ] Quit and relaunch. Use Setup's hotkey action to attach this run's
  session without resetting your chosen keys. Confirm only one Bind attempt
  per session, a stable shortcut session identity, and session closure on
  quit. No automatic startup Bind is intentional in this slice.
- [ ] With an untouched M1b fallback row, confirm only its list entry is
  retired on the explicit Setup action; its fields and foreign rows survive.
  With an edited row or a foreign row invoking our toggle, confirm the app
  asks you to disable it first and creates no duplicate active shortcut.
- [ ] In Setup, Allow keyboard access. Confirm only keyboard input is
  requested, the portal grants it, and the row reflects the live session.
  Confirm the dialog is parented when an active native window can be
  identified, including Wayland handle export. Check the documented
  unparented case after hide and on export failure.
- [ ] Quit and relaunch, then Allow again. Confirm consent persists under
  the installed app identity and replacement restore tokens remain private
  (portal.json mode 0600). Confirm revocation produces a consent interaction
  only from Allow or a direct first-delivery gesture. Never record tokens.
- [ ] Run Setup's Test paste and `monkeyspaw --selftest` on GNOME Wayland.
  Record the full per-backend readback report, including sent-but-not-received
  results and failures. Confirm portal -> ydotool -> copy order. A mock-bus
  `.sent` result is not proof of receipt.
- [ ] From the real shortcut, deliver into a browser text field with Return
  (Ctrl+V), and into a terminal with Ctrl+Shift+Return (Ctrl+Shift+V). Confirm
  clipboard-before-hide, compositor refocus, correct modifier release, and
  no unintended submission or stuck modifiers. Check first-delivery consent
  and delivery with an already established session separately.
- [ ] Test unsupported GlobalShortcuts, denied/cancelled consent, an empty
  shortcut binding and a stale/closed RemoteDesktop session. Unsupported
  GNOME should offer gsettings installation only from Setup. Cancellation
  must not silently install it. Test paste resets the paste failure cache;
  ordinary delivery must skip a failed portal for the rest of the run.
- [ ] Hold/abandon a consent dialog, revoke an established session, and quit
  during an interaction. Confirm bounded completion and no late chord after
  a fallback. Check explicit Allow recovery followed by Test paste.

Paste results: **NOT RUN**. Record each backend, grant/session status,
standard/terminal receipt, and any fallback. A copy-only result needs a
written root cause (capability, identity, consent, focus, session loss,
injection or readback), evidence and the recovery tried.

Flatpak checks: **NOT RUN; require the installed package**.

Record the main commit, artifact version/hash, Flatpak version and any user
overrides as well as the session/portal versions above. Use one active install
route per user: native and Flatpak share `ch.lkmc.monkeyspaw`. Quit the other
route and verify the activated process is the sandbox before these checks.

- [ ] Confirm exported `.desktop`, D-Bus service and app id all match
  `ch.lkmc.monkeyspaw`. From the host, cold `gapplication action
  ch.lkmc.monkeyspaw toggle` must start the sandbox and show the picker once.
- [ ] Confirm the sandbox uses portal -> copy only, with no host tool or
  gsettings writes. Remove any old host toggle binding before choosing a
  portal shortcut: the sandbox cannot inspect host dconf rows.
- [ ] Verify cold action identity, consent persistence, native parenting,
  real shortcut activation and per-backend self-test readback in the package.
- [ ] Inspect `flatpak info --show-permissions ch.lkmc.monkeyspaw`: IPC/network,
  Wayland/fallback-X11, home read/write and only Secret Service plus
  `org.kde.StatusNotifierWatcher` talk permissions. Portals/app subnames use
  filtered defaults; no host dconf, KGlobalAccel, host-spawn, unrestricted bus
  or foreign-name ownership grant. Review user overrides separately.
- [ ] With a tray extension/watcher enabled, confirm one item registers as
  `ch.lkmc.monkeyspaw.StatusNotifierItem-<pid>-1`; click the picker and menu
  actions, quit/relaunch, and restart the watcher. The item must disappear on
  quit and return once on restart, with no owned `org.kde.*` name. Without a
  watcher, the app remains usable and starts no watcher.
- [ ] Confirm fresh sandbox settings and file-backed secrets are under
  `~/.var/app/ch.lkmc.monkeyspaw/{config,data}/monkeyspaw`, with no native-state
  import. Home access is read/write for the entire home, to support editable,
  watched libraries there. Open the default library and choose another home
  library; edit a prompt and confirm its live refresh and saved choice after
  restart. A host XDG Documents folder outside home must fall back to
  `~/Documents/MonkeysPaw`.
- [ ] Choose an external folder or a document-portal path, then cancel another
  choice. Refusal must show home/native guidance and preserve the active
  library, watcher, editor and saved choice; cancellation preserves them too.
  Include a home symlink leading outside home. Keep the library in home or
  use the native app; an outside-home filesystem override does not remove
  the app's home-only boundary.
