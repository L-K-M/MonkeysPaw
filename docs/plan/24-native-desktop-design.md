## 24. Native desktop design

The desktop apps follow each platform's conventions: the macOS app behaves
like a Mac app an experienced user already knows, and the Linux app applies
the same structure with GNOME conventions. This section records the design;
§11 keeps the behavioural contract it builds on.

### 24.1 Reference apps

| Surface | Mac reference | Why it fits |
|---|---|---|
| Picker panel | Spotlight, Raycast | A transient, keyboard-first panel over any app: one search field, a result list, a preview, key hints instead of buttons. |
| Library window | Notes, Mail | A shoebox library of many small text items: sidebar of collections, folders and tags; an item list; an editor. Search filters the list. |
| Inspector | Pages, Keynote, Xcode | Information about the selected prompt (fields, history, assistant) beside the content, toggled without resizing the window. |
| Settings | Mail, Safari | Toolbar tabs with symbols, a fixed-width window titled after the pane, grouped forms. |
| Menu bar extra | Apple's menu extras | The primary action first with its shortcut, then windows, Settings, Quit. |

The library is a folder of prompt files, not a set of independent
documents. It therefore uses one Library window, like Notes or Music,
rather than one `NSDocument` window per prompt. `EditorModel` owns one
editing session with its draft guard, conflict and sync handling (§11.7);
several simultaneous editors would multiply those states without a clear
benefit.

### 24.2 Document lifecycle

Saving stays explicit. Each save is a history revision, a sync upload and a
conflict boundary (§5.5, §9), so autosaving keystrokes would flood history
and sync. The Library window shows the standard edited state instead: the
close button's dot, an "Edited" subtitle, File ▸ Save (⌘S), Duplicate
(⇧⌘S, the existing Save as Copy) and Revert to Saved. Closing, switching
prompts, renaming, moving, deleting and quitting with unsaved edits use the
standard Mac alert: "Do you want to save the changes you made to “Title”?",
"Your changes will be lost if you don't save them.", Save, Don't Save,
Cancel. Revert asks "Revert to the saved version of “Title”?" with Revert
and Cancel. Window restoration at login stays off: a menu bar agent should
not open windows by itself. The Library window remembers its frame, split
positions, inspector state and toolbar configuration.

### 24.3 Library window

The example shows Source; Edit opens the properties form and body editor.

```
┌ ● ● ●  [⊞]          │ Review a diff               [Edit│Preview]  ☆  ✦  [⌕ Search ] │ ⓘ ┐
│                     │ code/review-a-diff.md — Edited                                   │   │
├─────────────────────┼───────────────────────┬──────────────────────────────┬──────────────┤
│ Library             │ ★ Review a diff       │ ---                          │ Fields  ⌚  ✦ │
│   ▤ All Prompts  10 │   Correctness-first…  │ title: Review a diff         │ language     │
│   ☆ Favourites    1 │   Revise for tone     │ fields:                      │  Choice      │
│   ◷ Recent        3 │   Rewrite a draft …   │   language: …                │ diff         │
│ Folders             │                       │ ---                          │  Multiline   │
│   ▸ ▢ code        4 │                       │ You are a senior {{language}}│              │
│   ▢ writing       5 │                       │ engineer …                   │              │
│ Tags                │                       ├──────────────────────────────┤              │
│   # review        2 │                       │ ✓ Valid      Saved           │              │
│ ⟳ Sync off          │                       │                              │              │
└─────────────────────┴───────────────────────┴──────────────────────────────┴──────────────┘
```

- **Structure.** An `NSSplitViewController` with a sidebar, a content list,
  the editor and an inspector (`NSSplitViewItem` sidebar, content-list and
  inspector behaviours). Panes collapse instead of widening the window.
  At compact widths the sidebar yields to the inspector, then returns when
  space permits or the inspector closes. An explicit sidebar choice takes
  precedence over that automatic restoration.
- **Toolbar.** A unified, customizable `NSToolbar` with tracking separators:
  sidebar toggle; New Prompt in the list column; an Edit/Preview/Source segmented
  control, Favourite and Assistant in the editor column; a search field
  that filters the list; the inspector toggle. Commands that act on the
  selected prompt live in menus and the list's context menu, not in rows
  of push buttons. The window title is the open prompt's title and the
  subtitle its path, or the section name and prompt count when nothing is
  open. The proxy icon represents the open prompt file.
