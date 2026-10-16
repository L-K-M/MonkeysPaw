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
| Every M2/M5 fixture is consumed by `:core` | PASS. [CorpusInventoryTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/CorpusInventoryTest.kt), `inventory accounts for every visible fixture exactly once`, requires every visible fixture to be accounted for. The current inventory below has 1,536 cases / 5,515 files / 10 categories and 54 schemas; the recorded PASS remains tied to the revision above. [EveryFixtureTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/EveryFixtureTest.kt), `every visible fixture is consumed semantically exactly once`, requires semantic consumption to equal that inventory, with pending 0. The nine M8 categories total 1,034 cases / 2,172 files; the later LLM category is also consumed. |
| DTO accounting, including admin contracts | PASS. [DtoConformanceTest](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/DtoConformanceTest.kt), `every contract consumes every valid and invalid case with canonical bytes` and `case order does not affect complete corpus accounting`: 649 cases (160 valid / 489 invalid), 1,298 files, all 54 contracts; pending 0. |
| Exact Android gate | PASS locally: 570 Core tests and 357 app tests, zero failures/errors/skips; lint and both APK assemblies pass, including seed-asset verification. Command/environment below. Compilation and R8 outputs may be reused from Gradle's build cache. |
| `ci.yml` Android job exists and runs the five tasks | PASS. [`android`](../../.github/workflows/ci.yml) is green on main `ea741f46`, [run 38634897474 / Android job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634897474/job/116122711154), including APK verification and artifact byte comparison. Main `766394cf`'s run 38656497917 was pending at collection. |
| `release.yml` APK and asset gates | PASS in PR dry runs: K19 [run 38586738354 / APK job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38586738354/job/116024653871), and the verifier fix now merged as #216, [run 38634076231 / APK job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634076231/job/116142682271). The latter's [asset gate](https://github.com/L-K-M/MonkeysPaw/actions/runs/38634076231/job/116159168194) passed; both publish jobs were skipped. [`android-build`](../../.github/workflows/release.yml) exists on the recorded main. This is dry-run evidence, not a published release or a post-K19 main tag/manual release run. |
| `scripts/sync-android-version.sh` works | PASS. [test_android_version.py](../../scripts/tests/test_android_version.py): 11 tests, none skipped, including seven hook/fake-engine tests and four installed-release-engine tests in disposable fixture repositories. Changed versions increment the code once, aligned retries do not write, malformed/overflow input preserves files, and hook edits enter the release commit/tag with rollback on failure. No release command or tag was created in the implementation checkout. |

