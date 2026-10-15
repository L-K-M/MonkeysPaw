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
end real NSAlert sheets with `.cancel` and `.stop`, and count an injected
clipboard's reads and writes. They do not prove real
IME behavior, keyboard focus, VoiceOver, Spaces or sheet appearance.

Hosted undo tests call the text view's `undoManager.undo()` and `redo()`
after closing explicit undo groups, as described in Apple's
[Performing Undo and Redo](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/PerformingUndo.html).
The coordinator observes that manager's
[did-undo](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nsundomanagerdidundochange)
and [did-redo](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nsundomanagerdidredochange)
notifications to publish native replacements even when `textDidChange`
does not fire. Apple's [notification delivery contract](https://developer.apple.com/library/archive/documentation/General/Conceptual/DevPedia-CocoaCore/Notification.html)
is synchronous; these main-thread tests assert native text, model source
and dirty state immediately, without a predicate polling UI state from a
worker thread. They also cover redo back to the saved, clean source.

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
| Selection opens Edit with exact raw source, monospace text, native undo/redo, cut/copy/paste/select-all and multiline scrolling; a save that adds an id header preserves the body caret and both normalization and prior typing remain undoable; undo/redo immediately update Preview and the unsaved indicator, and redo back to saved text clears it | NOT RUN | |
| Edit, Preview and Fields tabs remain usable on resize; diagnostics below Edit update during typing and identify severity/location; Fields shows parsed declarations and implicit fields read-only | NOT RUN | |
| Preview uses defaults or field names, real date/time and a literal {clipboard}; opening, typing and all tab changes make zero clipboard reads or writes | NOT RUN | |
| Source stays non-editable while its initial load is pending; non-UTF-8, oversized and future-format prompts show distinct read-only reasons and disable source edits, Save and Save as Copy | NOT RUN | |
| Save button and ⌘S write the file, update picker/favourites, clear dirty state and show Saving/Saved or typed failure; typing during a save retains the newer draft | NOT RUN | |
| Favourite on the open dirty prompt updates its source without writing; a clean favourite saves through the editor and causes no false conflict | NOT RUN | |
| Revert asks Save/Discard/Cancel while dirty and reloads the current disk source after approval; Save as Copy creates a distinct identity/path and selects the copy when the watcher publishes it | NOT RUN | |
| An external write while dirty opens a native sheet; independently exercise Keep Mine, Take Theirs and Save Mine as Copy, confirming original/copy bytes and retained newer edits; Cancel keeps the draft and conflict available, including after an invalid save, so Edit can repair it before Save reopens the choices without writing; Save as Copy and Revert stay disabled until the conflict is resolved | NOT RUN | |
| An external deletion while dirty leaves its draft visible and offers Keep Mine (recreate), Save Mine as Copy and Discard; exercise all choices; a copy gets a fresh identity and an alternate filename | NOT RUN | |
| After cancelling a deletion conflict, externally recreate then delete the file again; the new deletion reopens the conflict sheet, while ordinary typing after Cancel does not | NOT RUN | |
| Selection change, red close button, ⌘W and Escape after clearing the filter ask Save/Discard/Cancel; Cancel keeps the current row/draft and Save completes before navigation/close | NOT RUN | |
| Return activates Save in an unsaved-edit decision; Return never activates Keep Mine in a conflict sheet; Escape and a programmatic non-button sheet dismissal retain the draft and cancel the pending action | NOT RUN | |
| With Settings, onboarding or the picker panel focused, ⌘S and ⌘W leave the Library draft and window alone | NOT RUN | |
| A close requested during Save waits for completion; failed saves preserve the decision and draft with retryable typed feedback | NOT RUN | |
| Settings Choose Folder/Use Default refuse a dirty draft or a pending save with the editor-specific message and keep the existing library; saving/discarding clears that message in an already-open Settings window; a later switch retires old worker replies, native input and sheet callbacks | NOT RUN | |
| Menu Quit and ⌘Q defer termination while dirty/saving; Cancel stays resident, Discard quits without writing and Save quits only after a successful save; failed saves keep Library open | NOT RUN | |
| Picker Edit/⌘Return and no-match create open the selected/new prompt in Library's Edit tab, including with a prior hidden row/filter; Show in Finder still reveals the current library folder | NOT RUN | |
| With a real Japanese/Chinese IME, Return/Escape during marked text go to the input method; typing/state refresh preserves composition, and document/library replacement never commits the old composition into the new draft | NOT RUN | |
| VoiceOver identifies source, editor tabs, field headings, save/revert/copy controls, validation/status messages and all sheet choices; Tab/Shift+Tab show visible focus | NOT RUN | |
| A conflict or decision published while Library is minimized or the app hidden appears on restore/unhide; minimized Library is restored for a quit decision; full-screen Spaces, repeated openings and simultaneous Settings/Library windows preserve activation and Dock policy | NOT RUN | |

