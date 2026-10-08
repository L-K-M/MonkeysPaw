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

These versions follow HalloMiao, the fleet's model Android repo (a2 §1). The
pins move only as one set; see the AGP 9 deadlock in Kararead's
`DEPENDABOT.md`.

| Item | Choice |
|---|---|
| Build | AGP 9.3.1, Gradle 9.7.0, Kotlin 2.4.10, JDK 17. No `kotlin-android` plugin: AGP 9 has built-in Kotlin. |
| SDK | `minSdk = 26`, `targetSdk = 37`, `compileSdkVersion("android-37.0")` with `android.suppressUnsupportedCompileSdk=37` |
| UI | Jetpack Compose (BOM 2026.08.00), Material 3, single activity + entry activities |
| DI | Hilt 2.60.1 (KSP) |
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

- **Read `EditorInfo.inputType` before committing.**
  - Multi-line text goes in only when `TYPE_TEXT_FLAG_MULTI_LINE` is set.
  - For single-line fields and `TYPE_NULL` (terminals such as Termux), only a
    single-line result is committed. Otherwise the picker offers "Copy
    instead".
  - Enter is never sent: in a chat composer it submits, and in a terminal it
    executes.
- **Password fields** get no prompts.
- **A null `InputConnection`** falls back to copy.
- **Free-text fields** open the fill form ("Fill in Monkey's Paw"),
  continuing as flow B.

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

**C. Text-selection action (`ACTION_PROCESS_TEXT`).**

- The user selects text, then picks "Monkey's Paw" from the selection
  toolbar. The selection is offered as the value of one field: the first
  `multiline` field by default, and the user can switch.
- If the field is editable, the result replaces the selection in place
  (`EXTRA_PROCESS_TEXT`). Otherwise it is copied.
- Coverage: Chrome (including editable web fields), `EditText` apps, and
  Compose apps on foundation ≥ 1.9. It needs a non-empty selection, so it is
  a bonus path, never the primary one.

**D. Share target (`ACTION_SEND`).** Shared text either fills a field of a
chosen prompt (then flow B), or is saved as a new prompt. It is input
capture only, with no way back to the sending field.

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
| Fill | one control per field (text, multi-line, choice), live preview, Copy (and Insert when opened from the IME or the selection action) |
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
- **Local state.** The sync state, remembered values, usage, and the Keystore
  ciphertexts mirror §5.1 and §9.2 in `filesDir` and DataStore.
- **Backups.** The manifest disables backup for app-private data:
  `android:allowBackup="false"`, plus `dataExtractionRules` (API 31+) and
  `fullBackupContent` limiting any backup to settings.
  - Auto Backup would otherwise upload the library and the remembered values
    to Google Drive.
  - A restored Keystore ciphertext cannot be decrypted anyway.
  - Re-syncing from the server rebuilds everything.
- **Sync engine.** The §9 algorithm, ported to Kotlin in `core`. It is the
  same protocol and passes the same scenario suite (§13.1), run against the
  real server in CI.
  - It runs when the app or IME is opened, after local edits (an expedited
    one-time work request), and every 15 minutes through WorkManager with a
    connected-network constraint. 15 minutes is the platform floor.
  - There is no push channel; FCM does not fit a self-hosted server.
- **Network.** HTTPS by default. The network security config permits
  cleartext so that LAN servers work. The client allows `http://` only for
  loopback, private-network, and `.local` hosts, and warns there too, the
  same rule as desktop (§8.5).
  - An opt-in setting trusts user-installed CAs for self-signed LAN TLS.
  - That setting lives in the OkHttp trust manager, because the network
    security config is static.
- **Manifest.**
  - It requests `INTERNET` and `POST_NOTIFICATIONS`. Notifications are asked
    for during onboarding; without them, the §9.3 and §9.6 notices appear
    as an in-app banner.
  - It registers `monkeyspaw://`, so join links open the app.
