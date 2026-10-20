## 4. Architecture

### 4.1 Components

```
                    ┌──────────────────── MonkeysPawCore (Swift package target) ───────────────────┐
                    │ Foundation + Yams only. Domain · Ports · Services · Presentation models ·     │
                    │ Assistant (LLM) · SyncEngine · SyncAPI (Codable DTOs)                         │
                    └───────┬──────────────────────────┬─────────────────────────────┬──────────────┘
                            │ linked by                │ linked by                   │ linked by
┌───────────────────────────▼─────────┐ ┌──────────────▼──────────────────┐ ┌────────▼──────────────────────┐
│ macOS app (Xcode, MonkeysPaw/)      │ │ Linux app (SwiftPM, monkeyspaw) │ │ Server (server/Package.swift) │
│ SwiftUI + AppKit views, NSPanel     │ │ GTK4 widgets via CGtk shim      │ │ Hummingbird routes            │
│ macOS drivers: Carbon hotkey,       │ │ Linux drivers: GDBus portals,   │ │ Server services (auth, sync,  │
│ CGEvent paste, Keychain, NSWorkspace│ │ KGlobalAccel, gsettings, ydotool│ │ groups) · Fluent repositories │
│                                     │ │ xdotool, secret-tool, GdkClipbd │ │ SQLite (WAL) on /data         │
└─────────────────────────────────────┘ └─────────────────────────────────┘ └───────────────────────────────┘
                                   HTTPS (device token) ───────────────────────────► sync API
                                                                                       ▲
┌──────────────────────────────────────────────────────────────────────────────┐       │
│ Android app (android/, Kotlin + Compose)                                     │───────┘
│ :core = Kotlin port of MonkeysPawCore, kept in step by spec/fixtures (§10.7) │
│ IME picker · tile → fill → copy · selection action · WorkManager sync        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Layers inside each desktop app

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ Views (per OS)   macOS: SwiftUI/AppKit       Linux: LinuxPanel picker/fill via CGtk   │
│                  Render presentation state; forward user intents. No logic.          │
└───────────────────────────────────────┬──────────────────────────────────────────────┘
┌───────────────────────────────────────▼──────────────────────────────────────────────┐
│ Presentation models (Core, shared)   PickerModel · FillModel · LibraryModel ·         │
│ AssistantModel · SettingsModel · SetupModel · AccountModel                            │
│ Platform-neutral state machines with an `onChange` callback; the view republishes.    │
└───────────────────────────────────────┬──────────────────────────────────────────────┘
┌───────────────────────────────────────▼──────────────────────────────────────────────┐
│ Services (Core)   LibraryService · FillService · DeliveryService · AssistantService · │
│ ShortcutService · SettingsService · SyncService                                       │
└───────────────┬───────────────────────────────────────────────────────┬──────────────┘
┌───────────────▼───────── Domain (Core, pure) ──────┐ ┌────────────────▼─ Ports (Core protocols) ┐
│ Prompt · FrontMatter · Template · Fields · Render · │ │ PromptStore StateStore WallClock          │
│ Search · Ranking · History · LlmArtifact · Rubric · │ │ PanelWindow FocusTracker PasteInjector    │
│ Diff · SyncState                                    │ │ HotkeyBackend Notifier SecretStore        │
└─────────────────────────────────────────────────────┘ │ HTTPTransporting SessionProbe Clipboard   │
                                                        └────────────────▲──────────────────────────┘
┌────────────────────────────────────────────────────────────────────────┴─────────────────────────┐
│ Drivers (per OS, in the front-end targets)  implement ports; the only code touching OS/fs/net      │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Rules:

- **Linux picker (M2f).** `LinuxPanel` renders `PickerModel`/`FillModel` and
  forwards search, selection, focus and delivery intents. `LinuxEnvironment`
  owns the library/index/watcher service graph and the shared GTK clipboard;
  view callbacks forward file/folder launch and prompt-creation actions there.
  The macOS picker (M2h) uses the same Core models; `AppDelegate` owns its
  library graph, file/folder launcher and prompt creation. Both front ends
  have replaced the canned M1 panel.

- **Each layer calls only the layer directly below it.** Views never touch a
  service, the clipboard, files, keys, or HTTP. Presentation models never
  touch drivers. Services see drivers only through port protocols.
  Domain and Ports form one layer under Services. One narrow exception:
  replacing the library graph is a composition intent, so
  `GeneralSettingsModel` calls the `LibraryLocationControl` port that each
  composition root implements; composition alone validates, restarts and
  persists the folder choice.
- **Portable networking exception** ([§19 B1](19-m4-m5-decisions.md)).
  `URLSessionHTTPTransport` is a shared driver in Core's `Platform/`,
  constructed by the composition roots and injected as `HTTPTransporting`.
  It uses data-task delegate callbacks. Conditional `FoundationNetworking`
  on Linux counts as Foundation; Core otherwise imports Foundation + Yams
  only. OS secrets remain in platform drivers.
- **Portability rule** (Vervellum). Nothing in `MonkeysPawCore` imports
  AppKit, SwiftUI, Combine, `os`, `Security`, or `CGtk`. Two Linux traps
  that must never appear in Core:
  - `@MainActor` / `DispatchQueue.main`, which never run under a GLib main
    loop. Callbacks are delivered through an injected `MainThread` port;
    the Linux driver marshals with `g_idle_add`.
  - `URLSession.bytes(for:)`, which is absent on Linux.
  The Linux CI job is the gate.
- **Module boundary.** Core is its own module on both platforms. The Xcode
  project links the local package product `MonkeysPawCore`, and so do the
  Linux app and the server. `public` marks exactly the API that front ends
  and the server consume. Everything else stays `internal` or `private`.
  This differs from Vervellum, which compiles Core straight into the macOS
  target through a synchronized group. A third consumer (the server) needs
  Core without GTK, and an explicit public surface is the owner's
  visibility rule anyway.
- **Composition roots.** Only two places construct drivers and inject them
  into services: `AppDelegate` on macOS and `LinuxEnvironment` on Linux
  (the Vervellum pattern). Views receive presentation models; nothing else
  constructs a driver.
- **Linux entry point.** A top-level `main.swift` calling
  `exit(MonkeysPawLinuxApp.main())`. Never `@main` with an async `main()`,
  which would drain the dispatch main queue in competition with GLib
  (Vervellum).
- **Subprocess discipline** (Vervellum), for `gsettings`, `ydotool`,
  `xdotool`, and `secret-tool`:
  - argument arrays, never shell strings, with resolved absolute paths
  - stderr goes to `/dev/null`, or is drained; an undrained pipe blocks the
    child at 64 KB
  - read stdout before `waitUntilExit`
  - stdin writes use `try?`, because EPIPE raises an Objective-C exception
  - a non-zero exit returns nil; tool error text is never logged
- **Enums over booleans.** Behavioural modes are enums: `DeliveryMode`,
  `PasteChord`, `FieldKind`, `SecretTier`, `HotkeyMechanism`, `Scope`,
  `Role`. Boolean *properties* in the file format (`favorite`, `private`,
  `optional`, `remember`) are data and stay booleans.
- **Named constants.** Timings, limits, and sizes are constants in
  `MonkeysPawCore/Domain/Limits.swift` (server: `ServerLimits.swift`).
  Values in this plan are their initial values.
- **Thread rules** (Copywraith and Vervellum lessons):
  - Panel and window operations run on the UI thread.
  - `PromptEditingService` runs file and codec work through the serial,
    nonblocking `BackgroundWork` port and returns immutable results through
    `MainThread`.
    Workers accept submissions from any thread. A drain succeeds only when
    its queued barrier executes after earlier work. Releasing a rejected or
    retired barrier cancels the wait; library replacement and quit must refuse
    that cancellation rather than treating it as a completed drain.
  - Platform workers never use the dispatch main queue on Linux.
  - Paste injection runs off the UI thread and is never awaited inline by a
    view.
  - Hotkeys fire on key *release*, with a toggle debounce.

### 4.3 Server layers

```
Routes (Hummingbird router + middleware: request id, auth, rate limit)
  → Server services (AccountService, DeviceService, GroupService, PromptService, SyncFeedService)
    → Repositories (Fluent models + migrations)  ── SQLite (WAL), /data/monkeyspaw.db
