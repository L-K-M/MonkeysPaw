## 6. Delivery: hotkey, panel, focus, paste

### 6.1 Session matrix

| | macOS 14+ | GNOME (Wayland or Xorg) | KDE Plasma 6 (Wayland or X11) | Other X11 / wlroots | Flatpak |
|---|---|---|---|---|---|
| **Hotkey** | Carbon `RegisterEventHotKey` | GlobalShortcuts portal on GNOME ≥ 48; else a gsettings custom keybinding running `gapplication action ch.lkmc.monkeyspaw toggle` | KGlobalAccel actions over GDBus (the user assigns keys in System Settings); portal on Plasma ≥ 6.3 | portal if present (Hyprland); else manual: bind `gapplication action ch.lkmc.monkeyspaw toggle` | portal; else the host mechanism with the same `gapplication action` (D-Bus activation crosses the sandbox; verify in M1c) |
| **Panel** | non-activating NSPanel at the cursor, clamped to the visible frame of the screen under the pointer | normal window; the compositor picks position and monitor (accepted, documented) | same | same | same as host |
| **Focus return** | re-activate the remembered app, verify, retry | compositor refocus after hide (best effort) | same | same | same |
| **Paste ladder** | CGEvent Cmd+V → AppleScript System Events → copy-only | RemoteDesktop portal keysyms → ydotool → copy-only | ydotool → RemoteDesktop portal (`PORTAL_CALL_TIMEOUT = 2 s`) → copy-only | X11: xdotool → ydotool → copy-only; wlroots: ydotool → copy-only (xdotool reaches only XWayland clients) | portal → copy-only |
| **Permissions** | Accessibility (+ Automation only when the fallback runs) | portal consent once (restore token), or ydotoold + `/dev/uinput` | ydotoold + `/dev/uinput`, or portal consent | xdotool: none; ydotool: as left | portal consent |

Hotkey notes:

- **Shortcuts settings (M2).** The shared `ShortcutsSettingsModel` shows the
  picker and repeat actions' live registrations, backend-reported binding/detail,
  conflict or failure information, and activation verification. An unknown
  binding stays unknown; the default is never presented as a current binding.
  Setup and Settings share refreshed snapshots and receive shortcut changes
  through removable observers on the injected `MainThread`, without issuing
  a second registration, portal List/Bind, or configuration request.
  - Carbon is app-owned. The in-app change intent parses an `Accelerator`,
    rejects Carbon's unsupported keys and overlapping Command aliases before
    replacing the registration, and retains the existing activation handler.
    Only a successful Carbon registration confirms the requested accelerator.
  - Portal v2 offers **Change in system settings** through the existing Setup
    hotkey action (`ConfigureShortcuts`). Portal v1 gives desktop settings
    guidance after binding, rather than binding again to change a key. Initial
    attachment/recovery remains an explicit Setup action. KDE's native path
    gives System Settings → Shortcuts → Monkey's Paw, retaining the existing
    explicit portal/native handoff actions. GNOME's fallback is installed only
    through the explicit Setup hotkey action; a registered fallback gives
    GNOME keyboard settings guidance. Manual mechanisms show the backend's
    `gapplication action` instructions.
  - Launching a change action does not confirm a binding or verification.
    Refresh uses the backend's reported result; verification still requires a
    real activation of the current mechanism/revision for that action. Manual
    activation never verifies an effective portal, KDE or Carbon binding.
  - Both actions are declared to the backend, including a callback and a nil
    accelerator for deliberately unbound repeat. Nil never selects a default.
    Registration identities, verification, debounce and replacement lifetimes
    are independent per action. Refresh only reads facts and never starts consent.
    A whole-catalogue apply during a replacement coalesces to the latest request
    and activation handler, applied after all in-flight replacements finish.
  - Carbon choices are persisted in version-1 settings as `carbonShortcuts`:
    `togglePicker` defaults to `Ctrl+Alt+P`, `repeatLast` to null. Null explicitly
    clears either action; omission uses that action's default. Validate Carbon
    translation and collisions (including aliases) before mutation. Save only
    confirmed registrations, restoring the previous action after native or save
    failure and reporting any failed recovery. Replacing or clearing one action
    preserves the other action and its verification. Restart loads both choices.
  The M7 Core contract precedes driver activation: portal, KDE and GNOME adapters
  report repeat unbound until their two-action implementations land (D9–D11).
  Native Settings/composition follows in D12/D13.
