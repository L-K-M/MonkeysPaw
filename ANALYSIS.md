# Monkey's Paw analysis

Remaining findings from the 2026-10-24 review of main `f58bd7b`. There are 2 important
and 20 nice-to-have findings. Findings implemented in open PRs are omitted. All eight
focus areas apply. Source inspection does not establish measured latency, visual
acceptance or device behavior; individual entries identify the remaining verification
needed.

### B03: Assistant watchdog can discard an on-time response

bugs — important

`Sources/MonkeysPawCore/Services/AssistantService.swift:61-65,84-86`;
`Sources/MonkeysPawCore/Assistant/OpenAIClient.swift:101-102`.

The service timer finishes and cancels the client at the deadline, even if receipt
completed on time and decoding is still running. Desktop users can lose an
already-received paid response. §7 explicitly requires retaining it; the direct-client
test does not exercise the service watchdog.

Suggested fix: distinguish credential/network waiting from post-receipt processing;
preserve user cancellation and waiting-network timeout. Audit the Kotlin service timer
for parity and add service-level receipt-boundary coverage.

Rough effort: about 1 day.

### P01: Desktop fuzzy search runs expensive work on the UI thread

performance problems, stuttering, and jank — important

`Sources/MonkeysPawCore/Presentation/PickerModel.swift:138-143,414`,
`Sources/MonkeysPawCore/Presentation/LibraryBrowserModel.swift:225`,
`Sources/MonkeysPawCore/Domain/Library/PromptSearch.swift:62-79`.

Each query edit synchronously evaluates the O(query × field-length) matcher over prompt
fields including bodies. A 1,000-scalar repeated query against a 256 KiB matching body
entails roughly 262 million inner iterations, before multiplying by the library. Desktop
typing and dismissal wait behind this work. Execution path/complexity are confirmed;
latency was not measured.

Suggested fix: search immutable snapshots on workers, reject obsolete generations, and
add cooperative cancellation or bounded matching work without silently changing ranking.
Verify responsiveness with representative large libraries.

Rough effort: 1–2 days.

### G01: Expired login buckets accumulate indefinitely

general issues — nice-to-have

`server/Sources/MonkeysPawServer/Repositories/LoginRepository.swift:26-32,51-57`;
`server/Sources/MonkeysPawServer/Services/RetentionService.swift:24-59`.

Logical decay does not remove stale username/IP rows. Distinct failed names and IPs
increase database and backup size over the lifetime of a public or long-running server.

Suggested fix: bounded retention deletes after the full quiet/lock decay window, inside
serialized writes; retain live locks and test expiry boundaries.

Rough effort: half a day.

### G02: Large UI coordinators are expensive to change safely

general issues — nice-to-have

`Sources/MonkeysPawLinux/LinuxLibraryWindow.swift:1` (1,703 lines),
`android/app/src/main/kotlin/ch/lkmc/monkeyspaw/ui/editor/EditorViewModel.kt:1` (1,043
lines).

Contributors must reason about editing, navigation, assistant, conflicts, history and
native controls together. This increases review cost and the chance of unrelated
lifecycle regressions; size alone is not a bug.

Suggested fix: extract cohesive native rendering/command components when next changing
these areas, keeping one explicit session/guard owner and existing boundaries.

Rough effort: 1–2 days, in small behavior-preserving changes.

### G03: Daily-use acceptance evidence remains incomplete

general issues — nice-to-have

`docs/plan/15-milestones.md:34-56,97-111`, with linked `docs/platform/` checklists.

Automated conformance does not demonstrate real focus restoration, desktop-compositor
behavior, physical Android Keystore use, provider calls, or installed-release UX. Users
and maintainers lack that remaining evidence.

