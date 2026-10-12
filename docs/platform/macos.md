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
- [ ] NOT RUN: Cmd+Return in picker opens the selected prompt in Library's Edit tab; Cmd+L opens Library.
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

1. Download `MonkeysPaw-<version>.dmg`, `.zip` and `.sha256` from the CI
   artifacts or release into the same directory. In that directory, run
   `shasum -a 256 -c MonkeysPaw-<version>.sha256`; both files must report
   **OK** before installation. Record the exact build and hashes; check for
   the download's quarantine attribute with
   `xattr -p com.apple.quarantine <path>`.
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

- [ ] NOT RUN: both downloaded archives match the `.sha256` manifest.
- [ ] NOT RUN: the downloaded dmg opens and provides a working Applications link.
- [ ] NOT RUN: the copied app launches after the image is ejected and after restart.
- [ ] NOT RUN: Gatekeeper behavior and any approval steps are recorded for ad-hoc signing.
- [ ] NOT RUN: the installed menu-bar app has the expected version and no Dock icon.
- [ ] NOT RUN: the zip copy launches with the same version and behavior.
- [ ] NOT RUN: installed-app Setup, picker and delivery checks above pass.
- [ ] Optional, NOT RUN: an Intel Mac launches the universal app's `x86_64` slice.

## M2 Settings, General and Shortcuts: NOT RUN

The Linux implementation host cannot compile or run this window. Record the
exact build and hosted-test results before these owner checks. The shortcut
change applies to this app session; a failed native registration removes the
previous shortcut and reports Failed, so record a working shortcut again.

- Commit / `macos-app` CI run and hosted-test result:
- macOS / hardware / keyboard layout / signing identity / date / tester:

| Check | Result | Details |
|---|---|---|
| Open Settings from the status menu; open twice and close/reopen the same window | NOT RUN | |
| Press ⌘, while Settings is key, then while Setup is key; Settings opens from both | NOT RUN | |
| Choose another readable library folder; its active path and picker contents update | NOT RUN | |
| Cancel Choose; the folder stays unchanged; close Settings during a chooser and reopen | NOT RUN | |
| Choose an invalid, unreadable or symbolic-link folder; read the error and confirm the old folder remains active | NOT RUN | |
| Use Default restores your default library; retry after a settings save error | NOT RUN | |
| Show in Finder reveals the active folder after choosing it and after Use Default | NOT RUN | |
| Open Setup from Shortcuts; the existing Setup window and live registration are reused | NOT RUN | |
| Record a modified physical key under a non-US layout; Escape cancels capture without closing Settings | NOT RUN | |
| Rebind Toggle picker, press Press your shortcut now and release the shortcut; verification changes only after it fires | NOT RUN | |
| Try a conflicting shortcut; Failed and the backend detail appear; record a working key to recover | NOT RUN | |
| Close Settings while Setup is key; activation policy returns to accessory and Setup remains usable | NOT RUN | |
| Open Settings with the picker armed, then close; no old paste target is reactivated and a fresh summon still works | NOT RUN | |
| VoiceOver identifies both tabs, folder path, recorder and actions; keyboard focus stays visible | NOT RUN | |

## M2 Forget values controls: NOT RUN

The Linux implementation host cannot compile or run these macOS controls.
Record the exact build and `MacForgetControlsTests` hosted results before
running these owner checks. Use two prompts with remembered fields, defaults
and session drafts; include text, multiline, choice and `remember: false`
fields. Forgetting must leave the clipboard and usage history unchanged.

- Commit / `macos-app` CI run and hosted-test result:
- macOS / hardware / signing identity / date / tester:

