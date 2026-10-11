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

Per OS:

- **macOS.** SwiftUI for windows and forms. AppKit for the NSPanel and an
  `NSTextView`-backed composer, because a SwiftUI `TextField` cannot
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

The macOS picker slice, the settings/seeds/first-run slice (including
library-folder setup), and the fixtures and release slice remain outstanding M2
work. Real compositor and paste-target checks remain owner-run in
`docs/platform/linux.md`.

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
   prompts from `seed/`:
   - code review, commit message, explain an error, summarise, rewrite for
     tone, translate, critique a plan, write tests
   - a meta-prompt that drafts a prompt
   - together they cover every field type
5. A one-screen tour of the picker and fill form.

### 11.5 Error and empty states

| State | Behaviour |
|---|---|
| Library folder missing or unreadable at start | Notification. The library step of first run reopens. The tray menu says "Library unavailable". |
| Folder disappears, becomes a non-directory or cannot be enumerated while running | An ordered root-health signal stops the watcher; the picker shows a banner and the index stays in memory read-only. Root loss emits no per-file deletions. Restoration requires a restart. |
| Save fails (permissions, disk full) | Typed error in the editor. The draft is kept; Retry is offered. |
| Watcher error or event overflow | Full rescan; one path-free warning per error/overflow streak. Linux GIO hides inotify overflow; every delivered batch still rescans the complete tree (§4.6). |
| Picker: no matches | "No prompts match '<query>'" with actions: create a prompt titled `<query>`, write it with the assistant (once configured), open the library folder. |
| Picker: prompt has validation errors | The preview lists the issues and offers Edit. No delivery. |
| Fill form: `Esc` | Back to the picker. Typed values stay in memory for that prompt until delivery or quit. |
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
