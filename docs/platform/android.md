# Android acceptance

## M8 acceptance record

**M8 is code-complete, but NOT closed.** K1–K19 are merged. K20's owner
evidence is still pending: every M8 owner row below is **NOT RUN (owner)**.
No device or emulator was used for this record. JVM tests, R8 assembly and
workflow checks do not establish physical paste, lifecycle or installation.
The [§15 milestone record](../plan/15-milestones.md) remains open until the
owner commits results for the final signed, shrunk release APK.

Automated evidence collected on 2026-10-14 at main `766394cf4a2a298f03e128870b3c7cad7de744ae`:

| Acceptance item | Result and evidence |
|---|---|
| Every M2/M5 fixture is consumed by `:core` | PASS. [CorpusInventoryTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/CorpusInventoryTest.kt), `inventory accounts for every visible fixture exactly once`, independently accounts for 1,509 cases / 4,346 files / 10 categories and 54 schemas. [EveryFixtureTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/EveryFixtureTest.kt), `every visible fixture is consumed semantically exactly once`, requires semantic consumption to equal that inventory, with pending 0. The nine M8 categories total 1,034 cases / 2,172 files; the later LLM category is also consumed. |
| DTO accounting, including admin contracts | PASS. [DtoConformanceTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/DtoConformanceTest.kt), `every contract consumes every valid and invalid case with canonical bytes` and `case order does not affect complete corpus accounting`: 649 cases (160 valid / 489 invalid), 1,298 files, all 54 contracts; pending 0. |
| Exact Android gate | PASS locally: 570 Core tests and 357 app tests, zero failures/errors/skips; lint and both APK assemblies pass, including seed-asset verification. Command/environment below. Compilation and R8 outputs may be reused from Gradle's build cache. |
| `ci.yml` Android job exists and runs the five tasks | PASS. [`android`](../../.github/workflows/ci.yml) is green on main `ea741f46`, [run 38634897474 / Android job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634897474/job/116122711154), including APK verification and artifact byte comparison. Main `766394cf`'s run 38656497917 was pending at collection. |
| `release.yml` APK and asset gates | PASS in PR dry runs: K19 [run 38586738354 / APK job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38586738354/job/116024653871), and the verifier fix now merged as #216, [run 38634076231 / APK job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634076231/job/116142682271). The latter's [asset gate](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634076231/job/116159168194) passed; both publish jobs were skipped. [`android-build`](../../.github/workflows/release.yml) exists on the recorded main. This is dry-run evidence, not a published release or a post-K19 main tag/manual release run. |
| `scripts/sync-android-version.sh` works | PASS. [test_android_version.py](../../scripts/tests/test_android_version.py): 11 tests, none skipped, including seven hook/fake-engine tests and four installed-release-engine tests in disposable fixture repositories. Changed versions increment the code once, aligned retries do not write, malformed/overflow input preserves files, and hook edits enter the release commit/tag with rollback on failure. No release command or tag was created in the implementation checkout. |

Counts from that run's Gradle JUnit XML and successful full semantic gate:

| Category | Cases | Consumed files |
|---|---:|---:|
| format | 17 | 34 |
| grammar | 22 | 44 |
| render | 22 | 44 |
| validation | 113 | 226 |
| canonical | 19 | 50 |
| paths | 141 | 282 |
| ranking | 36 | 164 |
| import | 15 | 30 |
| dto | 649 | 1,298 |
| M8 subtotal | 1,034 | 2,172 |
| llm (later M11 fixtures) | 475 | 2,174 |
| Current corpus total | 1,509 | 4,346 |

The LLM consumer also checked 16,902 expectations, pending 0. The inventory
SHA-256 (sorted relative path, NUL, exact file bytes) was
`ac2db8413b5705b23cba52758f776dc3faec2eb37c0c725e07a7e1fbed0693fe`.
The inventory rejects missing/orphan/unknown cases; the full gate also
rejects changed semantic expectations. This proves semantic consumption,
beyond opening fixture files.

Reproduce from the repository root on the implementation host:

```bash
export JAVA_HOME=/opt/java/openjdk
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME=/home/paseo/Android/Sdk
export MONKEYSPAW_GOOGLE_MAVEN_URL=https://redirector.gvt1.com/edgedl/android/maven2/
export LANG=C.UTF-8 LC_ALL=C.UTF-8
cd android
./gradlew --max-workers=2 :core:test testDebugUnitTest lintDebug assembleDebug assembleRelease
```

This uses JDK 21 locally; CI uses Temurin 17 and the default Google Maven
endpoint. Install `platforms;android-37.0` and `build-tools;36.0.0` first.
From the repository root, `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`
passed all 87 tests; add `-p test_android_version.py -v` to isolate the 11
version-hook/engine tests. Preserve the JUnit summaries before deleting
`android/build`, `android/*/build`, `android/.gradle` and `android/.kotlin`.
Do not run a Gradle daemon stop on the shared implementation host.