Additional local evidence: with Xcode 27.1, the broader picker suite reported key-window
activation failures;
`MacPickerViewTests.testLibrarySwitchReusesPanelAndHostingViewWithFreshControlsAndCallbacks`
also failed on unchanged main. The full Android app run reported file-store/sync
failures and was interrupted after stalling. One representative failure,
`AndroidFileStoreTest.library rules are exact and state enumeration keeps sidecars`,
also fails on unchanged main because the expected `readme.md` entry is absent alongside
`README.md` on this case-insensitive host. The other broad-run Android failures remain
unclassified. Focused fix suites passed; neither broader app gate is claimed green.
Investigate the app/runner boundary and run the supported-host CI and owner checks.

CI also reported one failure among 704 macOS app tests on PR #322:
`MacLibraryEditorTests.testRenderedEditorShowsBodyByDefaultAndSourceOnRequest`
could not find `library-prompt-description` after a fixed 0.1-second delay
(`MonkeysPawTests/MacLibraryEditorTests.swift:192-195`). Both new picker
Accessibility tests passed in that run. The failing Library test passed when
run alone on local main, so the CI failure is not reproduced locally and its
root cause remains unconfirmed. A single retry of the failed CI job was requested.

Suggested fix: run the owner checklists on actual supported devices and installed
artifacts, recording revision, build, environment and results. Keep NOT RUN explicit
until demonstrated; this review did not establish those checks.

Rough effort: 1–3 days across available hardware/accounts.

### P02: Opening a desktop fill form reads remembered values synchronously

performance problems, stuttering, and jank — nice-to-have

`Sources/MonkeysPawCore/Presentation/PickerModel.swift:325`,
`Sources/MonkeysPawCore/Services/FillService.swift:64`,
`Sources/MonkeysPawCore/Services/ValuesStore.swift:26`.

The hotkey-to-form path can read and decode the complete values file (up to 1 MiB) on
the UI thread. Slow storage or a contended store delays users filling prompts. I/O is
confirmed; visible delay remains unmeasured.

Suggested fix: cache validated state or load prefill asynchronously with session checks.

Rough effort: half to one day.

### P03: macOS source highlighting repeats full-buffer work

performance problems, stuttering, and jank — nice-to-have

`MonkeysPaw/Views/LibrarySourceEditor.swift:159-162,215-232,351-357`.

Identical-source publications still scan and recolor the buffer; edits can trigger both
delegate and model-publication passes. Large prompts incur avoidable UI work. This is a
profiling candidate, not measured jank.

Suggested fix: cache content/appearance revisions, avoid duplicate scans, then measure
typing and unrelated inspector updates before considering incremental scans.

Rough effort: half a day.

### P04: Android searches keep obsolete work and recompute invariant sections

performance problems, stuttering, and jank — nice-to-have

`android/app/src/main/kotlin/ch/lkmc/monkeyspaw/ui/library/LibraryViewModel.kt:122-130`,
`android/app/src/main/kotlin/ch/lkmc/monkeyspaw/ui/library/LibraryUiState.kt:86-120`.

Every query creates a job; generation checks reject results only after search and
projection. Old queries still compete for the repository mutex, and every query rebuilds
all rows, folder/tag counts and recent order. Fast typists with large libraries may wait
for obsolete work; no timing measured.

Suggested fix: retain/cancel the search job, check obsolescence before projection, and
cache library-version-dependent sections separately from query results.

Rough effort: half to one day.

### P05: Delta sync makes approximately two SQL calls per event

performance problems, stuttering, and jank — nice-to-have

`server/Sources/MonkeysPawServer/Services/SyncFeedService.swift:117,138`,
`server/Sources/MonkeysPawServer/Repositories/SyncFeedRepository.swift:73-85`.

Consuming 1,000 events performs roughly 2,000 sequential database operations plus setup,
increasing catch-up work for busy shared libraries. Query count follows the code;
wall-clock impact was not measured.

Suggested fix: fetch bounded chunks including sequence and event payload; retain
cross-scope order, transaction snapshot, collapse and byte-limit semantics.