- **The device token and API keys** use the Keystore-backed secret store. The
  keys require no user authentication, because WorkManager and the IME read
  them in the background.

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
  - LLM request bodies and response parsing
  - SyncAPI DTO JSON
  The Swift tests (`MonkeysPawCoreTests`) and the Kotlin tests
  (`core` JVM tests) both run every fixture. CI fails if either side
  diverges.
- **Wire contract.** SyncAPI DTOs are defined once in Swift (`SyncAPI`).
  - A `dump-schema` executable in the server package writes JSON Schemas to
    `spec/schema/`. CI regenerates them and fails on any diff.
  - The Kotlin DTOs are validated against those schemas in tests.
  - Route-level behaviour (status codes, error shapes) is pinned by the
    server tests and by `sync/*.json` scenario fixtures: event sequences with
    the expected requests and final state, run by both clients' engines.
- **The server is a backstop.** It validates every upload with the Swift
  core, so a drifting Android client fails loudly with `422` instead of
  corrupting a shared library.
- **Every fixture is consumed.** Both suites enumerate `spec/fixtures/` and
  fail on any fixture they do not consume (the HalloMiao drift-gate pattern).
- **Sync scenarios are written once.** Every §13.1 scenario is encoded once
  as a `spec/fixtures/sync/*.json` case: server events, plus the expected
  request log and final state. Both engines run every case, and the
  real-server CI runs execute the same fixtures live.
- **The move-together rule** goes into AGENTS.md: a change to format,
  grammar, validation, canonical form, or the sync protocol lands with
  fixture updates and both implementations in the same PR.

### 10.8 Build, CI, release

- **Layout.** An `android/` Gradle root (settings, version catalog, wrapper,
  `core/`, and `app/`), so Gradle never sits next to `Package.swift`. Copied from
  HalloMiao: `gradle.properties`, the version catalog (minus its sherpa
  pins), the wrapper, `proguard-rules.pro` (enum and kotlinx.serialization
  keeps), and `.editorconfig`.
- **CI (ci.yml `android` job).**
  - `gradle/actions/wrapper-validation`, Temurin 17, `setup-gradle` (root
    `android`).
  - `./gradlew :core:test testDebugUnitTest lintDebug assembleDebug`, plus
    `assembleRelease` on every PR to prove R8.
  - Uploads the debug APK as an artifact.
  - Dependabot: a `gradle` entry for `/android`, with HalloMiao's `androidx`
    and `kotlin`+`ksp` groups.
- **Signing.** `android/app/debug.keystore` is checked in and signs both
  build types, so CI needs no secrets (the HalloMiao decision, recorded as an
  ADR). `.gitignore` blocks keystores except that one.
  - Consequence: moving to a real key later breaks upgrades for every
    installed copy. That is a product decision, and Q12 records it.
- **Release.** The same `v*` tag as the desktop apps and the server. An
  `android-build` job:
  1. checks the tag against `versionName`
  2. runs `testDebugUnitTest lintDebug assembleRelease`
  3. stages `monkeyspaw-vX.Y.Z.apk` + `.sha256`
  The publish job attaches them to the same GitHub Release.
- **Versioning.**
  - `scripts/release.sh` keeps `RELEASE_KIND=xcode` and sets
    `RELEASE_POST_BUMP=scripts/sync-android-version.sh`. That script sets
    `versionName` to the new version and increments `versionCode` by
    exactly 1.
  - `versionCode` is never hand-edited, and `v*` tags are never created by
    hand.
  - Before the first tag, a dry run of `scripts/release.sh` (no `--push`)
    proves the post-bump hook against `android/app/build.gradle.kts`. No
    fleet repo has exercised the xcode kind with this hook yet.
- **`scripts/build.sh`** becomes the multi-target orchestrator: per-target
  feasibility (skip Android without an SDK, fail when it is named) and one
  summary block. It stages into `dist/`.