## M3 macOS History and file commands: NOT RUN

Run `MacLibraryCommandTests` together with `MacLibraryEditorTests` and
`MacLibraryWindowTests` in `macos-app` CI. The Linux host can check Swift 5
syntax and Xcode structure, but cannot compile or execute AppKit/SwiftUI.
Hosted tests drive presentation state, held worker jobs and the existing
dialog seam, including real NSAlert form submission and non-button dismissal.
They do not prove keyboard focus, VoiceOver or native sheet appearance.

- Commit / `macos-app` CI run / hosted-test results:
- macOS / hardware / keyboard navigation setting:
- Date / tester:

Use an isolated library and app-data folder. Save several versions of a
prompt, including snapshots of malformed YAML, a future format, non-UTF-8
bytes and an oversized source. Use another editor for external changes.
Record outcomes without recording prompt content.

| Check | Result | Details |
|---|---|---|
| History opens as the fourth tab and refreshes when opened or when selecting another prompt; revisions appear newest first with local timestamp, locale-formatted file size and Valid/Forensic only status | NOT RUN | |
| Select History while a Rename or Move is running, including an occupied/invalid destination; history loads after the command settles, an empty history stays settled, and the typed command outcome remains visible | NOT RUN | |
| Keep History open during a plain file's first save and a same-path external identity assignment; revisions follow the assigned identity, first save preserves source undo/caret, and rename/move refresh history at the new path | NOT RUN | |
| Selecting a revision shows its exact source in a selectable, read-only monospace preview without changing the draft; non-UTF-8 and oversized revisions show distinct preview reasons | NOT RUN | |
| Restore updates the editor and reloads history, preserves the prompt identity and revision body, and shows Restored or a committed history-maintenance warning | NOT RUN | |
| Restore of malformed, non-UTF-8, oversized or future-format revisions displays the typed refusal and leaves current file bytes unchanged | NOT RUN | |
| Restore while dirty asks Save/Discard/Cancel; Cancel keeps draft, selection and history; a stale restore opens the same conflict sheet as Save and never silently overwrites external changes | NOT RUN | |
| The menu bar shows File between the application and Edit menus; the editor header and File menu offer Rename…, Move… and Delete… for the open prompt; File → Save uses ⌘S, and native text editing keeps its existing Cut/Copy/Paste equivalents | NOT RUN | |
| Rename starts with the current .md filename and changes only the filename; Move offers known folders and accepts a new nested relative folder or empty text for root; selection follows assigned and unassigned prompts | NOT RUN | |
| An occupied destination or invalid name/folder produces typed status copy, preserves the source and never replaces the destination | NOT RUN | |
| Delete confirmation names the exact relative file path; Cancel/Escape/non-button dismissal preserves it, and an explicit Delete closes the editor, clears the selection and keeps history | NOT RUN | |
| Rename, Move and Delete each use Save/Discard/Cancel for dirty edits; Save finishes before the command, Discard drops only the draft, and Cancel keeps everything | NOT RUN | |
| Stale Rename/Move/Delete open conflict choices; a missing file keeps the loaded draft with a deletion conflict and a typed missing-file message | NOT RUN | |
| After cancelling a command, an external edit and dismissal of its conflict shows conflict guidance instead of the old Cancelled status; cancelling a guard Save conflict also keeps that guidance and draft | NOT RUN | |
| Commands and Restore disable while loading, saving, updating a file, awaiting a guard/conflict, without a prompt, for read-only prompts or after library loss; File menu commands affect only the focused Library window | NOT RUN | |
| Closing or switching the library retires pending form callbacks; tab changes and command forms make no clipboard reads or writes | NOT RUN | |
| Tab/Shift+Tab, Return in rename/move forms, Escape, resize and repeated use remain usable; Return never confirms Delete or a conflict overwrite; VoiceOver identifies revisions, preview, commands and all typed messages | NOT RUN | |

## M4 A3 Keychain secrets: NOT RUN

