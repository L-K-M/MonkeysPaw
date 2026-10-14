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
| Reinvoke while Copy is pending; one write and one learning operation complete, then the Activity finishes | NOT RUN | NOT RUN | |
| Copy finishes after saving usage/remembered fields; no automatic paste, target-app start or duplicate app copy toast | NOT RUN | NOT RUN | |
| Back from picker or form and Cancel finish, returning to the prior app or launcher; clipboard and usage are unchanged | NOT RUN | NOT RUN | |
| After Copy or Back, a new entry opens a fresh session; an already open Library/Editor is preserved | NOT RUN | NOT RUN | |
| Rotate, background, lock and resume a form; fields survive and the builtin snapshot is not retaken | NOT RUN | NOT RUN | |
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
