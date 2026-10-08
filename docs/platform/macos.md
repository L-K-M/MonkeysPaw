# macOS delivery acceptance

Owner-run checks for M1a (§6 and §15). These checks have not been run on the
Linux implementation host. Record results against the exact build tested.

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