```

- Routes decode `SyncAPI` DTOs from Core, call one service, and map typed
  errors to HTTP status codes.
- Services enforce permissions inside the write transaction.
- Services use Core's `FrontMatter` and `Template` to validate uploaded
  prompt files.

### 4.4 Repository layout

```
MonkeysPaw/
  Package.swift                 MonkeysPawCore (+ Yams); on Linux also CGtk (systemLibrary gtk4)
                                and the `monkeyspaw` executable; MonkeysPawCoreTests
  Sources/
    MonkeysPawCore/             Domain/ Ports/ Services/ Presentation/ Assistant/ Sync/ SyncAPI/
    MonkeysPawLinux/            #if os(Linux): GTK front end + Linux drivers
    CGtk/                       shim.h + module.modulemap (GTK4, GIO/GDBus)
    monkeyspaw/                 Linux entry point
  Tests/MonkeysPawCoreTests/    run on macOS and Linux
  Tests/MonkeysPawLinuxTests/   GTK lifecycle under Xvfb, driver fakes
  MonkeysPaw.xcodeproj          macOS app; links the local package product MonkeysPawCore
  MonkeysPaw/                   App/ Panel/ Hotkeys/ Paste/ Security/ Views/ Settings/ Resources/
  MonkeysPawTests/              macOS driver and view-model glue tests
  server/
    Package.swift               MonkeysPawServer (+ Hummingbird, Fluent); depends on ../ for MonkeysPawCore
    Sources/MonkeysPawServer/   Routes/ Services/ Repositories/ Migrations/ Admin/ (CLI)
    Sources/monkeyspaw-server/  entry point: serve | migrate | healthcheck | user | group | backup
    Tests/MonkeysPawServerTests/
    Dockerfile
  compose.yaml  .env.example  update.sh
  deploy/nginx-proxy-manager/compose.override.yaml.example
  packaging/debian/  flatpak/ch.lkmc.monkeyspaw.yml  scripts/  media-sources/  seed/  docs/platform/
  android/                      Gradle root: settings, version catalog, wrapper
    core/                       kotlin("jvm") module: the Kotlin port of the core domain + sync engine
    app/                        ch.lkmc.monkeyspaw: Compose UI, IME, tile, entry activities, drivers
  spec/
    fixtures/                   language-neutral conformance cases, run by Swift and Kotlin tests
    schema/                     JSON Schemas generated from SyncAPI (CI fails on drift)
  docs/plan/                    this plan, one file per section
  .github/workflows/            ci.yml linux.yml release.yml zai-code-review.yml
  AGENTS.md CLAUDE.md CHANGELOG.md PLAN.md README.md SECURITY.md PRIVACY.md CICD.md