## Release APK verification

Download `monkeyspaw-v<full-version>.apk` and its `.apk.sha256` from this
repository's GitHub Release into the same directory. Android API 26 or later
is required. Verify the download:

```bash
version='<full-version>' # Replace with the release version, including any suffix.
sha256sum -c "monkeyspaw-v${version}.apk.sha256" &&
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "monkeyspaw-v${version}.apk"
```

The signature command requires SDK build-tools 36.0.0 and the JDK's `bin`
on `PATH`; compare its single SHA-256 certificate digest with the ADR below.
Install only if both commands succeed and the digest matches:

```bash
adb install -r "monkeyspaw-v${version}.apk"
```

`adb` requires platform-tools and USB debugging. Alternatively open the
verified APK on the device and permit installation from that source.
On macOS, use `shasum -a 256 -c` instead. Both debug and release APKs
use the same [public signer](../decisions/0001-android-zero-secret-signing.md)
and app ID, so installing one replaces the other. Anyone with the checked-in keystore
can sign an update; the signature does not establish publisher identity.
Obtain APKs from this repository's release. Changing the signer breaks
updates and requires uninstall/reinstall, which deletes app-private data.

Ordinary CI and release dry runs verify the APK's ID, full version,
committed code, API levels, signature/fingerprint and checksum, then download
the workflow artifact and byte-compare both files. Release publication also
requires every desktop and server-image gate and draft-download comparisons.
These checks do not prove device installation, runtime behavior or updates.

Record the following on both API 26–33 and API 34+ using the final signed,
shrunk release APK. For every owner row in the M8 sections, record the main
commit, APK version/code/SHA-256/signer, device/model/API/launcher, target app
version and editor type where applicable, date/tester, expected versus actual
result and a sanitized evidence reference. Keep prompt content, field values
and clipboard contents out of collected logs. Each row's final column names
the additional evidence to collect. Unsupported or unavailable checks remain
explicit gaps, not PASS.

| Owner check | Status | Additional evidence to record |
|---|---|---|
| Release asset verification | NOT RUN (owner) | Release URL/tag/commit and publishing run ID; APK + checksum asset names, checksum OK and equality with the verified workflow APK pair. Record the seven-asset baseline (macOS dmg/zip/manifest, deb/checksum, APK/checksum), or the explicitly integrated Flatpak additions. A workflow artifact alone does not prove published assets. |
| APK metadata and signature | NOT RUN (owner) | `aapt2 dump badging` package ID `ch.lkmc.monkeyspaw`, full version, committed code, minSdk 26/targetSdk 37; successful `apksigner verify --verbose --print-certs`, one signer matching the ADR fingerprint; checksum output. |
| Clean install and launch | NOT RUN (owner) | Installation method/permission, success or exact sanitized failure, installed version/code and launch result on each device; use disposable data for a clean-install test. |
| Install over an existing copy, including debug → release | NOT RUN (owner) | Old/new APK versions/codes/hashes and matching signer; `adb install -r` or system update result; verify an edited prompt, favourite, remembered field, usage, history and seed-offer decision survive. Record a higher code for a version upgrade; do not hand-edit it or count uninstall/reinstall or a forced downgrade as an update. |

The automated CI/dry-run links are in the M8 record above. No post-K19
published APK or owner installation is asserted here. Version upgrades
need a suitable earlier APK; repeated same-core prereleases remain
unclaimed until increasing codes and engine support exist (§20 F20).

## M9 keyboard and tile setup: NOT RUN

Owner-run checks for §10.4 onboarding and §22 H6/H10/H12, with Gboard and
Samsung Keyboard. JVM tests cover state and fake effects; they do not execute
the actual Settings, keyboard picker or Quick Settings dialogs. Use the final
signed, shrunk release APK on API 26–32, API 33 and API 34+ where available.
Record the main commit, APK version/SHA-256/signer, device/API, previous keyboard
version, tester/date and results. Keep private text and keyboard IDs out of logs.

| Check | Result / device details |
|---|---|
| Fresh install and upgrade from M8 show the three skippable steps once; starter-prompt choice and existing library are preserved | NOT RUN |
| Privacy explanation precedes Android's enable warning; return from keyboard settings rereads enabled status, including disabling it again | NOT RUN |
| Picker shows Monkey's Paw picker; dismissing it does not complete selection; window focus return, Check status and launcher resume reflect selection and permit another picker request | NOT RUN |
| API 26–33 selection uses the system setting's parsed ComponentName; API 34+ reflects the current input method API | NOT RUN |
| API 26–32 shows manual Quick Settings editing instructions and user confirmation; no tile request is attempted | NOT RUN |
| API 33+ explicitly requests the existing Insert prompt tile with its existing label/icon; added, already added, denied and error remain distinct | NOT RUN |
| Repeated taps while a request is pending do not stack requests; skip, Back, rotation and late replies do not resurrect old setup | NOT RUN |
| Failed choice publication keeps its pending decision for retry; Back can leave after failure without claiming the choice was saved | NOT RUN |
| Settings → Keyboard and tile setup reopens after disabling the keyboard or removing the tile, without displaying saved progress as current installation | NOT RUN |
| IME, tile, shortcut and widget invocation do not launch keyboard/tile setup; setup requests no sign-in or notification permission | NOT RUN |
| TalkBack, large text, rotation and background/resume keep setup actions and skips usable | NOT RUN |