- **Sidebar.** A source list with symbols and count badges: Library (All
  Prompts, Favourites, Recent, Conflicts), Groups, Folders (a collapsible
  folder tree), Tags. Sync status sits at the sidebar's foot.
- **List.** A native table: title, one secondary line (description, or
  folder and tags), a favourite star, and symbols for read-only, invalid
  and group prompts. It supports type-select, arrow keys, Return to edit,
  Delete to delete, a context menu and dragging a prompt onto a sidebar
  folder or group. Opening a prompt follows the click's release, so a drag
  never raises the unsaved-edits alert first.
- **Editor.** Edit shows labelled title, description, tag and privacy
  controls above a body-only text view. The title stays visible; description,
  tags and privacy use a collapsible Details section, also available from View.
  Placeholder settings live in the Fields inspector, reachable directly from
  the editor's placeholder count. Source retains the complete file in
  a monospaced text view; both text views keep native Find, undo and highlighted
   `{{placeholders}}`. Placeholder rows open settings without editing YAML.
   Source also edits advanced metadata and declarations.
  Preview renders the body. A slim status bar below shows validation (with an expandable
  issue list) and the save state. A sync conflict shows a bar above the
  editor with Keep Server, Keep Mine, Keep Both and an expandable
  comparison.
- **Inspector.** Fields (the parsed fields and prompt details), History
  (revisions, preview, Restore) and Assistant, chosen with a segmented
  control at its top. On macOS, Assistant has two current-prompt tabs:
  **Review & Improve** and **Improve Directly**. Review returns selectable
  findings followed by optional instructions and **Improve selected findings**.
  Direct improvement needs only an instruction; its action is **Generate
  improvements**. Switching tabs preserves instructions, selected findings and
  the candidate. Either improvement action opens a separate, resizable desktop
  window immediately. Its header names the prompt and echoes the instruction
  and selected findings. Generating and preparing the diff each show one
  centered status. A fixed bar keeps the provider footer, retry feedback,
  Reject and prominent Accept (⌘↩) visible; Show diff appears only for a stale
  or missing diff. Invalid results show the returned draft below their errors.
  **Open improvement…** in the inspector returns to that window. Diff columns
  share the available width and wrap long lines, including long tokens;
  wrapping preserves the source bytes, line numbers and newline markers.
  Cancel while generating or preparing, Reject, Close and a committed save end
  the improvement and close its window; the save outcome remains in the Library
  status line. Cancel while saving withdraws only a queued acceptance and keeps
  the improvement open; an executing save reports its actual outcome. Failures
  and conflicts keep it open; Escape leaves it open. Closing the window cancels
  its request/draft; editor-session or library retirement closes it. An
  acceptance must finish or be cancelled through its editor guard before the
  window closes; its close button is disabled meanwhile.
- **Assistant creation (macOS).** File and the toolbar's **New Prompt** menu
  offer **Blank Prompt…** (⌘N) and **Generate with Assistant…**. Generation
  opens a separate sheet with a brief, candidate and diff; it sends no current
  prompt text. Its own Assistant session preserves the current prompt's review,
  instructions and candidate when generation opens or closes. It uses §7.3's
  existing creation destination and acceptance contract. Unsaved-edit and
  conflict sheets temporarily replace the generation sheet without losing its
  draft. A changed guard snapshot requires a fresh diff before acceptance.
  Closing cancels it; switching editor
  sessions or libraries retires it. Linux and Android retain their existing
  Assistant navigation; request, prompt and acceptance semantics are unchanged.
- **Empty and error states.** Centered placeholder text in the list and
  editor; library unavailability, import progress and import reports use
  bars and sheets rather than permanent rows.
- **Escape** clears the search field when it has focus and dismisses sheets
  and popovers. It no longer closes the window; ⌘W does.
- **Search navigation.** Down/Up from toolbar Search selects a result without
  clearing the query. Return edits the selected result, or the first result
  when none is selected. A queued save/open retains that focus request until
  the prompt loads; further search or navigation cancels it. Input-method
  composition keeps these keys until conversion finishes. Empty-result
  transitions preserve the active search editor and composition ownership.
- **Dock reopening.** With a regular window visible, reopening raises that
  window. With only minimized windows, it restores Library or Settings. The
  picker opens only when there is no regular window to resume.
- **Save feedback.** A compact Save control beside validation and draft status
  makes explicit saving discoverable without adding a permanent button row.
- **Undo boundaries.** Initial and external loads establish native text baselines;
  they are never undoable replacements of an empty buffer. Typing, save
  normalization and draft edits retain native undo. A successful Forget resets
  live picker controls, composition and undo together, even when reset values
  equal the previous render. A failed Forget preserves them.

