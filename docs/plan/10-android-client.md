## 10. Android client

### 10.1 Scope

The Android app is a full member of the system:

- It uses the same prompt format and placeholder grammar.
- It syncs with the same server, for personal and group prompts.
- It has the same conflict rules.

Android has no global hotkey and no cross-app paste injection, so the
"insert into the field you are typing in" loop uses the platform's
sanctioned mechanisms instead (§10.4). It is distributed the fleet way: an
APK on GitHub Releases, with no Play Store or F-Droid.

v1 features:

| Area | v1 |
|---|---|
| Library | browse, search, edit, folders, groups, tags, conflicts |
| Delivery | fill form; picker keyboard (IME); Quick Settings tile, shortcut, and widget into fill → copy; text-selection action; share target |
| Sync | sign-in, personal and group prompts, roles, invites (accept) |
| Assistant | write, review, improve (M11) |
| Not in v1 | accessibility-service auto-paste, overlays and bubbles, a user-visible library folder (SAF mirror), group administration (done on desktop) |

### 10.2 Stack

The stack follows HalloMiao, the fleet's model Android repo (a2 §1).
Current dependency pins live in the [version catalog](../../android/gradle/libs.versions.toml)
and the [Gradle wrapper](../../android/gradle/wrapper/gradle-wrapper.properties);
§20 records the original K1 choices. Change compatible pins together; see
the AGP 9 deadlock in Kararead's `DEPENDABOT.md`.

| Item | Choice |
|---|---|
| Build | Catalog-pinned AGP and Kotlin, checked-in Gradle wrapper, JDK 17 in CI (JDK 21 also works locally). No `kotlin-android` plugin: AGP 9 has built-in Kotlin. |
| SDK | `minSdk = 26`, `targetSdk = 37`, `compileSdkVersion("android-37.0")` with `android.suppressUnsupportedCompileSdk=37` |
| UI | Catalog-pinned Jetpack Compose BOM, Material 3, single activity + entry activities |
| DI | Catalog-pinned Hilt and KSP; graph wiring starts with app data drivers in M8 K12. |
| Serialization | kotlinx.serialization (JSON); snakeyaml-engine 3.x for front matter (kaml is archived) |
| Networking | OkHttp (+ okhttp-coroutines) behind an `HttpTransport` port, with `followRedirects(false)` (§7.1 transport rules). OkHttp is the fleet standard (Kararead, Neutrodyne). |
| Storage | app-private files (§10.6) + DataStore for settings |
| Secrets | AES-256-GCM key in AndroidKeyStore (StrongBox when available); ciphertext in DataStore. EncryptedSharedPreferences is deprecated. |
| Background | WorkManager |
| Ids | `ch.lkmc.monkeyspaw` (namespace and applicationId, lowercase per the conventions); launcher label "Monkey's Paw" from a string resource |

### 10.3 Architecture

```
android/core   kotlin("jvm") Gradle module. Pure Kotlin: a JVM module cannot import android.*
               domain/ format · grammar · render · validator · canonical form · path rules ·
                       ranking · history · diff · ULID · LLM artifacts
               ports/  PromptStore · StateStore · SecretStore · HttpTransport · Clock · Clipboard
               sync/   SyncAPI DTOs (kotlinx.serialization) · SyncEngine (coroutines)
               llm/    Anthropic + OpenAI-compatible clients over HttpTransport
android/app    ch.lkmc.monkeyspaw
├── data/    the only code touching Context, disk, network, Keystore, WorkManager
├── ui/      Compose screens + ViewModels (one immutable UiState per screen)
├── ime/     MonkeysPawImeService + the Compose lifecycle bridge
├── entry/   PromptTileService, ProcessTextActivity, ShareReceiverActivity, shortcuts, widget
└── di/      Hilt modules (the composition root)
```

- **Layering.** `ui` and `ime` → ViewModels → `core` services → ports, which
  `data` implements. The same rule as §4.2: views never touch disk, network,
  or Keystore.
