# Linux picker and delivery checks

## Onboarding and library recovery (M2, NOT RUN)

Run these with isolated XDG config/data/documents directories on X11 and
GNOME/KDE Wayland. Record the commit, date, desktop/compositor, GTK and
portal versions. Private-bus/Xvfb tests cover the composition and controls;
they do not complete these owner checks.

| Check | Expected result | Status |
|---|---|---|
| Fresh install | Launcher opens Setup first. Closing Setup opens the library folder step; accept the displayed default or choose an existing readable folder. | NOT RUN |
| Legacy install | With only the old `setup-shown` marker, launcher opens the folder step without repeating Setup. | NOT RUN |
| Starter prompts | An empty accepted library offers Add Starter Prompts and Skip Starter Prompts. Adding shows the copied/skipped counts and makes the prompts available in the picker; restart never copies them again. | NOT RUN |
| Skip starter prompts and non-empty library | Skipping records the offer without copying. A library containing an eligible prompt, including malformed Markdown, skips the offer. | NOT RUN |
| Folder chooser and cancellation | Invalid choices show a typed message and retain the step. Closing or switching between Settings and onboarding cancels that window's chooser; a stale result cannot switch the library. | NOT RUN |
| Startup unavailable notification and recovery | A missing or unreadable saved folder produces one path-free notification with no focus action and reopens the folder step. Closing and reopening retains recovery; choosing a readable folder or Use Default restores the library. | NOT RUN |
| Runtime folder loss | Cached prompts remain read-only. No startup notification or new recovery step appears; an already-open onboarding window shows restart guidance. Restart, or a successful Settings folder switch, restores library health. | NOT RUN |
| Read-only settings | Future-version or corrupt settings show the Settings error and suppress Setup/onboarding; the settings file remains unchanged. | NOT RUN |
| Tray status row (I14b) | No Linux tray exists in this slice. I14b must attach the shared `LibraryStatusModel.menuLabel` and verify unavailable/recovered labels on the real desktop. | NOT RUN |

Composition retains one onboarding model and one library status model for
the process. Folder checks and seeding resolve the current library graph;
every successful or degraded replacement reports its health. Startup
health includes watcher startup and index rebuild. Runtime loss is latched
until a new graph replaces it or the app restarts. Library status UI in
Settings and the tray is left to I14b to avoid expanding the Settings slice.

## Settings (M2, NOT RUN)

Run these on X11 and GNOME/KDE Wayland. Record the tested commit, date,
desktop/compositor, GTK and portal versions. Xvfb and private-bus tests do
not complete these owner checks.

| Check | Expected result | Status |
|---|---|---|
| Picker Settings button and Ctrl+, | The picker dismisses without delivery; Settings opens or raises one reusable window. Close and reopen it. | NOT RUN |
| Launcher Settings desktop action, cold and resident | The action opens the same General and Shortcuts window; the picker stays usable after closing it. | NOT RUN |
| Choose folder | Choosing an existing readable folder updates the active path and picker; relaunch uses the saved folder. | NOT RUN |
| Cancel folder chooser | The active folder and settings remain unchanged; Choose becomes usable again. | NOT RUN |
| Invalid folder | A missing, unreadable or symlinked chosen folder shows an error and retains the previous library. | NOT RUN |
| Use Default | The active folder returns to the XDG documents default and survives relaunch. | NOT RUN |
| Open Folder | The file manager opens the active library folder, including after choosing another folder or Use Default. | NOT RUN |
| Forget all values | Cancel keeps remembered values and session drafts. Confirm clears both while the picker is closed and after switching libraries with Settings open. A failed write shows a sanitized error and keeps values; an unreadable regular values file can be reset once its directory is writable. | NOT RUN |
| Shortcuts Open Setup | Open Setup opens or raises the existing Setup window; closing and reopening it retains the live shortcut state. | NOT RUN |
| GNOME portal Shortcuts tab | Binding, registration and verification match Setup; portal configuration/Setup guidance follows the advertised interface version. Opening Settings never verifies the shortcut. | NOT RUN |
| KDE Shortcuts tab | Native and portal binding, registration, guidance and verification match Setup and update after system changes or mechanism handoff. Repeat remains inactive and unbound. | NOT RUN |

## Picker and fill (M2f, NOT RUN)

Run these on X11 and on GNOME/KDE Wayland. Record the desktop/compositor,
tool versions and date. These owner checks are not completed by Xvfb tests.

| Check | Expected result | Status |
|---|---|---|
| Forget values in picker and fill | The action appears only for a selected prompt or open form. It clears that prompt's remembered values and draft, keeps other prompts' values, and resets an open form to defaults without delivery. Failure keeps values and shows a sanitized error. The action is disabled during delivery. | NOT RUN |