- **GNOME keybinding.** The custom keybinding row is named
  `Monkey's Paw: <action>`, so re-syncs update it in place. Installation
  runs from the explicit Setup hotkey action, never from startup, a service,
  a self-test or the package's `postinst` (that would write
  root's dconf). It is recorded only on success (Vervellum
  `ShortcutInstaller` rule). A failed read of the binding list aborts, and is
  never treated as an empty list that a write could then wipe.
- **D-Bus activation.** The `.desktop` file sets `DBusActivatable=true`.
  The package installs a D-Bus service file whose `Exec` runs
  `monkeyspaw --gapplication-service`. `gapplication action` therefore
  reaches the running instance, or starts the app when it is not running.
  - `g_application_hold` keeps the process resident while no window is
    visible.
  - One identity string, `ch.lkmc.monkeyspaw`, is the D-Bus name, the
    `.desktop` basename, and `StartupWMClass`. All three break silently if
    they diverge.
  - Desktop action ids must match the `GSimpleAction` names exactly
    (Vervellum `AGENTS.md`).
  - The flatpak build installs the same service file at
    `/app/share/dbus-1/services/ch.lkmc.monkeyspaw.service`. Flatpak exports
    it and rewrites `Exec` to `flatpak run`, which lets host keybindings
    cold-start the sandboxed app (verify in M1c).
  - The deb depends on `libglib2.0-bin`, which provides `gapplication`.
- **Portal app identity.** Non-sandboxed portal calls take their app id from
  the installed `ch.lkmc.monkeyspaw.desktop`. A mismatch stops the
  permission store from persisting consent. Verify in M1c.
- **Portal bindings.** The user chooses the keys. Settings shows the
  bindings from `ListShortcuts` and offers "Change in system settings"
  (`ConfigureShortcuts`, v2). A saved action from List is shown and rebound
  without another preferred trigger; the XDG default is only a suggestion
  for a new action.
  Startup only probes capability. Setup creates/lists/binds the session,
  with at most one Bind attempt per session. A cancelled, denied or unbound
  interaction stays actionable; it never silently installs gsettings.
  A new explicit Setup action may retry with a new session.
- **GNOME fallback migration (M1c).** Before portal binding, inspect the
  custom rows. Retire only the exact untouched M1b default (owned name,
  exact toggle command, default GTK trigger), by removing its list entry
  while retaining its fields. Preserve all other entries and fields. An
  edited owned row or another active row invoking our toggle blocks binding
  and asks you to disable that row in GNOME Settings first. Failed reads or
  writes also block binding. This happens only from the explicit Setup
  action; cancellation does not recreate the retired fallback. Unsupported
  or unavailable GlobalShortcuts uses the existing gsettings mechanism on
  GNOME, installed only on its Setup action. Other unsupported desktops
  retain the manual D-Bus instructions; KDE integration stays in M1d.
