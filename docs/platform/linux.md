# Linux picker and delivery checks

## Library import (M3, NOT RUN)

- Commit / artifact / GTK version / desktop / compositor:
- Date / tester / isolated library and XDG directories:

Use disposable sources and a library with an existing `Imported/example.md`.
Automated tests exercise GTK 4.8 chooser responses and the actual GdkFileList
drop signal under Xvfb and a private bus. Real file-manager drag data, native
chooser presentation and accessibility still need these owner checks.

| Check | Expected result | Status |
|---|---|---|
| Native file selection | Library's Import… opens a modal native file chooser. Select several lowercase `.md`, `.prompt`, `.prompty` files. The destination defaults to `Imported/`; prompts appear without changing the sources or replacing an occupied library path. | NOT RUN |
| Native folder selection | Import folder… opens the native folder chooser and accepts the selected folder. Import its nested files without adding the selected folder's basename. GTK 4.8 uses a separate folder action because file-open mode does not accept folders. | NOT RUN |
| File-manager drops | On GNOME and KDE, drop files, a folder, then mixed files/folders onto the Library prompt list, including names with spaces and non-ASCII characters. All local sources enter the same import flow and use the selected destination. | NOT RUN |
| Destination and progress | Choose an existing subfolder, start a multi-source import, and confirm the destination and both chooser actions stay disabled while progress advances. A second drop is refused with a visible explanation. Temporary drop guidance clears when the batch finishes. Every source in that batch uses the original destination. | NOT RUN |
| Partial success and report | Mix a valid prompt, malformed/non-UTF-8/oversized files, a symlink and foreign metadata or unsupported template syntax. Read the per-file created paths, typed skips, mapped fields, preserved keys, header-formatting loss and warnings. Successful imports remain usable. Dismiss clears the completed report. | NOT RUN |
| Report open and window close | Close Library during import, reopen it, and confirm the completed report is available. Report Open actions are disabled while the library is unavailable and become usable again after recovery. Open an imported path from the report after watcher refresh; unsaved editor work gets Save / Discard / Cancel. | NOT RUN |
| Graph replacement | Switch libraries with a chooser open or import queued. The chooser closes; old selections, progress and reports cannot enter the new library. Newly opened import actions target only the replacement graph. | NOT RUN |
| Resource limits | A source exceeding Core's 262,144-byte cap is skipped. A folder whose total enumerated relative-name bytes exceed that budget reports a typed enumeration failure before publication. A relative path exceeding 1,024 bytes is a typed skip; its subtree is pruned while valid siblings import. Import a smaller subtree to proceed. Links are never traversed. | NOT RUN |
| Filesystem entry failures | An unreadable subdirectory is listed as a nonregular skip while readable siblings import. A non-UTF-8 filename fails the folder listing because the report cannot represent its exact path; rename that source and retry. | NOT RUN |
| Keyboard and AT-SPI | Tab to both import actions, destination, report opens and Dismiss; activate with the keyboard. Verify readable labels, progress and report details with the screen reader. | NOT RUN |

## Secret storage (M4 A4, NOT RUN)

- Commit / artifact version / desktop / keyring and libsecret-tools versions:
- Date / tester / isolated XDG config and data directories:

Use disposable provider profiles and test keys in Settings → Assistant.
Do not record key values,
stdin contents or keyring/tool error bodies in this checklist or logs.

| Check | Expected result | Status |
|---|---|---|
| GNOME Keyring lookup/store/Clear | With an unlocked GNOME Keyring, save and reload two profiles with separate keys. Each item is labelled `Monkey's Paw: provider:<UUID>` and has service/account attributes. The reported tier is Secret Service. Clear removes only that profile; its key appears nowhere in config, data or logs. | NOT RUN |
| KWallet lookup/store/Clear | Enable KWallet's Secret Service support and repeat the two-profile save/reload/Clear checks. The tier is Secret Service and accounts remain isolated. | NOT RUN |
| Locked keyring prompt and deadline | Lock the keyring, then read/save a profile. The keyring may prompt; unlock and retry if the two-second budget expires. Cancel or let the deadline expire: a typed locked/unavailable failure appears without hanging GTK, changing persisted credentials or creating plaintext. An existing fallback remains readable. | NOT RUN |
| Environment override | Set `MONKEYSPAW_PROVIDER_<UUID without hyphens, uppercase>_API_KEY` before launch. That profile reports Environment; replacing it is read-only. Clear removes persisted credentials and disables profile auth while the environment stays untouched. Another profile never borrows the override. | NOT RUN |
| Unencrypted fallback visibility | Launch with `secret-tool` absent from PATH. Save/reload a disposable key: Settings visibly reports unencrypted storage and only `<config>/secrets-unencrypted.json` contains it, with version 1, the `unencrypted` label and mode 0600. No private temporary file remains. Restore the tool, save through an unlocked service, and confirm that account's plaintext copy is removed. | NOT RUN |
| Unavailable service and symlink refusal | With the tool installed but Secret Service stopped or inaccessible, save/Clear fails with a typed error and preserves existing data. Replace the fallback or a config ancestor with a symlink: file operations refuse it and leave the target unchanged. | NOT RUN |
| Tool removal and restoration | Save a disposable service key, remove the tool from PATH, and save a different file key. Restoring the tool restores priority to the older service item. Re-enter and save the intended key through the unlocked service; it replaces that item and removes the file copy. Restore the tool before Clear to remove both copies. | NOT RUN |
| Crash temporary cleanup | Terminate during a file save, then retry a file or service save. Any abandoned private `.secrets-<UUID>` files are removed before the next mutation; a live file writer's lock causes a typed failure without deleting its temporary. | NOT RUN |