- [ ] Add a Markdown prompt under the XDG documents directory's `MonkeysPaw`
  folder (default `~/Documents/MonkeysPaw`). From a browser/editor field,
  press the hotkey, type a live search, select with arrows or the pointer and
  press Return. The rendered prompt reaches the previous field.
- [ ] Save an external edit while the picker is open. The result and preview
  refresh within one second without losing the search or selected prompt.
- [ ] From a terminal, use Ctrl+Shift+Return. For a fielded prompt, the form
  retains terminal paste for its Deliver button and single-line Return.
  Confirm text arrives without submitting it; Ctrl+Return explicitly chooses
  standard paste and Alt+Return copies only.
- [ ] Fill text, multiline and choice fields, including label/value choices
  and descriptions. Check live preview, mouse focus, Tab/Shift+Tab order and
  remembered values after delivery. Return inside multiline adds a newline;
  Ctrl+Return, Ctrl+Shift+Return and Alt+Return deliver from that field.
- [ ] Escape from fill returns to the picker with typed values retained.
  A focused panel toggles off and native close dismisses fill; reopening restores
  its draft. Toggling an unfocused panel raises it and returns to the picker.
- [ ] Click another window while filling. The panel hides after 300 ms,
  leaves focus in that window and restores typed values on the next form open.
- [ ] Search for no matches. Open the library folder, create a prompt and
  verify its safe filename opens in the default editor. The assistant action
  is disabled and shows the Settings hint. Ctrl+Return edits a selected file;
  Ctrl+L opens the folder and dismisses the picker.
- [ ] Make the library unavailable at startup, then remove it while running.
  The app stays usable and shows the banner; cached prompts remain available
  after removal. Restore the folder and restart to resume watching.

## Delivery plumbing (M1b)

M1b adds local X11 and wlroots delivery with one canned prompt. These checks
are owner-run and have **not** been completed on the implementation host.
Record your desktop/compositor, tool versions, date, and self-test report
when you run them. Do not put clipboard text or tool error bodies in logs.

X11 dependencies are `xdotool` and `xprop` (`x11-utils` on Debian/Ubuntu).
The display smoke also needs Xvfb, xauth, D-Bus, GLib's command-line tools,
xterm, Openbox, and Python 3.

## X11

- [ ] Launch `monkeyspaw` normally on first run. Setup opens, then closing it
  continues through the folder and eligible seed steps above. Later launcher
  activations resume pending steps or show the picker when complete; Setup
  stays available there. Ordinary service launches and CLI diagnostics do
  not open first-run Setup. Startup library failure opens recovery.
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
- [ ] Tab to the Setup button and press Return. Setup opens without delivery.
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
  and never logged. X11 capture shares one shorter 250 ms deadline between
  `xdotool getactivewindow` and `xprop -id <id> WM_CLASS`.
- The CI smoke uses Openbox because Xvfb alone has no window manager to
  refocus after a hide. It exercises the real Return handler with the
  terminal chord, pastes through xdotool into xterm running raw-input `cat`,
  compares the exact bytes without logging them, and verifies both CLI and
  D-Bus self-test JSON. Focused XCTest assertions check that capture returns
  the xterm's class and excludes the picker using real xdotool and xprop.
  Build tests with `swift test` first, then run the smoke from the repository
  root. Each capture assertion runs through `swift test --skip-build --filter`
  with its exact test name and a 20-second timeout. The smoke sends no Enter
  to the target terminal. The whole smoke keeps CI's 60-second timeout:

  ```sh
  timeout 60s dbus-run-session -- xvfb-run -a \
    bash scripts/linux-delivery-smoke.sh .build/debug/monkeyspaw
  ```

  The optional second script argument selects the Swift runner used to build
  the tests. On the implementation host, build with
  `/home/paseo/.local/bin/swift64` and append that path to the smoke command.
  Omitting it uses `swift`, as CI does.
- The standalone diagnostic skips GNOME shortcut installation. CI checks
  this with a fake gsettings after the resident service exits.
- CI gates GTK lifecycle, notification mock-bus, and X11 smoke checks.
  Real compositor behavior, full-screen windows, browser fields, and
  ydotool/uinput remain owner-run. GNOME portal and KDE checklists arrive
  in M1c and M1d respectively.

The first Devin review found only minor issues. The timeout test confirms
Foundation reaps the killed child without a blocking wait. Executable
directories on PATH are skipped, and writer handles are explicitly closed
once. A busy legacy stream daemon can currently be reported as unavailable;
rerun "Test paste" to recheck after it recovers. The review suggestion to
drop socket read checks was rejected because M1b requires unreadable sockets
to report `permissionDenied`. Pending nonblocking connects are not treated
as proof of a reachable daemon.