## M8 quick entry points: NOT RUN (owner)

Owner-run checks for §10.4 B and §20 F2/F16. No Android device or emulator
was used on the implementation host. JVM policy tests, manifest checks and
APK assembly do not prove launcher, keyguard, Activity stacking or return.
Use the final signed, shrunk release APK on an API 26–33 device and an API
34+ device, including minimum API and target 37 coverage when available.

- Commit / APK version / code / SHA-256 / signer: NOT RUN (owner)
- Device / Android API / launcher: NOT RUN (owner)
- Target app versions / field: NOT RUN (owner)
- Date / tester / sanitized evidence reference: NOT RUN (owner)

Add the tile through Quick Settings editing, expose **Insert prompt** by
holding the launcher icon, and add the **Monkey's Paw: Insert prompt** widget.
No keyboard or automatic tile onboarding is part of M8. For a cold entry,
end the app process while retaining its library, then invoke the entry.
For a warm entry, invoke it after another completed or cancelled form.

| Check | API 26–33 | API 34+ | Additional evidence to record for each device |
|---|---|---|---|
| Cold tile opens seed choice or the picker; pick → fill → Copy returns to the previous app | NOT RUN (owner) | NOT RUN (owner) | How the process was ended, seed/picker destination, actual return app/field and successful manual paste |
| Warm tile collapses Quick Settings and opens the picker, using the Intent / PendingIntent policy respectively | NOT RUN (owner) | NOT RUN (owner) | Prior session, panel collapse and picker/return destinations |
| Cold and warm launcher shortcut opens the same pick → fill → Copy flow | NOT RUN (owner) | NOT RUN (owner) | Shortcut label, cold/warm opening and actual return destination |
| Cold and warm widget button opens the same flow; two widget instances both work | NOT RUN (owner) | NOT RUN (owner) | Launcher, widget instance/size, both launches and return destinations |
| Locked tile requires unlock before showing prompts; cancel unlock opens nothing; retry succeeds | NOT RUN (owner) | NOT RUN (owner) | Locked/unlocked/cancelled outcomes and absence of prompt disclosure before unlock |
| Shortcut and home-screen widget do not show a form, preview or clipboard above the lock screen | NOT RUN (owner) | NOT RUN (owner) | Lock method, entry attempted and what was visible before/after unlock |
| Reinvoke any entry while editing; switch between tile, shortcut and widget; one form keeps its fields and initial clipboard snapshot | NOT RUN (owner) | NOT RUN (owner) | Entry sequence, number of forms and unchanged field/snapshot outcome without their contents |
| Open Library while a fill picker is held and select a prompt; the selected prompt opens. Repeat while editing/copying; the active form is preserved | NOT RUN (owner) | NOT RUN (owner) | Picker/form/pending-copy state, selected prompt identity and preserved session outcome |
| Reinvoke while Copy is pending; one write and one learning operation complete, then the Activity finishes | NOT RUN (owner) | NOT RUN (owner) | Reentry timing, observed copy/usage count and single finish; record unavailable diagnostics as a gap |
| Copy finishes after saving usage/remembered fields; no automatic paste, target-app start or duplicate app copy toast | NOT RUN (owner) | NOT RUN (owner) | Reopened Recent/remembered state, toast count, return app and absence of automatic input |
| Back from picker or form and Cancel finish, returning to the prior app or launcher; clipboard and usage are unchanged | NOT RUN (owner) | NOT RUN (owner) | Each cancellation path, actual return destination and unchanged clipboard/Recent state |
| After Copy or Back, a new entry opens a fresh session; an already open Library/Editor is preserved | NOT RUN (owner) | NOT RUN (owner) | Completion path, new-session state and retained Library/Editor draft |
| Rotate, background, lock and resume a form; fields survive and the builtin snapshot is not retaken | NOT RUN (owner) | NOT RUN (owner) | Each transition, retained fields and stable clock/clipboard snapshot outcome |
| With "Don't keep activities" enabled, Copy/Back still returns and a new entry opens without stalling | NOT RUN (owner) | NOT RUN (owner) | Developer setting, return/new-entry results and restoration of the setting afterward |
| TalkBack identifies the tile, shortcut and widget button; large text and widget resizing keep the button usable | NOT RUN (owner) | NOT RUN (owner) | Accessibility labels, font/display scale, widget size and usable controls |