## Assistant Settings (M4 A14, NOT RUN)

Record the commit, date, desktop, GTK, keyring and provider versions. Use
disposable profiles and keys; never include key values or provider error
bodies in evidence. Xvfb tests use injected transport and secret storage;
these checks require a real desktop and, for Anthropic, owner-supplied access.

| Check | Expected result | Status |
|---|---|---|
| GNOME Keyring profiles | Add two profiles, rename and select them, Keep/Replace/Clear a key, Save, close and reopen Settings. The active profile and metadata persist; Secret Service is shown, saved keys never populate the masked field, and deleting or clearing one profile keeps the other's key. A locked prompt leaves GTK responsive and reports a typed result. | NOT RUN |
| KWallet profiles | With Secret Service support enabled, repeat the GNOME two-profile, key-edit and close/reopen checks. Selecting, disabling and deleting the active profile stay coherent; no plaintext fallback is created by a failing installed service. | NOT RUN |
| Unencrypted storage notice | With secret-tool absent, save and reopen a profile. A prominent unencrypted-file warning and File tier appear; only the named 0600 secrets file contains the key. Clear and Save remove it and the warning. | NOT RUN |
| Anthropic Test and model picker | Save an Anthropic profile, explicitly Test, and choose a returned model. No request occurs on editing, Save, selection or reopening. Test shows progress and success or a typed failure; an independently entered model ID works after failure. Changing the destination requires re-entry or Clear. | NOT RUN |
| Ollama Test and manual model | Use OpenAI-compatible with http://localhost:11434/v1 and no key. Test lists installed models, or shows a typed listing failure while manual IDs remain editable. Save/reopen retains the ID; cancelling or closing during Test rejects late results. | NOT RUN |
| Orca and keyboard | Navigate the Assistant tab with Tab/Shift+Tab and select profiles/models with the keyboard. Orca announces control labels, masked key input, active profile, key edit mode, storage tier, unencrypted warning, progress and typed results. Focus remains visible, and no saved key is spoken. | NOT RUN |

## Release deb installation (M2, NOT RUN)

Use an amd64 Ubuntu 24.04+ desktop for the release's amd64 package. Candidate
checks use the Release workflow's `dry_run=true` artifacts from the exact
main commit; after publication repeat with the `v0.1.0` release downloads.
Keep a separate record for each candidate and published build.

- Commit / CI run / Release workflow run:
- Artifact version / `.deb` SHA-256:
- Ubuntu / desktop / compositor / architecture:
- Date / tester / launch and delivery results:

1. Download `monkeyspaw_0.1.0_amd64.deb` and its
   `monkeyspaw_0.1.0_amd64.deb.sha256` into the same directory. Confirm
   `dpkg --print-architecture` reports `amd64`.
2. In that directory run
   `sha256sum -c monkeyspaw_0.1.0_amd64.deb.sha256`. Require **OK** and record
   the hash before installing.
3. Run `sudo apt install ./monkeyspaw_0.1.0_amd64.deb`. Record dependency or
   installation failures; then run `monkeyspaw --version` and require
   `monkeyspaw 0.1.0`.
4. Launch `monkeyspaw` from the terminal and from the desktop launcher.
   Complete pending Setup, folder and seed steps. Run the picker/fill and
   delivery checks below from this installed copy.
5. Quit through the tray where present, or run
   `gapplication action ch.lkmc.monkeyspaw quit`. Relaunch from the desktop
   launcher. Confirm saved folder, completed onboarding and
   remembered values persist; check the version and deliver again. A second
   ordinary launch while resident must reopen pending onboarding or raise
   the picker, as described in the recovery rows below.
6. Quit, then run `sudo apt remove monkeyspaw`. Confirm
   `dpkg-query -W -f='${db:Status-Status}\n' monkeyspaw` no longer reports
   `installed`, and `/usr/bin/monkeyspaw`, the desktop launcher and D-Bus
   service entry are removed. Record retained user library/config/data
   separately; package removal must not delete your prompts.

| Check | Expected result | Status |
|---|---|---|
| Download and checksum | The exact candidate/release deb and manifest are recorded; `sha256sum -c` reports OK. | NOT RUN |
| Install and version | apt succeeds; the installed `monkeyspaw --version` reports `monkeyspaw 0.1.0`. | NOT RUN |
| Launch and relaunch | Terminal/desktop launch, onboarding, saved state and installed-copy delivery work through steps 4–5. | NOT RUN |
| Uninstall | Package-managed binary, desktop and service entries disappear; user prompts and state remain. | NOT RUN |

