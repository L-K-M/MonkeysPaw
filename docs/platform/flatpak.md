# Flatpak owner procedure

Status: **NOT RUN** on both GNOME and KDE hosts. Record each run in the
[M7 ledger](m7-acceptance.md), with result and sanitized evidence for every
row below. The installed CI smoke proves package exports and local invite
staging under a test session; it does not prove real portals, browser
association, consent persistence or focus. Do not replace owner results with
that smoke or with a tool exit code.

Use the [bundle installation instructions](../../README.linux.md#flatpak).
Record exact main SHA, bundle/version/hash, host Flatpak/runtime versions,
distro, compositor/session, architecture/hardware/keyboard, portal backend
and interface capabilities, signing information, overrides, target versions,
date/tester and sanitized evidence. Repeat all rows on a GNOME host and KDE
host. Use one active install route; quit the native app and check activation
reaches the sandbox, since both share `ch.lkmc.monkeyspaw`.

## Install, permissions and state

1. Verify the downloaded bundle checksum and install it for your user. Confirm
   GNOME Platform 50 is available, `flatpak run ch.lkmc.monkeyspaw --version`
   matches the artifact and the app launches. Upgrade with a newly verified
   bundle using `flatpak install --user ./<bundle>`; confirm preferences and
   the library survive. Do not assume `flatpak update` provides app releases.
2. Inspect `flatpak info --show-permissions ch.lkmc.monkeyspaw` and user
   overrides. Match [the manifest](../../flatpak/ch.lkmc.monkeyspaw.yml):
   IPC/network, Wayland/fallback-X11, whole-home read/write, Secret Service
   and optional tray watcher only. Check absence of host dconf, broad buses,
   KGlobalAccel, host-spawn, uinput and foreign-name ownership grants.
3. Confirm config/data are separate sandbox roots under
   `~/.var/app/ch.lkmc.monkeyspaw/{config,data}/monkeyspaw`, with no automatic
   native-state or file-secret import. Exercise default and chosen home
   libraries, live refresh and restart. Select an outside-home folder,
   document-portal mount and home symlink escaping home, then cancel another
   choice: each refusal/cancellation preserves the active graph and choice.
4. Through Assistant settings and disposable credentials, check real Secret
   Service Save/read/Clear. Lock/deny the service and confirm typed errors
   without a newly created plaintext fallback. Inspect only safe file/tier
   metadata in shared evidence. Runtime `secret-tool` presence alone is not
   proof. Check the optional tray app subname, watcher restart and clean exit;
   with no watcher the app remains usable.

| Check | GNOME result | GNOME evidence | KDE result | KDE evidence |
|---|---|---|---|---|
| Verified install/version and explicit bundle upgrade | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Exact permissions, overrides and no host dconf writes | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Separate state, home library and refused/cancelled choices | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Real Secret Service and no plaintext downgrade on denial | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Optional tray lifecycle and app-owned subname | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

## Actions and invite staging

1. Inspect the installed host desktop/service/icon exports, action names
   `toggle`, `repeat`, `selftest`, `settings`, `library`, app ID and
   `x-scheme-handler/monkeyspaw` registration. Cold and resident host
   `gapplication action ch.lkmc.monkeyspaw toggle` opens/closes once;
   `gapplication action ch.lkmc.monkeyspaw repeat` shows Nothing to repeat
   without a usable record. After a real delivery check repeat into a different
   target. Inspect the activated process to exclude a competing native app.
2. Inspect your current association with
   `xdg-mime query default x-scheme-handler/monkeyspaw`. If you choose to
   associate the app, do so explicitly through your desktop. The package
   must not change your default automatically. Keep the previous association
   for restoration after testing.
3. Use a disposable, encoded invite link from a controlled test server. Open
   it through a real browser/desktop association, cold and resident. Inspect
   destination and enabled Accept in Account; cancel without accepting and
   confirm no redemption request reached the test server. Do not put the URI
   in a shell command, process dump, screenshot or collected log. Separately
   exercise launcher fallback in a controlled harness that never prints argv.
   It inherently exposes the link in argv and possibly browser history (E28).
4. Confirm denied/cancelled browser or OpenURI interaction stays recoverable.
   Restore any association changed for the test. URI staging alone does not
   prove invite redemption or the M6 sync matrix.

| Check | GNOME result | GNOME evidence | KDE result | KDE evidence |
|---|---|---|---|---|
| Exported identity, MIME, icons and cold/resident actions | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Browser association and destination review before Accept | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| No launch redemption, preserved encoding and launcher fallback | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

## Portals, clipboard and settings

1. Probe actual GlobalShortcuts and RemoteDesktop interfaces/device types.
   Explicitly configure both actions; Repeat has no guessed default key.
   Verify real activations, persistence across restart, cancellation,
   revocation, session loss and recovery. Manual/cold actions do not verify
   portal registration. Remove duplicate host bindings yourself; there is
   no sandbox host-dconf installer or direct KGlobalAccel route.
2. Run Setup/Test paste and the same installed build's self-test, then exact
   Unicode/multiline readback in a browser/chat field and terminal. Record
   portal → Copy behavior, keyboard consent, failed/denied backend caching,
   default/explicit terminal chord and focus after hide, including full-screen
   and multiple monitors. No xdotool/ydotool, X11 terminal detection, host
   autostart or Return-key injection may appear.
3. Repeat the [Linux clipboard/Repeat procedure](linux.md#m7-current-desktop-procedures)
   with text-only restore off/on, a slow target, competing identical/different
   copies, cancellation, Forget, restart and graph retirement. Lack of reliable
   ownership leaves delivered text. Record paste-privacy prompts and the OS
   simultaneous-copy limitation; never record previous clipboard contents.
4. Exercise Delivery, both Shortcuts and General settings through close/reopen
   and restart; keep Assistant/Account available. Check visible failures,
   keyboard focus and Orca. With automatic updates off confirm zero checker
   requests; Check Now makes only the disclosed metadata GET. View release
   uses the real URI portal/browser and does not install an update.

| Check | GNOME result | GNOME evidence | KDE result | KDE evidence |
|---|---|---|---|---|
| Two-action portal consent, persistence and recovery | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Self-test plus browser/terminal readback and denial fallback | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Repeat/Forget, clipboard off/on and competing copies | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Settings persistence/failures, Orca and update/browser behavior | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