For each target below, focus a harmless editable field, invoke the tile,
pick and fill a prompt with multiple lines, then Copy and long-press Paste.
Confirm exact text once and that no Enter is submitted. For Termux, use a
harmless sentinel and clear the line without executing it. Repeat via the
shortcut and widget after returning to the launcher, then test Back without
copying. Record the actual return destination; these home-screen entries
cannot promise a sending text field.

| Target | Tile → fill → Copy → manual Paste | Shortcut / widget → manual Paste | Back / return | Additional evidence to record |
|---|---|---|---|---|
| Chrome | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Version, website/editor type, exact multiline text once, no submission, actual return app/field for each entry and cancellation |
| ChatGPT app | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Version, conversation composer, exact multiline text once, no send, actual return destination for each entry and cancellation |
| Claude app | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Version, conversation composer, exact multiline text once, no send, actual return destination for each entry and cancellation |
| Termux | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Version, shell/editor and bracketed-paste behavior; harmless sentinel pasted once without execution, line safely cleared, actual return destination |

## M8 seeds, library and editor/history: NOT RUN (owner)

Use disposable libraries/devices for fresh-install and decline variants;
clearing app data or uninstalling destroys local prompts and history.
Use the same APK/device metadata and evidence format as the release table.

| Owner check | Status | Additional evidence to record |
|---|---|---|
| Accept seeds in an empty library | NOT RUN (owner) | Offer shown once, accepted/added/failure counts against the `seed/` catalog bundled into the APK as `assets/seeds/`, unique first-save identities, browsable/fillable prompts; restart offers no duplicates and retains edits. |
| Decline seeds and reopen | NOT RUN (owner) | Fresh-install decline, empty-library state, manual create success, no repeated offer after restart and decision retained across update. |
| Existing or partially seeded library | NOT RUN (owner) | Initial prompt/count state, no overwrite or automatic reseed; if a failure can be reproduced, added/failure counts, retained prompts and Continue/Retry outcome. If not exercised, leave that failure case NOT RUN. |
| Browse/search/filter/favourite/Recent | NOT RUN (owner) | Search and All/Favourites/Recent/folder/tag results for known synthetic prompts; toggled favourite and successful-copy usage survive restart. Invalid prompts remain listed with issues. |
| Create → raw edit → save → rename/move → reopen | NOT RUN (owner) | Paths and stable identity, validation/Fields/Preview results, retained unknown front matter and exact body outcome; all saved changes survive restart. Preview does not consume clipboard data. |
| Unsaved changes and invalid/read-only source | NOT RUN (owner) | Save/Discard/Cancel outcomes for navigation; live validation and refused invalid save; malformed text remains repairable, future/oversized/non-UTF-8 files are read-only if available through a controlled fixture setup. Record unavailable setup as a gap. |
| History and restore | NOT RUN (owner) | At least two saved revisions, selected revision/time, confirmed restored source/preview, preserved identity and restored content after restart/update. |
| Local stamp conflict | NOT RUN (owner) | Controlled second local edit while a draft is open, visible conflict and Keep mine/Take theirs/Cancel outcomes; no silent overwrite or lost draft. Record how the second edit was produced; do not claim M10 sync here. |
| Fill on the final minified APK | NOT RUN (owner) | Text/multiline/choice, optional/required and remembered fields; fieldless prompt still previews before Copy; clock/date/time snapshot and one foreground clipboard read only when used. Check Unicode and line-break preservation, sensitive clipboard handling, failed-copy retention/no learning if reproducible, and post-copy storage warning without a second copy. |

## Text-selection entry checks (M9 N5): NOT RUN

The selection toolbar's "Monkey's Paw" action hosts the same picker and
Fill form in `ProcessTextActivity`. An editable selection offers Insert and
Copy. Insert returns `RESULT_OK` with plain `EXTRA_PROCESS_TEXT` to the
caller, without writing the clipboard. Read-only selections offer Copy;
missing or mistyped read-only flags also use Copy only. Explicit Copy and
Back leave `RESULT_CANCELED`, preserving the original selection. No activity
is forwarded and no target app is launched.

JVM tests use decoded extras and fake result/clipboard hosts to check input
validation, field choice, lifecycle retirement and effect/learning order.
They do not execute Intent/Bundle unparcelling, spans, Compose attachment,
the selection toolbar or the caller's replacement behavior. No device or
emulator was used for N5. Keep every physical check below NOT RUN until
the owner records evidence on the final signed minified APK.

| Host / editor | Editable Insert | Read-only Copy | Back / return | Status / details |
|---|---|---|---|---|
| Chrome editable web field | NOT RUN | n/a | NOT RUN | Record Chrome version and editor type |
| Chrome page text | n/a | NOT RUN | NOT RUN | Record whether the action is offered |
| App using native `EditText` | NOT RUN | NOT RUN | NOT RUN | Record app/version and editable/read-only widget configuration |
| Supporting Compose host, foundation 1.9+ | NOT RUN | NOT RUN | NOT RUN | Record app/version, foundation version and text field or selection container |

