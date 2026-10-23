## 11. User interface

### 11.1 Windows (both front ends)

| Window | Content |
|---|---|
| Picker panel (hidden at start, `PANEL_SIZE = 640×420`) | search field, result list, preview pane, footer with key hints, the paste target, and sync status |
| Fill form (same panel, next state) | one control per field, live preview, Deliver / Copy / Cancel |
| Library (menu bar or tray → "Library…", or `⌘L` / `Ctrl+L` in the picker) | sidebar: All, Favourites, Recent, Conflicts, folders, groups, tags; list; Edit/Preview/Source editor; Fields, History and Assistant inspector |
| Assistant (panel inside Library) | write from a description, review findings, improve diff |
| Settings | General · Shortcuts · Delivery · Assistant · Account (sign in, devices, groups, members, invites) |
| Setup | §6.4 |

M2 Settings contains **General · Shortcuts**; the other tabs follow their
milestones. Shortcuts renders the shared `ShortcutsSettingsModel`: the current
picker and repeat bindings (or unknown/unbound), registration mechanisms and statuses,
backend conflict/failure detail, and a **Press your shortcut now** verification
intent. macOS Carbon offers in-app rebinding. Linux offers the applicable
system settings action, explicit Setup action, or desktop/manual instructions
described in §6.1. Opening settings or completing a change request never turns
verification green. M7 makes registration, verification, change and clear intents
action-aware. Repeat starts unbound, with no suggested key. Carbon choices survive
restart; capture or clear affects only the selected action. A failed registration
or save restores its previous binding and reports failure, including unsuccessful
recovery. GNOME/manual drivers supply repeat instructions. GNOME installs only
explicitly assigned keys; portal/KDE adapters follow in D9/D10. D12/D13 provide
the native controls and activation. Core supplies this contract
independently of the native windows.

Settings → General shows your active library folder, whether it is the default,
and any read-only settings or library-switch error. You can choose another
folder, return to the default, or reveal the active folder in your file manager.
Views call `GeneralSettingsModel`; its `LibraryLocationControl` port delegates
graph replacement and folder reveal to the platform composition root.
General also offers **Forget all values** with confirmation through
`RememberedValuesSettingsModel`, including while the picker panel is closed.

M7 Settings → Delivery uses `DeliverySettingsModel` for the saved Linux
default chord and clipboard-restore mode. Both desktops show the restore
control and its previous-text/750 ms caveat, sanitized paste backend,
permission and failure facts, **Test paste**, and **Open Setup…**. Test
reuses the existing Setup self-test; opening Setup requests the existing
window. Refresh never reads the clipboard, captures a target, registers a
shortcut or starts permission consent. macOS displays fixed Cmd+V without
a Linux selector. Native Linux offers Standard/Terminal and explains X11
detection; Wayland/Flatpak explains the default/manual chord, portal consent
and copy fallback. Repeat assignment stays in Shortcuts. General owns
automatic update checks and the later Check Now/result controls.

These are additive fields in the existing version-1 `settings.json` at
each desktop's current settings location, without a version bump:

```json
"delivery": {"linuxDefaultPasteChord": "standard", "clipboardRestore": "off"},
"automaticUpdateChecks": "enabled",
"carbonShortcuts": {"togglePicker": "Ctrl+Alt+P", "repeatLast": null}
```

`linuxDefaultPasteChord` accepts `standard`/`terminal`; `clipboardRestore`
accepts `off`/`previousText`; `automaticUpdateChecks` accepts
`enabled`/`disabled` (§17 Q11). A missing delivery object or member uses its
default; only a missing update-check field defaults to enabled. A present
null, wrong type or unknown enum value follows the corrupt/read-only rule.
Loading an older version-1 file does not rewrite it just to add defaults.
Every folder, first-run and preference change preserves all other fields
and unknown JSON keys, including keys inside `delivery`. Failed saves
publish the prior committed preference and a typed error. A read-only
snapshot never permits automatic update checks, even when its fallback
document contains the enabled default. No update requests or restore
behavior are activated by the Core preference/model slice. `carbonShortcuts`
contains parsed Carbon-compatible accelerator strings or explicit null for an
unbound action. Missing actions use picker/unbound defaults. Present invalid
types, malformed accelerator strings, unsupported Carbon translations and
in-app collisions make settings read-only. In that read-only snapshot, the
entire `carbonShortcuts` family uses Carbon defaults while valid library,
first-run and other preferences still load. Both recovery and the write
restriction apply together; no write may overwrite invalid or future choices.
Restore a valid settings file and restart to recover editing, including when
the stored choices collide. In-app rebinding handles valid, writable settings.
Unknown nested members survive edits, and every settings setter preserves both
choices. Registration and save failures never publish a requested key as saved.