```

The server package must build without GTK headers, so `CGtk` and the Linux
app sit outside `MonkeysPawCore`'s dependency closure. M0 proves this: the
server Docker image builds in a container with no GTK.

`seed/` holds the first-run Markdown prompts and an excluded root README.
`python3 scripts/generate-seeds.py` deterministically embeds their relative
paths and exact UTF-8 bytes in Core's checked-in `SeedCatalog.generated.swift`.
Both apps link that catalog without resource bundles, Xcode resource phases
or separate deb assets. Core tests fail on missing/extra prompts or byte drift.

### 4.5 Core service APIs (sketch)

```swift
public final class LibraryService {
    // M2b store API. Search/index APIs follow in later slices.
    public func entries() throws -> [LibraryEntry]
    public func load(at path: String) throws -> LibraryEntry
    public func save(_ document: PromptDocument, at path: String,
                     expectedStamp: FileStamp? = nil) throws -> LibraryEntry
    public func assignIdentity(to path: String,
                               expectedStamp: FileStamp? = nil) throws -> LibraryEntry
    public func availablePath(for path: String) throws -> String
    public func move(from source: String, to destination: String) throws -> LibraryEntry
    public func delete(at path: String, expectedStamp: FileStamp? = nil) throws
    public func history(for identity: PromptIdentity) throws -> [HistoryRevision]
    public func restore(_ revision: HistoryRevision, at path: String,
                        expectedStamp: FileStamp? = nil) throws -> LibraryEntry
}