| Check | Result | Details |
|---|---|---|
| Picker action row: Forget values clears only the selected prompt's remembered fields and draft; another prompt keeps both | NOT RUN | |
| Fill action row: Forget values keeps the form open and resets all native fields and preview to defaults without delivery | NOT RUN | |
| Search with no selection hides Forget values; delivery disables it and an attempted forget reports the wait message | NOT RUN | |
| A corrupt or unreadable values.json gives a path-free failure for Forget values and retains the fields and draft; retry after repair succeeds | NOT RUN | |
| Settings → General: Forget all values… opens a native confirmation sheet; Cancel and Escape keep values and drafts | NOT RUN | |
| Confirm Forget all with the picker closed; values.json becomes empty private version-1 state and both prompts reopen with defaults | NOT RUN | |
| Keep Settings open across a library switch, then confirm Forget all; the current library's picker loses its drafts | NOT RUN | |
| Block app-data writes and confirm Forget all; the error preserves state; restore writes and retry, including with unreadable or corrupt values.json | NOT RUN | |
| Close Settings during confirmation and reopen; no pending confirmation or late response clears values | NOT RUN | |
| VoiceOver identifies both Forget actions, the sheet's destructive action, Cancel and outcome messages; existing picker shortcuts and visible focus still work | NOT RUN | |

## M2 onboarding and library recovery: NOT RUN

The Linux implementation host cannot compile or run these macOS windows.
Record the exact commit and `MacOnboardingTests` / `UserNotificationNotifierTests`
hosted results from `macos-app` CI before the owner checks. Setup stays first;
close it to continue to the library folder. Setup and onboarding keep the
accessory policy; Settings continues to use the shared regular-window policy.
Use an isolated macOS account or test app-data and library directories so the
fresh-install checks do not overwrite your normal settings or prompts.

- Commit / `macos-app` CI run and hosted-test result:
- macOS / hardware / signing identity / notification permission / date / tester:

| Check | Result | Details |
|---|---|---|
| Fresh install: Setup opens first; close it, accept Use Default Folder, then Add Starter Prompts; the summary reports ten added and the picker shows them | NOT RUN | |
| Finish the tour with Done and restart; Setup, folder, seed offer and tour do not return and no starter file or identifier changes | NOT RUN | |
| Fresh install: choose Skip Starter Prompts, finish the tour, then restart; the empty library remains empty and the offer does not return | NOT RUN | |
| First-run tour (M3 C6): after adding or skipping starters, or accepting a non-empty library, the same window shows hotkey, search, Tab/Shift+Tab, Return/Escape and Copy versus Deliver copy with one Done button; seed counts or failures remain visible | NOT RUN | |
| Tour native close (M3 C6): closing the tour saves completion and closes the window; relaunch opens the picker; quitting before completion resumes the tour | NOT RUN | |
| Tour settings write failure (M3 C6): prevent app-data writes, then use Done and native close; the typed error keeps the tour visible and pending; restore writes and retry, then restart to confirm completion | NOT RUN | |
| Tour upgrade and recovery policy (M3 C6): existing installs, read-only settings and library recovery skip the tour; recovery preserves an explicitly pending tour flag | NOT RUN | |
| Legacy install with Setup already presented and library step pending opens the folder step directly | NOT RUN | |
| Choose Folder… uses a native directory sheet; Cancel keeps the active folder; choosing a readable empty folder seeds only that folder | NOT RUN | |
| Choose a missing, unreadable or symbolic-link folder; the typed message keeps the folder step pending and a later valid choice succeeds | NOT RUN | |
| Accept a non-empty library, including one malformed prompt; the starter offer is skipped and existing bytes remain intact | NOT RUN | |
| Prevent settings writes, then choose a folder or accept seeds; the save error remains visible, progress is not claimed and no seeds copy before their flag saves; restore writes and retry | NOT RUN | |
| Prevent seed writes after accepting the offer; the path-free failure appears, copied files remain, and restart does not repeat the offer | NOT RUN | |
| Restart with a missing or unreadable chosen folder and completed onboarding; one path-free notification appears and the folder window opens; choose a readable folder to recover | NOT RUN | |
| Deny notification permission; startup recovery still opens the folder window without another notification request in the same process | NOT RUN | |
| Close recovery while it is pending and reopen the app; the folder step returns without clearing the saved completion flag | NOT RUN | |
| Close onboarding while a chooser is pending, then reopen on next launch; no late callback switches the library or completes a newer request | NOT RUN | |
| With future-version or corrupt settings, onboarding stays closed and Settings shows its read-only error | NOT RUN | |
| The status menu says Open Library and opens the browser window; Show in Finder inside Library reveals the current folder; runtime root loss changes the menu row to disabled Library unavailable without a notification or reopened onboarding | NOT RUN | |
| After runtime loss, choose a healthy folder in Settings; Open Library is enabled again and the browser follows the replacement folder; restoring the old folder alone still requires restart | NOT RUN | |
| Keyboard and VoiceOver identify the folder paths, chooser/default actions, seed actions, summary/failure and Done; Settings remains reachable and picker dismissal never restores an old target | NOT RUN | |