Settings → Assistant renders `AssistantSettingsModel`: saved profiles and
the active profile, a staged name/kind/base URL/model draft, key edit mode,
saved-key tier, typed save errors, and Test results/model suggestions. You
can add, select, rename and delete profiles, keep/replace/clear a key, Save,
or explicitly Test the draft. A stored key is never read back into a field;
the Linux file tier says "unencrypted" and the environment tier says
"read-only". The native secure field owns typed text and forwards it to the
model; it clears when the draft changes profile or a key edit is committed
or discarded. Model IDs remain editable after any listing failure. Views
show a loading state while the model reads the saved metadata off the UI
thread. Profile commands cannot overlap loading or a save/select/delete;
metadata/key inputs are disabled during load/select/delete and remain
editable during Save. Closing the settings model cancels its Test. Native
controls and composition follow in A13/A14; Core owns the behavior
independently of either front end.

Per OS:

- **macOS.** SwiftUI for windows and forms. AppKit for the NSPanel and native
  `NSTextField`/`NSTextView` search and fill inputs, because a SwiftUI `TextField` cannot
  reliably retake focus in a reused hosting view (Vervellum). Menu-bar
  agent (`LSUIElement`); the activation policy turns `.regular` only while
  Settings or Library is open.
  - **Settings…** in the status menu and **⌘,** open the same reusable
    General/Shortcuts window, including while Setup has focus. Shortcuts has
    **Open Setup…** to reopen the existing Setup screen.
    During shortcut capture, modified chords and Escape are consumed before
    menu dispatch. Tab, key repeats and bare modifier changes retain native
    handling; leaving the recorder stops capture. The Command-or-Control
    binding alias displays as **Cmd** on macOS.
  - A main menu is installed even while it is hidden: AppKit routes
    ⌘C/⌘V/⌘A/⌘Z through main-menu items, and without them those keys die
    silently in text fields (Vervellum).
- **Linux.** GTK4 through the shim:
  - `GtkListBox` with single selection for the picker
  - `GtkSearchEntry`, `GtkEntry`, `GtkComboBoxText`, `GtkTextView`
  - `GtkHeaderBar`, nested `GtkPaned` panes and `GtkStack` pages
  - Window and application actions for menus and accelerators

  Choose **Settings…** in the picker footer, press **Ctrl+,** in the picker,
  or use your launcher's desktop action to open or raise the reusable General
  and Shortcuts window. The picker dismisses before Settings opens, without
  delivery. Closing Settings hides it for the next opening. **Open Setup…**
  in Shortcuts opens the existing Setup window and shares its live service.

  The windows share the macOS structure with GNOME conventions (§24.6).
  The tray uses a StatusNotifierItem where available. The hotkey is the primary entry point, because stock GNOME
  hides tray icons.

  Linux attaches one StatusNotifierItem at resident startup, with left click and
  **Show Picker** toggling the picker, the shared library status row opening the
  Library window (§11.7) when available, and **Settings…**, **Setup…** and
  **Quit** actions.
  Without a tray watcher, the hotkey, desktop actions and picker Settings menu item
  remain the entry points.

  Linux's **Repeat Last Prompt** desktop action and repeat shortcut share the
  resident application's `repeat` action. Repeat uses the current target and
  preserves hidden picker drafts. It refuses repeat while any of the app's
  windows has focus, including the picker and fill form. Refusals and repeat
  persistence warnings appear in a reusable **Repeat last** window;
  review-required results offer **Open prompt…** through the existing Library
  editor. Shortcuts renders both
  actions' live bindings, verification, change instructions and errors.
  Repeat has no default key; GNOME/manual guidance uses the repeat command.

### 11.2 Picker and fill form