- **Plasma selection and handoff (M1d).** Native KDE Wayland/X11 probes the
  public GlobalShortcuts `version`; v1 and later are supported. No desktop
  version guessing. Startup and diagnostics never Create/List/Bind/configure
  a portal session or open settings. A saved native `toggle`, including a
  custom, unbound, multi-chord or alternative assignment, remains native
  until you choose **Attach shortcut portal** in Setup. A fresh supported
  path offers portal attachment; absent capability retains native behavior.
  **Use native KDE shortcut** remains an explicit Setup action even after
  verification. Flatpak retains its portal-only driver and host instructions.
  - Both drivers use component `ch.lkmc.monkeyspaw`, action `toggle`.
    KDE CreateSession.loadActions can make saved actions present before Bind;
    Bind.setActions can delete omitted actions. Inspect all component contexts
    and action names before creation, then again before Bind. Unknown actions
    or non-default contexts block the single-toggle handoff without mutation.
    Read complete `a(ai)` assignments, never reconstruct them from legacy
    `ai` fields or localized portal descriptions. Autoloading must preserve
    the exact daemon assignment across Create and Bind; recheck it. Native
    multi-chord/alternative values never become preferred_trigger strings.
    Saved portal actions from List omit preferred_trigger, including unbound
    actions. Only a new action gets the default suggestion. No foreign-key
    stealing, destructive unregister/cleanUp or NoAutoloading.
  - Gate native callbacks before acknowledged SetInactive, then create/list/
    bind once on the retained portal connection. Gate portal callbacks and
    tokens before acknowledged Close, then reactivate native. Two-second IPC
    and cleanup bounds remain; explicit Setup has a total 60-second consent
    budget. Snapshot reads and operations on separate connections are not an
    atomic transaction. Detect changes and fail closed; owner-run settings
    races remain required proof. A failed/uncertain Close or timed-out Create
    never authorizes native activation. Denial/cancellation installs no
    fallback. This slice deliberately leaves a suspended native action
    inactive after a failed handoff; choose the explicit native action to
    resume after verified cleanup. Persistent keys survive every cleanup.
  - One composite registration id survives selection changes. Only events
    from the effective mechanism/revision may toggle or verify. Reject
    duplicate events and obsolete tokens; manual/cold GApplication toggles
    remain usable and never verify either mechanism. Verification is tied
    to the current mechanism so a handoff requires a real new activation.
  - Persist only the explicit mechanism enum in an owner-private, validated,
    atomic `<data>/shortcut-mechanism.json` record, with no key values or
    tokens. Save portal intent before creation to recover conservatively from
    an interrupted transition. Restart with portal intent offers **Attach
    shortcut portal**; it never starts consent automatically or activates
    native. Save native intent only after portal quiescence. Missing/corrupt
    records inspect saved native choices without prompting; read/save failures
    stay actionable and do not claim durable success. No settings framework.
  - v1 Bind may immediately return unbound while System Settings is open;
    ShortcutsChanged updates readiness. For an attached v1 session, Setup
    gives System Settings guidance without another Bind. v2 ConfigureShortcuts
    is ordinary no-output IPC. Retain native window leases and activation
    tokens through their bounded interaction, invalidating late continuations.
- **Linux actions.**
  - `toggle` opens or closes the picker.
  - `repeat` re-delivers the last delivered prompt with the exact values
    used. With no prior delivery, repeat shows "Nothing to repeat". M7's
    Core service uses the private version-1 `<data>/last-delivery.json`,
    separate from frecency, with `LAST_DELIVERY_FILE_CAP_BYTES = 1 MiB` and
    atomic 0600 replacement. It stores root/account binding, identity/path
    hint, source fingerprint, an idless incarnation stamp, remembered fields,
    session-only requirement and Copy intent. Full exact fields remain in
    memory. No rendered text, template or builtin is persisted or logged.
    A latest session-only marker prevents an older delivery reappearing after
    restart; incomplete snapshots require reopening/review (§5.3, §12).
  - Repeat resolves assigned IDs from the current library across moves, or
    an idless path within the recorded root with the same incarnation. It
    never assigns an ID. Changed sources/field definitions require review;
    deleted, inaccessible or access-revoked sources block delivery. Date/time
    are sampled once at invocation; clipboard is read once only if used.
    Source/access/epoch checks run again after asynchronous work and inside
    the delivery queue before writing and before paste injection.
  - Completed user deliveries, including Copy, paste fallback and repeat,
    update repeat state and usage once. Self-test, preview and cancellation
    do not. Persistence failure is visible without undoing delivery. Repeat
    preserves Copy intent; paste uses the current invocation's target/session
    and current chord policy. The immutable invocation is captured before
    file/builtin work without changing hidden picker drafts or its armed target.
    Overlapping repeats are dropped. Native composition must supply a live
    own Settings/Library window gate, including on Wayland.
  - Forget values clears matching repeat state; Forget all, root/account
    replacement and sign-out retire all repeat data and pending callbacks.
    A tombstone is persisted before reporting a successful clear/retirement.
    Failure reports unsuccessful clear and disables repeat until a durable
    retry; composition must retain the binding rather than claim retirement.
    A failed disk write cannot promise removal across restart. Revoked
    continuations cannot start a paste or recreate cleared state; an event
    already submitted to a native injector cannot be unsent. D12/D13 supply
    native actions/hotkeys/UI, and D14 supplies the current terminal policy.
  - `selftest` runs §6.5.

