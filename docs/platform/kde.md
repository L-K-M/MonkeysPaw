# KDE shortcut selection and delivery owner check

For current setup, see [README.kde.md](../../README.kde.md). Earlier
milestone procedures retain their original unrun results; use the
[current M7 procedure](#m7-current-desktop-procedures) and [M7 ledger](m7-acceptance.md)
for the added behavior and exact-build owner evidence.

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
  allowed. Real installed identity remains owner proof.

## Flatpak tray and library boundary

All checks are **NOT RUN**. Record the main commit, artifact version/hash,
Flatpak version and user overrides with the KDE/portal versions above.
Use one active install route per user: native and Flatpak share
`ch.lkmc.monkeyspaw`. Quit the other route and verify host activation reaches
the sandbox before testing.

- [ ] Inspect `flatpak info --show-permissions ch.lkmc.monkeyspaw`: IPC/network,
  Wayland/fallback-X11, home read/write and only Secret Service plus
  `org.kde.StatusNotifierWatcher` talk permissions. Portals/app subnames use
  filtered defaults. No host dconf, KGlobalAccel, host-spawn, unrestricted bus
  or foreign-name ownership grant is allowed; review user overrides separately.
- [ ] Confirm one tray item registers under
  `ch.lkmc.monkeyspaw.StatusNotifierItem-<pid>-1`, with no owned `org.kde.*`
  name. Click the picker/menu actions, quit/relaunch and restart the watcher.
  The item disappears on quit and returns once on restart. With no watcher,
  the app remains usable and starts no watcher.
- [ ] Confirm fresh config/data and file-backed secrets use
  `~/.var/app/ch.lkmc.monkeyspaw/{config,data}/monkeyspaw`, without importing
  native state. Home access is read/write for the whole home to support
  editable, watched home libraries. Test the default and a chosen home
  library, live edits, return to default and persistence after restart.
  An outside-home XDG Documents setting falls back to `~/Documents/MonkeysPaw`.
- [ ] Select an external/document-portal folder or a home symlink leading
  outside home. The typed refusal shows home/native guidance and preserves
  the active graph, watcher, editor and saved library choice. Cancel another
  selection and confirm the same preservation. Use a home library or the
  native app; an outside-home filesystem override cannot remove this boundary.

Results: no owner session, version record or real KDE test has been run.

## M7 current desktop procedures

Status: **NOT RUN**. Keep all earlier transition and Flatpak rows. Apply the
[Linux M7 procedure](linux.md#m7-current-desktop-procedures) to native KDE
Wayland and X11 where available, then record these results and exact
main/artifact/session metadata in the [M7 ledger](m7-acceptance.md). Record
actual GlobalShortcuts/RemoteDesktop capabilities, backend versions, keyboard,
signing, permission state, targets and tester/date.

| Check | Required observation | Result | Evidence |
|---|---|---|---|
| Two native actions | In System Settings inspect picker and Repeat. Assign/verify custom keys, alternative multi-chords and deliberate unbinding for each; restart and independently clear/rebind. Real native releases verify the matching action, without duplicates or replacing another app's keys. | NOT RUN | NOT RUN |
| Both-action handoff matrix | Rerun every earlier portal/native transition row with both actions present. Compare complete assignments before/after Create/List/Bind/Close and native return. Include edits/foreign contexts, denial/cancel, daemon loss, pending parenting and settings races. Uncertain state fails closed; saved keys survive and both routes never fire together. | NOT RUN | NOT RUN |
| Cold actions and delivery | Toggle/repeat cold and resident; manual actions verify neither native nor portal route. Then real keys, self-test plus browser/chat/Konsole readback in normal/full-screen/multiple monitors. Confirm current-target Repeat, default/explicit chords and no Return event. | NOT RUN | NOT RUN |
| Failure/clipboard/privacy | Native ydotool → short portal → Copy and sandbox portal → Copy; test missing/denied/stale cases and cache reset. Execute Linux M7 restart/Forget/retirement, restore off/on/slow target and competing identical/different copy cases with sanitized evidence. | NOT RUN | NOT RUN |
| Settings and updates | Complete D18 persistence/failure/lifetime, General update traffic/browser and Delivery/Shortcuts/Orca/keyboard rows; preserve Assistant/Account. Do not count a sent event or successful tool exit as target readback. | NOT RUN | NOT RUN |
| Installed Flatpak | Complete all KDE columns in the [Flatpak procedure](flatpak.md): no native KGlobalAccel/uinput route, real portal consent/focus, optional tray app subname, home/state/Secret Service, cold actions and browser/URI staging without launch redemption. | NOT RUN | NOT RUN |

See [README.kde.md](../../README.kde.md) for setup. Missing required sessions
become BLOCKED when attempted and keep acceptance open.