Use harmless test strings. For each supported host, select nonempty text,
choose the action, pick a prompt and complete the shared Fill form. Verify
literal braces, Unicode, whitespace and line breaks in the replacement or
manual paste. Insert replaces exactly once and returns to the original
caller with no clipboard write or submission. Editable Copy leaves the
selection intact. Read-only Copy changes only the clipboard, with manual
paste afterward. Back/Cancel from picker or form changes neither result,
clipboard nor learning. Also check:

- Multiple candidate fields: first multiline in body first-use order, else
  first explicit/implicit text; switch and ignore capture, preserving edits
  and restoring unedited defaults/remembered prefills.
- Choice-only, builtin-only and fieldless prompts: no injected capture,
  clear no-field message and explicit completion or cancel.
- Rotation, background/resume and repeated entry: one retained form and
  builtin snapshot; a new selection replaces the old session. Old callbacks
  cannot return text or copy into the new session.
- Process loss or "Don't keep activities": no saved capture/draft or replay;
  return canceled when the original in-memory session is lost.
- Invalid action/MIME, missing/empty/mistyped text, malformed Unicode and
  text above the inclusive 256 KiB UTF-8 cap: cancel without partial capture,
  field mutation, clipboard/result effect or learning.
- Post-delivery storage failure: show the shared warning; Done keeps the
  accepted result and never repeats Insert or Copy.

Some hosts do not expose `ACTION_PROCESS_TEXT`, even for a nonempty
selection. Record that cell as **UNSUPPORTED** with the app/version/editor
and observed toolbar behavior. No selection normally offers no action;
missing actions are unsupported coverage, not a passing replacement test.
This entry supplements the keyboard and universal Copy flows.

Record main commit, APK SHA-256, signing fingerprint/build type,
device/model/API, keyboard/version, host app/version/editor type,
scenario, expected/actual return behavior, tester/date and PASS/FAIL/NOT RUN
or UNSUPPORTED. Keep prompt content, typed text and selections out of logs
and collected evidence.

## Share entry checks (M9 N6): NOT RUN

The sharesheet's "Monkey's Paw" target accepts `ACTION_SEND` with exact
`text/plain`. It offers **Use in prompt**, which hosts the same picker,
capture-field chooser and Copy form, or **Save as new prompt**, which opens
the existing editor with an unsaved body draft. Shared text is never sender
metadata, a file path or an import. A leading YAML fence remains body text.
Subject, HTML, stream, URI and routing extras are ignored; URLs are not fetched.
No result or insertion is returned to the sender.

JVM tests exercise the decoder's pure extraction seam, retained entry with
fake clipboard effects, and the existing Fill/editor against isolated
app-private stores. The Android build gate covers compilation, lint and
minified APK packaging. These checks cannot execute Android Bundle
unparcelling, native spans, the sharesheet or Compose attachment. Keep all
physical checks below NOT RUN until evidence is recorded on the final signed
minified APK. No device or emulator was used for N6.

| Source / scenario | Expected behavior | Status |
|---|---|---|
| Plain text from a native app | Chooser opens; no file, clipboard write or learning before an explicit action | NOT RUN |
| Styled text from a supporting host | Plain snapshot retains Unicode, whitespace, braces and line breaks; spans are removed | NOT RUN |
| Browser URL plus subject/HTML/attachment | Only EXTRA_TEXT is captured; no URL fetch or attachment access | NOT RUN |
| Use in prompt, multiple candidate fields | First multiline by body order, else first explicit/implicit text; switch/ignore preserves edits and restores unedited prefills | NOT RUN |
| Use in prompt, choices/builtins/fieldless | No injected capture; ordinary choices/preview and explicit Copy or cancel | NOT RUN |
| Copy success or failure | Sensitive clipboard changes once on success, then permitted learning and finish; failure keeps form and teaches nothing | NOT RUN |
| New prompt, Save | No file until Save; exclusive creation, fresh ID and exact body; intentionally edited unknown metadata follows the existing editor policy | NOT RUN |
| Occupied filename or failed Save | Existing file stays intact; draft stays editable with an error and explicit retry | NOT RUN |
| Back / cancel | Chooser/Fill has no delivery; editor offers its existing Save/Discard/Cancel guard | NOT RUN |
| Rotation / background / replacement | Retain current in-memory form and builtin snapshot through rotation; a new Intent retires the prior share; stale callbacks cannot finish or copy into it | NOT RUN |
| Process loss | Drop capture and draft, finish safely without replay or saved payload | NOT RUN |
| Forged action/MIME or invalid text | Missing/empty/mistyped, malformed Unicode and over-256-KiB UTF-8 input cancel without truncation or effects | NOT RUN |

