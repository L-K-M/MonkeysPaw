## 13. Testing

| Layer | How |
|---|---|
| Core domain | Unit tests on macOS and Linux:<br>• grammar table (escapes, invalid `{{…}}`, reuse, ordering) and single-pass render<br>• front matter round-trip with unknown keys; validation messages<br>• ranking with an injected clock; history pruning; diff<br>• artifact JSON → file and the merge rule<br>• review parsing with fence/`<think>`/brace recovery<br>• SyncAPI DTO round-trips |
| Presentation models | Keystroke-budget scenarios (§2) and state machines (picker, fill, assistant phases, setup, account) driven without any UI. These replace UI tests for logic; views stay thin. |
| Services | Fakes for every port.<br>• `DeliveryService`: the call order write → hide → settle → restore → inject; failure caching; copy-only fallback; chord selection.<br>• `AssistantService`: cancel in flight (gate fake); retry-with-feedback transcripts.<br>• `SyncService`: deterministic request, orchestration and durable-operation failures; real client/server acceptance belongs to §13.1. |
| LLM transport | Request-level stub transport (Vervellum doctrine: doubles answer *requests*). It asserts:<br>• per-provider headers, with no `x-api-key` sent to OpenAI and vice versa<br>• no sampling parameters to Anthropic; the `/v1` normalisation; keyless local servers<br>• truncation, refusal, and empty 200<br>• redirect refusal, and the 400 → `json_object` downgrade |
| Linux drivers | • Fake executables on `PATH` for `ydotool` (both dialects; unknown help → refuse), `gsettings` (argv capture), `xdotool`, and `secret-tool` (asserts stdin, not argv).<br>• GDBus drivers against a private bus (`dbus-run-session`) with mock portal and KGlobalAccel services.<br>• GTK lifecycle tests under Xvfb (Vervellum `linux.yml`). |
| macOS drivers | Unit tests for the CGEvent sequence builder, the AX-focus wait (fake clock), Carbon modifier translation, and Keychain blob encoding. |
| Server | Hummingbird's test client against an in-memory SQLite:<br>• every endpoint and every row of the §8.2 permission matrix (allowed and denied)<br>• compare-and-swap conflicts; per-scope feeds after moves and membership changes (a non-member never receives a row)<br>• snapshot mode for new and stale cursors; login backoff; invite single-use; migrations from an empty database |
| Sync integration | `server/Tests/MonkeysPawSyncIntegrationTests/`, compiled in Swift 5 mode. §13.1 scenarios execute through Core's HTTP port into the real Hummingbird router, authentication, services and repositories on migrated temporary file SQLite. Each device owns independent disk/secret roots and a Core graph. The suite enumerates and executes every `spec/fixtures/sync/*.json` case exactly once; unknown or unused inputs/expectations fail. |
| Deployment | CI job `compose-smoke`:<br>• `docker compose config --quiet` (default and `--profile tls`; TLS configuration only)<br>• local image build; `compose up --wait --wait-timeout 120`; unauthenticated `/api/health`<br>• bootstrap login, private PUT + GET, initial snapshot, second PUT + GET and delta from the snapshot cursor, asserting id/rev/path/content and database identity<br>• `shellcheck`, Bash syntax and fake-command smoke tests; `shellcheck update.sh` when S19 supplies it |
| Conformance | Nine content categories in `spec/fixtures/` run by `MonkeysPawCoreTests` and Android `:core`; each suite fails on an unconsumed file in its owned categories. Both explicitly delegate `sync/` to the server integration target; Kotlin sync-engine replay arrives in M10. Server Schema tests call `MonkeysPawServer.SchemaRenderer` directly, check deterministic bytes and complete catalog coverage, and validate every DTO fixture against the emitted keywords plus documented contract annotations, comparing with strict Codable. One CLI test runs the built `dump-schema` executable with a deadline. These schema tests need no database, GTK or network. CI regenerates `spec/schema/` into a fresh directory and compares recursively, including missing and extra files. |
| Android | `:core` JVM tests with fakes, including the `sync/*.json` scenarios and the §13.1 suite against the real server in CI. App JVM tests for ViewModels, the IME `inputType` decision table, and the entry activities' intent handling. No emulator job (HalloMiao decision). |
| End-to-end, manual | A per-release checklist in `docs/platform/`: macOS (Safari, Chrome, Terminal, full-screen Space), GNOME Wayland, KDE Wayland, X11, Android (Chrome, ChatGPT, Claude, Termux; Gboard and Samsung Keyboard). Run the §6.5 self-test plus a browser chat box and a terminal. Two devices and two users syncing a group prompt, one of them a phone. |