Rough effort: about 1 day.

### P06: Snapshot continuation decodes the entire frozen snapshot per page

performance problems, stuttering, and jank — nice-to-have

`server/Sources/MonkeysPawServer/Repositories/SnapshotRepository.swift:30-36`,
`server/Sources/MonkeysPawServer/Services/SyncFeedService.swift:77`.

Each continuation loads/decodes a snapshot that may reach 64 MiB to produce an 8
MiB/200-item page. Small self-hosted servers repeatedly pay the full memory/CPU cost.
Actual latency is unmeasured.

Suggested fix: store addressable frozen chunks or indexed frozen rows, preserving
generation/HMAC checks, quotas, eviction, restore and frozen semantics.

Rough effort: about 2 days, including migration and lifecycle tests.

### P07: Canceled database writers remain in the admission queue

performance problems, stuttering, and jank — nice-to-have

`server/Sources/MonkeysPawServer/Database/WriterGate.swift:4-21`.

Canceled waiters retain continuations until their turns arrive; array removeFirst also
shifts remaining admissions. Bursts/disconnected clients add work behind slow
transactions. No throughput failure reproduced.

Suggested fix: cancellation-aware queued admission and constant-time FIFO removal;
verify exactly-once resume, ordering and writer ownership on cancellation.

Rough effort: half to one day.

### P08: Linux library recreates whole lists on small changes

performance problems, stuttering, and jank — nice-to-have

`Sources/MonkeysPawLinux/LinuxLibraryWindow.swift:1512-1591`.

Changed sections/rows clear all native children and recreate them, even after one
favourite or count change. Selection/focus are restored, but no explicit scroll-anchor
preservation is present. Large libraries incur widget churn; flicker/scroll jumps
require a GTK runtime reproduction.

Suggested fix: update keyed rows incrementally or preserve scroll anchors around a
minimal rebuild. Measure before claiming a complexity or latency improvement.

Rough effort: about 1 day.

### P09: Clipboard restore timeout does not bound a synchronous pasteboard read

performance problems, stuttering, and jank — nice-to-have

`MonkeysPaw/Drivers/PasteboardClipboard.swift:24-39`.

A promised-data clipboard owner may block data(forType:) on AppKit's UI thread before
the elapsed-time check can reject it. Users of slow clipboard providers can see delivery
pause. Delayed-owner behavior was not reproduced.

Suggested fix: investigate a safe bounded/asynchronous retrieval strategy, keeping
pasteboard thread requirements and clipboard identity checks intact; test with a
deliberately delayed owner before changing production behavior.

Rough effort: about 1 day of investigation and implementation.

### F01: Folder import has no per-operation Cancel

missing features — nice-to-have

`Sources/MonkeysPawCore/Presentation/ImportModel.swift:17`,
`Sources/MonkeysPawCore/Services/ImportService.swift:75`.

Desktop users choosing a large or mistaken folder must wait; the service only checks
graph-wide active state, while the UI offers progress.

Suggested fix: cancel between files and during enumeration where practical; keep
successful imports and report partial completion rather than rolling back.

Rough effort: about 1 day.

### F02: Picker offers an Assistant action that is permanently unavailable

missing features — nice-to-have

`MonkeysPaw/Views/PickerView.swift:204-208`,
`Sources/MonkeysPawLinux/LinuxPanel.swift:462-464` and its assistant setup.

No-match users see a disabled Write action/setup hint even when a provider is configured
and Library Assistant works. The old milestone placeholder makes the configured app
appear incomplete.

Suggested fix: hand off the query to Library Assistant Write through a model intent,
reflecting provider availability, or remove the misleading dormant action.

Rough effort: half to one day across desktop front ends.

### F03: Android local-only libraries have no user export path

missing features — nice-to-have

Reproducible product scope: prompts live in app-private filesDir/library;
`docs/plan/10-android-client.md:262-268` explicitly defers export/mirror and
LibraryScreen's menu has no export action.

