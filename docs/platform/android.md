# Android Unicode runtime checks

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
