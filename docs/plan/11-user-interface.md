## 11. User interface

### 11.1 Windows (both front ends)

| Window | Content |
|---|---|
| Picker panel (hidden at start, `PANEL_SIZE = 640×420`) | search field, result list, preview pane, footer with key hints, the paste target, and sync status |
| Fill form (same panel, next state) | one control per field, live preview, Deliver / Copy / Cancel |
| Library (menu bar or tray → "Library…", or `⌘L` / `Ctrl+L` in the picker) | sidebar: All, Favourites, Recent, Conflicts, folders, groups, tags; list; editor with tabs Edit · Preview · Fields · History |
| Assistant (panel inside Library) | write from a description, review findings, improve diff |
| Settings | General · Shortcuts · Delivery · Assistant · Account (sign in, devices, groups, members, invites) |
| Setup | §6.4 |

M2 Settings contains **General · Shortcuts**; the other tabs follow their
milestones. Shortcuts renders the shared `ShortcutsSettingsModel`: the current
toggle-picker binding (or unknown/unbound), registration mechanism and status,
backend conflict/failure detail, and a **Press your shortcut now** verification
intent. macOS Carbon offers in-app rebinding. Linux offers the applicable
system settings action, explicit Setup action, or desktop/manual instructions
described in §6.1. Opening settings or completing a change request never turns
verification green. Repeat last prompt is displayed unbound, inactive and
unavailable for configuration until M7. Core supplies this contract
independently of the later native windows.

Settings → General shows your active library folder, whether it is the default,
and any read-only settings or library-switch error. You can choose another
folder, return to the default, or reveal the active folder in your file manager.
Views call `GeneralSettingsModel`; its `LibraryLocationControl` port delegates
graph replacement and folder reveal to the platform composition root.
General also offers **Forget all values** with confirmation through
`RememberedValuesSettingsModel`, including while the picker panel is closed.

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
  - `GtkEntry`, `GtkComboBoxText`, `GtkTextView`
  - `GtkNotebook` for tabs
  - `GtkApplication` actions for menus

  Choose **Settings…** in the picker footer, press **Ctrl+,** in the picker,
  or use your launcher's desktop action to open or raise the reusable General
  and Shortcuts window. The picker dismisses before Settings opens, without
  delivery. Closing Settings hides it for the next opening. **Open Setup…**
  in Shortcuts opens the existing Setup window and shares its live service.

  Plainer than macOS by design. The tray uses a StatusNotifierItem where
  available. The hotkey is the primary entry point, because stock GNOME
  hides tray icons.

  Linux attaches one StatusNotifierItem at resident startup, with left click and
  **Show Picker** toggling the picker, the shared library status row opening the
  folder when available, and **Settings…**, **Setup…** and **Quit** actions.
  Without a tray watcher, the hotkey, desktop actions and picker Settings button
  remain the entry points.

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

Both native pickers, the five-category conformance corpus and the release
workflow are merged. Native Settings, onboarding/recovery, Forget controls,
Linux tray, the v0.1.0 tag and owner-run platform checks remain open M2 work.

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
| Library | `⌘/Ctrl+N` · `⌘/Ctrl+S` · `⌘/Ctrl+F` | new · save · search |
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
5. A one-screen tour of the picker and fill form.

Settings version 1 records `setupPresented`, `libraryFolderCompleted` and
`seedsOffered` independently (§5.1). Accepting the default folder completes the
library step too. Composition supplies the legacy M1 Setup fact from macOS
`hasShownDeliverySetup` or Linux `<config>/setup-shown` only when settings are
missing: it marks Setup presented in memory, leaves the library step pending,
and is saved with the next successful settings change. Folder changes, including
returning to the default, keep every first-run flag. `OnboardingModel` resumes
at the first incomplete eligible step: Setup presented, folder, then seed offer.
Sync sign-in and the tour remain deferred to M6 and M3. Folder intents share
General's `LibraryLocationControl` composition exception (§4.2); validation,
graph replacement and folder persistence remain in composition. Only a
successful switch or a saved, already-active healthy folder permits
`completeLibraryFolderStep`. `settingsNotSaved`, invalid targets, delivery in
progress and unavailable graphs do not complete the step. Service closures
resolve the active graph at call time, so choosing another folder also changes
the seed eligibility check and copy destination. A read-only settings error
is surfaced by `SettingsModel` and `OnboardingModel`. While
settings are read-only, the model reports `needsSetupPresentation`,
`needsLibraryFolderStep` and `needsSeedOffer` as false. The UI shows the error
instead of repeating onboarding that cannot persist each launch. A failed
completion does not claim durable progress.

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
  list, and the selected prompt's editor. Recent orders by the last delivery
  or copy recorded in the app-data usage store (§5.4); using a prompt never
  writes its file. Conflicts and groups join the sidebar with sync (M6).
  Toggling a favourite saves `favourite` in front matter through the same
  service as the editor. If that prompt is open with unsaved edits, the
  toggle changes the editor's text instead, and the app's own saves refresh
  the editor's stamp, so they never trigger a conflict. The picker's Library
  control and the menu or tray open this window instead of the file manager.
- **Edit · Preview · Fields · History.** Edit shows the raw file, front
  matter and body, with live validation from the same codec and validator as
  the picker. Fields lists the parsed fields read-only. Preview renders with
  field defaults (or the field name when there is none), the real date and
  time, and a `{clipboard}` placeholder; browsing or typing never reads the
  clipboard. Non-UTF-8, oversized and future-format files open read-only.
  History lists revisions newest first with restore (§5.5).
- **Saving and conflicts.** Saves pass the editor's load stamp. If the file
  changes on disk while you have unsaved edits, the conflict dialog opens at
  once: keep mine (save over theirs), take theirs (reload), or save mine as
  a copy. A deletion on disk offers keep mine (recreate), save mine as a
  copy, or discard. A stale save opens the same dialog. Without unsaved
  edits the editor reloads silently. The app never merges.
- **Unsaved edits.** Changing selection, closing the window, renaming,
  moving, deleting, or quitting asks Save / Discard / Cancel. A library
  switch from Settings is refused with a message while an edit is unsaved.
  Intents wait for a save in flight to finish.
- **Rename, move, delete.** Rename edits the filename; the title stays in
  front matter. Move targets an existing or new folder. An occupied
  destination is refused, never replaced. Delete removes the file and keeps
  its history; restoring a deleted prompt arrives later.
- **Import.** Drop or choose `.md`, `.prompt` (Dotprompt) or `.prompty`
  files or a folder. `string` inputs map to text fields, `string` with an
  enum to choice fields, and defaults are kept; everything else is preserved
  as metadata and listed in the report. Imports land in `Imported/`, use
  exclusive creation with alternate names, assign fresh ids when an id is
  already taken, and never overwrite.
- **Tour.** New installs see a one-screen tour of the picker and fill form
  right after the seed step. Closing it counts as done. Upgrades from v0.1.0
  are marked done.