## M2 VoiceOver, visible focus and reduced motion: NOT RUN

- Commit / `macos-app` CI run / artifact version / SHA-256:
- macOS / hardware / VoiceOver settings / keyboard navigation setting:
- Reduce Motion setting / date / tester:

1. Enable VoiceOver and macOS keyboard navigation. Use the picker/fill
   prompts above with text, multiline and choice fields, descriptions and
   a required empty field. Summon the panel over an editable target.
2. Navigate search, results and preview with the keyboard and VoiceOver.
   Open fill, visit all field kinds, change a choice and read the live
   preview and validation. Inspect Deliver, Copy, Cancel and Forget values,
   including disabled states. Escape returns without delivery.
3. Open Settings from the status-menu Settings… item and inspect
   General/Shortcuts tabs, the folder path,
   shortcut recorder/status and actions. Open Forget all confirmation, read
   its destructive action and Cancel, then cancel without clearing values.
4. In the isolated account/directories described above, follow onboarding
   and recovery with VoiceOver: Setup, folder path/chooser/default, seed
   Add/Skip, summary/Done and failures. Read the status-menu Open Library
   and Library unavailable states; confirm Settings stays reachable.
5. Turn VoiceOver off. Traverse picker/fill, Settings, confirmation and
   onboarding with Tab/Shift+Tab and inspect focus on each reachable control.
   Enable System Settings → Accessibility → Display → Reduce Motion, then
   repeat summon/dismiss, picker-to-fill, tab changes and onboarding steps,
   including a full-screen Space.

| Check | Result | Details |
|---|---|---|
| VoiceOver picker and fill: search/results, field kinds, labels/descriptions, choice values, preview, validation and action/disabled states are announced and operable inside the panel | NOT RUN | |
| VoiceOver Settings and onboarding: tabs, folder/shortcut state, confirmation, actions, progress/failures and status-menu library state are announced and keyboard accessible | NOT RUN | |
| Visible focus (§11.6): keyboard focus stays visible through every surface and reverse traversal | NOT RUN | |
| Reduced motion (§11.6): with Reduce Motion enabled, app transitions add no motion and controls/focus remain usable, including in a full-screen Space | NOT RUN | |

## M2 input-method composition: NOT RUN

- Commit / `macos-app` CI run / artifact version / SHA-256:
- macOS / hardware / input source / keyboard layout:
- Date / tester:

1. Enable a real conversion input source, such as Japanese or Chinese, in
   macOS keyboard settings. Confirm marked-text composition and candidate
   selection work in TextEdit before checking Monkey's Paw.
2. In picker search, start composition with visible marked text/candidates.
   Return commits the candidate and updates search without using a prompt.
   Start another composition and press Escape: it cancels composition and
   leaves the picker open.
3. In a prompt's text and multiline fields, repeat Return-to-commit and
   Escape-to-cancel while marked text is active. Neither key delivers,
   copies or returns to picker. Committed characters appear once in the
   native field and live preview.
4. After composition ends, multiline Return adds a newline. Escape returns
   to picker retaining the draft; reopen fill and confirm the committed
   text remains, then Cmd+Return delivers.

| Check | Result | Details |
|---|---|---|
| Real IME search: Return/Escape stays with marked text until commit/cancel; the picker remains open and committed search works | NOT RUN | |
| Text and multiline IME: composition commits/cancels without app actions; normal delivery/cancel keys resume afterward | NOT RUN | |

## M2 conditional clipboard privacy: NOT RUN

- Commit / `macos-app` CI run / artifact version / SHA-256:
- macOS / hardware / privacy prompt behavior / read-count tracing method:
- Date / tester / per-step read counts:

Use harmless test clipboard text and fieldless/fielded prompts with and
without `{{clipboard}}`, including two occurrences in one prompt. Observe
macOS paste-privacy prompts and count app-origin reads with a permitted
debugger/trace on `-[NSPasteboard stringForType:]`, identifying the
`PasteboardClipboard` caller without recording arguments or contents.
If the tested build cannot be traced, keep the count checks NOT RUN;
absence of a privacy prompt does not prove zero or exactly one read.
Change the external clipboard with a background writer such as `pbcopy`
while the form stays open; switching focus would hide it and require reopening.

| Check | Result | Details |
|---|---|---|
| Search and selection (§5.3): reset the count, summon/search and select every prompt without use; zero reads and no app-triggered paste-privacy request, including on selection of a clipboard prompt | NOT RUN | |
| No clipboard builtin: open/edit/deliver the fielded prompt and use the fieldless prompt without the builtin; zero reads and no app-triggered paste-privacy request | NOT RUN | |
| One snapshot per form open: open the form and read once for both occurrences; edit fields and update the clipboard in the background without changing the preview snapshot or reading again; Escape and reopen to read the new text once, then deliver without another read | NOT RUN | |
| One snapshot per fieldless use: each use reads once for both occurrences; change the external clipboard and use again to observe one new read | NOT RUN | |

## M3 M1 Library window shell: NOT RUN

The Linux implementation host cannot compile or run AppKit. Record the exact
commit and `MacLibraryWindowTests` hosted results from `macos-app` CI before
these owner checks. CI exercises presentation state, explicit key routing,
window reuse and composition; real keyboard traversal, VoiceOver, clipboard
privacy, activation and Spaces behavior still require a Mac. M1 supplied
the read-only preview; M2 adds the editor tabs below. Return on a browser row
does not launch another editor.

- Commit / `macos-app` CI run and hosted-test result:
- macOS / hardware / signing identity / keyboard navigation setting:
- VoiceOver / input source / clipboard read-count tracing method:
- Date / tester / per-step clipboard read counts:

Create valid prompts with defaults, required text and choice fields without
defaults, escaped template openers, and date/time/clipboard builtins. Include
favourites, recent deliveries or copies, nested folders and shared tags. Add
malformed YAML, a future-format file, a non-UTF-8 file and a file larger than
256 KiB. Use the permitted clipboard tracing procedure above without recording
clipboard contents; leave read-count checks NOT RUN if tracing is unavailable.

| Check | Result | Details |
|---|---|---|
| Picker Library control and ⌘L, status Open Library and the main-menu ⌘L item open the same reusable window; closing and reopening preserves the window | NOT RUN | |
| Opening Library with an armed picker, pending blur or queued summon hides the picker and closing Library never restores an old paste target | NOT RUN | |
| All, Favourites, Recent, nested folder rows and tag rows show correct counts; counts stay unchanged by the text filter | NOT RUN | |
| Rows show title, exact relative path, favourite star, read-only/invalid badges and a last-use date in Recent; new deliveries and copies refresh Recent | NOT RUN | |
| Filtering or changing section keeps a selected prompt's preview when its row disappears; selecting another row updates the preview | NOT RUN | |
| Preview uses field defaults or {field} names, actual date/time, escaped openers and a literal {clipboard}; opening, filtering and selection make zero clipboard reads | NOT RUN | |
| Invalid, future-format, non-UTF-8 and oversized rows show their issues, never rendered bodies, and disable the favourite button | NOT RUN | |
| Favourite button and ⌘⇧F save the selected prompt and update picker/sidebar state; an external edit before toggling shows a conflict without overwriting it | NOT RUN | |
| Show in Finder reveals the active folder; after a Settings folder switch the same Library window shows only the new graph and reveals its folder | NOT RUN | |
| Runtime folder loss disables Open Library in both menus and disables favourite/reveal actions in an already-open window; switching to a healthy folder restores them | NOT RUN | |
| Settings and Library can stay open together; the Dock icon appears while either is open and disappears only after both close, including close/reopen and minimization | NOT RUN | |
| Arrow keys navigate sidebar and prompt rows; Tab/Shift+Tab reach filter, actions, sidebar, list and preview with visible focus; Return on a prompt opens nothing | NOT RUN | |
| Escape from each pane clears the filter first, then closes; a real IME consumes Return/Escape during marked-text composition without Library actions | NOT RUN | |
| VoiceOver identifies sidebar sections/counts, prompt rows/badges/last use, filter, preview, favourite/reveal actions and failure messages | NOT RUN | |
| Repeated picker-to-Library openings work from a full-screen Space; window resize and Reduce Motion retain usable controls and visible focus | NOT RUN | |