M2f supplies the Linux picker and fill view, bound to Core `PickerModel` and
`FillModel`. `LinuxEnvironment` composes the library, watcher, index, remembered
values and shared GTK clipboard. The default library is `MonkeysPaw` under the
XDG documents directory, falling back to `~/Documents/MonkeysPaw`. Search,
pointer selection, previews and all Linux keyboard bindings use model intents.
Fill controls remain in place during edits; plain Return in multiline controls
stays native, while the primary Deliver action and single-line Return retain
the mode chosen in the picker. Explicit Ctrl+Return selects standard paste.
Blur and toggling a focused panel off dismiss the entire panel and retain
session drafts. Toggling an unfocused panel raises it.

Before M3, Edit opens the prompt with the OS default file handler and Library
opens its folder. No-match creation sanitizes a single filename, probes a free
name through `LibraryService`, saves a minimal prompt and opens it for editing.
The assistant action stays disabled with its Settings hint. Library failures
show a banner; failed watcher batches attempt one full rescan before stopping,
and root loss retains the cached index. Delivery owns the panel hide. Delivery
persistence warnings stay visible in the next picker until another use starts.

M2h supplies the macOS picker and fill view over the same models. `AppDelegate`
composes the library, watcher, index, remembered values and shared pasteboard
clipboard, using `~/Documents/MonkeysPaw` and the bundle identifier's Application
Support directory. AppKit text and multiline controls retake focus whenever
the reusable panel appears; native focus changes and Tab follow model field
order. Choice controls display labels and render their associated values; descriptions sit
under their controls, and previews show Core validation messages. Return uses
the picker-selected mode outside multiline input; multiline Return stays a
newline, Cmd+Return selects standard paste and Option+Return copies. Escape
returns from fill to picker; blur, Cmd+W and toggling a key panel off dismiss
and keep drafts. Toggling a visible non-key panel raises it. The footer resolves
the captured pid to the remembered application's name without changing the
focus tracker's pid/bundle-id identity.
Typing after native result-list focus retakes search and continues the query.
Pending text focus retries when the panel becomes key after deferred activation;
removing the native view or withdrawing the focus request cancels that retry.
Printable keys on a focused native control keep its native behavior.

On both desktops, active input-method composition keeps keys in the focused
native text control. Return confirms conversion and Escape cancels composition
without using a prompt, delivering a form or dismissing the panel. GTK tracks
non-empty preedit per control; AppKit checks the first responder's marked text.
Edit/Library requests are consumed once before their handler runs. An invalid
edit path or unavailable library keeps the panel open with a status, preserving
the query and selection. Valid requests dismiss before launching. macOS
publishes the current view state before handling the request.

macOS installs the picker hook, arms FSEvents, then rebuilds. Scheduler updates
marshal through `MainThread`; a root preflight protects pending reloads after
physical root loss. Root health stops monitoring, shows the unavailable banner
and preserves cached prompts until restart. Before M3, Edit/Library launch the
file/folder's default handler after dismissing; no-match creation uses the shared
single-filename rules, preserves the exact query as its title and opens the
saved file. The assistant remains disabled with its Settings hint. Hosted tests
use temporary roots and a recording launcher, including a measured one-second
external-save deadline through real FSEvents. Their compile and execution proof
requires the `macos-app` CI job; hardware checks stay NOT RUN in
`docs/platform/macos.md`.

