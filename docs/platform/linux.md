# Linux delivery checks (M1b)

M1b adds local X11 and wlroots delivery with one canned prompt. These checks
are owner-run and have **not** been completed on the implementation host.
Record your desktop/compositor, tool versions, date, and self-test report
when you run them. Do not put clipboard text or tool error bodies in logs.

## X11

- [ ] Launch `monkeyspaw` normally on first run. Setup opens. It opens again
  if the `setup-shown` marker cannot be saved under the XDG config directory.
  Later launcher activations show the picker; Setup stays available there.
  Service launches and CLI diagnostics do not open first-run Setup.
- [ ] Start `monkeyspaw --gapplication-service`. It remains resident with no
  visible window. Run `gapplication action ch.lkmc.monkeyspaw toggle` twice:
  the picker opens and closes. Close it natively and toggle again.
- [ ] Bind `gapplication action ch.lkmc.monkeyspaw toggle` in your desktop's
  shortcut settings to Ctrl+Alt+P. In Setup, select "Press your shortcut
  now" and use the binding. The hotkey row becomes ready only after it fires.
- [ ] On GNOME Xorg, the owned custom keybinding is named
  `Monkey's Paw: toggle`. Existing bindings stay present. Change its keys
  in GNOME Settings and restart the app: your changed binding is preserved.
- [ ] From a browser or text editor, open the picker and press Return.
  The canned prompt reaches the previous field. Successful paste is silent.
- [ ] From a terminal, confirm with Ctrl+Shift+Return. The terminal receives
  the canned prompt without submitting it. Return uses Ctrl+V; automatic
  terminal-class selection is reserved for M7.
- [ ] Esc cancels without delivery. Clicking another window hides the picker
  after 300 ms and leaves focus in the window you selected.
- [ ] Run `monkeyspaw --selftest` from a terminal, both with and without a
  resident instance. JSON appears in the invoking terminal. The report must
  show `xdotool` as `pasted`, based on field readback. A standalone test exits.
- [ ] Run `gapplication action ch.lkmc.monkeyspaw selftest`. Its report is
  written to the resident process's stdout. Setup's "Test paste" shows the
  same backend results without treating exit zero as proof of receipt.
- [ ] Without xdotool/ydotool, delivery still copies the text and shows the
  appropriate Ctrl+V or Ctrl+Shift+V notification. The target keeps focus;
  the notification has no buttons or configured default action.

GNOME's paste ladder still contains the deferred portal before ydotool, even
on Xorg, as §6.1 specifies. Portal attempts report `backendUnavailable` in
M1b. An ordinary X11 session prefers xdotool. Missing or failed backends are
cached until "Test paste" resets and rechecks them.

## wlroots with ydotool

- [ ] Install ydotool and configure ydotoold for `/dev/uinput`. Setup offers
  the udev rule, group command, service command, and upstream documentation.
  Adapt the service to your distribution and log out/in after group changes.
- [ ] Verify the daemon socket is reachable and readable/writable. Modern
  ydotool receives an explicit `YDOTOOL_SOCKET`: your override first, an
  existing `$XDG_RUNTIME_DIR/.ydotool_socket` second, then
  `/tmp/.ydotool_socket`. Version 0.1.8 uses its fixed `/tmp` socket.
- [ ] Bind the manual `gapplication action ch.lkmc.monkeyspaw toggle`
  command in your compositor. KDE also uses this manual mechanism in M1b.
- [ ] Run the CLI and Setup self-tests. The `ydotool` result must be `pasted`.
  Record `sentButNotReceived` separately: a successful tool exit does not
  establish receipt, and the self-test caches that failure.
- [ ] Test Return into a browser and Ctrl+Shift+Return into a terminal.
  Clipboard ownership persists while the picker is hidden. There is no
  automatic XWayland fallback or active-window capture on Wayland.
- [ ] Stop ydotoold or deny socket access, restart the app, and deliver.
  Copy-only guidance appears without a hang or focus theft. Restore access
  and use "Test paste" to reset cached failures.

## Decisions and validation boundary

- Keep the Linux job in `.github/workflows/ci.yml`, following M0b, rather
  than adding the plan's separate `linux.yml`.
- Defer an unused GDBus portal helper to M1c. GTK's notification payload is
  covered by a mock notification daemon on a private bus. No portal or KDE
  driver is implemented here; the portal Setup row says "Added in M1c".
- Core owns the 140 ms settle. Linux never explicitly activates a target
  or reports confirmed focus. X11 capture excludes our own WM_CLASS;
  Wayland has no target identity and returns nil.
- Each subprocess has a two-second budget, a 64 KiB output cap, discarded
  stderr, and typed failures. The exception is dialect discovery: legacy
  ydotool's help exits one on stderr, which is drained together with stdout
  and never logged. X11 capture uses a shorter 250 ms budget.
- The CI smoke uses Openbox because Xvfb alone has no window manager to
  refocus after a hide. It exercises the real Return handler with the
  terminal chord, pastes through xdotool into xterm running raw-input `cat`,
  compares the exact bytes without logging them, and verifies both CLI and
  D-Bus self-test JSON. It sends no Enter to the target terminal.
- CI gates GTK lifecycle, notification mock-bus, and X11 smoke checks.
  Real compositor behavior, full-screen windows, browser fields, and
  ydotool/uinput remain owner-run. GNOME portal and KDE checklists arrive
  in M1c and M1d respectively.