## Tray (M2, NOT RUN)

Record the commit, date, desktop/compositor, GTK and tray host versions.
Private-bus/Xvfb tests verify registration, menu actions, library status and
shutdown; these real desktop checks remain owner-run.

| Check | Expected result | Status |
|---|---|---|
| KDE Plasma tray icon and menu | Interactive and service startup show one Monkey's Paw icon. Left click and Show Picker toggle the picker; Open Library reveals the active folder; Settings… and Setup… open their reusable windows; Quit exits and removes the icon. | NOT RUN |
| GNOME with the AppIndicator extension | With the extension enabled, the icon and all five menu entries work. An unavailable library disables Library unavailable; a successful folder switch restores Open Library. Quit removes the item. | NOT RUN |
| Stock GNOME without a tray | No fallback window appears. The hotkey, launcher toggle/Settings desktop actions and picker Settings button still work; an ordinary service launch stays hidden. | NOT RUN |

## Onboarding and library recovery (M2, NOT RUN)

Run these with isolated XDG config/data/documents directories on X11 and
GNOME/KDE Wayland. Record the commit, date, desktop/compositor, GTK and
portal versions. Private-bus/Xvfb tests cover the composition and controls;
they do not complete these owner checks.

| Check | Expected result | Status |
|---|---|---|
| Fresh install | Launcher opens Setup first. Closing Setup opens the library folder step; accept the displayed default or choose an existing readable folder. | NOT RUN |
| Legacy install | With only the old `setup-shown` marker, launcher opens the folder step without repeating Setup. | NOT RUN |
| Starter prompts | An empty accepted library offers Add Starter Prompts and Skip Starter Prompts. Adding shows the copied/skipped counts and makes the prompts available in the picker; restart never copies them again. | NOT RUN |
| Skip starter prompts and non-empty library | Skipping records the offer without copying. A library containing an eligible prompt, including malformed Markdown, skips the offer. | NOT RUN |
| First-run tour (M3 C6) | After adding or skipping starters, or accepting a non-empty library, the same onboarding window shows the hotkey, search, Tab/Shift+Tab, Return/Escape and Copy versus Deliver copy with one Done button. Seed counts or failures remain visible. | NOT RUN |
| Tour Done, native close and restart (M3 C6) | Done or closing the tour saves completion and hides the window. Relaunch opens the picker without repeating onboarding or changing starter files. Quitting before completion resumes the tour. | NOT RUN |
| Tour settings write failure (M3 C6) | Prevent config-directory writes, then use Done and native close. Both keep the tour visible with the typed settings error and leave the completion flag pending. Restore writes and retry; completion closes the window and survives restart. | NOT RUN |
| Tour upgrade and recovery policy (M3 C6) | An existing install skips the tour. Read-only settings and library recovery suppress it; recovery never consumes an explicitly pending tour flag. | NOT RUN |
| Folder chooser and cancellation | Invalid choices show a typed message and retain the step. Closing or switching between Settings and onboarding cancels that window's chooser; a stale result cannot switch the library. | NOT RUN |
| Resident launcher continuation | Close a pending folder, seed or recovery window, leave the process running and launch `monkeyspaw` again. The same step reopens. After completion, another launch opens or raises the picker; the explicit toggle action still opens and closes it. | NOT RUN |
| Startup unavailable notification and recovery | A missing or unreadable saved folder produces one path-free notification with no focus action and reopens the folder step. Closing and reopening retains recovery; choosing a readable folder or Use Default restores the library. | NOT RUN |
| Runtime folder loss | Cached prompts remain read-only. No startup notification or new recovery step appears; an already-open onboarding window shows restart guidance. Restart, or a successful Settings folder switch, restores library health. | NOT RUN |
| Read-only settings | Future-version or corrupt settings show the Settings error and suppress Setup/onboarding; the settings file remains unchanged. | NOT RUN |
| Tray status row (I14b, M3L1) | Open Library opens the reusable browser window. Missing/unreadable startup and runtime root loss change it to disabled Library unavailable; a successful folder switch restores Open Library without restarting the tray. | NOT RUN |

Composition retains one onboarding model and one library status model for
the process. Folder checks and seeding resolve the current library graph;
every successful or degraded replacement reports its health. Startup
health includes watcher startup and index rebuild. Runtime loss is latched
until a new graph replaces it or the app restarts. The tray subscribes to
this status; additional library status UI in Settings remains deferred.

## Settings (M2, NOT RUN)

Run these on X11 and GNOME/KDE Wayland. Record the tested commit, date,
desktop/compositor, GTK and portal versions. Xvfb and private-bus tests do
not complete these owner checks.