### 24.4 Menus (macOS)

| Menu | Items |
|---|---|
| Monkey's Paw | About, Check for Updates…, Settings… ⌘,, Services, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q |
| File | New Prompt ▸ (Blank Prompt… ⌘N, Generate with Assistant…), Import… ⇧⌘I, Close ⌘W, Save ⌘S, Duplicate ⇧⌘S, Rename…, Move To ▸, Revert to Saved, Show in Finder, Delete… |
| Edit | Undo/Redo (named by the text system), Cut, Copy, Paste, Paste and Match Style, Delete, Select All, Find ▸ (Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for Find ⌘E, Search Library ⌥⌘F), Spelling and Grammar ▸ |
| View | Edit ⌘1, Preview ⌘2, Source ⌘3, Show/Hide Prompt Details, Show/Hide Sidebar ⌃⌘S, Show/Hide Inspector ⌥⌘I, Fields, History, Assistant ⇧⌘A, Show/Hide Toolbar, Customize Toolbar…, Enter Full Screen |
| Prompt | Add to/Remove from Favourites ⌘D, Review with Assistant ⌘R, Improve with Assistant ⌘I |
| Window | Minimize ⌘M, Zoom, Library ⌘L, Bring All to Front, window list |
| Help | Monkey's Paw Help |

Menu items use the responder chain: text commands reach the focused text
view, and Library commands validate against the key window, so items are
enabled only when they would act. The menu bar appears while a regular
window is open (`LSUIElement`, §11.1). Favourite moves from ⇧⌘F to ⌘D,
matching Safari's bookmark command and Linux's Ctrl+D.

The status item menu lists Show Picker with the global shortcut, Repeat
Last Prompt, Library, Settings… ⌘,, Setup…, About and Quit.
Its template icon is the paw silhouette in `media-sources/paw-symbol.svg`.
`python3 scripts/generate-paw-icon.py` derives the macOS vector and Android
tile and Android 13+ themed-icon assets from that source. Launcher shortcuts
use the full-color paw app icon for contrast on light and dark menus.

### 24.5 Settings, picker and other windows

- **Settings** is an `NSTabViewController` with toolbar tabs: General,
  Shortcuts, Delivery, Assistant, Account. The window is not resizable,
  is titled after the pane, resizes its height within the screen's visible
  frame and remembers the last pane. Panes are grouped forms with labelled
  rows and section footers for explanations.
- **Picker.** A rounded panel with the system popover material, a large
  borderless search field with a magnifying-glass symbol, result rows with
  a symbol, title and folder/tags, the preview, and a footer bar with the
  paste target, sync state and key caps for Return, ⌥Return, ⌘Return and
  ⌘L. The fill form uses labelled rows and a default Deliver button.
- **Setup, onboarding and Repeat** use the welcome-window pattern: symbol,
  title, short explanation, status rows with symbols, a default button.
- **Visual rules.** System fonts and semantic colours only; SF Symbols for
  state (never colour alone); standard spacing; light, dark and increased
  contrast checked; Reduce Motion disables animated transitions.

### 24.6 Linux

The GTK app uses the same structure with GNOME conventions (GTK 4, no
libadwaita dependency):

- **Library.** A `GtkHeaderBar` with the sidebar toggle and New on the
  left, the title and path as a two-line title, and Edit/Preview/Source,
  Favourite, Search, Inspector and a primary menu on the right. A search
  bar (Ctrl+F) filters the list. Nested `GtkPaned` panes hold the sidebar
  (`navigation-sidebar`), the list, the editor with its status bar, and the
  inspector stack (Fields, History, Assistant).
- **Menus.** The primary menu holds New Prompt, Import, Show in Files,
  Rename, Move, Duplicate, Revert, Delete, Settings, Keyboard Shortcuts and
  About. Application accelerators mirror macOS with Ctrl: Ctrl+N, Ctrl+S,
  Ctrl+Shift+S, Ctrl+F, Ctrl+D, Ctrl+1/2/3, F9 (sidebar), Ctrl+W, Ctrl+Q,
  Ctrl+, and F2 (rename); Delete in the list deletes.
- **Settings.** A header bar with a stack switcher for the same five
  panes; each pane is a clamped column of `boxed-list` rows.
- **Picker.** An undecorated rounded window with a search entry, result
  rows with icons, the preview and a footer of key hints; no button row.
