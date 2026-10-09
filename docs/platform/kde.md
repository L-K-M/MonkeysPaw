# KDE shortcut selection and delivery owner check

Status: NOT RUN

Coupled private-bus tests exercise native/portal component ownership and
GTK/Setup integration. They do not prove real Plasma behavior. The M1d coding
path includes capability selection and explicit handoff; M1d acceptance stays
open for every owner check below.

Record the tested commit, distro, kernel, Plasma/KWin, KGlobalAccel,
xdg-desktop-portal and KDE portal versions, GTK version, session type,
packaging (native/flatpak), available portal interfaces/versions, ydotool
dialect/socket permissions and keyboard layout. Run on KDE Wayland and X11.
Do not paste shortcut keys, portal tokens or prompt/field contents into logs.

- [ ] With the public GlobalShortcuts interface absent, start the native app
  resident. System Settings -> Shortcuts ->
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

## Portal/native transition matrix

All rows are NOT RUN. Inspect the public interface version, not the desktop
version string. Plasma 6.3 supplies v1; v2 adds ordinary ConfigureShortcuts.
Run every applicable row on Wayland and X11, retaining a private backup of
KDE shortcut settings and portal permission-store entries for comparison.
Never commit those backups or shortcut values/tokens to this checklist.

| Starting state | Explicit action | Expected result |
|---|---|---|
| Portal absent or unsupported, no mechanism record | Start / diagnostics | Native registration; no consent, settings window or active-key rewrite. |
| Portal v1/v2, fresh component | Start | Offer Attach shortcut portal; no native registration, portal session or settings window. |
| Portal v1/v2, saved native custom/unbound/full alternatives | Start | Exact saved native choice stays effective. Deliberate unbinding remains unbound. |
| Native active and verified | Attach shortcut portal | Native routing and presence stop before Create loads actions. List then Bind once; saved keys survive and preferred_trigger is omitted. Portal requires new genuine verification. |
| Additional component actions or contexts | Attach shortcut portal | Block before Create/Bind, keep native, explain System Settings guidance. Foreign state stays unchanged. |
| Assignment/component changes during handoff | Attach shortcut portal | Recheck complete snapshots; block or quiesce without claiming an atomic transaction or restoring keys. |
| Portal v1 returns unbound while settings opens | Assign keys in system UI | ShortcutsChanged updates readiness; Activated verifies. Configure gives settings guidance with no second Bind. |
| Portal v2 attached | Change in system settings | Ordinary no-output ConfigureShortcuts; one Bind per session; window parent lease survives the call. |
| Portal denied/cancelled after native suspension | Complete interaction | Native stays suspended, choices persist, no automatic fallback. Explicit native action resumes after acknowledged Close. |
| Portal active, including verified | Use native KDE shortcut | Visible enabled Setup button; portal routing/tokens stop and Close completes before native presence resumes. New native release required for verification. |
| Failed/uncertain Close or timed-out Create | Retry / Use native KDE shortcut | Fail closed with restart guidance. Never run both mechanisms. |
| Portal/native service loss | Retry in Setup | Remove readiness and ignore obsolete events; no automatic peer activation. Quiet capability recheck on portal retry. |
| Saved portal mechanism choice | Restart | Offer attachment without startup consent or native activation. Setup reattaches with existing portal/native daemon keys. |
| Saved native mechanism choice | Restart | Preserve native even when portal capability is present. |
| Missing/corrupt/unreadable record | Restart | Preserve saved native choices; show recovery failure where applicable, no portal consent. Explicit choice repairs the record. |
| Choice save failure | Choose either mechanism | Actionable failure; no durable-success claim, preserve keys, no unverified peer activation. |

- [ ] Verify the daemon uses the same `ch.lkmc.monkeyspaw` / `toggle` row for
  both mechanisms, without `.desktop`. Compare complete multi-chord and
  alternative assignments before/after Create, List, Bind, Close, native
  fallback and restart. Do not rely on localized trigger descriptions or
  legacy first-chord arrays as proof. Include empty alternatives and a
  deliberately unbound saved action. No NoAutoloading, destructive unregister,
  cleanUp or foreign shortcut removal may occur.
- [ ] Preserve every foreign action/context and every other app's keys. Add a
  foreign action during window parenting and settings interaction. Record
  observed race behavior; separate D-Bus/settings operations are not atomic.
- [ ] Hold/repeat a key and alternate native release with portal Activated,
  including delayed events after fallback/retry/service restart. One effective
  activation toggles once. Manual/cold GApplication actions still open the
  picker and never verify either mechanism or consume a portal activation
  token. Verify the stable registration survives every handoff.
- [ ] On real Wayland, check exported parent handles, activation tokens, focus,
  full-screen windows and multiple monitors. Cancelling/closing Setup while
  export or consent is pending must release leases and prevent late binding.
  Record compositor focus limitations and compare clipboard-before-hide,
  settle/refocus and captured-target paste with the native delivery checks.
- [ ] Compare shared daemon settings and portal permission-store entries after
  cancellation, denial, fallback, revocation, restart and repeated configure.
  Stored choices and deliberate unbinding survive cleanup. Changing a key in
  the portal UI must be distinguished from loss/truncation in transition.
- [ ] On a KDE-host flatpak, verify the real installed/exported app identity,
  consent persistence, exported D-Bus service cold activation and per-backend
  paste readback. No direct KGlobalAccel activation or new host permission is
  allowed. Packaging and real identity remain later owner proof.

Results: no owner session, version record or real KDE test has been run.