| Check | Expected result | Status |
|---|---|---|
| Picker Settings button and Ctrl+, | The picker dismisses without delivery; Settings opens or raises one reusable window. Close and reopen it. | NOT RUN |
| Launcher Settings desktop action, cold and resident | The action opens the same General and Shortcuts window; the picker stays usable after closing it. | NOT RUN |
| Choose folder | Choosing an existing readable folder updates the active path and picker; relaunch uses the saved folder. | NOT RUN |
| Cancel folder chooser | The active folder and settings remain unchanged; Choose becomes usable again. | NOT RUN |
| Invalid folder | A missing, unreadable or symlinked chosen folder shows an error and retains the previous library. | NOT RUN |
| Use Default | The active folder returns to the XDG documents default and survives relaunch. | NOT RUN |
| Open Folder | The file manager opens the active library folder, including after choosing another folder or Use Default. | NOT RUN |
| Forget all values | Cancel keeps remembered values and session drafts. Confirm clears both while the picker is closed and after switching libraries with Settings open. A failed write shows a sanitized error and keeps values; an unreadable regular values file can be reset once its directory is writable. | NOT RUN |
| Shortcuts Open Setup | Open Setup opens or raises the existing Setup window; closing and reopening it retains the live shortcut state. | NOT RUN |
| GNOME portal Shortcuts tab | Binding, registration and verification match Setup; portal configuration/Setup guidance follows the advertised interface version. Opening Settings never verifies the shortcut. | NOT RUN |
| KDE Shortcuts tab | Native and portal binding, registration, guidance and verification match Setup and update after system changes or mechanism handoff. Repeat remains inactive and unbound. | NOT RUN |

## Picker and fill (M2f, NOT RUN)

Run these on X11 and on GNOME/KDE Wayland. Record the desktop/compositor,
tool versions and date. These owner checks are not completed by Xvfb tests.

| Check | Expected result | Status |
|---|---|---|
| Forget values in picker and fill | The action appears only for a selected prompt or open form. It clears that prompt's remembered values and draft, keeps other prompts' values, and resets an open form to defaults without delivery. Failure keeps values and shows a sanitized error. The action is disabled during delivery. | NOT RUN |

- [ ] Add a Markdown prompt under the XDG documents directory's `MonkeysPaw`
  folder (default `~/Documents/MonkeysPaw`). From a browser/editor field,
  press the hotkey, type a live search, select with arrows or the pointer and
  press Return. The rendered prompt reaches the previous field.
- [ ] Save an external edit while the picker is open. The result and preview
  refresh within one second without losing the search or selected prompt.
- [ ] From a terminal, use Ctrl+Shift+Return. For a fielded prompt, the form
  retains terminal paste for its Deliver button and single-line Return.
  Confirm text arrives without submitting it; Ctrl+Return explicitly chooses
  standard paste and Alt+Return copies only.
- [ ] Fill text, multiline and choice fields, including label/value choices
  and descriptions. Check live preview, mouse focus, Tab/Shift+Tab order and
  remembered values after delivery. Return inside multiline adds a newline;
  Ctrl+Return, Ctrl+Shift+Return and Alt+Return deliver from that field.
- [ ] Escape from fill returns to the picker with typed values retained.
  A focused panel toggles off and native close dismisses fill; reopening restores
  its draft. Toggling an unfocused panel raises it and returns to the picker.
- [ ] Click another window while filling. The panel hides after 300 ms,
  leaves focus in that window and restores typed values on the next form open.
- [ ] Search for no matches. Open the library folder, create a prompt and
  verify its safe filename opens in Library's Edit tab. The assistant action
  is disabled and shows the Settings hint. Ctrl+Return opens a selected prompt
  in Library's Edit tab; Ctrl+L opens Library and dismisses the picker. Open Folder inside
  Library reveals the active folder.
- [ ] Make the library unavailable at startup, then remove it while running.
  The app stays usable and shows the banner; cached prompts remain available
  after removal. Restore the folder and restart to resume watching.

## Library browser shell (M3L1, NOT RUN)

Run these on X11 and GNOME/KDE Wayland, including GNOME without a tray
extension. Record the commit, date, desktop/compositor, GTK, Orca and portal
versions. The implementation uses GTK 4.8 controls; private-bus/Xvfb tests
do not complete these owner checks. The editor and History checks follow below.

