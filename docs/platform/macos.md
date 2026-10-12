# macOS delivery acceptance

Owner-run checks for M1a (§6 and §15). These checks have not been run on the
Linux implementation host. Record results against the exact build tested.

M2h replaces the canned delivery panel with the picker and fill form. The M1a
matrix below records the original delivery gate; use the picker checklist at
the end for the current app. All M2h owner checks are **NOT RUN**.

- Commit:
- macOS version:
- Mac model / processor:
- Keyboard layout:
- App signing identity (Developer ID, ad-hoc, or unsigned):
- Date / tester:
- `macos-app` CI run and hosted-test result:

## Accessibility and Setup

1. Launch Monkey's Paw. Setup opens on the first launch; reopen it from the
   menu-bar item → **Setup…**.
2. Read the Accessibility row, then click **Fix…**. The first click requests
   the system Accessibility prompt. Use its Settings button, or click
   **Fix…** again to open System Settings → Privacy & Security → Accessibility.
3. Enable Monkey's Paw. If it is missing, add the exact app build with **+**.
   Return to Setup and click **Refresh**. The row should say **Ready**.
   An updated or differently signed build may need to be added or granted again.
4. Click **Press your shortcut now**, then press and release **Control+Option+P**.
   The Hotkey row should turn green only after the actual shortcut fires.
   Cancel the panel with Escape and reopen Setup to inspect the row.
5. Click **Run self-test**. For each backend, the test opens an empty field,
   pastes the canned text and reads it back. Record both report lines below.
6. The AppleScript test may request Automation permission for System Events.
   Allow it. An unanswered prompt times out after two seconds; grant the
   permission and rerun the self-test. You can inspect the grant under System
   Settings → Privacy & Security → Automation → Monkey's Paw → System Events.
   The self-test resets failures cached earlier in this app session.

- [ ] Setup opens on first launch and from the status menu.
- [ ] Accessibility **Fix…** launches the prompt or Settings; **Ready** reflects the grant.
- [ ] Hotkey registration shows Carbon and the correct shortcut.
- [ ] Shortcut verification turns green only after a real key release.
- [ ] Self-test receives the exact canned text through at least one backend.
- [ ] Self-test reports both CGEvent and AppleScript results, including failures.

| Backend | Report | Permission / failure details |
|---|---|---|
| CGEvent | Not run | |
| AppleScript | Not run | |

Expected text (without the code fence):

```text
Monkey's Paw test: if you can read this, delivery works.
```

## Delivery matrix

Focus an editable field in the target app, press and release
**Control+Option+P**, then press **Return** or click **Paste**. Check that the
panel hides, the original field regains focus and the exact text appears once.
For Terminal, inspect the text at an empty shell prompt and clear it with
**Control+C** after checking it. Paste sends no Return and executes no command.

Repeat with the target app in a full-screen Space. The panel must appear on
that Space at the cursor without switching to another Space. Delivery must
return to the same target field.

| Target | Normal window | Full-screen Space | Version / field / details |
|---|---|---|---|
| Safari | Not run | Not run | |
| Chrome | Not run | Not run | |
| Terminal | Not run | Not run | |

- [ ] Safari receives the canned text in both window modes.
- [ ] Chrome receives the canned text in both window modes.
- [ ] Terminal receives the canned text in both window modes, without submitting it.
- [ ] Repeated summon → paste cycles work; the clipboard keeps the result.
- [ ] Holding the shortcut does not repeatedly toggle; quick releases are debounced.
- [ ] Escape or a second shortcut release dismisses and returns focus to the original app.
- [ ] Clicking a different app hides the panel after about 300 ms and keeps that app focused.
- [ ] Clicking the already-open Setup window keeps Setup focused after the panel hides.
- [ ] A dismissal queued during self-test does not refocus the old external target.
- [ ] If the captured app quits, dismissal leaves no invisible app swallowing keystrokes.
- [ ] Option+Return and **Copy** copy the text and return focus without pasting.
- [ ] Without Accessibility, delivery still returns focus and keeps the text on the clipboard.
      With notifications allowed, fallback says **Copied. Press Cmd+V**.
- [ ] After granting or regranting permission, rerunning the self-test enables a new attempt.
- [ ] Setup and the self-test remain usable while the picker is hidden.
- [ ] VoiceOver identifies the panel buttons and the self-test field.

## Implementation notes and remaining gates

- The brief asked to leave the Xcode project unchanged apart from framework
  linkage. The System Events fallback needs the Apple Events entitlement and
  usage description under Hardened Runtime. Only those Debug/Release settings
  were added; synchronized sources need no project entries or extra frameworks.
- The named Invoque paste precedent contains the CGEvent path, but no AppleScript
  fallback. The fallback uses a fixed `/usr/bin/osascript` argument array, as in
  Invoque's system-action runner, with a kill deadline and no logged tool output.
- Accessibility Settings uses Invoque's current Privacy & Security URL; §6.4
  lists the older compatible preference-pane URL. The first Fix requests the
  system prompt; subsequent fixes open Settings, following that precedent.
- Core changes are limited to named driver timings and window sizes in `Limits`.
  The full Core/Linux tests still cover delivery ordering and fallback.
- Linux syntax and Xcode-object checks cannot establish AppKit API compatibility.
  `macos-app` CI must compile and run the hosted driver tests. Real focus, TCC,
  notification permission and full-screen behavior require the owner checks above.
- Devin's first review identified blur refocusing our own Setup/self-test windows
  and failure to relinquish unused activation. Hosted regression tests were added
  before the fixes, but their failing/passing runs require macOS and remain for CI.

