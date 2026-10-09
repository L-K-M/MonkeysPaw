# KDE native delivery owner check

Status: NOT RUN

Private-bus tests prove the native protocol and GTK/Setup integration, not
real Plasma behavior. M1d stays open for these checks and the later shared
Plasma >= 6.3 portal selection/transition slice.

Record the tested commit, distro, kernel, Plasma/KWin, KGlobalAccel,
xdg-desktop-portal and KDE portal versions, GTK version, session type,
packaging (native/flatpak), available portal interfaces/versions, ydotool
dialect/socket permissions and keyboard layout. Run on KDE Wayland and X11.
Do not paste shortcut keys, portal tokens or prompt/field contents into logs.

- [ ] Start the native app resident. System Settings -> Shortcuts ->
  Monkey's Paw shows Open picker under `ch.lkmc.monkeyspaw` (without
  `.desktop`). A fresh install is unbound; Ctrl+Alt+P is only the default
  suggestion. Repeat is unbound.
- [ ] Assign a free key in System Settings. Setup updates the actual
  assignment live. Start "Press your shortcut now": key press and held-key
  repeat do not toggle or verify; release toggles once and verifies.
- [ ] Change to a custom assignment, including a multi-chord sequence if
  Plasma supports it. Exit and relaunch: the exact assignment survives.
  Deliberately unbind, exit and relaunch: it remains unbound and Setup
  removes readiness. The native configuration button still gives guidance
  and refreshes the actual registration.
- [ ] Occupy Ctrl+Alt+P with another app before a fresh installation. Setup
  gives conflict guidance without changing the foreign app. Repeat with
  a saved assignment that conflicts. Resolve in System Settings and use
  Setup to retry; no foreign shortcut is stolen or removed.
- [ ] Stop/restart KGlobalAccel while the app is resident. Readiness is
  removed, obsolete releases do nothing, and explicit Setup retry restores
  the live assignment. App exit neither restarts the daemon nor removes
  persistent choices.
- [ ] With the native app stopped, invoke
  `gapplication action ch.lkmc.monkeyspaw toggle`; it cold-starts and opens
  the picker once. Invoke it again while resident. Neither manual action
  verifies the native shortcut. Native release handling requires residency;
  a separately configured desktop-file action launches on press.
- [ ] On Wayland, open the picker over a focused browser/chat field and a
  terminal, including a maximized/full-screen window and multiple monitors.
  Check typing, dismissal and compositor refocus; clicking another app does
  not pull focus back. Record limitations rather than inferring macOS focus
  guarantees.
- [ ] Allow each available paste backend explicitly in Setup, then run Test
  paste. Record per-backend standard Ctrl+V and terminal Ctrl+Shift+V
  readback, plus a browser/chat field and a terminal delivery. The KDE ladder
  is ydotool -> short lazy RemoteDesktop portal -> copy. A tool's zero exit
  is not proof of receipt.
- [ ] Test unavailable ydotool, a failed/stale portal, and copy fallback.
  Clipboard ownership survives hide; the captured target receives paste
  after settle/refocus; failures are cached until Test paste resets them.
- [ ] Run `monkeyspaw --selftest` and the GApplication `selftest` action
  before allowing the portal. Diagnostics request no consent. Record
  failed/sent-but-not-received results and their root causes honestly.

Later slice, also NOT RUN: capability-based portal selection on Plasma
>= 6.3, saved-binding preservation, native-to-portal transition without
duplicate toggles, explicit fallback, portal configuration and revocation,
and KDE-host flatpak identity, consent, exported D-Bus cold activation and
per-backend paste readback. This native PR does not implement that transition.

Results: no owner session, version record or real KDE test has been run.