| Check | Expected result | Status |
|---|---|---|
| Picker Library, no-match Library and Ctrl+L | Each dismisses the picker without delivery and opens or raises one Library window. Close natively, reopen, and confirm the same window remains usable. | NOT RUN |
| Tray Open Library and launcher Library action | Both open the same window, including a cold `gapplication action ch.lkmc.monkeyspaw library`. Missing/unreadable libraries keep the tray row disabled. Repeat the launcher action without a tray host. | NOT RUN |
| Sidebar and filter | All, Favourites, Recent, nested folders and tags show the model's counts. Counts remain stable while filtering. Folder sections include descendants; changing the filter or section retains the selected preview even when its row is hidden. | NOT RUN |
| Prompt rows and Recent | Rows show title, exact relative path, favourite star and invalid/read-only badges. Recent orders retained uses newest first and shows last-used times. Delivery/copy refreshes Recent while Library is open. | NOT RUN |
| Read-only preview and privacy | Defaults appear, empty fields use `{field}` names, date/time are real and clipboard uses `{clipboard}`. Selecting and filtering never read the clipboard or write prompt files. Invalid, future-format, non-UTF-8 and oversized prompts display their issues. | NOT RUN |
| Favourite button and Ctrl+D | A valid prompt saves its favourite through the library service, refreshes sidebar/list and picker, and retains selection after first-save identity assignment. A stale file or failed write shows an error without changing the star. Read-only entries disable the button. | NOT RUN |
| Open Folder and folder switching | Open Folder reveals the active folder. With Library visible or hidden, change the folder in Settings or Use Default: the same window binds to the new library, clears its old selection/filter and receives no retired-library updates. | NOT RUN |
| Keyboard, Orca and visible focus | Tab/Shift+Tab reach the labelled sidebar, prompt list, preview and actions. Arrows navigate the lists; Return on a prompt opens nothing. Escape clears a nonempty filter, then hides the window. Input-method Escape stays with active filter preedit. Orca announces rows/counts, badges, preview and favourite errors; focus stays visible. | NOT RUN |
| Settings and shutdown | Settings and Library can remain open together; closing either leaves the other usable. Quit with both open and reopen the app: no stale window or callback survives. | NOT RUN |

## Library editor tabs (M3L2, NOT RUN)

Run these on X11 and GNOME/KDE Wayland with GTK 4.8 or newer. Record the
commit, date, desktop/compositor, GTK, Orca and input-method versions.
Private-bus/Xvfb tests exercise saves, guards and native controls, including
Core file-command busy states and selection following; these real desktop
checks remain owner-run. While a Core command runs, the editor shows "Updating the
file…", disables Revert and holds conflict/discard dialogs until completion.

| Check | Expected result | Status |
|---|---|---|
| Edit, Preview and Fields | Select a prompt. Edit shows its exact raw source in a native monospace multiline control; validation updates as you type. Preview uses field defaults, real date/time and literal `{clipboard}`. Fields shows parsed names, labels, descriptions, kinds, defaults, options and behavior read-only. | NOT RUN |
| Native editing and undo | Copy/cut/paste, selection, multiline Return, Ctrl+Z and redo work natively. Save normalization keeps the caret in the body and can be undone. Closing/reopening or replacing the library resets the old session's undo. | NOT RUN |
| Save, Ctrl+S, Revert and Save as Copy | Save writes disk bytes and shows saving/saved or a typed failure while retaining failed drafts. Revert asks before discarding edits. Copy creates a distinct file/id and selects it without replacing the original. History-maintenance failures report a committed save with a warning. | NOT RUN |
| Read-only prompts | Future format, non-UTF-8 and oversized files show the specific reason and disable Edit, Save and Save as Copy. | NOT RUN |
| Modified conflict and Cancel | Edit, then save the file externally. The modal dialog offers Keep Mine, Take Theirs and Save Mine as Copy. Check each choice on separate files. Native close/Escape/Cancel keeps the conflict and draft; repair invalid text and Save reopens the choices. | NOT RUN |
| Deleted conflict and Cancel | Delete a dirty file externally. The draft remains visible after its browser row disappears. Keep Mine recreates it; Save Mine as Copy creates a distinct file; Discard closes the draft. Cancel retains the conflict and draft. External deletion retains the selection key, including after Discard; restoring the file recovers its selection. | NOT RUN |
| Selection, window close and app quit | Dirty selection changes, native close, Ctrl+W and the tray/GApplication quit action wait for Save/Discard/Cancel. Cancel preserves the current selection/window/draft; a failed save keeps the decision pending. Closing retains the selection, filter and section for reopening. Close/quit during a save or file command wait for completion and any newer draft. | NOT RUN |
| Settings folder switch | While dirty, saving, running a file command or awaiting a decision, choosing another folder or Use Default is refused with the Library editor message and preserves the graph. Save/discard or wait for completion, then switch; no old editor publication or draft leaks into the replacement. | NOT RUN |
| Picker Edit and no-match creation | Ctrl+Return/Edit and no-match Create dismiss the picker and open the prompt in Library's Edit tab. A target hidden by the Library filter/section is revealed only after the discard guard allows it. Open Folder still reveals the active folder. | NOT RUN |
| Real IBus/Fcitx editor composition | Compose with a real conversion engine. Return commits and Escape cancels through the input method without saving or closing. Model refreshes preserve active preedit; committed characters appear once and update validation/preview. Switch/reopen the session and confirm no old composition survives. | NOT RUN |
| Orca and visible focus | Tab/Shift+Tab reach source, tabs, actions, validation, Fields and modal choices. Orca announces labels, read-only reasons, errors and conflict/discard choices; Cancel has initial dialog focus. | NOT RUN |
| Clipboard privacy | Trace `gdk_clipboard_read_text_async` with harmless clipboard contents, recording counts only. Browsing, typing, tab changes and saves read zero times when the prompt source contains `{{clipboard}}`; Preview renders the literal marker `{clipboard}`. | NOT RUN |