The Linux implementation host cannot compile Security or run hosted macOS
tests. Record `KeychainSecretStoreTests` and the real-login-keychain test's
explicit skip from `macos-app` CI. The real-store check runs only with the
owner's `MONKEYSPAW_RUN_KEYCHAIN_INTEGRATION=1` opt-in; it uses a unique service,
suppresses Keychain dialogs and removes its item. It does not prove interactive
ACL or signing behavior. The Assistant settings UI arrives in
A13; keep the saved-key display check NOT RUN until that UI is available.

- Commit / `macos-app` CI run / hosted test result or skip reason:
- macOS / hardware / signing identity / login-keychain state:
- Date / tester / observed ACL prompt count:

Use a disposable macOS account and nonproduction credentials. Record only
status and storage tier, never a key or resolved connection. Save two provider
profiles, replace one key, restart and check both profiles. Deny/cancel access
and repeat with the login keychain locked; failed edits must preserve the
stored map. Repeat after installing an updated build with the same signing
identity, and record any new access request.

| Check | Result | Details |
|---|---|---|
| ACL prompts: record requests across both provider profiles sharing one item; allow, deny and cancel behave as expected, and denied/locked edits preserve saved credentials | NOT RUN | |
| Unreadable shared-map recovery guard: with two profiles saved, deny/lock access or corrupt a disposable Keychain map, then explicitly Clear/Delete/Replace one profile. While the shared map is unreadable, a typed locked/unavailable/readFailed result preserves both the item and metadata; no whole-item reset occurs. Restore access or repair the disposable map and retry; the other profile remains usable | NOT RUN | |
| Signed-build access: the intended signed build and an update can read, replace and delete their saved keys; record signing identities and any new ACL prompts | NOT RUN | |
| Key never shown after save: Assistant settings show only saved status and Keychain tier after save/reopen/restart; no stored value appears in the key field, errors or diagnostics | NOT RUN | |

## M3 M4 Library import: NOT RUN

The Linux implementation host cannot compile AppKit/SwiftUI or run hosted
macOS tests. Run `MacLibraryImportTests` and `MacImportSourceReaderTests` in
`macos-app` CI before these checks. Hosted tests inject chooser replies,
decode item-provider file URLs, release worker jobs and drive presentation
state. They cover mixed files/folders, destination choice, progress, typed
reports, exclusive creation, symlink refusal, bounded reads, report opening
through the watcher/editor guard, retirement during/after imports on a library
switch or library loss, and reports retained across closing during a batch. They
do not prove native chooser appearance, real Finder drops or VoiceOver.

