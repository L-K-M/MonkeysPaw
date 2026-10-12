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

Per OS:

- **macOS.** SwiftUI for windows and forms. AppKit for the NSPanel and native
  `NSTextField`/`NSTextView` search and fill inputs, because a SwiftUI `TextField` cannot
  reliably retake focus in a reused hosting view (Vervellum). Menu-bar
  agent (`LSUIElement`); the activation policy turns `.regular` only while
  Settings or Library is open.
  - A main menu is installed even though it never shows: AppKit routes
    ⌘C/⌘V/⌘A/⌘Z through main-menu items, and without them those keys die
    silently in text fields (Vervellum).
- **Linux.** GTK4 through the shim:
  - `GtkListBox` with single selection for the picker
  - `GtkEntry`, `GtkComboBoxText`, `GtkTextView`
  - `GtkNotebook` for tabs
  - `GtkApplication` actions for menus

  Plainer than macOS by design. The tray uses a StatusNotifierItem where
  available. The hotkey is the primary entry point, because stock GNOME
  hides tray icons.

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

The settings/seeds/first-run slice (including library-folder setup) and the
fixtures and release slice remain outstanding M2 work. Real compositor and
paste-target checks remain owner-run in `docs/platform/linux.md`.

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
   Settings records "seeds offered" separately; onboarding owns the no-server
   condition and when to offer seeds.
5. A one-screen tour of the picker and fill form.

Settings version 1 records `setupPresented`, `libraryFolderCompleted` and
`seedsOffered` independently (§5.1). Accepting the default folder completes the
library step too. Composition supplies the legacy M1 Setup fact from macOS
`hasShownDeliverySetup` or Linux `<config>/setup-shown` only when settings are
missing: it marks Setup presented in memory, leaves the library step pending,
and is saved with the next successful settings change. Folder changes, including
returning to the default, keep every first-run flag. The later seeding slice must
record the offer successfully before copying seeds, so it cannot repeat after a
restart. A read-only settings error is surfaced by `SettingsModel`. While
settings are read-only, the model reports `needsSetupPresentation`,
`needsLibraryFolderStep` and `needsSeedOffer` as false. The UI shows the error
instead of repeating onboarding that cannot persist each launch. A failed
completion does not claim durable progress.

Linux now wires the shared settings model to its config root and imports the
legacy marker without completing the library step. Presenting Setup records
both settings progress and the legacy marker for downgrade compatibility.
The composition operation for later General/onboarding folder controls stores
the chosen absolute path in `settings.json`, or null for the default, after the
replacement graph starts (§5.1). It dismisses the picker, drops its session
drafts and rebinds the existing native panel. Delivery in progress refuses a
switch. A settings save failure leaves the selected library active for the
session and exposes the error without claiming persistence. Read-only settings
use the default library. Folder controls and seed onboarding remain later work.

### 11.5 Error and empty states

| State | Behaviour |
|---|---|
| Library folder missing or unreadable at start | Notification. The library step of first run reopens. The tray menu says "Library unavailable". |
| Folder disappears, becomes a non-directory or cannot be enumerated while running | Root unavailability as defined in §5.5 stops the watcher; the picker shows a banner and the index stays in memory read-only. The menu/tray shows the startup row's "Library unavailable" state once the settings slice adds it. Root loss emits no per-file deletions. Restoration requires a restart. |
| Save fails (permissions, disk full) | Typed error in the editor. The draft is kept; Retry is offered. |
| Watcher error or event overflow | One path-free warning per error/overflow streak, defined in §4.6. Each delivered native batch triggers one coalesced full rescan, idle-coalesced on Linux. Linux GIO hides inotify overflow (§4.6). |
| Picker: no matches | "No prompts match '<query>'" with actions: create a prompt titled `<query>`, write it with the assistant (once configured), open the library folder. |
| Picker: prompt has validation errors | The preview lists the issues and offers Edit. No delivery. |
| Fill form: `Esc` | Back to the picker. Typed values stay in memory for that prompt until delivery, an explicit forget action or quit. |
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

### 11.6 Accessibility and language

- **Accessibility.**
  - Native controls on both OSes carry accessibility labels.
  - VoiceOver works inside the non-activating NSPanel; this is checked
    explicitly.
  - AT-SPI on Linux comes from GTK.
  - Focus is always visible. Reduced motion is respected.
- **Language.** v1 is English only. User-visible strings live in one table
  per front end (`Strings.swift`) so extraction is mechanical later.