## History and file commands (M3L3, NOT RUN)

Run these on X11 and GNOME/KDE Wayland with GTK 4.8 or newer. Record the
commit, date, desktop/compositor, GTK and Orca versions. Use disposable
prompts and isolated app data. Private-bus/Xvfb tests with fatal GTK warnings
cover the controls, typed outcomes, guards and selection changes; they do
not complete these owner checks.

| Check | Expected result | Status |
|---|---|---|
| History list and refresh | Save several revisions, open History and use Refresh History. Revisions appear newest first with local timestamp, exact byte size and Valid or Forensic only status. Opening a different prompt refreshes its own list. | NOT RUN |
| Read-only revision preview | Select valid and malformed revisions. Exact source appears in a read-only monospace control and leaves the live draft untouched. Non-UTF-8 and oversized revisions show the specific reason without fabricated text. | NOT RUN |
| Restore and refusals | Restore a valid revision: the editor and history reload and the current id stays. Forensic and future-format revisions remain selectable; Restore reports the typed refusal without changing the file. | NOT RUN |
| Rename | Use Rename… in the editor header with a .md filename. File bytes and front-matter title stay; the selection follows the new path, including an unassigned prompt. Occupied, ignored and invalid names show an error without replacing another file. | NOT RUN |
| Move | Choose an existing folder, type a new nested relative folder, then move to the root with an empty input. Parents are created and selection follows. Occupied destinations and invalid paths are refused. | NOT RUN |
| Delete and Cancel | Delete… names the exact relative path and initially focuses Cancel. Cancel, Escape and native close preserve the file. Confirming closes the editor and clears selection while keeping history. | NOT RUN |
| Unsaved decisions | Repeat Rename, Move, Delete and Restore with a dirty draft. Save commits before the command; Discard uses the loaded baseline; Cancel preserves draft, file, history and selection. A failed save keeps the decision pending. | NOT RUN |
| Stale or missing file | Change or delete the file externally while a form is open, then confirm. The existing modified/deleted conflict dialog opens without overwriting or recreating it. Resolve it, then retry the intended command. | NOT RUN |
| Disabled controls and graph replacement | No open prompt, read-only files, unavailable library, saving, pending decisions and running commands disable file actions and Restore. Losing the library or switching its graph cancels an open form and drops stale replies. | NOT RUN |
| Keyboard, Orca and privacy | Tab/Shift+Tab reach the header actions, History list, preview and labelled form controls. Orca announces revision metadata, refusal/status copy and delete confirmation. Escape respects native input-method preedit. Browsing History and using these commands read no clipboard contents. | NOT RUN |

## Orca, visible focus and reduced motion (M2, NOT RUN)

- Commit / CI run / artifact version / SHA-256:
- Desktop / compositor / GTK / Orca / AT-SPI versions:
- Accessibility and animation settings / date / tester:

1. Enable Orca through the desktop's accessibility settings. Use a library
   with a fieldless prompt and a prompt containing text, multiline and choice
   fields, descriptions, defaults and a required empty field.
2. Summon the picker and navigate search, results and preview with the
   keyboard and Orca. Open fill, traverse each field with Tab/Shift+Tab,
   change a choice and read the preview and required-field message. Inspect
   Deliver, Copy, Cancel, Forget values and Settings, including disabled
   states. Escape returns to picker without delivery.
3. Open Settings. Navigate General and Shortcuts, read the active folder,
   shortcut binding/status and errors, then inspect Choose, Use Default,
   Open Folder, Open Setup and the Forget all confirmation and Cancel.
4. In isolated XDG directories, follow the onboarding/recovery rows above
   with Orca: Setup, folder path/chooser/default, seed Add/Skip, result/Done
   and recovery/error messages. Confirm Settings remains reachable.
5. Turn Orca off and repeat keyboard navigation across picker/fill,
   Settings and onboarding. Inspect the focus indicator on every reachable
   control. Disable desktop animations/reduce motion using the desktop's
   setting, record the effective GTK animation setting, and repeat summon,
   dismiss, picker-to-fill, tab changes and onboarding steps.

| Check | Expected result | Status |
|---|---|---|
| Orca picker and fill | Search/results, field kinds, labels/descriptions, choice values, preview, actions, disabled states and validation are announced and usable. | NOT RUN |
| Orca Settings and onboarding | Tabs, folder/shortcut state, actions, confirmation, progress and failures are announced and operable with the keyboard. | NOT RUN |
| Visible focus (§11.6) | Keyboard focus remains visible throughout picker/fill, Settings, confirmation and onboarding, including reverse traversal. | NOT RUN |
| Reduced motion (§11.6) | With desktop animations disabled, app transitions add no motion; controls and focus remain usable. | NOT RUN |

## Input-method composition (M2, NOT RUN)