Users avoiding the sync server cannot easily take their authored Markdown library to
another tool or make an inspectable manual backup.

Planned omission, not a specification violation.

Suggested fix: opt-in SAF export with explicit destination, private-prompt warning and
per-file report; keep normal app I/O on direct private storage.

Rough effort: 1–2 days for export; mirroring is a larger separate feature.

### V01: Linux Settings starts at picker-sized height

visual issues and layout problems — nice-to-have

`Sources/MonkeysPawLinux/LinuxSettingsWindow.swift:74`.

Five Settings panes start in 640×420, leaving little vertical room after the header.
Users scroll through ordinary configuration immediately. The default is
source-confirmed; clipping and preferred size need live GTK testing. GTK windows are
resizable by default; no contrary claim is made.

Suggested fix: use a dedicated screen-bounded Settings default size and verify at small
displays/large text, preserving the existing scrolled content.

Rough effort: 1–2 hours plus Linux visual verification.

### V02: macOS diff lacks explicit addition/removal cues

visual issues and layout problems — nice-to-have

`MonkeysPaw/Views/LibraryDiffView.swift:45-62`.

Backgrounds distinguish added/removed lines, but text has no +/- marker or accessible
change label. Colour-blind/VoiceOver users have to infer changes from blank opposite
cells and column positions when accepting edits.

Suggested fix: add explicit signs and accessible change/column/line descriptions while
preserving exact content and newline markers. Verify with VoiceOver.

Rough effort: 2–3 hours.

### U02: Android tag dialog loses unconfirmed input on recreation

usability — nice-to-have

`android/app/src/main/kotlin/ch/lkmc/monkeyspaw/ui/editor/EditorForm.kt:58-59,73-93`.

Editing/input live only in remember state, so activity recreation dismisses the dialog
and loses the typed tag even though the main ViewModel draft survives. This affects
rotation and other recreation while adding tags.

Suggested fix: save the small dialog index/input with a document identity key; reject
stale indices if tags change. Verify rotation preserves unconfirmed input.

Rough effort: 1–2 hours.

### A01: Picker selection hardcodes white over the selected accent

aesthetics and theming — nice-to-have

`MonkeysPaw/Views/PickerView.swift:171-184`.

Bright user accents can give weak contrast for white title and 85%-white metadata,
particularly at caption size. The hardcoded pair is confirmed;
yellow/graphite/light/dark/increased-contrast need visual checks.

Suggested fix: use a semantic selected foreground/background pair and verify supported
appearances; avoid changing the app's otherwise native restrained theme.

Rough effort: 1–2 hours plus visual checks.

### N01: Explain surprising fuzzy matches

novel, delightful, or quirky ideas worth trying — nice-to-have

`Sources/MonkeysPawCore/Domain/Library/PromptSearch.swift:24`,
`Sources/MonkeysPawCore/Presentation/PickerModel.swift:418`.

Matches already know their matched fields, but picker rows drop them. A body-only hit
can look unrelated to the visible title/description.

Optional product experiment.

Suggested fix: show a quiet “Matched in body” cue or safe excerpt only when visible
metadata does not explain the match. Avoid exposing field values/secrets.

Rough effort: half a day for cues, about 1 day for excerpts.

### N02: A lightweight prompt test bench

novel, delightful, or quirky ideas worth trying — nice-to-have

Product idea anchored in `Sources/MonkeysPawCore/Presentation/FillModel.swift` and
Library preview.

Prompt authors currently inspect defaults and then use a separate fill session to try
realistic values. A local sandbox could make authoring more playful and expose
missing-field behavior before leaving Library.

Optional product experiment.

Suggested fix: offer Try with temporary values in Library, reusing FillService with no
delivery, usage learning or persisted remembered values; provide Reset.

Rough effort: 1–2 days across desktop UIs.