### 6.2 Default hotkeys

| Action | macOS | Linux |
|---|---|---|
| Open picker | `⌃⌥P` | `Ctrl+Alt+P` |
| Repeat last prompt | unbound (user assigns) | unbound (user assigns) |

The defaults avoid these shortcuts:

| Shortcut | Taken by |
|---|---|
| `⌘⇧P` | VS Code command palette; Firefox private window |
| `⌘⇧R` | Browser hard reload |
| `⌘⇧M` | Firefox responsive mode |
| `⌃⌥Space` | macOS input source |
| `⌥Space` | Raycast; ChatGPT |
| `⌘⌥Space` | Finder search |
| `⌃⌥` + arrows, `C`, `D`, `E`, `F`, `G`, `T` | Rectangle |
| `Super+P` | GNOME display switch |
| `Cmd/Ctrl+Shift+V/B` | Copywraith |

The repeat action is left unbound so the app takes only one shortcut. Known
overlap: JetBrains "Extract Parameter" is `Ctrl+Alt+P` on Linux. On macOS
it is `⌥⌘P`, so there is no clash. `Ctrl+Alt+E` is the alternative if M1
finds the overlap matters (Q4).

Where possible, the app checks its hotkeys at startup against the system's
own shortcuts: the GNOME keybinding list, KGlobalAccel, and the portal's
`ListShortcuts`. On a conflict it warns and links to the Shortcuts setting.

### 6.3 The delivery sequence

```
DeliveryService.deliver(text, mode)
  1. clipboard.write(text)        ← while the panel still has focus (Wayland selection serial)
  2. panel.hideForDelivery()      ← UI thread; does not run the "restore focus" path
  3. wait SETTLE_MS_MACOS = 100 | SETTLE_MS_LINUX = 140      ← Copywraith's measured values
  4. focus.restore()              ← macOS: yieldActivation + activate, then wait for the AX
                                     focused app to match, up to AX_FOCUS_WAIT_MS = 500
  5. if mode == .copyOnly → notifier.copied(); done(.copiedOnly)
  6. for backend in ladder(session) where !failedThisSession(backend):
         backend.paste(chord) → success: done(.pasted(backend))
                              → failure: markFailed(backend); continue
  7. notifier.pressPaste(chord); done(.copiedOnly(reason))
```

- **macOS CGEvent.**
  - `CGEventSource(stateID: .hidSystemState)` posts `kVK_ANSI_V` down and
    up with `.maskCommand`, `CGEVENT_PAIR_GAP_MS = 20` apart, to
    `.cghidEventTap`. Some apps debounce same-timestamp pairs (Invoque).
  - `AXIsProcessTrusted()` is checked before each paste. When it fails, the
    app still re-activates the target, so focus returns even when the paste
    cannot run (Copywraith `PASTE_PROBLEM.md` lesson).