- **Purity by construction.** `core` is a plain JVM module, so an
  `android.*` import does not compile, the way the Linux CI job guards the
  Swift core. It is tested on the JVM with fakes, so there is no
  `androidTest` and no emulator job, as in HalloMiao.
- **Assistant contracts (M11).** `domain/llm` owns immutable provider,
  action, output and body-free error values. `ports` owns suspend
  `HttpTransport` and `SecretStore`, plus an injected nanosecond monotonic
  clock. Request construction validates headers and byte caps before a driver
  can consume them. URL values are canonical strings so JVM URI parsing cannot
  reinterpret or reject Foundation's authority spellings. Only `app/data`
  implements networking and Keystore access;
  Core has no network client, Android, AndroidX or DI dependency. L7/L8 supply
  shared drivers if M10 has not already supplied them
  ([§20 J1/J2](20-m6-m8-decisions.md#m11-portable-assistant-contracts)).
- **Unicode parity.** `core` ships catalog-pinned ICU4J for NFC and Unicode
  properties, independent of Android's runtime Unicode version. Sync keys
  use the frozen Swift C/F table (§19 B4); search normalization remains a
  separate port. The [Android checklist](../platform/android.md) distinguishes
  dex/R8 packaging proof from the remaining minimum-API device check.
- **One process.** The IME, the tile, and the activities share one process
  and one warm in-memory prompt index in `Application`, so the keyboard picker
  opens instantly and never waits for disk or network.

### 10.4 Delivery flows

**A. Picker keyboard (IME). The fast lane, for prompts without free-text
fields.**

1. While typing in any app, the user switches keyboards: the globe key on
   Gboard, or the navigation-bar keyboard button. Monkey's Paw opens in the
   keyboard area as a searchable prompt list. It is picker-only, with no
   letter keys.
2. Fields that need no typing are filled inline: `choice`, defaults,
   remembered values, `{{clipboard}}`. The current IME may read the
   clipboard.
3. Tap → `currentInputConnection.commitText(result, 1)` →
   `switchToPreviousInputMethod()` returns the user to their keyboard.
   - That call needs API 28+. On API 26-27 the app falls back to
     `InputMethodManager.switchToLastInputMethod`, or else leaves the
     keyboard switcher open.

Rules:

- **Classify metadata before opening a prompt and recheck before delivery**
  ([§22 H4/H5](22-m9-m11-decisions.md)). Mask class and variation separately;
  apply these rows in order:

  | Condition | Decision |
  |---|---|
  | Text password, visible-password or web-password; numeric password | Hide prompts and offer Switch keyboard, with no render, capture, clipboard or delivery effects. Password variations match only their corresponding class. |
  | Retired session, changed target or changed connection | Cancel the old attempt without delivery, learning or switch-back. |
  | Invalid/future prompt, unresolved builtin or invalid field value | Block delivery. |
  | Missing `EditorInfo` or connection, with a valid render | Offer explicit Copy. |
  | Non-password text class with `TYPE_TEXT_FLAG_MULTI_LINE` | Allow single- and multi-line Insert. |
  | Text without that flag, or masked class zero | Allow single-line Insert; multi-line offers Copy. `TYPE_TEXT_FLAG_IME_MULTI_LINE` alone grants no multi-line permission. Class zero includes `TYPE_NULL` and `0x00080090`. |
  | Other classes, including number, phone, date/time and unknown | Offer Copy without coercing the result. |

  Multi-line detection checks the final render, including fields and builtins,
  for LF, CR, CRLF, VT, FF, NEL, U+2028 and U+2029. Preserve the text exactly.
  Insert uses one `commitText(result, 1)` only; never send Enter, key events or
  an editor action. Action flags never change this decision. A failed commit
  offers explicit Copy while the session remains active, with no automatic retry.
- **Inline Fill** reuses the form's preview, choices and existing text
  values without opening software text input. A fieldless row activation is
  an explicit Insert request; a form with fields waits for Insert or Copy.
- **Free-text fields**, editing a prefill and software search open the
  existing fill activity ("Fill in Monkey's Paw" / "Search in Monkey's Paw"),
  continuing as flow B. The activity always uses Copy and never retains the
  old input connection.

Before this explicit Search/Fill handoff, switch to the previous keyboard or
open the system picker. If both are unavailable, keep the keyboard controls
and switching instructions visible. A process-local foreground FillActivity
guard gives its editors only Switch keyboard in our IME, so cancelling the
picker cannot recursively hand off or insert into that activity. This guard
reads no target package, field identity or text. An accepted Insert/Copy
finishes permitted bookkeeping before switching; persistence warnings wait
for Done, and a retired input session never switches a later target.

IME activity handoff uses a one-use opaque token in a fresh explicit Intent.
One process-local slot holds the opened prompt, field values, capture assignment,
completed builtin snapshot and Normal/Ephemeral learning policy. No content,
delivery endpoint or session callback enters the Intent or saved state.
Failed or abandoned launches clear the slot; consumption drops it, and a
retained ViewModel keeps the adopted form through configuration changes.
If process loss removes the token's payload, the activity opens a fresh Copy
picker with Ephemeral bookkeeping and no previous fields or capture. A pending
builtin read must complete in its original active session before form handoff.

**B. Fill form → clipboard. The universal lane: works in every app.**

1. Entry points:
   - the Quick Settings tile (`startActivityAndCollapse(PendingIntent)` on
     API 34+; the `Intent` overload on API 26-33)
   - the launcher shortcut "Insert prompt"
   - the home-screen widget
   - the IME's "Fill in Monkey's Paw" button
2. `FillActivity`: pick → fill (§10.5) → **Copy**. Android 13+ shows its own
   copy preview, so the app shows no toast of its own. The activity finishes.
3. The user is back in the target app, long-presses, and pastes. Terminals
   paste through their own bracketed-paste path, so multi-line text is safe.

The M8 entries use one explicit route to a private `FillActivity` in its own
`singleTask` task, separate from Library. Repeated entry brings the held
picker or form forward without resetting its fields or builtin snapshot.
A Library activation opens its selected prompt in a held picker; during
loading, editing or copying it preserves the active form.
Copy and Back finish that session; a later invocation opens a fresh one.
The static shortcut targets a small private, empty-affinity trampoline
because Android adds `NEW_TASK | CLEAR_TASK` to its first intent. The
system launches it as the publisher app, so it need not be exported. The
trampoline forwards only a fresh shortcut route, then finishes. The tile
service is exported with `BIND_QUICK_SETTINGS_TILE`; the widget receiver
is private and its button uses an explicit immutable activity PendingIntent.
Locked tile clicks use `unlockAndRun`; the other entries use normal system
keyguard behavior, without showing the form above the lock screen (§20 F16).

**C. Text-selection action (`ACTION_PROCESS_TEXT`).**

- The user selects text, then picks "Monkey's Paw" from the selection
  toolbar. Capture uses effective fields in body first-use order: the first
  `multiline`, else the first explicit or implicit text field. Choices and
  builtins never receive capture; a fieldless prompt has no assignment.
  The user can switch fields or ignore capture. User edits override capture,
  which overrides remembered/default prefills; moving capture restores an
  unedited field's prior prefill. A new prompt recomputes the assignment;
  any retained edits belong to that prompt's in-memory form.
- If the field is editable, the result replaces the selection in place
  (`EXTRA_PROCESS_TEXT`). Otherwise it is copied.
- Validate the action, exact `text/plain` MIME and nonempty `CharSequence`.
  Missing or mistyped `EXTRA_PROCESS_TEXT_READONLY` means read-only; only
  Boolean false permits a replacement result. Explicit Copy or cancel leaves
  the caller's selection unchanged ([§22 H8](22-m9-m11-decisions.md)).
- Coverage: Chrome (including editable web fields), `EditText` apps, and
  Compose apps on foundation ≥ 1.9. It needs a non-empty selection, so it is
  a bonus path, never the primary one.

**D. Share target (`ACTION_SEND`).** Shared text either fills a field of a
chosen prompt (then flow B), or is saved as a new prompt. It is input
capture only, with no way back to the sending field.

Both capture flows strip spans to a plain-text snapshot, retain whitespace,
braces and line breaks, and reject malformed Unicode or text above the
inclusive `Limits.capturedTextCapBytes` UTF-8 bound (256 KiB), without
truncation. A share accepts only `ACTION_SEND` and exact `text/plain`;
HTML, subject, stream and URI payloads are ignored. Field assignment follows
flow C and rendering remains single-pass. Creating a prompt starts an unsaved
body draft; only explicit Save persists it ([§22 H7/H9](22-m9-m11-decisions.md)).

**Onboarding** (first run, one screen per step, each skippable):

1. Enable the keyboard: a deep link to `ACTION_INPUT_METHOD_SETTINGS`. The
   system shows its one-time "may collect all the text you type" warning;
   the screen explains beforehand that the keyboard only inserts prompts and
   reads nothing else.
2. Select it once: `showInputMethodPicker()`.
3. Add the Quick Settings tile: `StatusBarManager.requestAddTileService()`
   on API 33+.
4. Sign in to a server, or start a local library with the seed prompts.

**Not in v1:**

- an AccessibilityService auto-paste: a Play-policy and trust burden, and
  the IME is the narrower API
- `SYSTEM_ALERT_WINDOW` overlays and bubbles

Both can return later as opt-in extras.

### 10.5 Screens

| Screen | Content |
|---|---|
| Library | search; filters for All, Favourites, Recent, Conflicts, folders, groups, tags; sync status |
| Fill | one control per field (text, multi-line, choice), live preview, capture field chooser/ignore when applicable; Copy in activities and activity handoff, Insert and explicit Copy in the IME or editable selection action. IME text values are displayed without software text input; editing opens the Copy activity. |
| Editor | front matter fields + body, live validation; read-only for `viewer` groups; history and restore |
| Assistant | write, review, improve with diff and accept (M11) |
| Settings | Account (server, sign-in, devices, groups and roles, accept an invite); Assistant provider; Keyboard and tile setup; Library (forget remembered values) |
| Conflicts | the resolve view: keep server, keep mine, keep both |

Behaviour mirrors §11.5: the same error and empty states, the same
keystroke-budget spirit (fewest taps), and the same enums and named
constants.

### 10.6 Storage and sync

- **Library.** App-private `filesDir/library/`, with the same layout as the
  desktop: personal prompts at the root, `Groups/<group folder>/`, and
  `Conflicts/`. It holds the same `.md` files and the same canonical form.
  - There is no user-visible folder in v1. SAF is about 100× slower than
    direct file access for many small files (a1 §7).
  - An opt-in "export / mirror to folder" through a persisted document-tree
    grant is deferred.
- **Local state.** M8 uses `filesDir/state/` for remembered values, usage and
  history, separate from the library and `filesDir/datastore/`. DataStore
  holds versioned settings and seed progress in `settings.json` (§20 F11).
  Its singleton DataStore owns a supervised IO scope with no exception
  diagnostics, so IME state access does not obtain the application scope.
  The existing `StateStore` driver maps logical `provider-settings.json` and
  `provider-state.json` to the namespaced `provider-settings`/`provider-state`
  entries in that same settings DataStore (§22 J8). Each entry preserves the
  exact logical JSON payload and a non-secret incarnation stamp. The optional
  `records` map is absent until the first provider edit, so reading an M8
  install performs no speculative migration. Atomic updates retain seed
  progress and the other provider record. Corrupt/future logical metadata is
  retained as a read-only provider-settings record, never reset or copied to
  a file. Provider stores use only background `StateStore` reads and atomic
  replacement; moves across the settings/file backends are rejected.
  M10 owns sync state under the §9.2 contract.
  L8 supplies the shared `SecretStore` for M10 and M11 in `app/data`, wired
  once by Hilt to a separate singleton `datastore/secrets.json` DataStore.
  Provider metadata remains separate from ciphertext (§22 J8).
  - One alias, `ch.lkmc.monkeyspaw.secrets.v1`, holds a non-exportable
    AES-256-GCM key. Version-1 records contain only the namespaced account,
    base64 IV and ciphertext including the 128-bit authentication tag.
    Encryption lets the provider generate a fresh 96-bit IV. AAD binds the
    app's secrets domain, format version and exact account. L9 places its
    provider kind/origin binding inside the encrypted credential payload;
    the storage driver does not reinterpret that payload.
  - Prefer StrongBox on API 28+ when the device advertises it. Only
    `StrongBoxUnavailableException` permits a retry in ordinary
    AndroidKeyStore. API 26-27 and devices without StrongBox use ordinary
    AndroidKeyStore directly. Other access/generation failures fail closed.
    Neither path exports a key or creates a plaintext/software-key file.
    The `keystore` tier describes storage, not proven hardware backing.
  - Keys require no user authentication, so background reads are supported.
    All operations serialize on injected IO. Reads do not create keys; Save
    creates or replaces a key only when the entire ciphertext store is empty.
    Replacing a credential authenticates the previous record first. With any
    retained ciphertext, missing or invalidated keys, altered ciphertext,
    corrupt/future documents and failed atomic publication retain the prior
    data and report typed errors.
    Explicit Clear removes only that account without decrypting it or
    deleting the shared alias; repeated Clear is harmless. Corrupt/future
    documents block Clear as well and are never silently reset. Once all
    retained ciphertext is cleared, the next explicit Save reuses a usable
    alias, creates a key when none exists, or deletes an unusable alias and
    creates a fresh key if lookup reports unavailable or encryption rejects
    the key as invalid. Locked-key failures do not trigger replacement.
- **Backups.** The manifest sets `android:allowBackup="false"` and nothing
  else. There is no settings-only backup or backup exception (§20 F11).
  - Auto Backup would otherwise upload the library and the remembered values
    to Google Drive.
  - A restored Keystore ciphertext cannot be decrypted anyway.
  - Re-syncing from the server rebuilds everything.
- **Sync engine.** The §9 algorithm, ported to Kotlin in `core`. It is the
  same protocol and passes the same scenario suite (§13.1), run against the
  real server in CI.
  - Opening the IME stays local, with no sync, assistant or transport access
    (§22 H11). Sync runs when the app is opened, after local edits (an expedited
    one-time work request), and every 15 minutes through WorkManager with a
    connected-network constraint. 15 minutes is the platform floor.
  - There is no push channel; FCM does not fit a self-hosted server.
- **Network.** HTTPS by default. The network security config permits
  cleartext so that LAN servers work. The client allows `http://` only for
  `localhost`, canonical literal IPv4 `127/8` or RFC1918 ranges, IPv6 `::1`
  or ULA, and warns there too, the same rule as desktop (§8.5, §23 P5).
  DNS names (including `.local`), link-local, CGNAT and IPv4-mapped IPv6
  do not receive an HTTP exemption. URLs reject credentials, queries,
  fragments and unsafe deployment prefixes; every request is bound to the
  selected normalized deployment and its `/api/v1/` tree.
  - **Trust user-installed CAs** defaults off and belongs to one normalized
    deployment, including scheme, effective port and prefix. The existing
    settings DataStore stores only that server and trust selection. Selecting
    another server or clearing the selection resets the option; a stale
    trust intent for the old server is refused (§23 P6).
  - The shared OkHttp driver revalidates the binding after native URL parsing.
    An opted-in HTTPS request gets a separate native trust manager initialized
    with AndroidCAStore's enabled system and user anchors, preserving chain
    and hostname validation. Its TLS context and connection pool belong to
    that request and are never reused for another deployment or policy.
    Native trust discovery consumes the original deadline and cancellation
    budget. The static network security config keeps system anchors only.
  - Assistant endpoints retain §7.1's separate policy: HTTP permits only
    literal `localhost`, canonical decimal IPv4 `127/8`, or IPv6 `::1`,
    without DNS classification. Sync's LAN and user-CA exceptions do not
    apply. Device-loopback forwarding or normally trusted HTTPS is required
    for a desktop Ollama endpoint ([§20 J5](20-m6-m8-decisions.md#m11-portable-assistant-contracts)).
- **Manifest.**
  - It requests `INTERNET` and `POST_NOTIFICATIONS`. Notifications are asked
    for during onboarding; without them, the §9.3 and §9.6 notices appear
    as an in-app banner.
  - It registers `monkeyspaw://`, so join links open the app.
- **The device token and API keys** use the Keystore-backed secret store. The
  keys require no user authentication, because WorkManager reads them in the
  background. The IME graph has no secret-store access (§22 H11).

### 10.7 One behaviour, two languages

The Android domain is a Kotlin port of the Swift core (a3). The Swift SDK
for Android is official now, and was rejected for v1 for these reasons:

- It needs a second toolchain in Android CI.
- Its JNI tooling (`swift-java` 0.3) is pre-1.0.
- Debugging is immature.
- It costs 15-40+ MB per ABI.
- Its JNI boundary needs an effective minSdk of 31.

It stays a documented fallback. Drift between the two languages is the main
risk, so it is contained by contract:

- **Conformance fixtures.** `spec/fixtures/` holds language-neutral cases:
  input files, plus the expected outputs as JSON.
  - front-matter parsing and canonical writing, including the YAML 1.1 vs
    1.2 divergence cases (`y`, `yes`, `on`, `off`, `<<` merge keys, anchors,
    octal-style integers) that §5.2 forbids
  - grammar tokens and render results
  - validation issues
  - canonical form
  - path validation and `path_key`
  - ranking order
  - pure import conversions and reports
  - LLM schemas, request bodies and response recovery/decoding, including
    ordered draft issues and exact UTF-8 review quote ranges; `llm` starts
    with schema/decode cases and gains each later kind with both consumers
  - SyncAPI DTO JSON
  The Swift `PromptConformanceTests` (`MonkeysPawCoreTests`) and Kotlin
  `EveryFixtureTest` (`core` JVM tests) both run every case and visible file
  in all ten current categories: format, grammar, render, validation,
  canonical, paths, ranking, import, DTOs and LLM. Import and all 54 wire DTOs,
  including admin contracts, are parity requirements even though Android
  has no import, Account or admin UI. CI fails if either side diverges. Future
  sync-engine fixtures land with both consumers under the
  move-together rule.
- **Wire contract.** SyncAPI DTOs are defined once in Swift (`SyncAPI`).
  - A `dump-schema` executable in the server package writes JSON Schemas to
    `spec/schema/`: `swift run --package-path server dump-schema <output-dir>`.
    It renders the shared `SyncAPI.schemas` descriptions as JSON Schema
    2020-12, one file per named contract, with sorted keys and a final newline.
    CI regenerates into a fresh directory and recursively compares every
    file, including the generated README, failing on changed, missing or
    extra files. No database, GTK or running server is required.
  - Every Kotlin DTO fixture runs typed decoding and independent schema
    validation. Accepted cases compare byte-exact canonical JSON and error
    HTTP status/Retry-After headers; invalid cases must fail decoding.
    Encoding also rejects constructed-invalid values and nested relations.
    The [schema README](../../spec/schema/README.md) documents the additional
    UTF-8, Gregorian calendar and cross-field checks required by the `x-`
    annotations; a generic schema validator alone does not enforce them.
  - Route-level behaviour (status codes, error shapes) is pinned by the
    server tests and by `sync/*.json` scenario fixtures: event sequences with
    the expected requests and final state, run by both clients' engines.
- **The server is a backstop.** It validates every upload with the Swift
  core, so a drifting Android client fails loudly with `422` instead of
  corrupting a shared library.
- **Every fixture is consumed.** Both suites enumerate `spec/fixtures/` and
  fail on any fixture they do not semantically consume, including orphans,
  unsupported categories/schemas and wrong goldens. Kotlin's mandatory full
  gate reuses every category adapter and requires its consumed files to
  equal the independently enumerated inventory; no skipped or stub adapters.
- **Sync scenarios are written once.** Every §13.1 scenario is encoded once
  as a `spec/fixtures/sync/*.json` case: server events, plus the expected
  request log and final state. Both engines run every case, and the
  real-server CI runs execute the same fixtures live.
  - A case can also carry client steps: a local file write, an engine
    restart mid-pull, a second device's pass, a sign-in change, a clock
    step. That covers the crash, concurrency, and account scenarios.
  - Any scenario that stays engine-specific is listed in the fixture
    README.
- **The move-together rule** goes into AGENTS.md: a change to format,
  grammar, validation, canonical form, sync protocol, or assistant requests,
  schemas, output recovery/decoding, merge/diff and shipped prompts lands
  with fixture updates and both Swift and Kotlin implementations in the
  same PR. New categories and kinds require both semantic consumers
  immediately; unknown kinds, orphan files and unconsumed expectations
  fail the gate.

### 10.8 Build, CI, release

- **Layout.** An `android/` Gradle root (settings, version catalog, wrapper,
  `core/`, and `app/`), so Gradle never sits next to `Package.swift`. Copied from
  HalloMiao: `gradle.properties`, the version catalog (minus its sherpa
  pins), the wrapper, `proguard-rules.pro` (enum and kotlinx.serialization
  keeps), and `.editorconfig`.
  - K1 adds a Kotlin JVM plugin alias using the same Kotlin pin, a wrapper
    distribution SHA-256, and a two-worker limit. Java source/target and
    Kotlin `jvmTarget` are 17 in both modules; Gradle can run on the host's
    JDK 21 without toolchain provisioning. CI remains on Temurin 17.
  - The implementation host times out on Google Maven over HTTP/1.1.
    A local `MONKEYSPAW_GOOGLE_MAVEN_URL` environment override points at
    Google's `https://redirector.gvt1.com/edgedl/android/maven2/` CDN with
    the same artifacts. CI leaves this unset and uses `google()` normally.
    Maven Central is searched first; AGP resolves directly to its pinned
    module to avoid the absent plugin-marker JAR's CDN fallback.
  - The initial app displays the string-resource launcher label and uses
    Core's shared display name. Its adaptive launcher icon uses resized
    `media-sources/icon.png`. Hilt/KSP pins are retained; graph construction
    is deferred to K12, when drivers exist to inject.
- **CI (ci.yml `android` job).**
  - `gradle/actions/wrapper-validation`, Temurin 17, `setup-gradle` (root
    `android`), on `ubuntu-24.04` with a 45-minute timeout. Actions are
    SHA-pinned, checkouts discard credentials, and permissions are
    `contents: read`. SDK packages are explicitly `platforms;android-37.0`
    and `build-tools;36.0.0`.
  - One invocation: `./gradlew :core:test testDebugUnitTest lintDebug assembleDebug assembleRelease`
    on every PR to prove JVM compatibility, lint and R8.
  - Only `setup-gradle` caches Gradle state, read-only outside main.
    Uploads the debug APK and the staged, verified R8 release APK/checksum;
    the release pair is downloaded and byte-compared with the originals.
    On failure, JVM test and lint reports are uploaded. All are retained
    for three days. The 45-minute timeout and two-worker/3 GiB limits are
    unchanged; tune them only from CI timing evidence (§20 F17).
  - Dependabot: a `gradle` entry for `/android`, with HalloMiao's `androidx`
    and `kotlin`+`ksp` groups.
- **Signing.** `android/app/debug.keystore` is checked in and signs both
  build types, so CI needs no secrets (the HalloMiao decision, recorded as an
  [ADR](../decisions/0001-android-zero-secret-signing.md)). `.gitignore`
  blocks keystores except that one. Both variants use `ch.lkmc.monkeyspaw`.
  - Consequence: moving to a real key later breaks upgrades for every
    installed copy. That is a product decision, and Q12 records it.
- **Release.** The same `v*` tag as the desktop apps and the server. An
  `android-build` job follows tests/version verification, alongside Linux
  packaging, with the same pinned Java/SDK/Gradle setup as ordinary CI:
  1. checks the tag against the committed numeric `versionName` (§20 F20):
     stable tags match exactly; prerelease tags match by numeric core
  2. runs `:core:test testDebugUnitTest lintDebug assembleRelease` with the full validated
     tag version as `-PreleaseVersion=X.Y.Z[-prerelease]`
  3. stages `monkeyspaw-v<full-version>.apk` + `.apk.sha256`
  `scripts/verify-android-release.py` checks the staged APK's application ID,
  full version, committed code, API levels, verified signature and recorded
  signer fingerprint, and requires its exact checksum. The artifact pair is
  uploaded, downloaded and byte-compared. Assembly and both publish jobs
  require Android plus every desktop/image gate; seven assets are required
  until separate Flatpak release wiring adds its pair. Draft assets are
  downloaded and compared before publishing (§14). Fork PRs and manual dry
  runs publish nothing; release notes include checksum/sideload guidance and
  public-signing disclosure. Actual tagging needs separate owner authorization.
- **Versioning.**
  - `scripts/release.sh` keeps `RELEASE_KIND=xcode` and sets
    `RELEASE_POST_BUMP=scripts/sync-android-version.sh`. The hook reads
    `RELEASE_NEW_VERSION` as numeric `X.Y.Z`, validates exactly one literal
    declaration of each version and a positive Int code, then replaces both
    values together. A changed version sets `versionName` and increments
    `versionCode` by exactly 1; an aligned retry writes nothing. Malformed
    input or code overflow leaves the file untouched.
  - Committed `versionName` equals every desktop `MARKETING_VERSION` and
    the README marker, enforced by `scripts/check-version.py`. Packaging's
    `releaseVersion` override accepts the same numeric core with an optional
    validated prerelease suffix, without source edits or build metadata.
    Both the APK name and packaged `versionName` retain the full suffix.
    The packaged code is the committed integer, never a CI run number.
  - Repeated prereleases with the same numeric core need increasing
    committed codes and release-engine support before owner use (§20 F20).
    The current hook does not claim that upgrade path.
  - `versionCode` is never hand-edited, and `v*` tags are never created by
    hand.
  - `scripts/release.sh --check` reports engine configuration only and
    never executes the hook. Omitting `--push` still creates a commit and
    annotated tag. Hook/commit/tag and rollback proofs run in disposable
    fixture repositories, never in an implementation checkout (§20 F19).
- **Local packaging.** `scripts/package-android.sh [version]` uses the
  checked-in wrapper, JDK 17+, SDK platform `android-37.0`, and build tools
  `36.0.0`, with two workers and SDK downloads disabled. Set `JAVA_HOME` and
  `ANDROID_HOME`, or use `android/local.properties`'s `sdk.dir`. It stages
  the signed release APK and checksum under `dist/`; `--check` validates
  configuration without invoking Gradle. `scripts/build.sh android` names
  this target. The default all-targets build skips unavailable Android
  tooling; a named target fails with the missing requirement and all targets
  share one Summary block (§20 F22).