public final class FillService {
    // Always completes; failed inputs deliberately resolve as empty values.
    // This fallback is the snapshot contract, with no separate error channel.
    public func builtinSnapshot(for document: PromptDocument,
        completion: @escaping @Sendable (PromptBuiltinValues) -> Void)
    // Entry supplies remembered-values identity and status; preview/render
    // below need only its document.
    public func form(for entry: LibraryEntry) -> FillForm
    public func preview(_ document: PromptDocument, values: [String: String],
        builtins: PromptBuiltinValues) -> FillPreview
    public func render(_ document: PromptDocument, values: [String: String],
        builtins: PromptBuiltinValues) throws -> String
    public func rememberedOnDelivery(identity: PromptIdentity, fields: [PromptField],
        values: [String: String]) throws
}

public enum DeliveryMode { case paste(PasteChord), copyOnly }
public enum PasteChord { case standard, terminal }                  // Cmd/Ctrl+V vs Ctrl+Shift+V
public enum DeliveryOutcome { case pasted(Backend), copiedOnly(CopyReason) }
public final class DeliveryService {
    public func arm()                                                // hotkey fired: remember target
    public func deliver(_ text: String, mode: DeliveryMode, done: @escaping (DeliveryOutcome) -> Void)
    public func selfTest(done: @escaping (SelfTestReport) -> Void)   // §6.5
}

public final class AssistantService {
    public func write(brief: String) async throws -> Draft
    public func review(_ prompt: Prompt) async throws -> Review
    public func improve(_ prompt: Prompt, request: ImproveRequest) async throws -> Draft
    public func testConnection(_ draft: ProviderDraft) async throws -> [ModelID]
}