- **Exit 0 proves nothing.** Mutter has been reported to drop uinput key
  chords while `ydotool` exits 0 (OpenWhispr #956). GNOME therefore prefers
  the RemoteDesktop portal.
  - The portal sequence is `CreateSession` → `SelectDevices(types: keyboard,
    persist_mode: until-revoked, restore_token)` → `Start`, then four
    `NotifyKeyboardKeysym` calls: Control_L down, `v` down, `v` up,
    Control_L up.
  - Inspect the interface version and keyboard capability, and require an
    actual keyboard grant from `Start`. Only v2 adds persistence options.
    When a successful `Start` returns a replacement single-use restore token,
    store it immediately in `<data>/portal.json`, including when the grant
    lacks a keyboard. It lives there, not in the secret store, because it
    rotates. Version 1 uses a session without persistence options.
  - Portal calls follow the Request/Response pattern: subscribe to
    `Response` before calling, and use an unguessable `handle_token`.
  - Keysym table: Control_L `0xFFE3`, Shift_L `0xFFE1` (terminal chord),
    `v` `0x0076`.
  - There is one RemoteDesktop session per app run, created lazily on the
    first paste and closed on exit.
  - This uses the D-Bus `Notify*` methods only, never `ConnectToEIS`, which
    disables them.
  - This has been seen working on GNOME 50 (OpenWhispr #2475).
- **GlobalShortcuts sessions.** `CreateSession` passes a stable
  `session_handle_token`, so bindings persist across runs. The hotkey acts
  on `Activated`. Only that signal verifies a portal shortcut; a manual
  D-Bus toggle still opens the picker. Registration ids survive asynchronous
  status changes, while session loss removes readiness. Both portals use
  the same retained GDBus connection for requests, ordinary calls and
  signals, because sessions belong to that connection.
- **Portal deadlines and consent (M1c).** `PORTAL_CALL_TIMEOUT = 2 s`
  bounds properties and established-session IPC. One deadline covers the
  entire key chord, not two seconds per key. Cleanup has one bounded
  two-second budget for reverse key releases and session close, and finishes
  before the paste ladder advances. No later callback can send a new chord.
  Explicit Setup consent and initial GNOME/flatpak first-delivery consent
  use a separate `PORTAL_CONSENT_TIMEOUT = 60 s` total across session setup.
  Each noninteractive stage still has the short IPC budget. Quiet probes
  and self-tests never start a consent interaction, even with a stored token
  (a revoked token could open a dialog). Allow in Setup first, then test.
  KDE's lazy delivery session retains its short total portal budget.
  Setup Allow explicitly retries a failed session; ordinary deliveries
  retain the process failure cache, and Test paste resets it as before.
  After a token-save failure, only explicit Setup Allow replaces an idle
  ready session through fresh consent to persist a replacement token.
- **Native portal windows (M1c).** Use the active realized GTK window's
  hexadecimal X11 XID or exported Wayland surface handle. Export failure,
  absence of an active window, an export already leased by another portal
  interaction, and first delivery after hide deliberately
  use the documented empty unparented identifier, never an inferred handle.
  Keep an exported handle alive through its interaction, then unexport it.
  Shortcut activation tokens reach Wayland presentation only through the
  native driver boundary.
- **Cache failures.** On KDE the portal session goes stale after a few idle
  minutes, and retrying it every time cost 6-19 s per paste (OpenWhispr
  #1614). A failed backend is skipped for the rest of the session.
- **ydotool.** The dialect is sniffed from `ydotool help`: 0.1.8 symbolic or
  1.x evdev codes. Never try both, because 0.1.8 types numbers as digits.
  `YDOTOOL_SOCKET` is resolved and set explicitly (OpenWhispr #957), in
  this order:
  1. `$YDOTOOL_SOCKET`
  2. `$XDG_RUNTIME_DIR/.ydotool_socket`
  3. `/tmp/.ydotool_socket`

  This ports Copywraith `ydotool.rs`, including its fake-executable tests.
- **wtype is not used.** It works only on wlroots compositors, not on GNOME
  (mutter#1974) or KWin (KDE bug 502882).
- **Terminals.**
  - macOS terminals accept Cmd+V.
  - On Linux, Ctrl+V in a shell is readline quoted-insert, so the user picks
    the chord per delivery: `Return` sends the standard chord,
    `Ctrl+Shift+Return` sends Ctrl+Shift+V.
  - Settings has a "default chord" option for users who mostly paste into
    terminals. Version-1 settings records it as
    `delivery.linuxDefaultPasteChord`: `standard` (the missing-field default)
    or `terminal`. It supplies the Linux preferred intent; an explicit
    per-delivery standard/terminal chord or Copy intent overrides it.
    macOS keeps Cmd+V regardless of this Linux preference.
  - On X11 the target's class is read at `arm()` with
    `xdotool getactivewindow`, then `xprop -id <id> WM_CLASS` (`x11-utils`).
    The class is matched against a terminal list, and the terminal chord is
    chosen automatically in M7.
- **Typing is never automatic.** Typing multi-line text sends Enter: it
  submits chat boxes and runs shell commands. An opt-in typing mode is
  deferred past v1.
- **Clipboard restore.** Off by default: the result stays on the clipboard,
  which is predictable and doubles as the fallback. When enabled, the
  optional `ClipboardRestoring` capability captures previous text before the
  write/hide, while the panel still has focus. `CLIPBOARD_SNAPSHOT_BUDGET =
  250 ms` bounds capture; `CLIPBOARD_SNAPSHOT_MAX_BYTES = 1 MiB` bounds UTF-8
  text. Timeout, read failure, nil, oversize data or a changed capture revision
  skips restore. After the final backend reports sent, including a later backend
  in the same delivery's ladder, `CLIPBOARD_RESTORE_MS = 750` elapses without
  holding the delivery queue. Failed, cached or missing earlier backends do not
  discard the pending snapshot. The driver rechecks opaque
  revision/write ownership immediately before replacing text on its UI thread,
  with no asynchronous read/check/write gap. Any newer copy, even identical
  bytes, invalidates ownership. Copy, exhausted copy-only fallback, self-test,
  a later delivery, disabling the preference, graph invalidation and shutdown skip
  restore. Prior text stays only in memory until restore/cancel, then is
  released; it is never logged or persisted. OS APIs cannot atomically exclude
  a simultaneous external copy; the guard covers observed revision/owner
  changes, and restore stays unavailable where that limitation is unacceptable.
  Version-1 settings uses `delivery.clipboardRestore`: `off` (the
  missing-field default) or `previousText`. Settings says "previous text
  only; 750 ms delay may be too short for some apps". This preference does
  not authorize reads merely to display Settings or change the preference.
- **Secure input.** macOS blocks synthetic keystrokes into password fields
  without reporting an error. The copy-only notification is the user's cue.

### 6.4 Permissions and setup

A Setup screen opens on first run and from Settings. Each mechanism gets one
row with a status dot, the detected backend, and a fix:

| Row | Fix offered |
|---|---|
| macOS Accessibility | An explainer, then a button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, then `AXIsProcessTrustedWithOptions(prompt)`. The app detects a grant revoked by an update and explains it (Vervellum). |
| GNOME/KDE portal | "Allow" starts a RemoteDesktop session and stores the restore token. |
| ydotool | A copyable udev rule (`KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"`), the group command, and `systemctl --user enable --now ydotoold`. |
| Hotkey | The mechanism in use, and the manual command when needed. **"Press your shortcut now"**: the row turns green only when the hotkey actually fires. |
| KDE | "Set the key in System Settings → Shortcuts → Monkey's Paw". |

### 6.5 Self-test

`exit 0 ≠ pasted`. "Test paste" in Setup:

1. Opens a small test window with a focused text field.
2. Runs `DeliveryService` against that field with a known string.
3. Reads the field back.
4. Reports which backend worked and which failed.

On Linux, `gapplication action ch.lkmc.monkeyspaw selftest` (and
`monkeyspaw --selftest`) prints the same report plus session detection, for
bug reports.
