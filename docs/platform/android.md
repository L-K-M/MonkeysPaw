# Android acceptance

## M8 quick entry points: NOT RUN

Owner-run checks for §10.4 B and §20 F2/F16. No Android device or emulator
was used on the implementation host. JVM policy tests, manifest checks and
APK assembly do not prove launcher, keyguard, Activity stacking or return.
Use the final signed, shrunk release APK on an API 26–33 device and an API
34+ device, including minimum API and target 37 coverage when available.

- Commit / APK version / SHA-256: NOT RUN
- Device / Android API / launcher: NOT RUN
- Target app versions / field: NOT RUN
- Date / tester: NOT RUN

Add the tile through Quick Settings editing, expose **Insert prompt** by
holding the launcher icon, and add the **Monkey's Paw: Insert prompt** widget.
No keyboard or automatic tile onboarding is part of M8. For a cold entry,
end the app process while retaining its library, then invoke the entry.
For a warm entry, invoke it after another completed or cancelled form.

| Check | API 26–33 | API 34+ | Device / details |
|---|---|---|---|
| Cold tile opens seed choice or the picker; pick → fill → Copy returns to the previous app | NOT RUN | NOT RUN | |
| Warm tile collapses Quick Settings and opens the picker, using the Intent / PendingIntent policy respectively | NOT RUN | NOT RUN | |
| Cold and warm launcher shortcut opens the same pick → fill → Copy flow | NOT RUN | NOT RUN | |
| Cold and warm widget button opens the same flow; two widget instances both work | NOT RUN | NOT RUN | |
| Locked tile requires unlock before showing prompts; cancel unlock opens nothing; retry succeeds | NOT RUN | NOT RUN | |
| Shortcut and home-screen widget do not show a form, preview or clipboard above the lock screen | NOT RUN | NOT RUN | |
| Reinvoke any entry while editing; switch between tile, shortcut and widget; one form keeps its fields and initial clipboard snapshot | NOT RUN | NOT RUN | |
| Open Library while a fill picker is held and select a prompt; the selected prompt opens. Repeat while editing/copying; the active form is preserved | NOT RUN | NOT RUN | |
| Reinvoke while Copy is pending; one write and one learning operation complete, then the Activity finishes | NOT RUN | NOT RUN | |
| Copy finishes after saving usage/remembered fields; no automatic paste, target-app start or duplicate app copy toast | NOT RUN | NOT RUN | |
| Back from picker or form and Cancel finish, returning to the prior app or launcher; clipboard and usage are unchanged | NOT RUN | NOT RUN | |
| After Copy or Back, a new entry opens a fresh session; an already open Library/Editor is preserved | NOT RUN | NOT RUN | |
| Rotate, background, lock and resume a form; fields survive and the builtin snapshot is not retaken | NOT RUN | NOT RUN | |
| With "Don't keep activities" enabled, Copy/Back still returns and a new entry opens without stalling | NOT RUN | NOT RUN | |
| TalkBack identifies the tile, shortcut and widget button; large text and widget resizing keep the button usable | NOT RUN | NOT RUN | |

For each target below, focus a harmless editable field, invoke the tile,
pick and fill a prompt with multiple lines, then Copy and long-press Paste.
Confirm exact text once and that no Enter is submitted. For Termux, use a
harmless sentinel and clear the line without executing it. Repeat via the
shortcut and widget after returning to the launcher, then test Back without
copying. Record the actual return destination; these home-screen entries
cannot promise a sending text field.

| Target | Tile → Copy → manual Paste | Shortcut / widget → manual Paste | Back / return | Details |
|---|---|---|---|---|
| Chrome | NOT RUN | NOT RUN | NOT RUN | |
| ChatGPT app | NOT RUN | NOT RUN | NOT RUN | |
| Claude app | NOT RUN | NOT RUN | NOT RUN | |
| Termux | NOT RUN | NOT RUN | NOT RUN | |

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
R8. The app skeleton has no sync caller yet, so its ProGuard rules retain
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

## Minimum-API device check: NOT RUN

No Android device or emulator was used on the implementation host. A
minimum-API device still needs to execute the minified validator through
the app's production call path when that caller exists. Check these cases:

| Input | Expected result in private scope |
|---|---|
| `Cafe\u0301/E\u0301.md` | NFC `Café/É.md`, key `café/é.md` |
| `\u0F73` repeated 20 times, followed by `.md` | All 20 U+0F71 marks, then all 20 U+0F72 marks, followed by `.md`; no truncation |
| U+E0001 followed by `a.md` | `path.control_character`, segment 0 |
| `Groupſ/a.md` | `path.reserved_groups_prefix`, null segment; accepted in group scope |
| `İ/Iıi.md` | Key `i\u0307/iıi.md` |

Record the commit, APK SHA-256, device/API level, tester and results. This
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