## M2h picker and fill form: NOT RUN

The implementation host cannot compile the macOS app. Record the `macos-app`
CI run, exact commit and external-save timing attachment from
`MacPickerViewTests` before running this hardware matrix. CI success does not
establish real paste, Spaces, TCC or VoiceOver behavior.

- Commit / `macos-app` CI run:
- External-save-to-picker elapsed seconds from hosted test:
- macOS / hardware / signing identity / date / tester:

Create a fieldless prompt and a prompt with text, multiline and choice fields
under `~/Documents/MonkeysPaw/`. Give the fields descriptions, choice labels
with distinct values, and defaults. Grant Accessibility through unchanged
Setup and run the paste self-test. Place the caret in each target below, summon
with Control+Option+P, search, pick with Return, fill if needed and deliver.
For Terminal, check the text without submitting it, then clear with Control+C.

| Target | Normal window | Full-screen Space | Field / exact text / details |
|---|---|---|---|
| TextEdit | NOT RUN | NOT RUN | |
| Safari | NOT RUN | NOT RUN | |
| Terminal | NOT RUN | NOT RUN | |

- [ ] NOT RUN: the remembered target's app name appears in the footer.
- [ ] NOT RUN: search, favourites, folder/tags, arrow selection and preview work.
- [ ] NOT RUN: selecting a result or tabbing into the list, then typing, continues search.
- [ ] NOT RUN: repeated summon cycles focus search and accept typing immediately.
- [ ] NOT RUN: the key panel toggles off; a visible non-key panel raises on toggle.
- [ ] NOT RUN: the panel opens over the current full-screen Space at the cursor.
- [ ] NOT RUN: each field kind updates live preview; descriptions appear below controls.
- [ ] NOT RUN: pointer focus and Tab/Shift+Tab wrap in body first-use order.
- [ ] NOT RUN: Return in multiline inserts a newline; Cmd+Return pastes and Option+Return copies.
- [ ] NOT RUN: picker Option+Return carries copy-only into fill's Return/Deliver action.
- [ ] NOT RUN: required/invalid choice values block delivery with an actionable message.
- [ ] NOT RUN: Escape from fill keeps the draft and returns to picker; another Escape closes.
- [ ] NOT RUN: Cmd+W/Cancel/toggle-off close fill and keep its draft for reopening.
- [ ] NOT RUN: clicking another app hides after about 300 ms, keeps its focus and retains the draft.
- [ ] NOT RUN: Cmd+Return in picker opens the selected prompt in its default editor; Cmd+L opens the folder.
- [ ] NOT RUN: a no-match title creates a safe free filename while retaining the exact title; the new file opens for editing.
- [ ] NOT RUN: the disabled assistant action displays its Settings hint.
- [ ] NOT RUN: an external editor save reaches the picker within one second; record elapsed time.
- [ ] NOT RUN: moving/removing the library shows the unavailable banner, retains cached prompts and requires restart after restoration.
- [ ] NOT RUN: delivery hides once and pastes once in the same target; fallback keeps the clipboard and gives Cmd+V guidance.
- [ ] NOT RUN: VoiceOver identifies search, results, field kinds/descriptions, preview and actions inside the panel.

## M2 macOS artifacts and installation: NOT RUN

The Linux implementation host cannot build or run these artifacts. Only the
`macos-artifacts` CI job on `macos-26` with Xcode 26.0 proves the universal
build, signatures, bundle versions, image integrity/content, zip equivalence
and five-second launches of both packaged copies. CI does not exercise a
quarantined download, Gatekeeper approval or installation on your Mac.

- Commit / `macos-artifacts` CI run:
- Artifact version / build number / SHA-256:
- macOS / hardware / signing identity / date / tester:
- Gatekeeper message and approval steps:

1. Download `MonkeysPaw-<version>.dmg` and `.zip` from the CI artifacts or
   release. Record the exact build and hashes; check for the download's
   quarantine attribute with `xattr -p com.apple.quarantine <path>`.
2. Open the dmg in Finder. Confirm it contains `MonkeysPaw.app` and an
   **Applications** link. Drag the app to Applications, eject the image,
   then open `/Applications/MonkeysPaw.app`.
3. Ad-hoc builds have no Developer ID certificate and are not notarized.
   A quarantined download can be blocked by Gatekeeper. Record the exact
   message. If you trust this build, use System Settings → Privacy &
   Security → **Open Anyway** when offered, then confirm **Open**. Do not
   remove quarantine for this check: record the real approval path, using
   [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/26/mac/26).
4. Confirm the menu-bar item appears and no Dock icon appears, then open
   Setup from the menu. Confirm the app works after the dmg has been ejected.
   Quit and relaunch, then run the picker/delivery matrix above from this copy.
5. Quit the installed app, extract the zip separately, launch that copy
   and record its Gatekeeper behavior and version. On an Intel Mac, also
   record whether the `x86_64` slice launches; CI runs the native runner
   architecture only.

- [ ] NOT RUN: the downloaded dmg opens and provides a working Applications link.
- [ ] NOT RUN: the copied app launches after the image is ejected and after restart.
- [ ] NOT RUN: Gatekeeper behavior and any approval steps are recorded for ad-hoc signing.
- [ ] NOT RUN: the installed menu-bar app has the expected version and no Dock icon.
- [ ] NOT RUN: the zip copy launches with the same version and behavior.
- [ ] NOT RUN: installed-app Setup, picker and delivery checks above pass.
- [ ] Optional, NOT RUN: an Intel Mac launches the universal app's `x86_64` slice.
