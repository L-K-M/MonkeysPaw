# M3 Library window acceptance

This maps every [§15 M3 acceptance item](../plan/15-milestones.md) to its
automated gate. Record the main commit, CI run and tester with the results.
The desktop owner checks below remain **NOT RUN**.

- Commit / CI run:
- Platform / date / tester:

| Acceptance item | Proof | CI job in [ci.yml](../../.github/workflows/ci.yml) |
|---|---|---|
| “Create → edit → rename → restore round-trips on disk (integration test on a temp library).” | [HistoryCommandDiskTests](../../Tests/MonkeysPawCoreTests/Library/HistoryCommandDiskTests.swift): `testCreateEditRenameMoveRestoreRoundTripsOnDiskWithIdentityAndHistory`. Creates real files in a temporary library and app-data root, edits and saves through EditorModel, renames and moves, then restores. Asserts exact saved/restored bytes, unchanged identity/title/body, history order, remembered values and usage. Reopens the stores to prove persistence; deletion keeps history and a missing-file restore does not recreate the prompt. | `linux-app` Core tests and `core-macos` |
| “An external write during an unsaved edit shows the conflict dialog (presentation-model test).” | [EditorConflictTests](../../Tests/MonkeysPawCoreTests/Library/EditorConflictTests.swift): `testDirtyExternalModificationOpensImmediatelyAndKeepMineUsesTheirStamp`. An unsaved “Mine” buffer and an external “Theirs” write publish a modified conflict immediately, retain the draft, load the external source/stamp and expose Keep Mine, Take Theirs and Save as Copy. Keep Mine saves against the external stamp and archives the overwritten version. | `linux-app` Core tests and `core-macos` |

The disk integration fixture uses Foundation regular files; it does not
establish native window or filesystem-driver behavior. The conflict test
drives the presentation model through the index change notification. The
recording sections below cover the real dialogs and desktop controls.
`core-linux` compiles Core tests without GTK; their Linux execution is in
`linux-app`. Hosted macOS UI checks require `macos-app`; this Linux host
cannot run them.

Owner-run gates (all rows in each linked section):

| Check | Status | Record results in |
|---|---|---|
| Library entry points, reusable window, sidebar/folder/tag/favourite/recent browsing, filtering, preview, root loss/recovery, folder replacement and Settings/window lifetime | **NOT RUN** | [macOS Library shell](macos.md#m3-m1-library-window-shell-not-run), [Linux Library shell](linux.md#library-browser-shell-m3l1-not-run); Linux's [Tray status row](linux.md#onboarding-and-library-recovery-m2-not-run) also records unavailable/recovered Open Library. |
| Edit/Preview/Fields, live validation, native editing/undo/caret, Save/Revert/Copy, read-only reasons, dirty selection/close/quit guards, folder-switch refusal and picker Edit/create | **NOT RUN** | [macOS editor tabs](macos.md#m3-m2-library-editor-tabs-not-run), [Linux editor tabs](linux.md#library-editor-tabs-m3l2-not-run) |
| External modified/deleted conflicts, every resolution, Cancel/dismissal, newer external changes and decisions while hidden/minimized or saving | **NOT RUN** | [macOS editor conflict rows](macos.md#m3-m2-library-editor-tabs-not-run), [Linux editor conflict rows](linux.md#library-editor-tabs-m3l2-not-run) |
| History list/refresh/preview, first-save identity and recovery, Restore/refusals, Rename/Move/Delete, occupied/stale destinations, unsaved guards, disabled commands and retired callbacks | **NOT RUN** | [macOS History and file commands](macos.md#m3-macos-history-and-file-commands-not-run), [Linux History and file commands](linux.md#history-and-file-commands-m3l3-not-run) |
| Native import choosers and Finder/file-manager drops, all three formats and folders, destinations, progress/busy refusal, partial reports, exclusive writes, links/limits/entry failures, report opening, close/reopen and graph replacement | **NOT RUN** | [macOS Library import](macos.md#m3-m4-library-import-not-run), [Linux Library import](linux.md#library-import-m3-not-run) |
| First-run tour content, Done/native close/restart, quit/resume, settings-write failure/retry, upgrade/read-only/recovery policy | **NOT RUN** | M3 C6 rows in [macOS onboarding](macos.md#m2-onboarding-and-library-recovery-not-run) and [Linux onboarding](linux.md#onboarding-and-library-recovery-m2-not-run) |
| Real IME composition, keyboard traversal/visible focus, VoiceOver or Orca/AT-SPI, clipboard read counts, resize/reduced motion and macOS activation/Spaces | **NOT RUN** | Relevant rows in macOS [shell](macos.md#m3-m1-library-window-shell-not-run), [editor](macos.md#m3-m2-library-editor-tabs-not-run), [commands](macos.md#m3-macos-history-and-file-commands-not-run) and [import](macos.md#m3-m4-library-import-not-run); Linux [shell](linux.md#library-browser-shell-m3l1-not-run), [editor](linux.md#library-editor-tabs-m3l2-not-run), [commands](linux.md#history-and-file-commands-m3l3-not-run) and [import](linux.md#library-import-m3-not-run), on X11 and GNOME/KDE Wayland as specified there. |

No missing automated assertion was found for the two §15 M3 items. A green
presentation or hosted test does not turn an owner row into a recorded run.