public final class SyncService {
    public func signIn(server: URL, username: String, password: String, deviceName: String) async throws
    public func signOut() async
    public func syncNow() async -> SyncReport                         // pull, apply, push, resolve
    public var status: SyncStatus { get }   // idle · syncing · offline · needsSignIn · hasConflicts · syncError
}
```

Async calls in Core never hop to a main actor. Results reach the UI through
the presentation model's `onChange`, which each front end republishes on its
own UI thread.

`assignIdentity(to:expectedStamp:)` checks a supplied stamp before assignment
or returning an already assigned entry. A mismatch throws
`LibraryError.conflict`; nil uses the version read by the operation.

### 4.6 Port → driver map

| Port | macOS driver | Linux driver | Precedent |
|---|---|---|---|
| `PanelWindow` | `NSPanel` subclass: `[.borderless, .nonactivatingPanel]`, `canBecomeKey = true`, `becomesKeyOnlyIfNeeded = false`, `level = .floating`, `hidesOnDeactivate = false`, `[.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient]`; shown with `orderFrontRegardless` + `NSApp.activate()` + `makeKey()` | `GtkApplicationWindow`, `gtk_window_present`, compositor-placed | Vervellum `ResearchPanel.swift`, `PanelController.swift`, `LinuxPanel.swift` |
| `FocusTracker` | `arm()` captures the frontmost `NSRunningApplication` (pid and bundle id, not its name) before the panel shows. Restore uses `NSApp.yieldActivation(to:)` + `activate(options:)`, then verify and retry. Dismissal without delivery restores only if we are still frontmost; a user who clicked elsewhere is not yanked back. | none (compositor refocus) | Invoque `AppActivator.swift`; Vervellum `PanelController.swift:104-107, 338-352` |
| `PasteInjector` | CGEvent Cmd+V after an AX-focus wait; AppleScript fallback | ladder §6.1: RemoteDesktop portal (GDBus), ydotool and xdotool (`Process`) | Invoque `InvoqueBridge.swift:528-654`; Copywraith `ydotool.rs` |
| `HotkeyBackend` | Carbon `RegisterEventHotKey` (no permission) | ladder §6.1 over GDBus and `gsettings` | Vervellum `CarbonHotkey.swift`, `ShortcutInstaller.swift`; Copywraith `shortcuts/kde.rs` |
| `Clipboard` | `NSPasteboard`; reads complete inline on the caller's AppKit UI thread | `GdkClipboard`; text reads use `gdk_clipboard_read_text_async` through a `GTask` shim returning once on the owning GTK context; the resident app retains write ownership | Vervellum; M2e |
| `Notifier` | `UNUserNotificationCenter` | `GNotification` via `g_application_send_notification`: no actions, so it cannot steal focus. Under flatpak it goes through the notification portal with no extra permission. | Copywraith `notifications.rs` (behaviour); GIO |
| `SecretStore` | Keychain, one item with a JSON map | env → `secret-tool` (stdin) → 0600 file | Vervellum `KeychainStore.swift`, `LinuxSecretStore.swift` |
| `HTTPTransporting` | `URLSession` delegate transport (in Core) | same | Vervellum `HTTPTransport.swift` |
| `FileStore` | `RootedFileStore`: Foundation atomic replacement and rooted file operations; `writePrivate` creates a 0600 temporary file, writes and fsyncs it before rename | same, with Linux metadata stamps | M2b/M2e; stands in for the sketch's `PromptStore` / `StateStore` ports; two instances, for library and app data |
| `FileStoreWatcher` | `RootedFileWatcher`: recursive FSEvents stream with regular-file snapshot reconciliation | `RootedFileWatcher`: non-recursive GIO `GFileMonitor` per directory, with recursive attachment/reconciliation on the owning GLib main context (via the `CGtk` bindings) | M2c; raw relative-path events feed Core `LibraryWatcher`, whose injected `Scheduler` owns debounce |
| `WallClock` / `EntropySource` | Core `SystemClock` / `SystemEntropy` | same | Foundation / stdlib; injected into identity/history lifecycle |
| `PromptKeyedStore` | Core history, usage and remembered-values stores over app-data `FileStore` | same | M2b/M2d/M2e; usage and remembered values join now |
| single instance / CLI | n/a (in-process hotkey) | `GtkApplication` D-Bus activation; actions `toggle`, `repeat`, `selftest` | Vervellum `LinuxApp.swift:239-325` |

The §4.2 diagram keeps the sketch port names. `EntropySource` and
`PromptKeyedStore` are the M2b port names for injected entropy and keyed-state
migration.

M2b's `FileStore` covers the sketch's `PromptStore` file access and
`StateStore` app-data file access. It lists regular files with opaque
`FileStamp` equality, reads/writes whole `Data`, deletes, and moves without
replacing a destination. Per-OS drivers perform lexical/root/symlink checks;
Core never reads files directly. Drivers canonicalize the selected root
once by resolving its deepest existing ancestor, then appending missing
components literally. This supports roots beneath macOS's `/var` symlink
or a symlinked Linux home even before the root exists. Subsequent operations
reject symlinked components in the canonical path; listing skips all
symlinks. Stamps include device/inode, size, and nanosecond mtime
and change time (plus birth time on macOS).

M2e adds `writePrivate` without changing ordinary `write`. Both rooted drivers
use a same-directory `mkstemp` file, pin its mode to 0600 with `fchmod` before
writing any private bytes, then rename the completed file over the destination.
Failure removes the temporary file and leaves the previous destination intact.
Existing root/path/symlink checks apply. Core calls only the port.

M2c adds `FileStoreWatcher` without changing `FileStore` or wiring the app.
Both drivers mirror the store's POSIX canonicalization and ignore symlinks
and nonregular files. Native notifications reconcile a metadata snapshot
into raw `created`, `modified`, or `deleted` events at relative POSIX paths;
directory moves/removals include their regular-file descendants. There is
no driver debounce or prompt filtering. Each delivered native batch triggers
one coalesced full rescan; Linux runs it at idle priority after queued monitor
callbacks drain. Linux arms each directory before
enumerating it and keeps canonical ancestor monitors to recover a missing
or replaced root. Its lifecycle runs on the owning GLib thread. macOS uses
one recursive FSEvents stream, with zero latency and `WatchRoot`; dropped-event
batches also trigger the full rescan. The stream
starts on the nearest existing ancestor when the root is absent and
reattaches to the real root when it appears. A serial dispatch queue owns
its resources. Each macOS snapshot opens the canonical path from `/` one
component at a time with `openat`, `O_DIRECTORY` and `O_NOFOLLOW`, then
enumerates with `fdopendir` and fd-relative metadata/child-directory access.
Replacing an ancestor with a symlink cannot redirect that scan. Before
accepting it, the driver walks the canonical path again and compares the
ancestor and root device/inode identities with the opened tree. A missing,
symlinked, inaccessible or changed root discards the scan and retains the
last good baseline; monitor attachment uses the newly checked safe ancestors.
An identity change during a scan reports `notFound`, even if a replacement
directory is already present. A later successful scan can reconcile it.
This scan guarantee does not change FileStore's check-then-act operations.
[Apple's FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
describes root-change detection and snapshot reconciliation;
[GIO's FileMonitor documentation](https://docs.gtk.org/gio/class.FileMonitor.html)
specifies callback delivery on the creating thread's main context.

Both drivers report root unavailability on the same ordered callback as file
events, once per transition, without diffing root loss into file deletions.
They retain the last good baseline. Core flushes earlier pending changes before
health and delivers both through its scheduler; desktop composition stops the
watcher and retains its cached index until restart. Its root check before
applying a batch also protects earlier pending reloads flushed after root loss.
A streak is consecutive failed or overflow callbacks: a successful scan ends
a failure streak, and a normal callback ends an overflow streak.
FSEvents flags `MustScanSubDirs`, `UserDropped` and `KernelDropped` trigger one
path-free warning per overflow streak and the usual full rescan. GLib
[2.80.0's inotify backend](https://github.com/GNOME/glib/blob/2.80.0/gio/inotify/inotify-path.c#L497-L509)
discards `IN_Q_OVERFLOW` before `GFileMonitor` delivery, exposing no overflow
flag to the Linux driver. Full scans of delivered batches reconcile dropped
individual events across the entire tree; an isolated overflow with no further
delivered batch is not observable through this port and cannot be logged.

Neither driver creates roots or emits its initial baseline. Start/stop are
idempotent, stop releases monitoring resources, and a new start takes a
fresh baseline. Core `LibraryWatcher` uses only raw events and `Scheduler`,
never filesystem access or time reads. Lifecycle epochs reject obsolete
raw callbacks; event generations invalidate non-cancelable debounce
callbacks. Notification consumers and `LibraryService` wiring remain in a
later slice.

An assigned id survives move, save, and restore, keeping its history key.
An unassigned prompt derives its identity from its relative path, so moving
it changes its history key.

The service synchronously serializes operations within one instance. Future
composition roots must share one service per library/app-data pair and run
file operations away from UI callbacks. M2b constructs no drivers in the
running apps because there is no consumer yet.