The chooser includes `UTType.folder` alongside the three prompt file types,
with `allowsOtherFileTypes = false`. Apple documents
[`canChooseDirectories`](https://developer.apple.com/documentation/appkit/nsopenpanel/canchoosedirectories)
as enabling directory selection, and
[`UTType.folder`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/folder)
as a user-browsable directory type. Including it in
[`allowedContentTypes`](https://developer.apple.com/documentation/appkit/nssavepanel/allowedcontenttypes)
makes the advertised folder choice explicit while retaining file filtering.
Native folder selection still requires the owner check below.

Closing the reusable Library window cancels its chooser but lets a running
batch finish in the background. Reopening the same window shows its report.
Losing the library retires import preparation, drop replies and queued model
work, keeps completed reports visible, and requires a replacement library
graph before importing again. Core may finish a publication already executing
when retired; later files do not start. Switching graphs clears the old report
and binds a fresh import model and state.

Folder enumeration walks iteratively, reopening one directory at a time from
the pinned root without following links. It uses Core's 1,024-byte path cap
and budgets the total bytes in visited paths with Core's 256 KiB import cap,
charging each file or directory's relative path plus one byte. Exceeding
either bound fails
that folder before writes, rather than returning an incomplete listing.
Vanished prompt files remain candidates for a typed `source(notFound)` skip;
unopenable subdirectories produce a visible `notRegularFile` container skip,
or a symbolic-link skip when replaced by a link. Unexpected directory-stream
or resource errors fail enumeration. Hosted fixtures cover races, denied
subdirectories, overlong relative paths and the total path budget.

- Commit / `macos-app` CI run / hosted-test results:
- macOS / hardware / keyboard navigation setting / VoiceOver:
- Date / tester:

Use an isolated library and source folder. Include `.md`, `.prompt` and
`.prompty` sources, nested directories, preserved foreign metadata,
unsupported inputs/templates, a duplicate id, invalid YAML, a future format,
non-UTF-8 bytes, a file over 256 KiB and file/directory symlinks. Prepopulate
a destination filename to check alternate naming. Keep source and existing
destination bytes for comparison, without recording prompt content here.

| Check | Result | Details |
|---|---|---|
| Library Import… and app-menu Import… (⌘⇧I) open a sheet accepting multiple `.md`, `.prompt`, `.prompty` files and folders together; Cancel leaves the library untouched and the next chooser works | NOT RUN | |
| Finder drops onto the prompt list work with one file, multiple files, folders and a mixed selection, including spaces and non-ASCII names; folder-relative structure is preserved | NOT RUN | |
| Destination defaults to Imported/; selecting an existing nested folder writes there, and the destination and both Import actions stay disabled throughout enumeration and every selection in the batch | NOT RUN | |
| Progress shows enumeration and processed-file counts; completion lists every created library path, each typed skip, mapped fields, preserved metadata keys, header-formatting loss and warnings; partial success remains available | NOT RUN | |
| Existing destination bytes and all sources stay unchanged; occupied names use alternates and duplicate ids receive fresh identities; symlinked sources and nested symlinks never import their targets | NOT RUN | |
| Imported rows appear through the watcher; opening a report path reveals it even with a filter or another sidebar section, and an unsaved editor draft still requires Save/Discard/Cancel | NOT RUN | |
| Dismiss report clears its contents; closing during a mixed batch lets it finish and reopening shows every completed result; switching libraries during and after imports retires old work and resets destination/report while the new graph can import | NOT RUN | |
| Runtime library loss retires queued imports and disables Import/report opening while preserving completed reports; native chooser dismissal, minimized windows and simultaneous editor sheets never leave Import stuck or revive a closed chooser | NOT RUN | |
| A source deleted during enumeration is a typed skip while readable prompts still import; inaccessible subdirectories appear as container skips; exceeding the path or enumeration budget fails the folder before writes | NOT RUN | |
| Tab/Shift+Tab reach Import, destination, report paths and Dismiss with visible focus; VoiceOver identifies each control, progress, created path and skip/warning text; resize and Reduce Motion keep the Library usable | NOT RUN | |

## M4 A13 Assistant Settings: NOT RUN

The Linux host can check Swift syntax and Xcode project structure, but cannot
compile SwiftUI/AppKit or run these hosted tests. Record the `macos-app` CI
build and `MacAssistantSettingsTests`, `MacSettingsWindowTests` and
`AppDelegateTests` results before performing the checks below. The production
composition test opens the real Settings factory with a saved keyless profile
and rejects every HTTP send. Saved-tier composition tests inject memory-only
secrets; hosted AppDelegate graphs without an injected store report secrets
unavailable and never construct the login-Keychain store. View-state tests use
memory-only secrets and stub clients. The real login-Keychain roundtrip is
skipped unless the owner explicitly sets `MONKEYSPAW_RUN_KEYCHAIN_INTEGRATION=1`.
These tests do not establish real provider, Keychain prompt or VoiceOver behavior.

AppDelegate shares the provider settings service, bounded URLSession transport,
provider clients and background worker with the lazy Assistant settings model.
Opening Settings may read a saved key's storage tier on that worker; only
explicit Test or assistant actions send network requests. Saved values never
enter the pane's state or secure field.

One Assistant model belongs to each retained Settings window. Closing cancels
Test; reopening the same window keeps its draft and does not construct another
model. Controller/application teardown retires it on the UI thread. Delete on
an unsaved new profile discards the draft without persistence. Metadata and key
input remain editable during Save; newer edits stay staged after the older Save
completes. Discard edits and reload cancels Test before returning to saved state.

- Commit / `macos-app` CI run / hosted test result:
- macOS / hardware / signing identity / login-keychain state:
- Date / tester / Anthropic model ID / Ollama version and model ID:
- VoiceOver / keyboard navigation settings:

Use nonproduction credentials and a disposable profile. Record statuses and
tiers only. Do not put keys, request headers or provider response bodies in
this checklist, screenshots or logs.

| Check | Result | Details |
|---|---|---|
| Open Settings → Assistant in the production app; the tab exists and loading/progress finishes without freezing the window or sending network requests; saved-tier reads may prompt Keychain on a worker, and opening/reopening the same window preserves its model and draft | NOT RUN | |
| Add, select, rename and delete profiles; Delete on an unsaved draft discards it without an error or persistence; selecting a saved profile makes it active, Disable Assistant clears the active selection, and saving a new profile preserves an existing active provider | NOT RUN | |
| With one active profile, add a draft; no saved row is highlighted and clicking the active row returns to it. Add and Save another profile; its edited row is highlighted while the old provider stays active, and Make active selects the new provider | NOT RUN | |
| Real Anthropic: enter the base URL and a test key, explicitly Test connection, observe typed success and listed models; select a listed ID, Save, then restart and verify saved metadata and Keychain tier | NOT RUN | |
| Real Ollama: choose OpenAI-compatible, enter a loopback base URL and installed model ID with no key; Test connection lists models, Save and restart retain the keyless profile | NOT RUN | |
| Enter an unlisted model ID before/after Test; success with no models, listing unsupported, authentication failure, network failure and timeout leave manual entry usable and show actionable typed copy | NOT RUN | |
| Test an unsaved draft without Save; no profile or key is persisted. Editing, switching profiles, or Discard edits and reload cancels Test and no stale result or model list reappears | NOT RUN | |
| Key field: saved keys never appear after selection, Save, close/reopen or restart; blank keeps, replacement stages, Keep discards typed input, and Clear empties the field without reverting to Keep | NOT RUN | |
| Save after Clear removes the persisted key and saved status; failed Clear/delete preserves the saved profile/status and shows a typed error; deleting the active profile leaves no stale draft, key tier or model list | NOT RUN | |
| Change kind or destination with a saved key; Save/Test requires re-entry or explicit Clear, and the previous key is never sent to the changed destination | NOT RUN | |
| Record Keychain prompt timing/count; allow, deny, cancel and locked-keychain cases leave Settings responsive and show typed status/errors without exposing credentials | NOT RUN | |
| Close Settings during Test and reopen the same window; Test is cancelled and late replies do not update the retained pane. Edit metadata/key input during Save; the older Save commits and newer edits stay staged. Close during Save; the accepted Save completes and reopen preserves that state | NOT RUN | |
| VoiceOver identifies Assistant, profile list/active provider, kind, base URL, model ID/picker, secure key input, key mode/tier, Save/Test/Cancel and progress/errors; Tab/Shift+Tab keep visible focus and all controls operable | NOT RUN | |

## M4 Library Assistant flows (§7.3, §7.6, §11.7)

These checks require macOS and live providers. None ran on the Linux host.
Run the three flows with a saved Anthropic profile and again with a local,
keyless Ollama OpenAI-compatible profile. Record the host/model before each
request and usage afterwards. Use a disposable library with no sensitive
templates or field values. No request starts when you merely open the panel.

- Commit / `macos-app` CI run / hosted-test result:
- macOS / hardware / provider host / model ID:
- Date / tester:

| Check | Anthropic | Local Ollama | Notes |
|---|---|---|---|
| Library toolbar and File → Assistant open the embedded panel; Cmd+Shift+A works from the editor and leaves Settings text editing alone. The window expands to fit, and Tab/Shift+Tab and VoiceOver reach every control | NOT RUN | NOT RUN | |
| Write: enter a brief, explicitly Write, inspect title/body/fields, notes and issues, then the final front-matter/body diff. No file appears until Accept; the saved file matches the candidate, has a fresh identity and excludes draft notes | NOT RUN | NOT RUN | |
| Review: send the current unsaved validated template, inspect severity/criterion/problem/suggestion, select findings, and Show quote in editor. An exact Unicode quote selects the right text without changing the file or undo history; unmatched quotes show an explanation and never highlight other text | NOT RUN | NOT RUN | |
| Improve: apply selected findings, an instruction, and then an instruction without reviewing first. Inspect both sides of the merged diff, preserved personal/unknown metadata, placeholder add/remove/rename warnings and newline markers. Accept creates an ordinary revision; Reject leaves the editor and file unchanged | NOT RUN | NOT RUN | |
| Invalid draft stays unaccepted with validation issues. Retry with feedback sends only on that explicit action, retains prior turns, and uses the current template. Authentication, missing-model, timeout and invalid-output failures show fixed actionable messages without provider error bodies | NOT RUN | NOT RUN | |
| Before calling, the footer shows host and model. While working, elapsed seconds tick; after completion, usage appears when supplied. Cancel, Close Assistant, Escape, editor navigation and Library close stop the timer and request. Late replies do not revive the panel, and reopening gives a fresh session | NOT RUN | NOT RUN | |
| No profile disables requests with Settings guidance. Private/read-only/invalid templates disable Review and Improve; Write remains independent of the open source. Busy editor operations, discard decisions and disk conflicts disable new calls with an explanation | NOT RUN | NOT RUN | |
| Change the buffer, including changing away and back, after preview or during a call. Acceptance stays disabled until an explicit fresh Show diff; no late reply applies old bytes. Change the file on disk and exercise the existing conflict choices while retaining your draft | NOT RUN | NOT RUN | |
| Write Accept with dirty editor invokes Save / Discard / Cancel. Save/Discard changes the snapshot and requires a fresh diff; Cancel preserves edits and creates no file. Cancel a pending acceptance without dismissing an earlier editor decision | NOT RUN | NOT RUN | |
| Save a changed model/profile or replacement key in Settings, including a credential-only save. The old preview is revoked and the Library footer follows the shared saved profile. Switch libraries during a request; the retired graph cannot publish into the new editor | NOT RUN | NOT RUN | |
| Observe saved, changed-buffer/disk conflict and failed acceptance messages. With disposable app-data permissions or a provenance-write failure fixture, a committed provenance/history warning explicitly says the file was saved and must not be saved again; the message remains visible after closing Assistant | NOT RUN | NOT RUN | |
| Confirm requests contain template source rather than rendered preview or remembered/fill/clipboard values. Inspect diagnostics using test sentinels: no keys, prompt content, feedback, field values, transcript or provider error bodies are logged | NOT RUN | NOT RUN | |

Group roles arrive in M6. Hosted tests exercise the existing viewer seam: the
control offers **Improve a private copy**, and acceptance preserves the source
while creating a fresh prompt in personal scope. Its LLM privacy flag is
preserved; ownership is defined by §9's scope. Record an owner check when
authoritative group roles are wired into macOS composition.

## M7 D17 Delivery and update Settings: NOT RUN

The Linux host cannot compile or run AppKit/SwiftUI. Record both `macos-app`
and `macos-artifacts` CI results before these owner checks. Hosted tests use
isolated roots/pasteboards, fake HTTP/paste and a fake update timer boundary;
they do not establish live permission, browser, clipboard or keyboard behavior.
Ordinary Settings close retains its window/models, detaches the two view
callbacks and refreshes on reopen. Teardown permanently retires those models;
any replacement controller must receive fresh models. Updates belong to app
data and survive a prompt-library change. Default-on automatic checks start
only in a versioned runtime outside XCTest.

- Commit / CI runs / packaged artifact SHA-256:
- macOS / hardware / signing identity / browser:
- Keyboard navigation / VoiceOver / date / tester:

| Check | Result | Details |
|---|---|---|
| Settings opens from the menu and Cmd+,; General, Shortcuts, Delivery and Assistant remain usable after repeated close/reopen, folder changes and Library window activation | NOT RUN | |
| Delivery shows fixed Cmd+V, current Accessibility and AppleScript fallback facts, cached failures and readback results. Test paste runs once; Open Setup reuses the existing window. Deny/revoke/grant Accessibility and Automation in a disposable session and check refresh without duplicate prompts or hotkey registration | NOT RUN | |
| Restore starts off, persists when enabled, and states previous text only, 750 ms timing and the simultaneous-copy limitation. Try slow browser/chat/terminal paste: record actual readback and whether 750 ms is sufficient. Newer copies, including identical text, Copy, failed paste, Test paste, disabling restore and shutdown preserve the expected clipboard | NOT RUN | |
| General displays the full installed beta version and numeric marketing version remains valid in both signed dmg/zip copies. Automatic off survives restart and prevents traffic; enabled checks remain at most daily across restart/offline failure. Inspect metadata only, never prompt/field/account content | NOT RUN | |
| Check Now shows progress and distinct success/no-release/offline/rate-limit errors, including while automatic is off. Update available is passive; only View release opens the repository release page, and opening failure is actionable. No download, installation or restart occurs automatically | NOT RUN | |
| Disable automatic checks during slow work, close/reopen Settings, switch libraries and quit; no stale result revives a retired window and no update timer survives shutdown. Check timestamp/state errors using disposable app-data permissions | NOT RUN | |
| With macOS Keyboard navigation enabled, Monkey's Paw active and Settings key, Tab/Shift+Tab reach both toggles, Test paste, Open Setup, Check Now and View release with visible focus; VoiceOver reads each label, version, status and error. Native text editing, Cmd+V and existing shortcut recorders retain focus and key handling | NOT RUN | |