- Commit / CI run / artifact version / SHA-256:
- Desktop / compositor / GTK / IBus or Fcitx version / engine / layout:
- Date / tester:

1. Configure a real IBus or Fcitx conversion engine, such as Japanese Mozc,
   through the desktop/input-method settings. Confirm composition works in
   another native app first. Run on X11 and each claimed Wayland desktop;
   record which input-method framework and engine were exercised.
2. In picker search, type text that produces visible uncommitted preedit
   and a candidate list. Press Return to commit a candidate: the query
   updates, the picker stays open and no prompt is used. Start composition
   again and press Escape: composition cancels without dismissing the panel.
3. Open a prompt with text and multiline fields. In each field, repeat
   Return-to-commit and Escape-to-cancel while preedit is active. Confirm
   there is no delivery, clipboard write or return to picker. Committed
   characters appear once in the field and live preview.
4. After composition ends, multiline Return adds a newline. Escape returns
   to picker retaining the draft; reopen and verify the committed text
   remains, then Ctrl+Return delivers.

| Check | Expected result | Status |
|---|---|---|
| Real IBus/Fcitx search | Candidate Return/Escape stays with the input method; committed search works and the picker remains open. | NOT RUN |
| Text and multiline composition | Both native controls commit/cancel without app actions; ordinary delivery/cancel keys resume after preedit ends. | NOT RUN |

## Conditional clipboard privacy (M2, NOT RUN)

- Commit / CI run / artifact version / SHA-256:
- Desktop / compositor / GTK / read-count tracing method:
- Date / tester / per-step read counts:

Use harmless test clipboard text. Create fieldless and fielded prompts with
and without `{{clipboard}}`; include two occurrences of that builtin in the
same prompt. Count app reads with a debugger breakpoint/trace on
`gdk_clipboard_read_text_async` in the resident process, without recording
arguments or clipboard contents. If read-count tracing is unavailable,
leave the count checks NOT RUN; unchanged output alone cannot prove one read.
Change the external clipboard with a background writer while the form stays
open; switching focus to another app would hide it and require a new form open.

| Check | Expected result | Status |
|---|---|---|
| Search and selection (§5.3) | Reset the count, summon/search and select each prompt without using it: zero clipboard reads, including selection of a clipboard prompt. | NOT RUN |
| No clipboard builtin | Open/edit/deliver the fielded prompt and use the fieldless prompt without `{{clipboard}}`: zero reads. | NOT RUN |
| One snapshot per form open | Open the clipboard form: one read supplies both builtin occurrences. Change fields and update the clipboard in the background; preview keeps the original snapshot without another read. Escape and reopen the form: one new read uses the new text. Deliver without another read. | NOT RUN |
| One snapshot per fieldless use | Use the fieldless clipboard prompt: one read supplies both occurrences. Copy new test text externally and use it again: one new read. | NOT RUN |

## Delivery plumbing (M1b)

M1b adds local X11 and wlroots delivery with one canned prompt. These checks
are owner-run and have **not** been completed on the implementation host.
Record your desktop/compositor, tool versions, date, and self-test report
when you run them. Do not put clipboard text or tool error bodies in logs.

X11 dependencies are `xdotool` and `xprop` (`x11-utils` on Debian/Ubuntu).
The display smoke also needs Xvfb, xauth, D-Bus, GLib's command-line tools,
xterm, Openbox, and Python 3.

## X11

- [ ] Launch `monkeyspaw` normally on first run. Setup opens, then closing it
  continues through the folder and eligible seed steps above. Later launcher
  activations resume pending steps or show the picker when complete; Setup
  stays available there. Ordinary service launches and CLI diagnostics do
  not open first-run Setup. Startup library failure opens recovery.
- [ ] Start `monkeyspaw --gapplication-service`. It remains resident with no
  visible window. Run `gapplication action ch.lkmc.monkeyspaw toggle` twice:
  the picker opens and closes. Close it natively and toggle again.
- [ ] Bind `gapplication action ch.lkmc.monkeyspaw toggle` in your desktop's
  shortcut settings to Ctrl+Alt+P. In Setup, select "Press your shortcut
  now" and use the binding. The hotkey row becomes ready only after it fires.
- [ ] On GNOME Xorg, the owned custom keybinding is named
  `Monkey's Paw: toggle`. Existing bindings stay present. Change its keys
  in GNOME Settings and restart the app: your changed binding is preserved.
- [ ] From a browser or text editor, open the picker and press Return.
  The canned prompt reaches the previous field. Successful paste is silent.
- [ ] From a terminal, confirm with Ctrl+Shift+Return. The terminal receives
  the canned prompt without submitting it. Return uses Ctrl+V; automatic
  terminal-class selection is reserved for M7.
- [ ] Esc cancels without delivery. Clicking another window hides the picker
  after 300 ms and leaves focus in the window you selected.
- [ ] Tab to the Setup button and press Return. Setup opens without delivery.
- [ ] Run `monkeyspaw --selftest` from a terminal, both with and without a
  resident instance. JSON appears in the invoking terminal. The report must
  show `xdotool` as `pasted`, based on field readback. A standalone test exits.