Current fixture inventory after L6 (#186), recomputed from this slice's files.
The automated pass above remains historical evidence for main `766394cf`:

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
| llm (later M11 fixtures) | 502 | 3,343 |
| Current corpus total | 1,536 | 5,515 |

The current LLM inventory contains 27,486 semantic expectations. The historical
run's inventory SHA-256 (sorted relative path, NUL, exact file bytes) was
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

## M9 acceptance record

**M9 is code-complete, but NOT closed.** N1–N8 are merged. Every owner
cell in the consolidated matrix below is **NOT RUN (owner)**. No device
or emulator was used for this record. Closure requires committed owner
evidence on the final signed, minified APK and green latest-main CI
([§15](../plan/15-milestones.md), [§22 H12](../plan/22-m9-m11-decisions.md)).

Automated evidence collected on 2026-10-15 at main
`3b900c8adefffb3ad687bb64e67afe0da48700fa`, which includes N8 merge `dee05a8f`.
The gate launched at `dee05a8f`; the fast-forward to `3b900c8a` did not
change the Android tree.

| Acceptance item | Result and evidence |
|---|---|
| `inputType` decision table | PASS. [ImeInputPolicyTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ime/ImeInputPolicyTest.kt): 7 JVM tests, covering class/variation masks, all four password variants, missing metadata/connection, terminal/null-like encodings, actual MULTI_LINE versus IME_MULTI_LINE, final-render line separators and learning opt-out. Counts are test methods, including their table-driven loops. |
| Selection-field choice | PASS. [CapturedTextFieldChoiceTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ui/fill/CapturedTextFieldChoiceTest.kt): 8 JVM tests. First effective multiline in body order, else explicit/implicit text; switch/ignore, prefill/edit precedence, no choice/builtin/fieldless capture and literal single-pass rendering. |
| IME and entry integration | PASS. [EntryFlowIntegrationTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/entry/EntryFlowIntegrationTest.kt): 3 JVM tests across IME, editable/read-only selection, share, tile, shortcut and widget. Shared Fill, held snapshots, one effect before learning/finish, repeated-entry preservation and accepted bookkeeping after IME teardown. |
| Persistence and diagnostics privacy | PASS. [ImePrivacyTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ime/ImePrivacyTest.kt): 11 JVM tests with fresh runtime sentinels and isolated file/log capture. Cancelled/failed/Ephemeral paths retain original bytes; Normal success writes only permitted remembered/usage state; explicit share Save alone creates a prompt. |
| Local IME graph | PASS. [ImeBoundaryTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ime/ImeBoundaryTest.kt): 17 JVM source/DI guards and negative probes for HTTP, secrets, scheduling, diagnostics, subprocess escapes and target-text reads. These are regression guards with the limits documented in the [N8 proof](#m9-insertion-integration-and-privacy-proof-n8), not complete semantic analysis or runtime network evidence. |
| Source and both merged manifests | PASS. [EntryManifestTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/entry/EntryManifestTest.kt): 8 JVM tests. AGP supplies debug and release manifests as declared test inputs. Assertions pin exact permissions/components/exports/filters, IME BIND_INPUT_METHOD/metadata, one process, backup denial, DUMP-protected profile receiver, and lifecycle/emoji-only eager startup metadata. Duplicate components and weakened receiver protection are rejected. Packaged debug/release manifests were also inspected after assembly. |
| Exact Android gate | PASS locally: 753 Core and 566 app JVM tests, zero failures/errors/skips; lint has zero errors and 14 warnings. Debug and signed/minified release APKs, R8/resource shrinking and both seed-asset verifiers pass. The [host command/environment above](#m8-acceptance-record) was run exactly: from `android/`, `./gradlew --max-workers=2 :core:test testDebugUnitTest lintDebug assembleDebug assembleRelease`, JDK 21 `/opt/java/openjdk`, SDK `/home/paseo/Android/Sdk`, the Google Maven CDN override and `LANG=C.UTF-8 LC_ALL=C.UTF-8`. Build directories started absent; some compilation outputs were restored from Gradle's cache, both JVM test tasks executed. |

The local release APK has SHA-256
`dbe1ca1fb4f4c18b913db479eb760086fb913b6cfefbbc31c1157c843dd3f37b`.
Signature verification passes with the one [committed public signer](../decisions/0001-android-zero-secret-signing.md),
certificate SHA-256 `76a19df68d562789f6ea990b23232875b70a98c9996ba81e794ccab063edd765`.
This identifies a local build, not a published release or owner-tested APK.
The scripts gate, `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`,
also passes all 87 tests.

Merged N-slice PRs and their successful **Android JVM tests, lint and APKs**
jobs, queried with `gh pr view <n> --repo L-K-M/MonkeysPaw --json mergeCommit,statusCheckRollup`:

| Slice | Merged PR / main commit | Green Android PR CI |
|---|---|---|
| N1 | [#184](https://github.com/L-K-M/MonkeysPaw/pull/184), `5a8b417b` | [Run 38537794630 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38537794630/job/115804650495) |
| N2 | [#194](https://github.com/L-K-M/MonkeysPaw/pull/194), `65927f5c` | [Run 38608413878 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38608413878/job/116025150804) |
| N3 | [#211](https://github.com/L-K-M/MonkeysPaw/pull/211), `e6906312` | [Run 38660555184 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38660555184/job/116181261544) |
| N4 | [#212](https://github.com/L-K-M/MonkeysPaw/pull/212), `795b886c` | [Run 38694640167 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38694640167/job/116294227142) |
| N5 | [#209](https://github.com/L-K-M/MonkeysPaw/pull/209), `ff69a34f` | [Run 38623389286 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38623389286/job/116075635759) |
| N6 | [#210](https://github.com/L-K-M/MonkeysPaw/pull/210), `0a6d3a81` | [Run 38640011276 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38640011276/job/116116281133) |
| N7 | [#213](https://github.com/L-K-M/MonkeysPaw/pull/213), `860740d1` | [Run 38694060343 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38694060343/job/116294201658) |
| N8 | [#256](https://github.com/L-K-M/MonkeysPaw/pull/256), `dee05a8f` | [Run 38792521260 / job](https://github.com/L-K-M/MonkeysPaw/actions/runs/38792521260/job/116623912299) |

These are build-job results, not reviewer approvals. N4's completed first
review led to merged fixes, but its [final automated review run](https://github.com/L-K-M/MonkeysPaw/actions/runs/38694637306)
failed without findings; final-revision review coverage is a gap, not approval.

`gh run list --repo L-K-M/MonkeysPaw --branch main --workflow ci.yml -L 5`
reports recent green main runs [38797937478](https://github.com/L-K-M/MonkeysPaw/actions/runs/38797937478)
at `283c8fa3` and [38783075632](https://github.com/L-K-M/MonkeysPaw/actions/runs/38783075632)
at `9829219c`. At collection, current-main [run 38809530240](https://github.com/L-K-M/MonkeysPaw/actions/runs/38809530240)
was pending; N8's main [run 38809381519](https://github.com/L-K-M/MonkeysPaw/actions/runs/38809381519)
was cancelled. The earlier green runs do not establish latest-main CI.

**N8 plan deviation:** the external N8 row requested “absent INTERNET”.
The app legitimately declares exactly `android.permission.INTERNET` for
M10 sync and M11 assistant. Both merged manifests assert that permission
set; the IME graph guards prove no reachable HTTP capability within their
stated source-analysis limits. The [N8 proof and runtime checklist](#m9-insertion-integration-and-privacy-proof-n8)
retain the distinction between packaging/JVM evidence and real OS behavior.

The consolidated owner matrix follows. **Each cell requires separate
Gboard and Samsung Keyboard results** on suitable hardware; a combined
result must not hide an untested keyboard or app. The linked N3–N8 and M8
sections retain their detailed procedures and per-app records.

| Owner scenario | Android 14 / API 34 | Android 15 / API 35 | Android 16 / API 36 | One device below API 34 | Additional evidence to record |
|---|---|---|---|---|---|
| [IME insertion and switch-back](#m9-ime-insertion-and-switch-back-not-run) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Chrome, ChatGPT and Claude fieldless/default/remembered/choice Insert exactly once; previous keyboard/subtype restored. Termux single-line Insert without execution; multi-line offers Copy and manual paste. Record literal Unicode/line breaks and no submission. |
| [Selection action](#text-selection-entry-checks-m9-n5-not-run) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Editable replacement versus read-only Copy, no selection, multiple candidate fields, switch/ignore and fieldless prompts; Chrome/native EditText/supporting Compose toolbar availability and return behavior. Unsupported hosts remain coverage gaps. |
| [Share target](#share-entry-checks-m9-n6-not-run) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Fill → explicit Copy; unsaved Editor → explicit Save or cancel, no early file, sender replacement or URL/attachment access; exact body and return destination. |
| [Keyboard/tile onboarding](#m9-keyboard-and-tile-setup-not-run) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Enable-warning explanation, enabled/selected rereads, tile add/deny/error or manual setup, skip/upgrade and Settings re-entry after disabling/removing components; no reseeding. |
| [M8 tile/shortcut/widget regressions](#m8-quick-entry-points-not-run-owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | All four M8 target apps; cold/warm/locked entry, held form and builtin snapshot, exactly-once Copy/manual paste, Back and actual return destination. |
| [IME lifecycle and handoff](#m9-ime-insertion-and-switch-back-not-run) / [runtime privacy](#m9-insertion-integration-and-privacy-proof-n8) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | NOT RUN (owner) | Passwords, stale target/connection, cold/warm process, hide/reopen, rotation/landscape, free-text/search Copy handoff and return from external Fill activity, cancel and failed switch fallback; Normal/Ephemeral state, no target reads or IME HTTP/scheduling/diagnostics. |

Prefer API 26/27 for the below-34 device to exercise legacy token switching
and manual tile setup. If only API 28–33 is available, record legacy API
26/27 switching separately as **NOT RUN (owner)**. Samsung Keyboard needs
supported Samsung hardware; the coverage may span multiple devices.

For every result record main commit, APK version/code/SHA-256, signing
fingerprint/build type (signed, minified release), device/model/API,
previous keyboard/version/subtype, target/source app/version/editor type,
scenario, expected/actual text and return behavior, tester/date and
PASS/FAIL/NOT RUN with a sanitized evidence reference. Use harmless test
strings; keep private prompt, field, selection and clipboard contents out
of collected logs. Missing or failed cells keep M9 open. JVM fakes, source
guards, lint and R8 do not execute real Intent/Bundle parsing, Compose
owners, Binder/InputConnection, keyboard history, logcat or OS storage.

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
| Alias loss or invalidation | Read/Save retain ciphertext and fail with typed errors while entries remain; check the Settings recovery gap below before claiming Clear/Delete works | NOT RUN |
| Disk/publication failure | Save/Clear failure retains the previous credential and unrelated account; retry is explicit | NOT RUN |
| Persistence and diagnostics | Runtime synthetic sentinel absent in raw/base64/percent/JSON forms from settings, logs and temporary outputs; only encrypted payload persists; no raw key export | NOT RUN |

Do not put real credentials, sentinel contents, raw key material or platform
exception bodies in this checklist or bug reports. Hardware that is
unavailable remains a validation gap for K17/L20; an unchecked row does not
satisfy milestone acceptance.

Settings Clear/Delete currently reads the old credential for compensation.
An inaccessible alias or unreadable credential therefore blocks these intents
before deletion. The driver's decrypt-free Delete is not exposed by Settings.
This is an unresolved recovery gap, carried from L9/L14; do not record it as a
successful recovery. An empty ciphertext store can recover an unusable alias
on explicit Save, but that does not make retained accounts recoverable through
the current controls. A compensation-safe recovery contract and device proof
are still required by §22 J7/J18.

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

Selection/share/setup implementations are merged; their owner checks and
the [M9 acceptance record](#m9-acceptance-record) remain open. Preserve
the M8 and Unicode evidence above when adding owner-run results.

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
| Persistent incarnation marker survives restart/rename/child edits; recreation changes it; corrupt bytes fail permanently | NOT RUN |
| Exclusive directory rename preserves unknown contents and refuses occupied destinations | NOT RUN |
| Interrupt both case-rename steps, recreate the graph and replay twice without losing either version | NOT RUN |
| Inject file/parent flush failures; applied effects retain losing bytes and no cursor commits early | NOT RUN |
| Durable journal/raw retention precedes checked unlink; empty-only removal keeps late files | NOT RUN |

Record commit, APK SHA-256, signer, device/API, filesystem, tester/date,
server/desktop versions where applicable, and PASS/FAIL/BLOCKED for each row.
Actual process death and power-loss testing remain distinct from injected
errors. Required NOT RUN rows keep M10 open (§23 P20).

The selection, share and setup checklists above also need owner results.
Preserve the M8 and Unicode evidence when adding them.

## M9 insertion integration and privacy proof (N8)

The automatic gate is `:core:test testDebugUnitTest lintDebug assembleDebug
assembleRelease`. `EntryFlowIntegrationTest` runs IME, editable/read-only
selection, share, tile, shortcut and widget sessions through the shared picker,
`FillViewModelFactory` and Fill service with fake delivery ports and real private
file stores. It checks held builtin snapshots, literal capture, effect before
learning/finish, one accepted delivery, M8 repeated-entry preservation and
accepted bookkeeping after IME teardown. Existing lifecycle, delivery, setup,
selection, share and M8 regression suites remain part of the full gate.

`ImePrivacyTest` generates fresh sentinels at runtime and compares every file
in its isolated sandbox, including cache/log locations. Cancelled sessions,
late builtin callbacks, failed effects/launches, lost handoffs, unsaved/failed
share drafts and Ephemeral Insert/Copy/activity handoff leave the original
bytes unchanged.
Normal delivery adds only `state/values.json` with remember=true fields and
one body-free usage record, verified through a new store graph. Explicit share
Save creates only its prompt; a later explicit edit/save can add its previous
bytes to history. Capture, remember=false values, builtins and error bodies
are checked in raw, JSON, base64 and percent-encoded forms outside permitted
files, including both form-encoded `+` and percent-encoded `%20` spaces. JVM
logger callbacks at all levels and stdout/stderr are also observed; planted
FINE records and concurrent publishers exercise the capture itself.

`ImeBoundaryTest` extends the existing constructor/provider/inheritance walk
with top-level helper calls, class constructions, object calls and callback
references, including imported aliases with explicit-import precedence.
Negative probes check network, secrets, scheduling, diagnostics and target-text
reads. The local graph excludes the application diagnostic scope; settings
DataStore owns its separate silent supervised scope. `Application.onCreate`
retains the existing local index refresh, and the JVM warm-up test checks
both success and a missing-root failure without diagnostics or files. Concrete
clipboard access reads plain clip text without URI coercion. These source and
fake-port checks are regression guards, not a complete semantic DI analysis.

Merged-manifest regressions also cover startup before `Application.onCreate`.
The audit found dependency metadata eagerly initializing OkHttp's platform/log
bridge and scheduling profile installation on a cold IME process. Both checks
failed before their initializer metadata was removed. OkHttp's Android context
setup now runs only when Hilt constructs the HTTP transport. Profile installation
uses AndroidX's once-per-process manual initialization from the launcher through
a data driver, preserving normal launcher profiling. Lifecycle/emoji startup and
the system-protected profile receiver remain. The two newly direct AndroidX
dependencies use the already resolved versions; no version was upgraded.

**Permission deviation from the original N8 plan row:** the main app already
ships exactly `android.permission.INTERNET` for M11 assistant and M10 sync.
N8 preserves it and asserts that exact permission set, rather than the row's
older “absent INTERNET” wording. `EntryManifestTest` pins exported flags,
exact filters, IME `BIND_INPUT_METHOD` protection/metadata, one process,
backup denial and quick-entry resources. JVM tests inspect both merged debug
and release manifests as declared inputs from AGP's artifact API. Inspect the
packaged release manifest after assembly as well: source XML alone cannot
detect dependency additions.
The IME graph continues to exclude HTTP, sync engine, secret and scheduler
capabilities; shared local sync recovery/value types are not outbound work.

No JVM result executes real Intent/Bundle parsing, Compose owners, Binder,
InputConnection, Android ClipboardManager, logcat or OS storage. Lint, R8 and
merged-manifest inspection prove build/packaging properties. They do not prove
that a target displayed inserted text or that Android performed no background
work. Use the signed, minified release APK for the owner matrix above and these
additional checks; all remain NOT RUN until runtime evidence is attached.

| Runtime privacy check | Result |
|---|---|
| Cold/warm IME open, browse, password target, hide/reopen and handoff cause no HTTP/sync/secret access, scheduled work or IME diagnostics | NOT RUN |
| Component-only startup does not initialize OkHttp or schedule profile installation; the first explicit network use and launcher profile initialization still work | NOT RUN |
| Cancel, failed commit/Copy, late callbacks and Ephemeral Insert/Copy/handoff leave no new value, draft, capture, log or temporary files; inspect private storage and logcat using runtime-generated harmless sentinels | NOT RUN |
| Normal delivery persists only permitted remembered fields/usage; shared new prompt persists only after explicit Save, with history only for later explicit saves | NOT RUN |
| Rotation, process loss and target changes never restore capture or an old connection from Intent/saved state; no extracted, selected or surrounding target text is requested | NOT RUN |

Record only pass/fail, file paths/counts and sentinel-match counts, never the
sentinels or private content. Required device gaps keep M9 open (§22 H12).

## Android assistant (M11): NOT RUN (owner)

M11 remains open. Local shared-fixture, JVM, lint and APK checks are distinct
from latest-main CI/review and these owner checks. Follow
[§7](../plan/07-llm-assistant.md), [§12](../plan/12-security-and-privacy.md),
[§15](../plan/15-milestones.md) and
[§22 J3/J18](../plan/22-m9-m11-decisions.md#m11-android-assistant).
Every required NOT RUN, skipped or blocked row keeps the milestone open.
Repeat all flows on the final signed, minified release APK after integration.

### Assistant disclosures

Calls happen only on your explicit action. Write sends your brief. Review and
Improve send the current template front matter and body, including unsaved
edits; Improve also sends your instruction and selected findings. Explicit
feedback retries can send the session transcript and feedback with the fresh
template and instruction. Requests include system instructions, output schema
and model selection. Test connection sends only an authenticated model-list
request, or a keyless list request for a keyless provider. Save, rename,
switch and delete do not send provider requests. The host and model appear
before sending, and token usage appears when returned. Providers can read
what you send and may charge for it.

Fill values, rendered previews, remembered values and IME target text are never
sent to the assistant. `private: true` blocks Review and Improve; Write sends
only the separately supplied brief while a private template is open. Session
briefs, instructions, findings, feedback and transcripts stay in memory;
Accept alone saves the validated candidate and local provenance/history.
Reject writes nothing. The offline editor and Fill remain available without
an assistant provider. There is no telemetry, HTTP logging, raw provider
diagnostic display or logging of keys, prompt content or field values.

Saved API keys are encrypted with AES-256-GCM using AndroidKeyStore. The
separate singleton `filesDir/datastore/secrets.json` DataStore contains account
names, IVs and ciphertext/tag only. Non-secret provider settings and capability
records share `filesDir/datastore/settings.json`. There is no plaintext,
environment or exported-key fallback. StrongBox is preferred where available;
the **keystore** tier does not establish actual hardware backing. Re-entry or
explicit Clear is required when a saved credential's kind or origin changes.
The native recovery limitation above remains unresolved.

### Evidence to record

Use harmless disposable content and synthetic credentials for scans. Record
only sanitized outcomes, counts and paths, never credentials, sentinels, prompt
content, Fill values, transcripts or provider/platform error bodies. Each run
must identify its exact APK and commit; local APK assembly is not installation
or provider evidence.

| Evidence | Status | Required record |
|---|---|---|
| Latest merged main commit and full CI/review | NOT RUN (owner/supervisor) | Commit SHA, CI URL, completed review and dispositions; both complete corpora and five Android tasks |
| Final release APK | NOT RUN (owner) | Artifact URL, version/code, SHA-256, signer fingerprint, minified release build |
| API 26-27 device | NOT RUN (owner) | Device/model/API, OS build, actual Keystore backing, tester/date |
| StrongBox-capable API 28+ device | NOT RUN (owner) | Device/model/API, actual security level/backing, fallback results, tester/date; unavailable hardware stays a gap |
| Provider identity for each run | NOT RUN (owner) | Protocol, endpoint scheme/host, actual model, Ollama version, tester/date; no credentials |
| Real Keystore lifecycle | NOT RUN (owner) | All native secret-store rows above, restart/reboot, masked input and recovery outcomes |
| Six provider/flow runs | NOT RUN (owner) | Each row below, expected/actual behavior, sanitized issue/evidence links |
| Fill/IME/offline editor preservation | NOT RUN (owner) | Existing entry/delivery checks, offline edit/save/history, no network from IME startup |

Use your own Anthropic key and an actually available model at
`https://api.anthropic.com`. The planned default model and beta/fallback
settings remain owner-unverified (§19 B31); a JVM golden is not proof of API
availability. For keyless Ollama use the OpenAI-compatible profile with
`http://localhost:11434/v1` on device loopback via USB reverse forwarding, or
system-trusted HTTPS. Assistant plaintext LAN and `.local` endpoints remain
refused; sync's LAN/user-CA policy does not apply to the assistant.

| Provider | Flow | Settings/Test/manual model | Flow and device result | Evidence |
|---|---|---|---|---|
| Anthropic | Write | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |
| Anthropic | Review | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |
| Anthropic | Improve | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |
| Keyless Ollama | Write | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |
| Keyless Ollama | Review | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |
| Keyless Ollama | Improve | NOT RUN (owner) | NOT RUN (owner) | NOT RUN |

For each provider, first verify masked key input and unavailable Copy/autofill,
usable Paste, blank Keep, explicit Clear, staged metadata and profile
selection/none. A stored key never reappears. Save, switch, Back/reopen and
rotation clear typed input; rotation/opening never resend. Test suggestions
and manual model IDs remain usable after empty/unsupported/failed listing.

For both Write rows, inspect fields, validation issues, notes and the exact
candidate source/identity. Reject must leave the library/history unchanged.
Repeat and Accept; reopen and compare saved bytes with the displayed candidate,
including LLM provenance and returned usage. Write must not import an open
private template or Fill values.

For both Review rows, review a validated unsaved template, inspect local
issues, severities and rubric labels, and highlight an exact quote after emoji
and combining text. Empty/unmatched quotes remain visible without unrelated
highlights. Change the buffer away and back; stale highlights and selections
remain disabled. Review creates no candidate, file, history or provenance.

For both Improve rows, run instruction-only and selected-findings flows.
Inspect separate front-matter/body diff panes, line numbers, placeholder
warnings and horizontal scrolling on a narrow phone. Reject preserves every
file. Accept saves exactly the preview, retaining existing identity/unknown
metadata and creating one prior revision. Saved provenance/history warnings
must not invite another write. Production group-role checks remain blocked
until M10's live access authority replaces `AssistantAccess.LOCAL`; injected
group-role tests do not prove that integration.

In all six rows, verify explicit feedback retry, elapsed/Cancel, Back/gesture,
rotation, background/resume, TalkBack and large text. Cancel or switch profile
while a response is pending; an old reply cannot revive the session. Editing
the buffer or changing disk bytes withdraws acceptance until fresh Show diff
or the existing conflict decision. `private: true` refuses Review/Improve
before HTTP. A harmless local endpoint inspected only in memory must receive
template bytes rather than distinctive Fill/remembered values. Preserve actual
committed outcomes after late cancellation; never repeat a committed save.

### Runtime sentinel scan and automated proof

Through production Settings on a disposable device, generate a new synthetic
key in memory with a random UUID plus quote, backslash, slash, percent, plus
and Unicode characters. Never place it in argv, environment, shell history,
screenshots or evidence. Scan after Save, successful Test, failed Test with an
in-memory diagnostic echo, force-stop/reopen graph reconstruction, rename,
switch away, switch back, unrelated-account deletion and sentinel deletion.
Cover app-private DataStore/state/library/cache/temp files, hidden files,
logcat captures, logs and test/diagnostic outputs. Detect raw UTF-8, base64,
percent encodings, JSON escaping (including Unicode and escaped slashes) and
nested JSON credential payloads. Calibrate with deliberate copies in each
encoding and remove them before each real checkpoint. Record paths/counts
only. Zero matching files are permitted at every checkpoint, including the
encrypted secrets DataStore; only the authenticated ciphertext record may
persist while saved. Deleting one account preserves unrelated ciphertext.
Use a local stub for deliberate failures, never a real paid key or HTTP logs.

[AssistantSettingsPersistenceTest](../../android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ui/settings/AssistantSettingsPersistenceTest.kt)
uses real settings/secrets DataStores, JVM AES-GCM with injected keys, both
production protocol clients and the OkHttp driver against MockWebServer.
Its scanner is calibrated on hidden binary and encoded copies, captures
stdout/stderr and logging, and reopens DataStores during graph reconstruction.
This proves testable policy and persistence, not AndroidKeyStore, native key
input, hardware, process death, rendering or live provider compatibility.
[Swift accounting](../../Tests/MonkeysPawCoreTests/Assistant/LlmConformanceTests.swift)
and [Kotlin accounting](../../android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/LlmConformanceTest.kt)
require all schema/decode/merge/diff variants and each protocol's
Write/Review/Improve/model-list exchanges; both full corpus gates still consume
every owned category and reject unread expectations. Local results belong in
the slice handoff; the main CI and owner rows above remain NOT RUN until
actual evidence is recorded.