Use harmless test strings, including a body beginning with `---`, decomposed
Unicode, CR/LF and literal braces. Verify the sender's original field stays
unchanged for Copy, Save and cancel, and no sender result or commit occurs.
An accepted Copy followed by a storage warning shows the shared Done path
without repeating Copy. Confirm rotation retains edits without a second
clipboard read; a replacement starts at the chooser with only its new text.
Back from an unsaved editor must retain the draft on Cancel and discard it
without a file on Discard. Save from that guard closes only after success.

Record main commit, APK SHA-256, signing fingerprint/build type,
device/model/API, source app/version and text type, scenario, expected/actual
behavior, tester/date and PASS/FAIL/NOT RUN. Keep shared text, prompt content
and field values out of collected logs and bug reports. A missing share
target or failing source integration is a coverage gap, not acceptance.
M9 remains open until the required owner matrix is complete (§22 H12).

## Unicode runtime checks

M8 K6 uses a pure JVM ICU4J dependency for NFC and Unicode Cc/Cf properties.
The version catalog owns the pin. Sync folding comes from the frozen Swift
Unicode table; these checks do not establish search parity or M8 acceptance.

The local Android gate builds both APKs and minifies the release APK with
R8. M8 has no production sync-path caller, so its ProGuard rules retain
the validator entry point with optimization enabled. Remove that temporary
rule once a production caller keeps the path code reachable, then repeat
the packaging check.

For the release APK, compare the packaged ICU data with the resolved ICU4J
JAR, especially `com/ibm/icu/impl/data/icudata/nfc.nrm` and `uprops.icu`.
Inspect the actual dex with the release mapping to confirm the validator,
normalizer, property reader and ICU data loader survive. JVM tests and a
successful R8 task alone do not prove resource retention. K6's handoff
records the APK hash, byte comparisons and dex inspection results before
the host's required build-directory cleanup.

## Minimum-API device check: NOT RUN (owner)

No Android device or emulator was used on the implementation host. A
minimum-API device still needs to execute the minified validator through
the app's production call path when that caller exists. Check these cases:

| Input | Expected result in private scope | Status |
|---|---|---|
| `Cafe\u0301/E\u0301.md` | NFC `Café/É.md`, key `café/é.md` | NOT RUN (owner) |
| `\u0F73` repeated 20 times, followed by `.md` | All 20 U+0F71 marks, then all 20 U+0F72 marks, followed by `.md`; no truncation | NOT RUN (owner) |
| U+E0001 followed by `a.md` | `path.control_character`, segment 0 | NOT RUN (owner) |
| `Groupſ/a.md` | `path.reserved_groups_prefix`, null segment; accepted in group scope | NOT RUN (owner) |
| `İ/Iıi.md` | Key `i\u0307/iıi.md` | NOT RUN (owner) |

For each row record the commit, APK version/code/SHA-256/signer, device/API
level, production caller or controlled test harness, tester/date, expected
and actual normalized path/key or error, and sanitized evidence. This
checks Android class/resource loading and any required Java library
desugaring on the actual minimum API; static APK inspection cannot prove
runtime execution.

## Assistant transport device checks: NOT RUN

M11 L7 supplies the shared `app/data/OkHttpHttpTransport` and Hilt binding.
M10 should extend this driver with its deployment-bound sync URL policy.
Assistant HTTP remains limited to literal localhost, canonical 127/8 and
IPv6 ::1. The static network config permits cleartext because it cannot
describe 127/8; the driver validates the policy before network work. Only
system trust anchors apply to assistant TLS.

JVM MockWebServer tests exercise request counts, caps, deadlines and
cancellation. The Android gate builds debug and minified release APKs.
Neither establishes runtime TLS or cancellation behavior on a phone.
Once an assistant production caller exists, record the commit, APK SHA-256,
device/API, signer fingerprint, tester/date and results for these checks:

| Check | Expected result |
|---|---|
| Normally trusted HTTPS | Request succeeds using system trust |
| Self-signed or user-installed-CA-only HTTPS | Typed network failure, no trust bypass |
| Redirect to another host | Typed redirect refusal; target receives no request or credentials |
| HTTP device loopback, including USB reverse forwarding | Allowed; a plaintext LAN or `.local` endpoint is refused |
| Cancel during connect or stalled/continuous body receipt | Prompt typed cancellation and closed receipt |
| Absolute deadline during queued work or continuous receipt | Typed deadline failure within the original intent budget |

No device or emulator was used for L7. All checks above remain NOT RUN.

## Android native secret-store checks (M11 L8): NOT RUN

The implementation host ran JVM AES-GCM with injected test keys and real
DataStore files. Those tests do not exercise AndroidKeyStore, establish
hardware backing, or prove behavior after a device reboot. No device or
emulator was used. Keep this item NOT RUN until the owner records evidence
through the production settings path supplied by L9/L14.