Schema regression tests distinguish numeric 0/1 from literal true/false,
retain exact Int64 bounds, distinguish `number` from `integer`, and reject
malformed JSON and `type`/`required` values in the test validator. Timestamp
annotations require exact UTC millisecond spelling and a valid Gregorian
date. Scope keys match their user/group branch; admin invite branches accept
an empty account request and reject partial group targets. Directory-set
checks ignore hidden metadata, and the CLI runner kills timed-out children.
Every UTF-8 byte cap also emits a standard `maxLength`
backstop: generic validation rejects excess code points, while contract
validation additionally rejects excess bytes below the code-point cap.
ASCII and multi-byte boundary cases cover passwords, content and paths.

The [Compose smoke script](../../scripts/compose-smoke.sh) uses a fresh,
disposable database. PUT returns only rev/seq and optional warnings (§8.3),
so GET verifies the stored representation before each pull verifies its feed
payload. The input uses canonical front matter and LF body bytes; private
storage preserves those exact bytes. Initial pull sends explicit
`database_id: null` with no cursors; the delta sends the returned database
identity and completed snapshot cursor. Every HTTP call has connection and
total deadlines and requires 200. Password JSON, bearer headers and responses
stay in private files removed on exit; bodies and curl stderr are never
printed. CI writes a random bootstrap secret into a 0600 `.env`, provisions
0700 binds with UID/GID 1000, prints server logs on failure, and always runs
`compose down -v` and removes private files. Fake curl tests prove request
shapes, secret-free argv/output, cleanup and rejection of incorrect responses;
they do not prove Docker runtime behavior.

[Server owner checks](../platform/server.md) cover a fresh host, real-domain
HTTPS and TLS persistence across two `update.sh` re-runs, plus backup/restore.
Desktop login/push/pull is recorded after M6 supplies the client. CI validates
the TLS configuration without starting Caddy or requesting certificates.

### 13.1 Sync tests

`SyncService` runs against a real `MonkeysPawServer` started in-process on a
temporary file SQLite, with two simulated devices and two users. The version-1
scenario contract is documented in [spec/README.md](../../spec/README.md).
The existing `swift test --package-path server` command owns this acceptance
suite; root fake tests and native driver tests provide different proofs.
Router connection metadata is supplied by a test responder wrapper for login's
peer-IP policy; no successful server mutation is synthesized. Network mutations
may corrupt a real request/response or commit a peer request before another
request. Restarts reopen the device's persisted library, state and secret roots.
Temporary roots are removed on success and failure; scenario/request deadlines
bound startup and execution. These disk adapters do not prove native system
trash or power loss. Row 17 uses the live loopback harness and a test-only
SyncCrashWorker, with real SIGKILL after partial durable file publications,
before state publication and after durable state commit before journal cleanup.
Fresh workers recover the same roots; all child paths have bounded cleanup and
stdin-only credentials. Retention and restore scenarios use the production
services, including closing database users for offline restore. Bulk snapshot
paging and expiry assertions exercise Core's collector without applying files.
Scenarios:

- a basic round trip; our own pushes echoed back are no-ops
- offline edits on both devices → conflict copy in `Conflicts/`, never in the group folder
- edit vs delete, both ways; a delete answered with 410 counts as success
- viewer edits, deletes, or moves a file → 403 → restored, plus a private copy
- move private → group, group → private, group → group; a move plus an edit
- member removed while offline (even past retention) → scope `removed` → dirty files rescued, rest trashed
- member added → snapshot of the group
- cursor below the floor, cursor above the head, `database_id` changed → snapshot
- a move between scopes in one pull → the file moves, never trash + recreate
- group renamed → folder renamed, ids unchanged; group deleted → scope removed
- path clash → local rename first, bounded; case-only and NFC/NFD clashes
- path traversal (`../`, absolute paths, control characters) rejected by the server, and re-checked on pull
- second device with the same library (git copy) → adopts ids, no duplicates
- sign-in as a different user → state discarded, folders rescued, nothing pushed across accounts
- `favorite` added to a group file → lifted to local state, no push loop
- 422 invalid content → `syncError`, no retry loop
- crash mid-pull (killed after some files are written) → resume without loss or duplicates
- rename on one device while the other edits
- two devices move one prompt to different scopes at once → one winner, no trashed file
- our own move echoed back as `move_out` → no-op; a move pair split across pull pages → the file moves, never trashed
- remote rename → the old file is gone, and no rename is pushed back
- server restored from backup (`database_id` changed, revs lower) → local content re-pushed or rescued, nothing trashed
- every change row of a quiet scope purged while a device is offline → snapshot detected through the floor

Shared Core tests may use `@testable import`: both `swift test` and Xcode
Debug builds compile local packages with testing enabled.

Bug fixes start with a failing test at the lowest layer that can observe the
bug.