Both native pickers, General and Shortcuts Settings, onboarding/recovery,
Forget controls, Linux tray, the five-category conformance corpus and the
release workflow are merged. Owner-run platform checks, including the
[M12 release install rows](../platform/m12-acceptance.md#post-publication-phase-from-actual-v100),
remain open M2 work; the owner removed the historical v0.1.0 gate on
2026-10-19. The Library window, editor, history, import and tour
follow in M3.

```
┌ Monkey's Paw ─────────────────────────────────────────────────┐
│ [ rev                                                     ]   │
│ ★ Review a diff            code   │ Correctness-first review  │
│ ▸ Revise for tone          team   │ of a pasted diff.         │
│   Reverse-engineer a spec  code   │ Fields: language, diff    │
│───────────────────────────────────┴───────────────────────────│
│ ⏎ use · ⌘⏎ edit · ⌘L library · esc close   → Firefox · ✓ sync │
└───────────────────────────────────────────────────────────────┘

┌ Review a diff ────────────────────────────────────────────────┐
│ Language  [ Rust          ▾]                                  │
│ Diff      ┌──────────────────────────────────────────────┐    │
│           │ @@ -12,7 +12,9 @@ fn settle() …            │    │
│           └──────────────────────────────────────────────┘    │
│ ┌ Preview ─────────────────────────────────────────────────┐  │
│ │ You are a senior Rust engineer. Review this change. …    │  │
│ └──────────────────────────────────────────────────────────┘  │
│ ⏎ paste · ⌥⏎ copy only · esc back                             │
└───────────────────────────────────────────────────────────────┘
```

Footers differ per OS:

- Linux adds `Ctrl+Shift+⏎ terminal paste`.
- The paste target is the remembered app name on macOS and the session type
  on Linux.
- Group prompts show the group name in the list (`team` above).

### 11.3 Keyboard map

| Context | Key | Action |
|---|---|---|
| Global | hotkey | toggle picker |
| Global | repeat hotkey (unbound by default) | re-deliver the last prompt with the same values |
| Picker | type · `↑↓` · `Return` · `Esc` | filter · move · use · close |
| Picker | `⌘Return` / `Ctrl+Return` | edit the selection (Library editor from M3; before that, the OS default editor) |
| Picker | `⌘L` / `Ctrl+L` | open Library |
| Picker | `Ctrl+,` (Linux) | open Settings |
| Picker | `Ctrl+Shift+Return` (Linux) | use the selection with the terminal chord (a prompt with fields goes to the form first and remembers the choice) |
| Picker | `⌥Return` / `Alt+Return` | use the selection, copy only |
| Fill form | `Tab` / `Shift+Tab` | next / previous field |
| Fill form | `Return` (single-line field), `⌘/Ctrl+Return` (anywhere) | Return uses the mode selected in the picker; ⌘/Ctrl+Return uses the standard chord |
| Fill form | `Ctrl+Shift+Return` | deliver with the terminal chord (Linux) |
| Fill form | `⌥Return` / `Alt+Return` | copy only |
| Fill form | `Esc` | back to the picker |
| Library | `⌘/Ctrl+N` · `⌘/Ctrl+S` · `⇧⌘S`/`Ctrl+Shift+S` | new · save · duplicate (save as copy) |
| Library | `⌥⌘F` / `Ctrl+F` · `⌘F` (macOS) | search the library · find in the editor |
| Library | `⌘/Ctrl+D` · `⌘/Ctrl+1` · `⌘/Ctrl+2` · `⌘/Ctrl+3` | favourite · Edit form · Preview · Source |
| Library | `⌃⌘S` / `F9` · `⌥⌘I` (macOS) | sidebar · inspector (§24.4) |
| Editor | `⌘/Ctrl+R` · `⌘/Ctrl+I` | review · improve |

### 11.4 First run

1. Setup screen (§6.4).
2. Pick the library folder, or accept the default.
3. Optionally sign in to a sync server, or paste an invite link.
4. If the library is empty and no server is configured, copy about ten seed
   prompts from repository-root `seed/`, embedded in Core for both apps
   (§4.4). `SeedService.seedIfEmpty()` uses §5.1's prompt enumeration: root
   `README.md`, `.DS_Store`, non-Markdown and ignored files do not make a
   library non-empty; any eligible prompt does, even malformed content.
   It creates each catalog path exclusively and skips occupied destinations
   without replacing any bytes. This is a real first save, assigning fresh
   ULIDs and canonical front matter under §5.2; bodies remain byte-exact.

   - code review, commit message, explain an error, summarise, rewrite for
     tone, translate, critique a plan, write tests
   - a meta-prompt that drafts a prompt
   - extract action items; together they cover every field kind, both choice
     option forms, defaults, optional/remember semantics, implicit fields and
     clipboard/date/time builtins

   The result reports seeded and skipped-existing counts. Other failures use
   the library's typed, sanitized errors; paths and content are never logged.
   There is no batch transaction: a failure or crash after some creates leaves
   a non-empty library, so the next run seeds nothing and does not fill gaps.
   `OnboardingModel` offers seeds only when `SettingsModel.needsSeedOffer` is
   true, `LibraryService.entries()` is empty, the active graph is available,
   and an injected `hasConfiguredSyncServer` predicate returns false (it
   always does until M6 adds servers). Accepting or declining first calls `markSeedsOffered`; a failed record
   copies nothing and leaves the step pending. Accepting then invokes the
   active graph's `SeedService.seedIfEmpty()` through an injected service
   closure. `SeedSummary` counts and typed, sanitized `SeedFailure` values
   are presentation state. Once the offer is recorded the step is complete,
   even if copying then fails, so the offer never repeats after a restart.
   A later recovery folder step clears the shown result. A prompt arriving after
   the offer can make the service return zero for both counts.
5. New installs see a one-screen tour of the global hotkey, picker search,
   fill form (Tab, Return and Escape), and Copy versus Deliver. It follows
   the seed offer, whether accepted or declined, or the folder step when
   seeds are not offered. `OnboardingModel.completeTour()` handles both
   finishing and closing the tour. It persists `firstRun.tourCompleted`
   before publishing completion; a failed write leaves `.tour` pending with
   the typed settings error. A restart resumes the pending tour. Read-only
   settings and a library recovery session never show it.

Settings version 1 records `setupPresented`, `libraryFolderCompleted`,
`seedsOffered` and `tourCompleted` independently (§5.1). The optional
`tourCompleted` key defaults to `setupPresented` only when absent from an
existing file, marking upgrades from v0.1.0 done. Fresh defaults have an
explicit false value, preserved when Setup is presented; a present value
must be a boolean. Unknown keys still survive every rewrite. Accepting the
default folder completes the library step too. Composition supplies the legacy
M1 Setup fact from macOS `hasShownDeliverySetup` or Linux `<config>/setup-shown`
only when settings are missing: it marks Setup and the tour done in memory
for an existing install, leaves the library step pending, and is saved with
the next successful settings change. Folder changes, including
returning to the default, keep every first-run flag. `OnboardingModel` resumes
at the first incomplete eligible step: Setup presented, folder, seed offer,
then tour. Sync sign-in remains deferred to M6. Folder intents share
General's `LibraryLocationControl` composition exception (§4.2); validation,
graph replacement and folder persistence remain in composition. Only a
successful switch or a saved, already-active healthy folder permits
`completeLibraryFolderStep`. `settingsNotSaved`, invalid targets, delivery in
progress and unavailable graphs do not complete the step. Service closures
resolve the active graph at call time, so choosing another folder also changes
the seed eligibility check and copy destination. A read-only settings error
is surfaced by `SettingsModel` and `OnboardingModel`. While
settings are read-only, the model reports `needsSetupPresentation`,
`needsLibraryFolderStep`, `needsSeedOffer` and `needsTourPresentation` as false.
The UI shows the error instead of repeating onboarding that cannot persist
each launch. A failed completion does not claim durable progress.

Both desktops wire the shared settings model: macOS to the app-data
`settings.json`, Linux to its config root (§5.1). Each imports its legacy M1
Setup fact without completing the library step, and presenting Setup records
both settings progress and the legacy flag for downgrades. The composition
switch operation for the General and onboarding folder controls stores the
chosen absolute path, or null for the default, after the replacement graph
starts. It dismisses the picker, drops its session drafts and rebinds the
reused native panel; delivery in progress refuses a switch. A settings save
failure leaves the new folder active for this session with a settings error,
while the saved folder remains the choice for the next launch. Read-only
settings use the default library.

### 11.5 Error and empty states

| State | Behaviour |
|---|---|
| Library folder missing or unreadable at start | `LibraryStatusModel.unavailableAtStartup` requests one path-free notification per process through composition's `LibraryAvailabilityNotifier`. `OnboardingModel` reopens the library step for this session, without clearing the persisted completion flag; only a successful folder completion clears the recovery requirement. Read-only settings still suppress onboarding and show their error. The tray menu says "Library unavailable". |
| Folder disappears, becomes a non-directory or cannot be enumerated while running | Root unavailability as defined in §5.5 stops the watcher; the picker shows a banner and the index stays in memory read-only. `LibraryStatusModel.lostWhileRunning` changes the menu/tray label to "Library unavailable", with no startup notification or reopened folder step. Root loss emits no per-file deletions. Restoration of that folder requires a restart; only a switch to another folder (`LibraryStatusModel.libraryReplaced`) supersedes the status. |
| Save fails (permissions, disk full) | Typed error in the editor. The draft is kept; Retry is offered. |
| Watcher error or event overflow | One path-free warning per error/overflow streak, defined in §4.6. Each delivered native batch triggers one coalesced full rescan, idle-coalesced on Linux. Linux GIO hides inotify overflow (§4.6). |
| Picker: no matches | "No prompts match '<query>'" with actions: create a prompt titled `<query>`, write it with the assistant (once configured), open the library folder. Creation never replaces an existing file; it retries alternate names within a bounded limit and reports a typed error on exhaustion. |
| Picker: prompt has validation errors | The preview lists the issues and offers Edit. No delivery. |
| Fill form: `Esc` | Back to the picker. Typed values stay in memory for that prompt until delivery, an explicit forget action, a library switch or quit. |
| Panel loses focus (click elsewhere) | Hides after `BLUR_HIDE_MS = 300`, keeping typed values. No delivery and no refocus, because the user already chose a new target. |
| Delivery fell back to copy-only | Notification "Copied. Press Ctrl+V" (Cmd+V on macOS). A successful paste is silent. |
| Secret Service unreachable | The error names the ladder and offers the env-var or file tier. |
| Assistant not configured | Buttons disabled with "Set up a provider in Settings". |
| Sync: offline / server error | Footer shows "offline" or "sync error"; local use continues; backoff retries. |
| Sync: signed out (401) | Banner "Sign in again"; local changes stay queued. |
| Sync: conflicts exist | Footer badge; the Conflicts filter lists them. |
| Sync: errors | The footer says "sync errors". The list names each file and the reason (§9.6). |
| Sync: snapshot in progress | The footer says "resyncing…". Automatic. |
| Removed from a group | Notification: "You were removed from <group>; N local files were kept". |
| Path renamed by a clash | Silent. The prompt's history entry notes the rename. |

Composition retains one `OnboardingModel` so recovery survives closing its
window, and shares one `LibraryStatusModel`, updated from the active graph
alongside `PickerModel.libraryAvailable`. Menus, Settings and onboarding
subscribe independently with removable observer tokens; updates, notification
requests and onboarding publications use the injected `MainThread`, under both
inline and queued delivery. `OnboardingStrings` owns the shared path-free copy.

### 11.6 Accessibility and language

- **Accessibility.**
  - Native controls on both OSes carry accessibility labels.
  - VoiceOver works inside the non-activating NSPanel; this is checked
    explicitly.
  - AT-SPI on Linux comes from GTK.
  - Focus is always visible. Reduced motion is respected.
- **Language.** v1 is English only. User-visible strings live in one table
  per front end (`Strings.swift`) so extraction is mechanical later.

### 11.7 Library window (M3)

These defaults resolve §17 Q14–Q20; the owner may override them.

- **Browse.** A reusable window (macOS: `.regular` while open; Linux:
  hide-on-close) with a sidebar of All, Favourites, Recent, folders and tags, a
  list, and the selected prompt's editor. Core's `LibraryBrowserModel` owns
  these sections, counts, selection and text filter. Folder counts include
  descendants; tags and the filter use the picker's matching rules. Counts
  are independent of the text filter. Lists order by title and exact path
  bytes; Recent instead orders by the newest retained delivery or copy
  timestamp in the app-data usage store (§5.4), with the same tie-breaks and
  at most `Limits.libraryRecentCap = 100` entries before filtering. Using a
  prompt never writes its file. Selection follows assigned identity across
  renames, with exact path bytes disambiguating duplicate ids; an ambiguous
  identity clears the selection key. External deletion hides the row but keeps
  the remembered selection key, so a restored file can reopen; the editor's
  Delete command clears the key. Changing section or filter retains an
  existing selection even if its row is hidden, without choosing another
  prompt. Invalid and future-format entries remain visible with their state.
  Conflicts and groups join the sidebar with sync (M6).
  Toggling a favourite saves `favorite` (§5.2's file key) through the same
  service as the editor. If that prompt is open with unsaved edits, the
  toggle changes the editor's text instead, and the app's own saves refresh
  the editor's stamp, so they never trigger a conflict. The picker's Library
  control and the menu or tray open this window instead of the file manager.
  `LibraryBrowserModel` hands open-prompt favourite toggles to `EditorModel`:
  dirty buffers stay unsaved, while clean buffers save through the editor's
  session. Unrelated prompts retain the `PromptFavoriteEditing` port.
  With sync, group sections are keyed by group ID and show the committed name
  and role badge. Group favourites use the account-bound personal overlay,
  including for viewers and dirty open editors. The toggle never edits their
  source, mode or history; sidebar counts and picker ranking refresh from the
  same effective value. Private-scope favourites keep the file-key behavior.
- **New prompt.** The toolbar's New Prompt item and ⌘/Ctrl+N (also File →
  New Prompt… on macOS) ask for a title, initially selected as `New prompt`.
  The dialog names the destination captured from the sidebar: the selected
  folder or editable group's `Groups/<folder>`, otherwise the library root,
  including for viewer groups. An external reload or conflict temporarily
  replaces the dialog; resuming it keeps the entered title and destination.
  Create keeps the exact title, using
  `New prompt` for blank input, then asks Save/Don't Save/Cancel for an open
  dirty draft before writing. Cancelling either dialog writes nothing.
  Creation uses the usual exclusive filename and collision suffix rules,
  clears the filter, and opens Edit in the same window with the new prompt
  selected and the editor focused; keep the containing sidebar section,
  otherwise select All. Both desktop creation entry points notify sync
  through its save debounce without waiting for a filesystem event.
- **Search.** ⌥⌘F on macOS and Ctrl+F on Linux focus the Library filter
  without changing the query, selection or editor draft. macOS ⌘F finds
  text in the visible editor. Native dialogs and input-method composition
  retain keyboard ownership.
- **Edit · Preview · Fields · History.** Edit and Preview are the editor's
  modes; Fields, History and the Assistant are inspector panes (§24.3).
  Edit defaults to a form: title, description, individual tags, a Private
  toggle and a separate prompt-body editor. Source is an alternative mode
  (⌘/Ctrl+3) for the complete file and custom metadata. Placeholder settings
  in the visual form edit type, label, description, an optional default,
  choice labels/values, optional and remember. Implicit placeholders become
  declarations only after a setting changes. Settings are staged with Apply
  and Cancel; Apply updates the draft, not the file. Choice settings require
  an option and a matching default when enabled. Builtins have no settings.
  Android exposes the same controls in Fields. Both modes share one draft, explicit Save, validation,
  history and conflict handling. Switching modes never writes or normalizes
  the draft. Form edits retain IDs, optional-key presence, field declarations
  and unknown metadata; body-only edits retain the original header bytes.
  Malformed headers fall back to Source with an explanation. Invalid body
  placeholders stay editable in the form. Unknown declaration and option keys
  survive setting edits; retained options keep their metadata when reordered
  or removed. Malformed/future headers remain inspectable, with settings disabled.
  Preview renders with
  field defaults (or the field name when there is none), the real date and
  time, and a `{clipboard}` placeholder; browsing or typing never reads the
  clipboard. Non-UTF-8, oversized and future-format files open read-only.
  `EditorModel`'s History state lists revisions newest first with timestamp,
  byte size and valid/forensic status. `loadHistory()` refreshes the list;
  `selectRevision(_:)` shows a read-only source preview. `restore(_:)` runs
  through `PromptEditingService` with the editor stamp, opens the same conflict
  on a stale stamp, and reloads the editor and history after success (§5.5).
  Forensic and future-format revisions stay visible and return their typed
  restore-refusal reason; non-UTF-8 or oversized sources have no text preview.
- **Saving and conflicts.** Saves pass the editor's load stamp. The editor
  loads and saves through Core's `PromptEditingService`; file and codec work
  runs off the UI thread, and session-tagged typed completions and external
  changes return through `MainThread`. Retiring a session or library graph
  drops late state replies. `EditorModel` completes each file-command caller
  exactly once through `MainThread`, with `inactive` on model retirement or
  release. A committed history-maintenance warning carries the
  saved entry and stamp, so the editor can clear dirty state and show the
  warning without retrying the write. If the file
  changes on disk while you have unsaved edits, the conflict dialog opens at
  once: keep mine (save over theirs), take theirs (reload), or save mine as
  a copy. A deletion on disk offers keep mine (recreate), save mine as a
  copy, or discard. Ordinary personal-file copies take an alternate name beside
  the original. Committed sync changes are tagged: dirty text survives remote
  rename, deletion and overwrite without automatic saving. Its explicit copy
  goes to private `Conflicts/` with a fresh ID and typed origin (§9.6), as does
  a group editor's copy. A sync deletion cannot recreate the retired identity.
  A role downgrade or removal disables original mutations and Assistant
  acceptance while retaining the draft and private-copy action (§20 E30/E36).
  A stale save opens the same dialog. Without unsaved
  edits the editor reloads silently. If an external writer replaces a newly
  created copy before verification, the editor reports a copy failure and
  keeps the original session, draft, conflict and pending decision. The app
  never merges.
- **Unsaved edits.** Creating a new prompt, changing selection, closing the
  window, renaming, moving, deleting, reverting, or quitting asks Save /
  Discard / Cancel. Core's `EditorModel` publishes a tokenized pending
  decision for these discard requests; the view resolves it, and file-command
  callers proceed only after an allowed result through `MainThread`.
  Requests queue in order while a save is in flight, and a failed save or a
  newer draft retains the decision. Both desktops refuse a library switch
  while the editor has unsaved edits, a save or file command in flight, a
  pending decision or queued actions. Settings shows an editor-specific
  message and keeps the active library. An allowed switch retires the session.
  History restore uses the revert guard. `EditorModel`'s file commands perform
  their writes only after the guard allows them. Open-prompt, close and revert
  requests issued during a command queue in order and act after it completes.
  A queued command cannot act on a different editor session.
- **Rename, move, delete.** `EditorModel.rename(to:)` edits the filename;
  the title stays in front matter. `move(to:)` targets an existing or new
  folder, creating intermediate folders; an empty folder path targets the root.
  These commands and `delete()` use `PromptEditingService`, the editor's load
  stamp and typed outcomes. An occupied destination is refused, never replaced;
  stale stamps open the same conflict, and read-only formats are refused.
  A change detected after the physical move keeps the editor at the
  destination; keep mine, take theirs or recreation applies to that path.
  Keyed values, usage and history follow §5.2's identity migration.
  `LibraryBrowserModel` follows the committed rename/move or Save as Copy
  adoption only while that editor prompt remains selected, including an
  unassigned path-hash move (§5.2). A committed editor Delete command explicitly
  clears that key, closes the editor and keeps its history; restoring a
  deleted prompt arrives later. Window close and Cmd+W retain the browser
  selection, filter and section for reopening. Escape clears a focused
  search field but never closes the window (§24.3). External deletion
  also retains the selection key, including after discarding a deleted draft;
  a missing row has no selected preview, and restoration can recover the
  retained selection. Closing an editor with no prompt is not a Delete signal.
- **Import.** Drop or choose `.md`, `.prompt` (Dotprompt) or `.prompty`
  files or a folder. `string` inputs map to text fields, `string` with an
  enum to choice fields, and defaults/descriptions are kept; Prompty sample
  values supply absent defaults. Everything else is preserved as metadata
  and listed in the report (§5.5). Core's `ImportModel` accepts chooser/drop
  paths through file/folder intents and exposes progress and the final
  per-file report. Imports land in `Imported/` or a chosen subfolder,
  preserve folder-relative structure, use exclusive creation with alternate
  names, assign fresh ids when an id is already taken, and never overwrite.
  Symlinks are not followed; size, encoding and individual-file failures
  appear as typed skips while successful imports remain available.
- **Tour.** New installs see a one-screen tour of the picker and fill form
  right after accepting or declining seeds, or after the folder step when
  seeds are not offered. `firstRun.tourCompleted` is an optional version-1
  settings flag. Fresh installs start false; an older settings file without
  it infers completion from `setupPresented`, so upgrades from v0.1.0 are
  marked done. Closing counts as done through `completeTour()`, which saves
  the flag before publishing completion. A write failure keeps the tour
  pending with the typed settings error, and a restart resumes it. Read-only
  settings skip the tour. Library recovery suppresses it for the session,
  without consuming a pending flag.