Use the final signed minified APK. Record the commit, APK SHA-256, signer
fingerprint, device/model/API, tester/date, alias/key security information and
results. Inspect `KeyInfo` with the API-supported security-level or hardware
backing accessor; do not infer backing from the `keystore` tier or a successful
JVM test. Follow the [Android Keystore guidance](https://developer.android.com/privacy-and-security/keystore).

| Check | Evidence required | Status |
|---|---|---|
| API 26-27 ordinary AndroidKeyStore | Save/read/Clear without StrongBox APIs; actual backing recorded | NOT RUN |
| API 28+ StrongBox-capable device | StrongBox requested; actual security level/backing recorded | NOT RUN |
| StrongBox unavailable | Ordinary AndroidKeyStore fallback only on unavailability; other failures retain ciphertext | NOT RUN |
| Restart and reboot | Save two synthetic credentials; force-stop/reopen and reboot; both remain readable without per-read authentication | NOT RUN |
| Account and provider destination binding | Swapped account record rejects decryption; kind/origin changes require explicit re-entry or Clear in L9 | NOT RUN |
| Alias loss or invalidation | Read/Save fail with typed static errors, ciphertext remains; Clear affects only the chosen account; no silent regeneration | NOT RUN |
| Disk/publication failure | Save/Clear failure retains the previous credential and unrelated account; retry is explicit | NOT RUN |
| Persistence and diagnostics | Runtime synthetic sentinel absent in raw/base64/percent/JSON forms from settings, logs and temporary outputs; only encrypted payload persists; no raw key export | NOT RUN |

Do not put real credentials, sentinel contents, raw key material or platform
exception bodies in this checklist or bug reports. Hardware that is
unavailable remains a validation gap for K17/L20; an unchecked row does not
satisfy milestone acceptance.

## Android sync TLS and device-token checks (M10 Z6): NOT RUN

Z6's JVM tests use MockWebServer, synthetic CAs and injected JVM AES-GCM keys.
They prove request binding, opt-in isolation, caps and receipt cancellation,
and device/provider ciphertext isolation. They do not exercise AndroidCAStore,
AndroidKeyStore, a real user-installed CA or hardware backing. All native
checks below remain NOT RUN. Repeat them through the final Z19/Z21 sync graph
and Account controls on the signed minified release APK.

Record commit, APK SHA-256, signer fingerprint, device/model/API, server and
desktop versions, tester/date and sanitized results. Use synthetic credentials
and a test CA; never record keys, tokens, certificate subject data, raw URLs
with queries, response bodies or native exception bodies.

| Check | Expected result | Status |
|---|---|---|
| System-trusted HTTPS with default and opted-in sync trust | Both requests succeed with normal hostname validation | NOT RUN |
| User-CA-only HTTPS before and after explicit opt-in | Default refuses; explicit opt-in succeeds only for the selected deployment | NOT RUN |
| Same CA on an assistant endpoint or a different sync server, port or deployment prefix | No inherited opt-in or bearer forwarding; wrong-bound requests fail before dispatch | NOT RUN |
| Change server, switch back, disable the option and restart | A changed server starts with system trust; disabled trust survives restart | NOT RUN |
| Untrusted, expired and wrong-host certificates while opted in | Typed body-free network failure, no HTTP request | NOT RUN |
| Remove the installed test CA, then retry | Fresh trust discovery refuses the next request; no retained TLS session bypass | NOT RUN |
| Same-server, cross-server and HTTPS-to-HTTP redirects | Typed redirect refusal; target receives no request or credentials | NOT RUN |
| Cancel or expire during queued work, trust discovery, connect or body receipt | Prompt typed failure; no late dispatch and receipt closes | NOT RUN |
| Permitted literal LAN HTTP versus private DNS or `.local` HTTP | Literal policy matches §23 P5 and Account warns; DNS names receive no exemption | NOT RUN |
| Save provider credentials and two device accounts; restart, replace and clear one device account | Provider and other device remain usable; only encrypted tokens enter the secrets DataStore | NOT RUN |
| Missing/inaccessible Keystore alias or tampered device ciphertext | Read/Save fail without key replacement; explicit device Clear preserves unrelated ciphertext | NOT RUN |
| Persistence and diagnostic scan after sync failures and device cleanup | No raw/base64/percent/JSON token copies in settings, logs, jobs or temporary outputs | NOT RUN |

The [network security guidance](https://developer.android.com/privacy-and-security/security-config)
describes system trust defaults. Android's [CA-store implementation](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/+/refs/heads/androidx-constraintlayout-release/android-35/com/android/org/conscrypt/TrustedCertificateKeyStoreSpi.java)
and [trust-manager factory](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/android-30/+/refs/heads/androidx-sharetarget-release/android/security/net/config/RootTrustManagerFactorySpi.java)
support the explicit-store factory choice; source inspection and JVM results
do not replace these device checks. Required missing device evidence keeps
M10 acceptance open (§23 P20).

## M9 IME insertion and switch-back: NOT RUN

N4 adds JVM fake-gateway proof and a release build gate. These do not execute
an Android input connection, keyboard history, Compose attachment or activity
handoff. No device/emulator insertion result is claimed here. Use the final
signed, shrunk release APK and keep M9 open until the required cells pass.

Record each result with main commit, APK SHA-256, signer/build type, device
model/API, previous keyboard/version/subtype, target app/version/editor type,
scenario, expected/actual behavior, tester and date. Use harmless local test
strings; collect no prompt content, typed text, selections or target context.

| Environment | Previous keyboard | Chrome | ChatGPT | Claude | Termux | Details |
|---|---|---|---|---|---|---|
| Android 14 / API 34 | Gboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Android 14 / API 34 | Samsung Keyboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Android 15 / API 35 | Gboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Android 15 / API 35 | Samsung Keyboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Android 16 / API 36 | Gboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Android 16 / API 36 | Samsung Keyboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Below API 34, preferably 26/27 | Gboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| Below API 34, preferably 26/27 | Samsung Keyboard | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |

For each cell, test fieldless tap and explicit Insert with default/remembered
text and inline choices: exact text once, previous keyboard/subtype restored,
no clipboard replacement on accepted Insert, no submission or execution.
In real multiline composers, all supported line separators remain literal.
In single-line fields and both Termux null-like modes, multiline renders
offer explicit Copy and manual paste; single-line Termux Insert never sends
Enter. A platform true return alone does not establish displayed insertion.

Also record these cases for each OS/keyboard pair:

- All four text/numeric password variants hide prompts; no render or
  clipboard read. Missing connection/metadata and other classes offer Copy.
- Cold/warm entry, used clipboard builtin sampled once after row activation,
  duplicate taps, Back/cancel, hide/reopen, rotation/landscape and large fonts.
- Change the input target or learning flag while form/clipboard/learning work
  is pending: no old insertion, Copy or delayed switch in the new session.
  Accepted bookkeeping finishes once; Ephemeral performs no value/usage writes.
- Search/Fill handoff restores the completed snapshot and policy in a Copy
  activity, with the prior typing keyboard or system picker shown first.
  Cancel the picker and select our IME in the Fill editor: Switch keyboard
  stays available; no recursive handoff or insertion into our own editor.
  In split-screen on API 29+, leave Fill resumed and focus the other app:
  the external picker must work, while dialogs/focus loss alone never enable
  prompts in an already identified own-editor session.
- Previous-keyboard failure falls back to the picker; unavailable picker
  leaves a visible Switch keyboard action and navigation-bar instructions.
  API 26/27 uses the IME window token. If only 28–33 hardware is tested,
  the legacy-device switch proof remains NOT RUN.
- Failed commit offers explicit Copy without retrying commitText; accepted
  persistence failure warns without replay and Done permits switching.

Selection/share/setup and final milestone closure are later slices. Preserve
the M8 and Unicode evidence above when adding their owner-run results.

## M10 Z4 private-filesystem durability: NOT RUN

The Z4 JVM tests use real temporary paths, POSIX modes and persistent directory
xattrs, with injected flush/race failures. They do not execute Android `Os`
or establish Android crash durability. No physical Android check has run.
Z19 owns production sync composition; repeat these checks through its final
signed, minified APK when that path is available.

Checked operations share the existing prompt/state roots. File and directory
flushes use read-only, no-follow `Os` descriptors, including viewer files.
Directory incarnations combine device/inode with a UUID in
`user.monkeyspaw.sync-incarnation`; checked flush persists the marker. The UUID
survives child edits, rename and restart, while delete/recreate gets a new one.
Unsupported xattrs or directory fsync fail closed. Ordinary index filtering
and best-effort local writes keep their existing contracts.

| Owner check on the private library and state filesystem | Status |
|---|---|
| Full inventory includes hidden, unknown, empty and unowned entries; links block unsafe sync | NOT RUN |
| Exact-byte exclusive publication and replacement; modes 0444 and 0600 survive replay | NOT RUN |
| Read-only descriptor file fsync and checked directory/ancestor fsync succeed | NOT RUN |
| Persistent incarnation marker survives restart/rename/child edits; delete/recreate changes it | NOT RUN |
| Exclusive directory rename preserves unknown contents and refuses occupied destinations | NOT RUN |
| Interrupt both case-rename steps, recreate the graph and replay twice without losing either version | NOT RUN |
| Inject file/parent flush failures; applied effects retain losing bytes and no cursor commits early | NOT RUN |
| Durable journal/raw retention precedes checked unlink; empty-only removal keeps late files | NOT RUN |

Record commit, APK SHA-256, signer, device/API, filesystem, tester/date,
server/desktop versions where applicable, and PASS/FAIL/BLOCKED for each row.
Actual process death and power-loss testing remain distinct from injected
errors. Required NOT RUN rows keep M10 open (§23 P20).