## M3 M2 Library editor tabs: NOT RUN

The Linux implementation host can parse Swift syntax and check the Xcode
project, but cannot compile AppKit/SwiftUI or run hosted macOS tests. Run
`MacLibraryEditorTests`, `MacLibraryWindowTests` and `MacPickerViewTests` in
the `macos-app` CI job before these checks. Hosted tests drive presentation
state and injected sheet/worker ports, exercise native NSTextView controls,
and count an injected clipboard's reads and writes. They do not prove real
IME behavior, keyboard focus, VoiceOver, Spaces or sheet appearance.

- Commit / `macos-app` CI run / hosted-test results:
- macOS / hardware / input source / keyboard navigation setting:
- VoiceOver / clipboard read-count tracing method:
- Date / tester:

Use an isolated library and app-data folder. Include valid sources with
front matter, declared and implicit fields, choice defaults, date/time and
clipboard builtins, malformed YAML, a future format, non-UTF-8 bytes and an
oversized file. Use a second editor for external writes and deletions. Do
not record prompt text, field values or clipboard contents in this checklist.

| Check | Result | Details |
|---|---|---|
| Selection opens Edit with exact raw source, monospace text, native undo/redo, cut/copy/paste/select-all and multiline scrolling | NOT RUN | |
| Edit, Preview and Fields tabs remain usable on resize; diagnostics below Edit update during typing and identify severity/location; Fields shows parsed declarations and implicit fields read-only | NOT RUN | |
| Preview uses defaults or field names, real date/time and a literal {clipboard}; opening, typing and all tab changes make zero clipboard reads or writes | NOT RUN | |
| Non-UTF-8, oversized and future-format prompts show distinct read-only reasons and disable source edits, Save and Save as Copy | NOT RUN | |
| Save button and ⌘S write the file, update picker/favourites, clear dirty state and show Saving/Saved or typed failure; typing during a save retains the newer draft | NOT RUN | |
| Favourite on the open dirty prompt updates its source without writing; a clean favourite saves through the editor and causes no false conflict | NOT RUN | |
| Revert asks Save/Discard/Cancel while dirty and reloads the current disk source after approval; Save as Copy creates a distinct identity/path and selects the copy when the watcher publishes it | NOT RUN | |
| An external write while dirty opens a native sheet; independently exercise Keep Mine, Take Theirs and Save Mine as Copy, confirming original/copy bytes and retained newer edits | NOT RUN | |
| An external deletion while dirty leaves its draft visible and offers Keep Mine (recreate), Save Mine as Copy and Discard; exercise all choices | NOT RUN | |
| Selection change, red close button, ⌘W and Escape after clearing the filter ask Save/Discard/Cancel; Cancel keeps the current row/draft and Save completes before navigation/close | NOT RUN | |
| A close requested during Save waits for completion; failed saves preserve the decision and draft with retryable typed feedback | NOT RUN | |
| Settings Choose Folder/Use Default refuse a dirty draft or a pending save with the editor-specific message and keep the existing library; after saving/discarding, a switch retires old worker replies, native input and sheet callbacks | NOT RUN | |
| Menu Quit and ⌘Q defer termination while dirty/saving; Cancel stays resident, Discard quits without writing and Save quits only after a successful save; failed saves keep Library open | NOT RUN | |
| Picker Edit/⌘Return and no-match create open the selected/new prompt in Library's Edit tab, including with a prior hidden row/filter; Show in Finder still reveals the current library folder | NOT RUN | |
| With a real Japanese/Chinese IME, Return/Escape during marked text go to the input method; typing/state refresh preserves composition, and document/library replacement never commits the old composition into the new draft | NOT RUN | |
| VoiceOver identifies source, editor tabs, field headings, save/revert/copy controls, validation/status messages and all sheet choices; Tab/Shift+Tab show visible focus | NOT RUN | |
| Minimized Library is restored for a quit decision; full-screen Spaces, repeated openings and simultaneous Settings/Library windows preserve activation and Dock policy | NOT RUN | |
