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
│ Views (per OS)   macOS: SwiftUI/AppKit       Linux: GTK widgets through CGtk          │
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

- **Each layer calls only the layer directly below it.** Views never touch a
  service, the clipboard, files, keys, or HTTP. Presentation models never
  touch drivers. Services see drivers only through port protocols.
  Domain and Ports form one layer under Services.
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
  compose.yaml  .env.example  update.sh  deploy/caddy/Caddyfile.example
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
    public func form(for prompt: Prompt) -> FillForm                    // fields + prefills
    public func preview(_ prompt: Prompt, values: FieldValues) -> Rendered
    public func render(_ prompt: Prompt, values: FieldValues) throws -> String
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
| `Clipboard` | `NSPasteboard` | `GdkClipboard` (`gdk_clipboard_set_text`); the app stays resident, so it keeps ownership | Vervellum |
| `Notifier` | `UNUserNotificationCenter` | `GNotification` via `g_application_send_notification`: no actions, so it cannot steal focus. Under flatpak it goes through the notification portal with no extra permission. | Copywraith `notifications.rs` (behaviour); GIO |
| `SecretStore` | Keychain, one item with a JSON map | env → `secret-tool` (stdin) → 0600 file | Vervellum `KeychainStore.swift`, `LinuxSecretStore.swift` |
| `HTTPTransporting` | `URLSession` delegate transport (in Core) | same | Vervellum `HTTPTransport.swift` |
| `FileStore` | `RootedFileStore`: Foundation atomic replacement and rooted file operations | same, with Linux metadata stamps | M2b; stands in for the sketch's `PromptStore` / `StateStore` ports; two instances, for library and app data |
| `WallClock` / `EntropySource` | Core `SystemClock` / `SystemEntropy` | same | Foundation / stdlib; injected into identity/history lifecycle |
| `PromptKeyedStore` | Core history store over app-data `FileStore` | same | M2b; usage/values join later |
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
and change time (plus birth time on macOS). No watch API exists yet;
watchers and change notification belong to a later slice.

An assigned id survives move, save, and restore, keeping its history key.
An unassigned prompt derives its identity from its relative path, so moving
it changes its history key.

The service synchronously serializes operations within one instance. Future
composition roots must share one service per library/app-data pair and run
file operations away from UI callbacks. M2b constructs no drivers in the
running apps because there is no consumer yet.
