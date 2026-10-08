## 13. Testing

| Layer | How |
|---|---|
| Core domain | Unit tests on macOS and Linux:<br>• grammar table (escapes, invalid `{{…}}`, reuse, ordering) and single-pass render<br>• front matter round-trip with unknown keys; validation messages<br>• ranking with an injected clock; history pruning; diff<br>• artifact JSON → file and the merge rule<br>• review parsing with fence/`<think>`/brace recovery<br>• SyncAPI DTO round-trips |
| Presentation models | Keystroke-budget scenarios (§2) and state machines (picker, fill, assistant phases, setup, account) driven without any UI. These replace UI tests for logic; views stay thin. |
| Services | Fakes for every port.<br>• `DeliveryService`: the call order write → hide → settle → restore → inject; failure caching; copy-only fallback; chord selection.<br>• `AssistantService`: cancel in flight (gate fake); retry-with-feedback transcripts.<br>• `SyncService`: §13.1. |
| LLM transport | Request-level stub transport (Vervellum doctrine: doubles answer *requests*). It asserts:<br>• per-provider headers, with no `x-api-key` sent to OpenAI and vice versa<br>• no sampling parameters to Anthropic; the `/v1` normalisation; keyless local servers<br>• truncation, refusal, and empty 200<br>• redirect refusal, and the 400 → `json_object` downgrade |
| Linux drivers | • Fake executables on `PATH` for `ydotool` (both dialects; unknown help → refuse), `gsettings` (argv capture), `xdotool`, and `secret-tool` (asserts stdin, not argv).<br>• GDBus drivers against a private bus (`dbus-run-session`) with mock portal and KGlobalAccel services.<br>• GTK lifecycle tests under Xvfb (Vervellum `linux.yml`). |
| macOS drivers | Unit tests for the CGEvent sequence builder, the AX-focus wait (fake clock), Carbon modifier translation, and Keychain blob encoding. |
| Server | Hummingbird's test client against an in-memory SQLite:<br>• every endpoint and every row of the §8.2 permission matrix (allowed and denied)<br>• compare-and-swap conflicts; per-scope feeds after moves and membership changes (a non-member never receives a row)<br>• snapshot mode for new and stale cursors; login backoff; invite single-use; migrations from an empty database |
| Sync integration | §13.1. |
| Deployment | In CI:<br>• `docker compose config -q` (default and `--profile tls`)<br>• image build; `compose up --wait`; `/api/health`<br>• a login + push + pull smoke test with `curl`; `shellcheck update.sh` |
| Conformance | `spec/fixtures/` run by `MonkeysPawCoreTests` and the Android `:core` tests; each suite fails on a fixture it does not consume. `spec/schema/` is regenerated in CI and diffed. |
| Android | `:core` JVM tests with fakes, including the `sync/*.json` scenarios and the §13.1 suite against the real server in CI. App JVM tests for ViewModels, the IME `inputType` decision table, and the entry activities' intent handling. No emulator job (HalloMiao decision). |
| End-to-end, manual | A per-release checklist in `docs/platform/`: macOS (Safari, Chrome, Terminal, full-screen Space), GNOME Wayland, KDE Wayland, X11, Android (Chrome, ChatGPT, Claude, Termux; Gboard and Samsung Keyboard). Run the §6.5 self-test plus a browser chat box and a terminal. Two devices and two users syncing a group prompt, one of them a phone. |

### 13.1 Sync tests

`SyncService` runs against a real `MonkeysPawServer` started in-process on a
temp SQLite, with two simulated devices and two users. Scenarios:

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