- [ ] Run `gapplication action ch.lkmc.monkeyspaw selftest`. Its report is
  written to the resident process's stdout. Setup's "Test paste" shows the
  same backend results without treating exit zero as proof of receipt.
- [ ] Without xdotool/ydotool, delivery still copies the text and shows the
  appropriate Ctrl+V or Ctrl+Shift+V notification. The target keeps focus;
  the notification has no buttons or configured default action.

GNOME's paste ladder still contains the deferred portal before ydotool, even
on Xorg, as §6.1 specifies. Portal attempts report `backendUnavailable` in
M1b. An ordinary X11 session prefers xdotool. Missing or failed backends are
cached until "Test paste" resets and rechecks them.

## wlroots with ydotool

- [ ] Install ydotool and configure ydotoold for `/dev/uinput`. Setup offers
  the udev rule, group command, service command, and upstream documentation.
  Adapt the service to your distribution and log out/in after group changes.
- [ ] Verify the daemon socket is reachable and readable/writable. Modern
  ydotool receives an explicit `YDOTOOL_SOCKET`: your override first, an
  existing `$XDG_RUNTIME_DIR/.ydotool_socket` second, then
  `/tmp/.ydotool_socket`. Version 0.1.8 uses its fixed `/tmp` socket.
- [ ] Bind the manual `gapplication action ch.lkmc.monkeyspaw toggle`
  command in your compositor. KDE also uses this manual mechanism in M1b.
- [ ] Run the CLI and Setup self-tests. The `ydotool` result must be `pasted`.
  Record `sentButNotReceived` separately: a successful tool exit does not
  establish receipt, and the self-test caches that failure.
- [ ] Test Return into a browser and Ctrl+Shift+Return into a terminal.
  Clipboard ownership persists while the picker is hidden. There is no
  automatic XWayland fallback or active-window capture on Wayland.
- [ ] Stop ydotoold or deny socket access, restart the app, and deliver.
  Copy-only guidance appears without a hang or focus theft. Restore access
  and use "Test paste" to reset cached failures.

## Decisions and validation boundary

- Keep the Linux job in `.github/workflows/ci.yml`, following M0b, rather
  than adding the plan's separate `linux.yml`.
- Defer an unused GDBus portal helper to M1c. GTK's notification payload is
  covered by a mock notification daemon on a private bus. No portal or KDE
  driver is implemented here; the portal Setup row says "Added in M1c".
- Core owns the 140 ms settle. Linux never explicitly activates a target
  or reports confirmed focus. X11 capture excludes our own WM_CLASS;
  Wayland has no target identity and returns nil.
- Each subprocess has a two-second budget, a 64 KiB output cap, discarded
  stderr, and typed failures. The exception is dialect discovery: legacy
  ydotool's help exits one on stderr, which is drained together with stdout
  and never logged. X11 capture shares one shorter 250 ms deadline between
  `xdotool getactivewindow` and `xprop -id <id> WM_CLASS`.
- The CI smoke uses Openbox because Xvfb alone has no window manager to
  refocus after a hide. It exercises the real Return handler with the
  terminal chord, pastes through xdotool into xterm running raw-input `cat`,
  compares the exact bytes without logging them, and verifies both CLI and
  D-Bus self-test JSON. Focused XCTest assertions check that capture returns
  the xterm's class and excludes the picker using real xdotool and xprop.
  Build tests with `swift test` first, then run the smoke from the repository
  root. Each capture assertion runs through `swift test --skip-build --filter`
  with its exact test name and a 20-second timeout. The smoke sends no Enter
  to the target terminal. The whole smoke keeps CI's 60-second timeout:

  ```sh
  timeout 60s dbus-run-session -- xvfb-run -a \
    bash scripts/linux-delivery-smoke.sh .build/debug/monkeyspaw
  ```

  The optional second script argument selects the Swift runner used to build
  the tests. On the implementation host, build with
  `/home/paseo/.local/bin/swift64` and append that path to the smoke command.
  Omitting it uses `swift`, as CI does.
- The standalone diagnostic skips GNOME shortcut installation. CI checks
  this with a fake gsettings after the resident service exits.
- CI gates GTK lifecycle, notification mock-bus, and X11 smoke checks.
  Real compositor behavior, full-screen windows, browser fields, and
  ydotool/uinput remain owner-run. GNOME portal and KDE checklists arrive
  in M1c and M1d respectively.

The first Devin review found only minor issues. The timeout test confirms
Foundation reaps the killed child without a blocking wait. Executable
directories on PATH are skipped, and writer handles are explicitly closed
once. A busy legacy stream daemon can currently be reported as unavailable;
rerun "Test paste" to recheck after it recovers. The review suggestion to
drop socket read checks was rejected because M1b requires unreadable sockets
to report `permissionDenied`. Pending nonblocking connects are not treated
as proof of a reachable daemon.
