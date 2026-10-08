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

- **GNOME keybinding.** The custom keybinding row is named
  `Monkey's Paw: <action>`, so re-syncs update it in place. Installation
  runs at first launch, never from the package's `postinst` (that would write
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
  (`ConfigureShortcuts`, v2).
- **Linux actions.**
  - `toggle` opens or closes the picker.
  - `repeat` re-delivers the last delivered prompt with the exact values
    used. Every delivery records the prompt id and value set in
    `usage.json`. With no prior delivery, repeat shows "Nothing to repeat".
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
  - Each `Start` returns a new single-use restore token. The app stores it
    in `<data>/portal.json` every time; it lives there, not in the secret
    store, because it rotates.
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
  on `Activated`.
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
    terminals.
  - On X11 the target's class is read at `arm()` with
    `xdotool getactivewindow getwindowclassname` and matched against a
    terminal list, and the terminal chord is chosen automatically.
- **Typing is never automatic.** Typing multi-line text sends Enter: it
  submits chat boxes and runs shell commands. An opt-in typing mode is
  deferred past v1.
- **Clipboard restore.** Off by default: the result stays on the clipboard,
  which is predictable and doubles as the fallback. When enabled, the
  previous text clipboard is restored `CLIPBOARD_RESTORE_MS = 750` after the
  chord. The delay is a guess, and the setting says so.
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
