# M12 v1.0 owner sign-off ledger

M12 is open. **Every result, actual observation and evidence field starts
NOT RUN.** No owner execution is asserted here. No agent creates or pushes
a tag. Only the owner authorizes publication and creates/pushes `v1.0.0`.

Use the [coverage table](#source-to-sign-off-coverage),
[candidate phase](#candidate-phase-before-tagging) and
[post-publication phase](#post-publication-phase-from-actual-v100) to locate
rows.

Use **PASS**, **FAIL**, **BLOCKED** or **NOT RUN**. PASS requires actual owner
observations and committed, sanitized evidence on the exact main SHA and
artifact for that row. FAIL is an observed mismatch; BLOCKED is an attempted
required check prevented by an unavailable prerequisite; NOT RUN is unattempted.
Vocabulary examples and expected refusals in sources are not observed failures.
Required unavailable sessions stay open. A sent event, zero tool exit, mock,
skipped native test or historical CI receipt cannot establish owner acceptance.

## Recording and phases

This inventory was re-enumerated from main baseline
`66cc2e70f9f5ae54fd4a4a2b8b7a760f3485083f`, not from the older frozen inventory.
That is a source baseline, **not a tested release SHA**. Refresh coverage after
source changes and bind every execution to the final reviewed main and bytes.

- **Candidate (`C-`):** pre-tag observations on one exact final main SHA and
  identified candidate artifacts. Record same-commit full CI, completed reviews
  and dispositions, and `dry_run=true` release run. No tag is created here.
- **Post-publication (`P-`):** independently execute the required rows using
  actual `v1.0.0` downloads/installed copies and the published image. Record
  the tag SHA, release/publishing run and exact downloaded bytes. Candidate
  evidence never closes a P row, even when the bytes compare equal.
- Each C/P pair below is two records. Repeated source keys are intentional;
  each environment and phase needs its own observations. Every compound key
  keeps **all** source conditions, subcases and checkpoints. An aggregate PASS
  needs a committed per-key/subcase outcome list, including expected/actual
  readback; unattempted members keep the aggregate NOT RUN.

Follow the source procedures without copying sensitive text into evidence.
Each evidence record must identify main SHA, artifact origin/name/version/build
and owner-observed SHA-256, OS/build/architecture/hardware, physical keyboard
layout/input method, signing, permissions, portal/backend capabilities and
versions, target app/version/field/WM_CLASS, tester and UTC date. Device rows
also need API/model, previous keyboard/version/subtype and actual Keystore
backing. Sync rows need deployed commit/version/image digest, database identity,
deployment scheme/host/prefix, peer versions and disposable user aliases/roles.
Do not invent a tester, date, artifact digest or result. Record safe outcomes,
counts, versions, issue references and redacted screenshots, never credentials,
sentinels, invite links, prompt/field/clipboard contents or raw error bodies.
The detailed evidence rules remain in
[M7 recording](m7-acceptance.md#recording-a-run),
[Android](android.md#evidence-to-record) and
[desktop sync](sync.md#required-owner-acceptance-ledger).

## Owner decisions before tagging

All five decisions are open. A decision records an authorized disposition;
it does not turn an unrun physical check into PASS.

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| D-HISTORY | [M2](m2-acceptance.md#m2-daily-use-acceptance) `P1; P4; T1.R5; T3.R1; T3.R2`; [Linux](linux.md#release-deb-installation-m2-not-run) `N1; N2; N3` | Owner / historical `v0.1.0` conflict | NOT RUN | Preserve exact historical artifacts and owner installations, or commit an explicit owner-authorized plan amendment before using replacement evidence | NOT RUN | NOT RUN | NOT RUN |
| D-R1 | [M12](../plan/15-milestones.md#15-milestones); [release contract](../../CICD.md#ci-and-releases) | Owner / release date and R1 preparation | NOT RUN | Supply actual date; approve dated notes, aligned 1.0.0 marketing versions and hook-managed Android code once, aligned retry, reviewed main and candidate dry run | NOT RUN | NOT RUN | NOT RUN |
| D-SIGN | [macOS install](macos.md#m2-macos-artifacts-and-installation-not-run) `N3; N5`; [M7 prerequisites](m7-acceptance.md#owner-prerequisites) `T1.R4` | Owner / actual macOS signing mode | NOT RUN | Choose documented ad-hoc or provision Developer ID; arrange notarization/stapling only if promised; require real quarantine/AX/Keychain update evidence; retain Android public signer | NOT RUN | NOT RUN | NOT RUN |
| D-PRIVATE | [M7 prerequisites](m7-acceptance.md#owner-prerequisites) `P1; T1.R1`; [Security](../../SECURITY.md#report-a-vulnerability-privately) | Owner / repository settings | NOT RUN | Enable and verify confidential reporting before release; the disabled source observation is historical, with no verified alternate contact | NOT RUN | NOT RUN | NOT RUN |
| D-GHCR | [M7 prerequisites](m7-acceptance.md#owner-prerequisites) `T1.R7`; [image contract](../../CICD.md#ci-and-releases) | Owner / first GHCR package | NOT RUN | Approve package/token permissions and first-created-package public-visibility sequence; later prove anonymous pulls for both architectures | NOT RUN | NOT RUN | NOT RUN |

## Open dispositions and accepted platform rules

These named gaps remain visible independently of implementation completion.
No source status or checkbox is changed by this ledger.

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| G-M4-D1 | [M4](m4-acceptance.md#m4-assistant-acceptance) `T1.R5; P7` | Owner/supervisor | NOT RUN | Source disclosure-assertion gap needs proof or an explicit approved disposition; disclosures already exist | NOT RUN | NOT RUN | NOT RUN |
| G-M5-D1 | [M5](m5-acceptance.md#m5-server-acceptance) `P1; P7; P9` | Owner/supervisor | NOT RUN | Source documentation-assertion gap needs proof/disposition; disclosure text is present | NOT RUN | NOT RUN | NOT RUN |
| G-M5-R3 | [M5](m5-acceptance.md#m5-server-acceptance) `T5.R6; P9`; [client names](server.md#client-filenames-after-m6-not-run) `T1.R1; T1.R2` | Desktop clients / M6 boundary | NOT RUN | Retain deferred group-folder/device-filename proof; do not reopen source-closed M5-R1/R2/R4–R10 | NOT RUN | NOT RUN | NOT RUN |
| G-N4-REVIEW | [M9](android.md#m9-acceptance-record) `P5; P6` | Owner/supervisor / final main | NOT RUN | Address/dispose the recorded final-revision review gap and bind latest CI/review to final main; historical green runs do not supply it | NOT RUN | NOT RUN | NOT RUN |
| G-NATIVE-RECOVERY | [Keystore](android.md#android-native-secret-store-checks-m11-l8-not-run) `T1.R7; P4; P5`; [disclosures](android.md#assistant-disclosures) `P3` | API26–30 and API31+ / real Keystore | NOT RUN | Preserve ambiguous-lookup recovery limitation and native key-loss evidence gap; follow source fail-closed/refusal policy | NOT RUN | NOT RUN | NOT RUN |
| G-PROVIDER | [M11 evidence](android.md#evidence-to-record) `P2` | Actual Anthropic model and local Ollama | NOT RUN | B31 default-model/beta/fallback availability remains owner-unverified; a fixture is not live API proof | NOT RUN | NOT RUN | NOT RUN |
| G-GROUP-AUTHORITY | [macOS assistant](macos.md#m4-library-assistant-flows-73-76-117) `P2`; [Android assistant](android.md#evidence-to-record) `P6` | Real sync roles / viewer and queued acceptance | NOT RUN | Demonstrate authoritative group-role behavior on the integrated build; inherited future-tense prose or injected roles supply no device acceptance | NOT RUN | NOT RUN | NOT RUN |
| G-LEGACY-HARDWARE | [M9](android.md#m9-acceptance-record) `P9`; [IME](android.md#m9-ime-insertion-and-switch-back-not-run) `B5`; [Keystore](android.md#android-native-secret-store-checks-m11-l8-not-run) `T1.R1; T1.R2; T1.R3` | API26/27, supported Samsung and StrongBox hardware | NOT RUN | API28–33 cannot replace legacy switching; absent required hardware stays a gap | NOT RUN | NOT RUN | NOT RUN |

Earlier checklists retain their historical scope. Apply the explicit
[Linux M7 supersession](linux.md#m7-current-desktop-procedures) to old
Repeat-inactive/terminal-detection/portal descriptions; preserve every old
unrun key. The [merged scheduler permission baseline](android.md#android-sync-scheduling-m10-z20-not-run)
supersedes the older N8-only INTERNET baseline. The
[current release contract](../../CICD.md#ci-and-releases) requires nine files
and four manifests, including Flatpak; Android's seven-file baseline is a
historical subset. The [Unicode follow-up](android.md#unicode-runtime-checks)
still requires actual packaged/runtime checks against the now-integrated caller;
its older no-caller prose does not waive the minimum-API rows. The
[macOS version display](macos.md#m7-d17-delivery-and-update-settings-not-run)
uses the actual full candidate/release version; its earlier beta example does
not require publishing a beta instead of 1.0.0. The
[current sync guide](sync.md#required-owner-acceptance-ledger) and
[integrated phone checklist](android.md#android-sync-m10-not-run-owner)
govern connected acceptance despite earlier pending-integration prose.

- Intel physical launch is optional, explicitly labelled in MAC06 rows.
  It cannot replace universal-slice verification or required native Mac runs.
- [Selection hosts](android.md#text-selection-entry-checks-m9-n5-not-run)
  without ACTION_PROCESS_TEXT retain an observed UNSUPPORTED annotation,
  app/editor/version and toolbar evidence. Keep this ledger's result vocabulary:
  required replacement coverage stays open; the universal Copy path is separate.
  Source N/A cells remain inapplicable, never inferred PASS.
- [X11 aliases](m7-acceptance.md#x11-alias-evidence) each need real readback;
  unknown/lookalike classes and XTerm/URxvt/st use the accepted default/explicit
  chord. Missing required terminals become BLOCKED after an attempt. Wayland
  and Flatpak use their accepted default/explicit chord with no detection.
- [Portal limitations](gnome.md#gnome-portal-owner-checks),
  [KDE transitions](kde.md#portalnative-transition-matrix) and
  [Flatpak](flatpak.md#portals-clipboard-and-settings) retain their accepted
  Copy/fail-closed recovery rules. Record capability, denial, cache/reset,
  root cause and actual fallback. Unsupported capability does not waive the
  required environment or target readback.
- [IME policy](android.md#m9-ime-insertion-and-switch-back-not-run) retains
  password refusal, Termux multiline Copy/manual paste and switch-picker
  fallbacks. [Scheduling](android.md#android-sync-scheduling-m10-z20-not-run)
  retains ordinary/expedited/quota/Doze/force-stop limits; no exact timing
  promise.
- [Clipboard restoration](linux.md#m7-current-desktop-procedures) stays opt-in
  with the simultaneous-copy/750 ms limits; accept them explicitly or keep it
  off. Count checks without instrumentation stay NOT RUN. Real IBus/Fcitx and
  macOS marked-text checks require actual conversion engines.

## Environment key

An environment name is a required record slot, not evidence that it exists.
Every row retains its source's finer failure/mode/checkpoint branches.

| Key | Required environment and retained dimensions |
|---|---|
| MAC-dmg / MAC-zip | Separately installed archive copies, actual signing/quarantine and permissions; normal/full-screen Spaces and each target/backend where listed; real VoiceOver, Reduce Motion, IME and physical layout. Record architecture; Intel launch alone is optional. |
| X11 | Ordinary native X11 WM; actual xdotool/xprop and installed deb. GNOME-X11 and KDE-X11 are separately listed where the sources require available X11 sessions. Attempt required sessions; absence remains BLOCKED with reason. |
| GNOME-W / KDE-W | Separate native Wayland installations; actual compositor, GlobalShortcuts/RemoteDesktop interface versions, keyboard-only capabilities, consent/revocation and effective backends. Include no-GlobalShortcuts and KDE absent/v1/v2 transition records. |
| wlroots-W | Actual wlroots compositor and ydotool/uinput, both documented tool dialects/socket policies, browser and terminal readback and Copy recovery. |
| FP-GNOME / FP-KDE | Separate installed bundles on both hosts with GNOME 50 runtime, overrides, whole-home boundary, isolated state, real Secret Service and optional tray; sandbox portal → Copy. |
| API 26/27, API 28–30, API 31–33, API 34+ StrongBox | Separate native API/security/recovery records; StrongBox-capable hardware and unavailable-StrongBox fallback are distinct source subcases. API 26–30 ambiguous lookup and API 31+ direct lookup must both be observed. |
| API 34 / API 35 / API 36 / below34 | Android 14/15/16 and a below34 device, each with separate Gboard and Samsung Keyboard records on supported hardware and every named target. Prefer API 26/27 below34; legacy API 26/27 remains separately required. |
| Android entry/target rows | Record each tile, shortcut, widget and Back outcome within the explicitly listed source keys; no successful app/keyboard stands in for another. Selection hosts and share source types have separate rows. |
| Server and peers | Fresh local-disk Linux Docker host; deployed real-domain trusted HTTPS, certificate renewal, both updater reruns, offline restore/resnapshot; two actual desktops/two users and separate phone↔desktop group sharing. |

## Source-to-sign-off coverage

Keys are section-local and one-based. `Tn.R[1,2].C3` explicitly lists rows 1
and 2, column 3 of table n (header/separator excluded); `Tn.R[1,2]` covers the
whole row of an inherited-status or mixed proof table. `P`, `B`, `U`, `N`
number prose paragraphs, ordinary bullets, unchecked tasks and numbered steps,
respectively; fenced code is attached to its surrounding procedure. Counters
reset at every heading. A wrapped item is one key. `P[1,2]` is an explicit
many-to-one key list, with no omitted intermediate assumption or wildcard.
All conditions and metadata columns of each referenced row still apply.
Where a key has conditional platform/target branches, each execution row
records its applicable branch; the key stays open until all required contexts
have evidence. A skipped branch must name its source applicability rule.
Evidence/identity cells are required record fields attached to that row,
not extra physical tests. Pure automated tables/receipts are excluded with
their disposition; an open gap inside such a table is retained as a row key.

The coverage table and execution rows give the same explicit source keys.
`C/P-name` denotes the separately printed `C-name` **and** `P-name` rows.
Repeated references reconcile summary and detail without discarding either.
Counts below are source obligation/record units, **not unique physical runs**.

| Source file | Pending sections / obligations | Disposition |
|---|---|---|
| [android.md](android.md#android-acceptance) | 24 / 333 | Open owner obligations; mapped below |
| [assistant.md](assistant.md#m4-assistant-owner-checks) | 6 / 58 | Open owner obligations; mapped below |
| [flatpak.md](flatpak.md#flatpak-owner-procedure) | 4 / 38 | Open owner obligations; mapped below |
| [gnome.md](gnome.md#gnome-portal-owner-checks) | 2 / 31 | Open owner obligations; mapped below |
| [kde.md](kde.md#kde-shortcut-selection-and-delivery-owner-check) | 4 / 51 | Open owner obligations; mapped below |
| [linux.md](linux.md#linux-picker-and-delivery-checks) | 23 / 227 | Open owner obligations; mapped below |
| [m2-acceptance.md](m2-acceptance.md#m2-daily-use-acceptance) | 1 / 22 | Open owner obligations; mapped below |
| [m3-acceptance.md](m3-acceptance.md#m3-library-window-acceptance) | 1 / 12 | Open owner obligations; mapped below |
| [m4-acceptance.md](m4-acceptance.md#m4-assistant-acceptance) | 1 / 17 | Open owner obligations; mapped below |
| [m5-acceptance.md](m5-acceptance.md#m5-server-acceptance) | 1 / 17 | Open owner obligations; mapped below |
| [m7-acceptance.md](m7-acceptance.md#m7-acceptance-ledger) | 6 / 58 | Open owner obligations; mapped below |
| [macos.md](macos.md#macos-delivery-acceptance) | 23 / 364 | Open owner obligations; mapped below |
| [server.md](server.md#server-deployment-acceptance) | 8 / 46 | Open owner obligations; mapped below |
| [sync.md](sync.md#desktop-sync-setup-and-verification) | 3 / 21 | Open owner obligations; mapped below |

No file has a no-pending disposition: all 14 source files contain owner
obligations. The two automated-only sync sections are listed separately below.

| Source section and explicit keys | Sign-off IDs or disposition |
|---|---|
| [AND01](android.md#android-acceptance) `P[1]` | C/P-AND-identity |
| [AND02](android.md#m8-acceptance-record) `P[1]` | C/P-AND-identity |
| [AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[1,2,3,4,5,6].C2; T3.R[1,2,3,4,5,6].C3; T3.R[1,2,3,4,5,6].C4; T3.R[1,2,3,4,5,6].C5` | C/P-AND05-01, C/P-AND15-01-1, C/P-AND06-01-1, C/P-AND15-01-2, C/P-AND06-01-2, C/P-AND15-01-3, C/P-AND06-01-3, C/P-AND15-01-4, C/P-AND06-01-4, C/P-AND08-01-1, C/P-AND08-01-2, C/P-AND08-01-3, C/P-AND08-01-4, C/P-AND09-01-1, C/P-AND09-01-2, C/P-AND09-01-3, C/P-AND05-02, C/P-AND15-02-1, C/P-AND06-02-1, C/P-AND15-02-2, C/P-AND06-02-2, C/P-AND15-02-3, C/P-AND06-02-3, C/P-AND15-02-4, C/P-AND06-02-4, C/P-AND08-02-1, C/P-AND08-02-2, C/P-AND08-02-3, C/P-AND08-02-4, C/P-AND09-02-1, C/P-AND09-02-2, C/P-AND09-02-3, C/P-AND05-03, C/P-AND15-03-1, C/P-AND06-03-1, C/P-AND15-03-2, C/P-AND06-03-2, C/P-AND15-03-3, C/P-AND06-03-3, C/P-AND15-03-4, C/P-AND06-03-4, C/P-AND08-03-1, C/P-AND08-03-2, C/P-AND08-03-3, C/P-AND08-03-4, C/P-AND09-03-1, C/P-AND09-03-2, C/P-AND09-03-3, C/P-AND05-04, C/P-AND15-04-1, C/P-AND06-04-1, C/P-AND15-04-2, C/P-AND06-04-2, C/P-AND15-04-3, C/P-AND06-04-3, C/P-AND15-04-4, C/P-AND06-04-4, C/P-AND08-04-1, C/P-AND08-04-2, C/P-AND08-04-3, C/P-AND08-04-4, C/P-AND09-04-1, C/P-AND09-04-2, C/P-AND09-04-3, C/P-AND05-05, C/P-AND15-05-1, C/P-AND06-05-1, C/P-AND15-05-2, C/P-AND06-05-2, C/P-AND15-05-3, C/P-AND06-05-3, C/P-AND15-05-4, C/P-AND06-05-4, C/P-AND08-05-1, C/P-AND08-05-2, C/P-AND08-05-3, C/P-AND08-05-4, C/P-AND09-05-1, C/P-AND09-05-2, C/P-AND09-05-3, C/P-AND05-06, C/P-AND15-06-1, C/P-AND06-06-1, C/P-AND15-06-2, C/P-AND06-06-2, C/P-AND15-06-3, C/P-AND06-06-3, C/P-AND15-06-4, C/P-AND06-06-4, C/P-AND08-06-1, C/P-AND08-06-2, C/P-AND08-06-3, C/P-AND08-06-4, C/P-AND09-06-1, C/P-AND09-06-2, C/P-AND09-06-3, C/P-AND05-07, C/P-AND15-07-1, C/P-AND06-07-1, C/P-AND15-07-2, C/P-AND06-07-2, C/P-AND15-07-3, C/P-AND06-07-3, C/P-AND15-07-4, C/P-AND06-07-4, C/P-AND08-07-1, C/P-AND08-07-2, C/P-AND08-07-3, C/P-AND08-07-4, C/P-AND09-07-1, C/P-AND09-07-2, C/P-AND09-07-3, C/P-AND05-08, C/P-AND15-08-1, C/P-AND06-08-1, C/P-AND15-08-2, C/P-AND06-08-2, C/P-AND15-08-3, C/P-AND06-08-3, C/P-AND15-08-4, C/P-AND06-08-4, C/P-AND08-08-1, C/P-AND08-08-2, C/P-AND08-08-3, C/P-AND08-08-4, C/P-AND09-08-1, C/P-AND09-08-2, C/P-AND09-08-3 |
| [AND04](android.md#release-apk-verification) `P[1,2,3,4,5,6]; T1.R[1,2,3,4].C2` | C/P-AND04-01, C/P-AND04-02, P-AND04-published |
| [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | C/P-AND05-01, C/P-AND05-02, C/P-AND05-03, C/P-AND05-04, C/P-AND05-05, C/P-AND05-06, C/P-AND05-07, C/P-AND05-08, C/P-AND05-09, C/P-AND05-10, C/P-AND05-11, C/P-AND05-12 |
| [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1,2,3,4].C2; T2.R[1,2,3,4].C3; T2.R[1,2,3,4].C4` | C/P-AND06-01-1, C/P-AND06-01-2, C/P-AND06-01-3, C/P-AND06-01-4, C/P-AND06-02-1, C/P-AND06-02-2, C/P-AND06-02-3, C/P-AND06-02-4, C/P-AND06-03-1, C/P-AND06-03-2, C/P-AND06-03-3, C/P-AND06-03-4, C/P-AND06-04-1, C/P-AND06-04-2, C/P-AND06-04-3, C/P-AND06-04-4, C/P-AND06-05-1, C/P-AND06-05-2, C/P-AND06-05-3, C/P-AND06-05-4, C/P-AND06-06-1, C/P-AND06-06-2, C/P-AND06-06-3, C/P-AND06-06-4, C/P-AND06-07-1, C/P-AND06-07-2, C/P-AND06-07-3, C/P-AND06-07-4, C/P-AND06-08-1, C/P-AND06-08-2, C/P-AND06-08-3, C/P-AND06-08-4, C/P-AND06-01, C/P-AND06-02 |
| [AND07](android.md#m8-seeds-library-and-editorhistory-not-run-owner) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C2` | C/P-AND07-01, C/P-AND07-02 |
| [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1,3,4].C2; T1.R[2,3,4].C3; T1.R[1,2,3,4].C4` | C/P-AND08-01-1, C/P-AND08-01-2, C/P-AND08-01-3, C/P-AND08-01-4, C/P-AND08-02-1, C/P-AND08-02-2, C/P-AND08-02-3, C/P-AND08-02-4, C/P-AND08-03-1, C/P-AND08-03-2, C/P-AND08-03-3, C/P-AND08-03-4, C/P-AND08-04-1, C/P-AND08-04-2, C/P-AND08-04-3, C/P-AND08-04-4, C/P-AND08-05-1, C/P-AND08-05-2, C/P-AND08-05-3, C/P-AND08-05-4, C/P-AND08-06-1, C/P-AND08-06-2, C/P-AND08-06-3, C/P-AND08-06-4, C/P-AND08-07-1, C/P-AND08-07-2, C/P-AND08-07-3, C/P-AND08-07-4, C/P-AND08-08-1, C/P-AND08-08-2, C/P-AND08-08-3, C/P-AND08-08-4 |
| [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | C/P-AND09-01-1, C/P-AND09-01-2, C/P-AND09-01-3, C/P-AND09-02-1, C/P-AND09-02-2, C/P-AND09-02-3, C/P-AND09-03-1, C/P-AND09-03-2, C/P-AND09-03-3, C/P-AND09-04-1, C/P-AND09-04-2, C/P-AND09-04-3, C/P-AND09-05-1, C/P-AND09-05-2, C/P-AND09-05-3, C/P-AND09-06-1, C/P-AND09-06-2, C/P-AND09-06-3, C/P-AND09-07-1, C/P-AND09-07-2, C/P-AND09-07-3, C/P-AND09-08-1, C/P-AND09-08-2, C/P-AND09-08-3 |
| [AND10](android.md#unicode-runtime-checks) `P[1,2,3]` | C/P-AND-identity |
| [AND11](android.md#minimum-api-device-check-not-run-owner) `P[1,2]; T1.R[1,2,3,4,5].C3` | C/P-AND11-01 |
| [AND12](android.md#assistant-transport-device-checks-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6]` | C/P-AND12-01, C/P-AND12-02 |
| [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | C/P-AND13-01, C/P-AND13-02, C/P-AND13-03, C/P-AND13-04 |
| [AND14](android.md#android-sync-tls-and-device-token-checks-m10-z6-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | C/P-AND14-01, C/P-AND14-02 |
| [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8].C3; T1.R[1,2,3,4,5,6,7,8].C4; T1.R[1,2,3,4,5,6,7,8].C5; T1.R[1,2,3,4,5,6,7,8].C6` | C/P-AND15-01-1, C/P-AND15-01-2, C/P-AND15-01-3, C/P-AND15-01-4, C/P-AND15-02-1, C/P-AND15-02-2, C/P-AND15-02-3, C/P-AND15-02-4, C/P-AND15-03-1, C/P-AND15-03-2, C/P-AND15-03-3, C/P-AND15-03-4, C/P-AND15-04-1, C/P-AND15-04-2, C/P-AND15-04-3, C/P-AND15-04-4, C/P-AND15-05-1, C/P-AND15-05-2, C/P-AND15-05-3, C/P-AND15-05-4, C/P-AND15-06-1, C/P-AND15-06-2, C/P-AND15-06-3, C/P-AND15-06-4, C/P-AND15-07-1, C/P-AND15-07-2, C/P-AND15-07-3, C/P-AND15-07-4, C/P-AND15-08-1, C/P-AND15-08-2, C/P-AND15-08-3, C/P-AND15-08-4, C/P-AND15-01, C/P-AND15-02 |
| [AND16](android.md#m10-z4-private-filesystem-durability-not-run) `P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8].C2` | C/P-AND16-01 |
| [AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | C/P-AND15-01-1, C/P-AND15-01-2, C/P-AND15-01-3, C/P-AND15-01-4, C/P-AND15-02-1, C/P-AND15-02-2, C/P-AND15-02-3, C/P-AND15-02-4, C/P-AND15-03-1, C/P-AND15-03-2, C/P-AND15-03-3, C/P-AND15-03-4, C/P-AND15-04-1, C/P-AND15-04-2, C/P-AND15-04-3, C/P-AND15-04-4, C/P-AND15-05-1, C/P-AND15-05-2, C/P-AND15-05-3, C/P-AND15-05-4, C/P-AND15-06-1, C/P-AND15-06-2, C/P-AND15-06-3, C/P-AND15-06-4, C/P-AND15-07-1, C/P-AND15-07-2, C/P-AND15-07-3, C/P-AND15-07-4, C/P-AND15-08-1, C/P-AND15-08-2, C/P-AND15-08-3, C/P-AND15-08-4 |
| [AND18](android.md#android-assistant-m11-not-run-owner) `P[1]` | C/P-AND-identity |
| [AND19](android.md#assistant-disclosures) `P[1,2,3]` | C/P-AND-identity |
| [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[1,2,3,4,5,6].C3; T2.R[1,2,3,4,5,6].C4` | C/P-AND20-1, C/P-AND20-2, C/P-AND20-3, C/P-AND20-4, C/P-AND20-5, C/P-AND20-6 |
| [AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | C/P-AND20-1, C/P-AND20-2, C/P-AND20-3, C/P-AND20-4, C/P-AND20-5, C/P-AND20-6 |
| [AND22](android.md#android-sync-scheduling-m10-z20-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C2` | C/P-AND22-01, C/P-AND22-02 |
| [AND23](android.md#android-invite-links-m10-z23-not-run) `P[1]; T1.R[1,2,3,4,5,6].C2` | C/P-AND23-01 |
| [AND24](android.md#android-sync-m10-not-run-owner) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T2.R[1,2,3,4,5,6,7,8,9,10].C2` | C/P-AND24-API26-27, C/P-AND24-API28+-StrongBox-capable |
| [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[1,2,3,4].C2; T1.R[1,2,3,4].C3; T1.R[1,2,3,4].C4; T1.R[1,2,3,4].C5` | C/P-AS01-1-MAC-dmg, C/P-AS01-2-MAC-dmg, C/P-AS01-3-X11, C/P-AS01-3-GNOME-W, C/P-AS01-3-KDE-W, C/P-AS01-4-X11, C/P-AS01-4-GNOME-W, C/P-AS01-4-KDE-W |
| [AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | C/P-AS01-1-MAC-dmg, C/P-AS01-2-MAC-dmg, C/P-AS01-3-X11, C/P-AS01-3-GNOME-W, C/P-AS01-3-KDE-W, C/P-AS01-4-X11, C/P-AS01-4-GNOME-W, C/P-AS01-4-KDE-W |
| [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T1.R[1,2,3,4,5,6,7,8].C3` | C/P-AS03-MAC-dmg, C/P-AS03-GNOME-W, C/P-AS03-KDE-W, C/P-AS03-X11 |
| [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | C/P-AS04-01, C/P-AS04-02, C/P-AS04-03, C/P-AS04-04 |
| [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | C/P-AS05-01, C/P-AS05-02, C/P-AS05-03, C/P-AS05-04, C/P-AS05-05, C/P-AS05-06, C/P-AS05-07, C/P-AS05-08 |
| [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | C/P-AS06-01, C/P-AS06-02, C/P-AS06-03, C/P-AS06-04, C/P-AS06-05, C/P-AS06-06, C/P-AS06-07, C/P-AS06-08 |
| [FP01](flatpak.md#flatpak-owner-procedure) `P[1,2]` | C/P-FP01-01, C/P-FP01-02 |
| [FP02](flatpak.md#install-permissions-and-state) `N[1,2,3,4]; T1.R[1,2,3,4,5].C2; T1.R[1,2,3,4,5].C4` | C/P-FP02-FP-GNOME, C/P-FP02-FP-KDE |
| [FP03](flatpak.md#actions-and-invite-staging) `N[1,2,3,4]; T1.R[1,2,3].C2; T1.R[1,2,3].C4` | C/P-FP03-FP-GNOME, C/P-FP03-FP-KDE |
| [FP04](flatpak.md#portals-clipboard-and-settings) `N[1,2,3,4]; T1.R[1,2,3,4].C2; T1.R[1,2,3,4].C4` | C/P-LIN23-FP-GNOME-browser-norm-portal, C/P-LIN23-FP-GNOME-browser-full-portal, C/P-LIN23-FP-GNOME-terminal-norm-portal, C/P-LIN23-FP-GNOME-terminal-full-portal, C/P-LIN23-FP-KDE-browser-norm-portal, C/P-LIN23-FP-KDE-browser-full-portal, C/P-LIN23-FP-KDE-terminal-norm-portal, C/P-LIN23-FP-KDE-terminal-full-portal, C/P-FP04-FP-GNOME, C/P-FP04-FP-KDE |
| [GN01](gnome.md#gnome-portal-owner-checks) `P[1,2,3,4,5,6]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]` | C/P-LIN23-GNOME-W-browser-norm-portal, C/P-LIN23-GNOME-W-browser-norm-ydotool, C/P-LIN23-GNOME-W-browser-full-portal, C/P-LIN23-GNOME-W-browser-full-ydotool, C/P-LIN23-GNOME-W-terminal-norm-portal, C/P-LIN23-GNOME-W-terminal-norm-ydotool, C/P-LIN23-GNOME-W-terminal-full-portal, C/P-LIN23-GNOME-W-terminal-full-ydotool, C/P-GN01-portal, C/P-GN01-native, C/P-GN01-01 |
| [GN02](gnome.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | C/P-LIN23-GNOME-W-browser-norm-portal, C/P-LIN23-GNOME-W-browser-norm-ydotool, C/P-LIN23-GNOME-W-browser-full-portal, C/P-LIN23-GNOME-W-browser-full-ydotool, C/P-LIN23-GNOME-W-terminal-norm-portal, C/P-LIN23-GNOME-W-terminal-norm-ydotool, C/P-LIN23-GNOME-W-terminal-full-portal, C/P-LIN23-GNOME-W-terminal-full-ydotool, C/P-GN02-01, C/P-GN02-02 |
| [KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | C/P-LIN23-KDE-W-browser-norm-ydotool, C/P-LIN23-KDE-W-browser-norm-portal, C/P-LIN23-KDE-W-browser-full-ydotool, C/P-LIN23-KDE-W-browser-full-portal, C/P-LIN23-KDE-W-terminal-norm-ydotool, C/P-LIN23-KDE-W-terminal-norm-portal, C/P-LIN23-KDE-W-terminal-full-ydotool, C/P-LIN23-KDE-W-terminal-full-portal, C/P-KD01-01, C/P-KD01-02 |
| [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5,6]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]` | C/P-KD02-KDE-W-absent, C/P-KD02-KDE-W-v1, C/P-KD02-KDE-W-v2, C/P-KD02-KDE-X11-absent, C/P-KD02-KDE-X11-v1, C/P-KD02-KDE-X11-v2, C/P-KD02-01 |
| [KD03](kde.md#flatpak-tray-and-library-boundary) `P[1,2]; U[1,2,3,4]` | C/P-KD03-01 |
| [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | C/P-LIN23-KDE-W-browser-norm-ydotool, C/P-LIN23-KDE-W-browser-norm-portal, C/P-LIN23-KDE-W-browser-full-ydotool, C/P-LIN23-KDE-W-browser-full-portal, C/P-LIN23-KDE-W-terminal-norm-ydotool, C/P-LIN23-KDE-W-terminal-norm-portal, C/P-LIN23-KDE-W-terminal-full-ydotool, C/P-LIN23-KDE-W-terminal-full-portal, C/P-KD04-01, C/P-KD04-02, C/P-KD04-03 |
| [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | C/P-LIN01-01, C/P-LIN01-02, C/P-LIN01-03 |
| [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | C/P-LIN02-01, C/P-LIN02-02, C/P-LIN02-03, C/P-LIN02-04, C/P-LIN02-05 |
| [LIN03](linux.md#invite-activation-m6-y24-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | C/P-LIN03-01, C/P-LIN03-02 |
| [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | C/P-LIN04-01, C/P-LIN04-02, C/P-LIN04-03 |
| [LIN05](linux.md#secret-storage-m4-a4-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | C/P-LIN05-GNOME-W, C/P-LIN05-KDE-W |
| [LIN06](linux.md#assistant-settings-m4-a14-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | C/P-LIN06-GNOME-W, C/P-LIN06-KDE-W |
| [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | C/P-LIN07-X11-Anthropic, C/P-LIN07-X11-Ollama, C/P-LIN07-GNOME-W-Anthropic, C/P-LIN07-GNOME-W-Ollama, C/P-LIN07-KDE-W-Anthropic, C/P-LIN07-KDE-W-Ollama |
| [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | C/P-LIN08-01, C/P-LIN08-02, C/P-LIN08-03 |
| [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[1,2,3].C3` | C/P-LIN09-1, C/P-LIN09-2, C/P-LIN09-3 |
| [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | C/P-LIN10-01, C/P-LIN10-02, C/P-LIN10-03 |
| [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | C/P-LIN11-01, C/P-LIN11-02, C/P-LIN11-03 |
| [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | C/P-LIN12-01, C/P-LIN12-02, C/P-LIN12-03 |
| [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | C/P-LIN13-01, C/P-LIN13-02, C/P-LIN13-03 |
| [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | C/P-LIN14-01, C/P-LIN14-02, C/P-LIN14-03 |
| [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | C/P-LIN15-01, C/P-LIN15-02, C/P-LIN15-03 |
| [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | C/P-LIN16-01, C/P-LIN16-02, C/P-LIN16-03 |
| [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | C/P-LIN17-01, C/P-LIN17-02, C/P-LIN17-03 |
| [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | C/P-LIN18-01, C/P-LIN18-02, C/P-LIN18-03 |
| [LIN19](linux.md#delivery-plumbing-m1b) `P[1,2]` | C/P-LIN19-01, C/P-LIN19-02 |
| [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | C/P-LIN20-01, C/P-LIN20-02, C/P-LIN20-03 |
| [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | C/P-LIN21-01, C/P-LIN21-02, C/P-LIN21-03, C/P-LIN21-04 |
| [LIN22](linux.md#decisions-and-validation-boundary) `B[7]; P[2]` | C/P-LIN22-01 |
| [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | C/P-LIN23-01, C/P-LIN23-02, C/P-LIN23-03, C/P-LIN23-04, C/P-LIN23-05, C/P-LIN23-X11-browser-norm-xdotool, C/P-LIN23-X11-browser-full-xdotool, C/P-LIN23-X11-terminal-norm-xdotool, C/P-LIN23-X11-terminal-full-xdotool, C/P-LIN23-GNOME-W-browser-norm-portal, C/P-LIN23-GNOME-W-browser-norm-ydotool, C/P-LIN23-GNOME-W-browser-full-portal, C/P-LIN23-GNOME-W-browser-full-ydotool, C/P-LIN23-GNOME-W-terminal-norm-portal, C/P-LIN23-GNOME-W-terminal-norm-ydotool, C/P-LIN23-GNOME-W-terminal-full-portal, C/P-LIN23-GNOME-W-terminal-full-ydotool, C/P-LIN23-KDE-W-browser-norm-ydotool, C/P-LIN23-KDE-W-browser-norm-portal, C/P-LIN23-KDE-W-browser-full-ydotool, C/P-LIN23-KDE-W-browser-full-portal, C/P-LIN23-KDE-W-terminal-norm-ydotool, C/P-LIN23-KDE-W-terminal-norm-portal, C/P-LIN23-KDE-W-terminal-full-ydotool, C/P-LIN23-KDE-W-terminal-full-portal, C/P-LIN23-FP-GNOME-browser-norm-portal, C/P-LIN23-FP-GNOME-browser-full-portal, C/P-LIN23-FP-GNOME-terminal-norm-portal, C/P-LIN23-FP-GNOME-terminal-full-portal, C/P-LIN23-FP-KDE-browser-norm-portal, C/P-LIN23-FP-KDE-browser-full-portal, C/P-LIN23-FP-KDE-terminal-norm-portal, C/P-LIN23-FP-KDE-terminal-full-portal, C/P-ALIAS-X11-1, C/P-ALIAS-X11-2, C/P-ALIAS-X11-3, C/P-ALIAS-X11-4, C/P-ALIAS-X11-5, C/P-ALIAS-X11-6, C/P-ALIAS-X11-7, C/P-ALIAS-X11-8, C/P-ALIAS-X11-fallback-unknown-class, C/P-ALIAS-X11-fallback-lookalike-class, C/P-ALIAS-X11-fallback-missing-class, C/P-ALIAS-X11-fallback-class-query-timeout, C/P-ALIAS-X11-fallback-XTerm, C/P-ALIAS-X11-fallback-URxvt, C/P-ALIAS-X11-fallback-st, C/P-ALIAS-GNOME-X11-1, C/P-ALIAS-GNOME-X11-2, C/P-ALIAS-GNOME-X11-3, C/P-ALIAS-GNOME-X11-4, C/P-ALIAS-GNOME-X11-5, C/P-ALIAS-GNOME-X11-6, C/P-ALIAS-GNOME-X11-7, C/P-ALIAS-GNOME-X11-8, C/P-ALIAS-GNOME-X11-fallback-unknown-class, C/P-ALIAS-GNOME-X11-fallback-lookalike-class, C/P-ALIAS-GNOME-X11-fallback-missing-class, C/P-ALIAS-GNOME-X11-fallback-class-query-timeout, C/P-ALIAS-GNOME-X11-fallback-XTerm, C/P-ALIAS-GNOME-X11-fallback-URxvt, C/P-ALIAS-GNOME-X11-fallback-st, C/P-ALIAS-KDE-X11-1, C/P-ALIAS-KDE-X11-2, C/P-ALIAS-KDE-X11-3, C/P-ALIAS-KDE-X11-4, C/P-ALIAS-KDE-X11-5, C/P-ALIAS-KDE-X11-6, C/P-ALIAS-KDE-X11-7, C/P-ALIAS-KDE-X11-8, C/P-ALIAS-KDE-X11-fallback-unknown-class, C/P-ALIAS-KDE-X11-fallback-lookalike-class, C/P-ALIAS-KDE-X11-fallback-missing-class, C/P-ALIAS-KDE-X11-fallback-class-query-timeout, C/P-ALIAS-KDE-X11-fallback-XTerm, C/P-ALIAS-KDE-X11-fallback-URxvt, C/P-ALIAS-KDE-X11-fallback-st |
| [AC201](m2-acceptance.md#m2-daily-use-acceptance) `B[1,2,3,4]; P[1,2,4]; T1.R[5]; T3.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | C/P-AC201-01, C/P-AC201-02 |
| [AC301](m3-acceptance.md#m3-library-window-acceptance) `B[1,2]; P[1,2,4]; T2.R[1,2,3,4,5,6,7].C2` | C/P-AC301-01, C/P-AC301-02 |
| [AC401](m4-acceptance.md#m4-assistant-acceptance) `B[1,2,3]; P[1,5,7]; T1.R[5,6]; T4.R[1,2,3,4,5,6,7,8,9].C2` | C/P-AC401-01, C/P-AC401-02 |
| [AC501](m5-acceptance.md#m5-server-acceptance) `B[1,2,3]; P[1,7,9]; T1.R[1,4,5]; T4.R[7,39]; T5.R[1,2,3,4,5,6].C2` | C/P-AC501-01 |
| [AC701](m7-acceptance.md#m7-acceptance-ledger) `P[1,2]` | C/P-AC701-01 |
| [AC702](m7-acceptance.md#recording-a-run) `P[1,2,3]` | C/P-AC702-01 |
| [AC703](m7-acceptance.md#owner-prerequisites) `P[1]; T1.R[1,2,3,4,5,6,7].C2` | C/P-AC703-01, P-AC703-published |
| [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32].C2` | C/P-AC704-01, C/P-AC704-02, C/P-AC704-03, C/P-AC704-04, C/P-AC704-05, C/P-AC704-06, C/P-AC704-07 |
| [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1,2,3,4,5,6,7,8].C2` | C/P-ALIAS-X11-1, C/P-ALIAS-X11-2, C/P-ALIAS-X11-3, C/P-ALIAS-X11-4, C/P-ALIAS-X11-5, C/P-ALIAS-X11-6, C/P-ALIAS-X11-7, C/P-ALIAS-X11-8, C/P-ALIAS-X11-fallback-unknown-class, C/P-ALIAS-X11-fallback-lookalike-class, C/P-ALIAS-X11-fallback-missing-class, C/P-ALIAS-X11-fallback-class-query-timeout, C/P-ALIAS-X11-fallback-XTerm, C/P-ALIAS-X11-fallback-URxvt, C/P-ALIAS-X11-fallback-st, C/P-ALIAS-GNOME-X11-1, C/P-ALIAS-GNOME-X11-2, C/P-ALIAS-GNOME-X11-3, C/P-ALIAS-GNOME-X11-4, C/P-ALIAS-GNOME-X11-5, C/P-ALIAS-GNOME-X11-6, C/P-ALIAS-GNOME-X11-7, C/P-ALIAS-GNOME-X11-8, C/P-ALIAS-GNOME-X11-fallback-unknown-class, C/P-ALIAS-GNOME-X11-fallback-lookalike-class, C/P-ALIAS-GNOME-X11-fallback-missing-class, C/P-ALIAS-GNOME-X11-fallback-class-query-timeout, C/P-ALIAS-GNOME-X11-fallback-XTerm, C/P-ALIAS-GNOME-X11-fallback-URxvt, C/P-ALIAS-GNOME-X11-fallback-st, C/P-ALIAS-KDE-X11-1, C/P-ALIAS-KDE-X11-2, C/P-ALIAS-KDE-X11-3, C/P-ALIAS-KDE-X11-4, C/P-ALIAS-KDE-X11-5, C/P-ALIAS-KDE-X11-6, C/P-ALIAS-KDE-X11-7, C/P-ALIAS-KDE-X11-8, C/P-ALIAS-KDE-X11-fallback-unknown-class, C/P-ALIAS-KDE-X11-fallback-lookalike-class, C/P-ALIAS-KDE-X11-fallback-missing-class, C/P-ALIAS-KDE-X11-fallback-class-query-timeout, C/P-ALIAS-KDE-X11-fallback-XTerm, C/P-ALIAS-KDE-X11-fallback-URxvt, C/P-ALIAS-KDE-X11-fallback-st |
| [AC706](m7-acceptance.md#procedure-ownership-and-remaining-work) `B[1,2,3]` | C/P-AC706-01 |
| [MAC01](macos.md#macos-delivery-acceptance) `B[1,2,3,4,5,6,7]; P[1,2,3]` | C/P-MAC01-01, C/P-MAC01-02 |
| [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[1,2].C2` | C/P-MAC02-MAC-dmg-CGEvent, C/P-MAC02-MAC-dmg-AppleScript, C/P-MAC02-MAC-zip-CGEvent, C/P-MAC02-MAC-zip-AppleScript |
| [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1,2,3].C2; T1.R[1,2,3].C3` | C/P-MAC03-MAC-dmg-1-2, C/P-MAC03-MAC-dmg-1-3, C/P-MAC03-MAC-dmg-2-2, C/P-MAC03-MAC-dmg-2-3, C/P-MAC03-MAC-dmg-3-2, C/P-MAC03-MAC-dmg-3-3, C/P-MAC03-MAC-zip-1-2, C/P-MAC03-MAC-zip-1-3, C/P-MAC03-MAC-zip-2-2, C/P-MAC03-MAC-zip-2-3, C/P-MAC03-MAC-zip-3-2, C/P-MAC03-MAC-zip-3-3 |
| [MAC04](macos.md#implementation-notes-and-remaining-gates) `B[5,6]` | C/P-MAC04-01, C/P-MAC04-02 |
| [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1,2,3].C2; T1.R[1,2,3].C3` | C/P-MAC05-MAC-dmg-1-2, C/P-MAC05-MAC-dmg-1-3, C/P-MAC05-MAC-dmg-2-2, C/P-MAC05-MAC-dmg-2-3, C/P-MAC05-MAC-dmg-3-2, C/P-MAC05-MAC-dmg-3-3, C/P-MAC05-MAC-zip-1-2, C/P-MAC05-MAC-zip-1-3, C/P-MAC05-MAC-zip-2-2, C/P-MAC05-MAC-zip-2-3, C/P-MAC05-MAC-zip-3-2, C/P-MAC05-MAC-zip-3-3 |
| [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `B[1,2,3,4]; N[1,2,3,4,5]; P[1]; U[1,2,3,4,5,6,7,8]` | C/P-MAC06-01, C/P-MAC06-02, C/P-MAC06-03, C/P-MAC06-04 |
| [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | C/P-MAC07-01, C/P-MAC07-02, C/P-MAC07-03, C/P-MAC07-04 |
| [MAC08](macos.md#m2-forget-values-controls-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | C/P-MAC08-01, C/P-MAC08-02 |
| [MAC09](macos.md#m2-onboarding-and-library-recovery-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21].C2` | C/P-MAC09-01, C/P-MAC09-02 |
| [MAC10](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C2` | C/P-MAC10-01, C/P-MAC10-02 |
| [MAC11](macos.md#m2-input-method-composition-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C2` | C/P-MAC11-01, C/P-MAC11-02 |
| [MAC12](macos.md#m2-conditional-clipboard-privacy-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C2` | C/P-MAC12-01, C/P-MAC12-02 |
| [MAC13](macos.md#m3-m1-library-window-shell-not-run) `B[1,2,3,4]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2` | C/P-MAC13-01, C/P-MAC13-02 |
| [MAC14](macos.md#m3-m2-library-editor-tabs-not-run) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20].C2` | C/P-MAC14-01, C/P-MAC14-02 |
| [MAC15](macos.md#m3-macos-history-and-file-commands-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17].C2` | C/P-MAC15-01, C/P-MAC15-02 |
| [MAC16](macos.md#m6-y20-account-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2].C2` | C/P-MAC16-01, C/P-MAC16-02 |
| [MAC17](macos.md#m4-a3-keychain-secrets-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4].C2` | C/P-MAC17-01, C/P-MAC17-02 |
| [MAC18](macos.md#m3-m4-library-import-not-run) `B[1,2,3]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | C/P-MAC18-01, C/P-MAC18-02 |
| [MAC19](macos.md#m4-a13-assistant-settings-not-run) `B[1,2,3,4]; P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13].C2` | C/P-MAC19-01, C/P-MAC19-02 |
| [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | C/P-MAC20-MAC-dmg-Anthropic, C/P-MAC20-MAC-dmg-Ollama, C/P-MAC20-MAC-zip-Anthropic, C/P-MAC20-MAC-zip-Ollama |
| [MAC21](macos.md#m7-d17-delivery-and-update-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4,5,6,7].C2` | C/P-MAC21-01, C/P-MAC21-02 |
| [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | C/P-MAC22-MAC-dmg-Safari-norm-CGEvent, C/P-MAC22-MAC-dmg-Safari-norm-AppleScript, C/P-MAC22-MAC-dmg-Safari-full-CGEvent, C/P-MAC22-MAC-dmg-Safari-full-AppleScript, C/P-MAC22-MAC-dmg-Chrome-norm-CGEvent, C/P-MAC22-MAC-dmg-Chrome-norm-AppleScript, C/P-MAC22-MAC-dmg-Chrome-full-CGEvent, C/P-MAC22-MAC-dmg-Chrome-full-AppleScript, C/P-MAC22-MAC-dmg-Terminal-norm-CGEvent, C/P-MAC22-MAC-dmg-Terminal-norm-AppleScript, C/P-MAC22-MAC-dmg-Terminal-full-CGEvent, C/P-MAC22-MAC-dmg-Terminal-full-AppleScript, C/P-MAC22-MAC-zip-Safari-norm-CGEvent, C/P-MAC22-MAC-zip-Safari-norm-AppleScript, C/P-MAC22-MAC-zip-Safari-full-CGEvent, C/P-MAC22-MAC-zip-Safari-full-AppleScript, C/P-MAC22-MAC-zip-Chrome-norm-CGEvent, C/P-MAC22-MAC-zip-Chrome-norm-AppleScript, C/P-MAC22-MAC-zip-Chrome-full-CGEvent, C/P-MAC22-MAC-zip-Chrome-full-AppleScript, C/P-MAC22-MAC-zip-Terminal-norm-CGEvent, C/P-MAC22-MAC-zip-Terminal-norm-AppleScript, C/P-MAC22-MAC-zip-Terminal-full-CGEvent, C/P-MAC22-MAC-zip-Terminal-full-AppleScript |
| [MAC23](macos.md#m6-y23-invite-activation-not-run) `P[1,2]; T1.R[1,2,3,4,5].C2` | C/P-MAC23-01, C/P-MAC23-02 |
| [SRV01](server.md#server-deployment-acceptance) `B[1,2,3,4,5]; P[1]` | C/P-SRV01-01 |
| [SRV02](server.md#fresh-host-via-updatesh-not-run) `N[1,2,3,4,5]; P[1]` | C/P-SRV02-01 |
| [SRV03](server.md#real-domain-https-and-two-update-re-runs-not-run) `N[1,2,3,4,5]` | C/P-SRV03-01 |
| [SRV04](server.md#backuprestore-drill-not-run) `N[1,2,3,4]; P[1]` | C/P-SRV04-01 |
| [SRV05](server.md#desktop-login-push-and-pull-after-m6-not-run) `N[1,2,3,4]` | C/P-SRV05-01, C/P-SRV05-02 |
| [SRV06](server.md#client-filenames-after-m6-not-run) `P[1]; T1.R[1,2].C2` | C/P-SRV06-01, C/P-SRV06-02 |
| [SRV07](server.md#host-the-sync-server) `P[1,2,3,4,5,6,7,8,9,10,11,12,13]` | C/P-SRV07-01 |
| [SRV08](server.md#server-backup-and-restore) `P[1,2,3,4]` | C/P-SRV08-01 |
| [SYNC01](sync.md#desktop-sync-setup-and-verification) `P[1]` | C/P-SYNC01-01, C/P-SYNC01-02 |
| [SYNC02](sync.md#set-up-a-disposable-verification-pair) `N[1,2,3,4,5,6,7]; P[1,2]` | C/P-SYNC02-01, C/P-SYNC02-02 |
| [SYNC03](sync.md#scenario-inventory-and-execution-owners) | No pending owner obligation: Automated corpus inventory and revision-bound receipts; physical work is in the owner ledger. |
| [SYNC04](sync.md#finite-native-privacy-proof) | No pending owner obligation: Revision-bound automated privacy proof and its limits; real native checks are in the owner ledger. |
| [SYNC05](sync.md#required-owner-acceptance-ledger) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C1` | C/P-SYNC05-01, C/P-SYNC05-02 |

## Candidate phase before tagging

Jump to [macOS](#c-macos), [Linux native](#c-linux-native), [Linux
delivery](#c-linux-delivery), [GNOME and KDE](#c-gnome-and-kde),
[Flatpak](#c-flatpak), [Desktop assistant](#c-desktop-assistant), [Server and
desktop sync](#c-server-and-desktop-sync), [Android
prerequisites](#c-android-prerequisites), [Android local
library](#c-android-local-library), [Android native sync and
storage](#c-android-native-sync-and-storage), [Android entry and
IME](#c-android-entry-and-ime), [Android selection and
share](#c-android-selection-and-share), [Android
assistant](#c-android-assistant), [Android connected
sync](#c-android-connected-sync), [Milestone
reconciliation](#c-milestone-reconciliation).

Record candidate origin and exact main/artifact identity in every row.
The historical v0.1.0 keys remain gated by D-HISTORY; no version substitution
is authorized here. Candidate results alone never authorize milestone closure.

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-BASE | [M12](../plan/15-milestones.md#15-milestones); [release contract](../../CICD.md#ci-and-releases) | Exact reviewed final main / candidate artifacts | NOT RUN | Full same-commit CI/review and dry_run=true, dated approved R1 notes/version/code, nine files/four manifests and both native image architectures | NOT RUN | NOT RUN | NOT RUN |
| C-BUILD-LINUX | [R4 orchestration](../plan/14-repository-packaging-ci-release.md#14-repository-packaging-ci-release) | Equipped Linux host / committed version | NOT RUN | Default and named build.sh targets per source; deb reused once for Flatpak, dist files, default-platform image-store output and VERSION/REVISION/CREATED; unavailable default skips and named failures visible | NOT RUN | NOT RUN | NOT RUN |
| C-BUILD-MAC | [R4 orchestration](../plan/14-repository-packaging-ci-release.md#14-repository-packaging-ci-release) | Equipped macOS host / reachable Linux Docker engine | NOT RUN | Every feasible default artifact and named availability behavior per source, --no-open, image-store provenance and Summary; no registry push | NOT RUN | NOT RUN | NOT RUN |

### C macOS

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-MAC01-01 | [MAC01](macos.md#macos-delivery-acceptance) `B[1,2,3,4,5,6,7]; P[1,2,3]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC01-02 | [MAC01](macos.md#macos-delivery-acceptance) `B[1,2,3,4,5,6,7]; P[1,2,3]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC04-01 | [MAC04](macos.md#implementation-notes-and-remaining-gates) `B[5,6]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC04-02 | [MAC04](macos.md#implementation-notes-and-remaining-gates) `B[5,6]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC06-01 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `B[1,2,3,4]; N[1,2,3,4,5]; P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC06-02 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `B[1,2,3,4]; N[1,2,3,4,5]; P[1]; U[1,2,3,4,5,6,7]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC07-01 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC07-02 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC08-01 | [MAC08](macos.md#m2-forget-values-controls-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC08-02 | [MAC08](macos.md#m2-forget-values-controls-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC09-01 | [MAC09](macos.md#m2-onboarding-and-library-recovery-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC09-02 | [MAC09](macos.md#m2-onboarding-and-library-recovery-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC10-01 | [MAC10](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC10-02 | [MAC10](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC11-01 | [MAC11](macos.md#m2-input-method-composition-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC11-02 | [MAC11](macos.md#m2-input-method-composition-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC12-01 | [MAC12](macos.md#m2-conditional-clipboard-privacy-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC12-02 | [MAC12](macos.md#m2-conditional-clipboard-privacy-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC13-01 | [MAC13](macos.md#m3-m1-library-window-shell-not-run) `B[1,2,3,4]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC13-02 | [MAC13](macos.md#m3-m1-library-window-shell-not-run) `B[1,2,3,4]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC14-01 | [MAC14](macos.md#m3-m2-library-editor-tabs-not-run) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC14-02 | [MAC14](macos.md#m3-m2-library-editor-tabs-not-run) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC15-01 | [MAC15](macos.md#m3-macos-history-and-file-commands-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC15-02 | [MAC15](macos.md#m3-macos-history-and-file-commands-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC16-01 | [MAC16](macos.md#m6-y20-account-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC16-02 | [MAC16](macos.md#m6-y20-account-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC17-01 | [MAC17](macos.md#m4-a3-keychain-secrets-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC17-02 | [MAC17](macos.md#m4-a3-keychain-secrets-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC18-01 | [MAC18](macos.md#m3-m4-library-import-not-run) `B[1,2,3]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC18-02 | [MAC18](macos.md#m3-m4-library-import-not-run) `B[1,2,3]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC19-01 | [MAC19](macos.md#m4-a13-assistant-settings-not-run) `B[1,2,3,4]; P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC19-02 | [MAC19](macos.md#m4-a13-assistant-settings-not-run) `B[1,2,3,4]; P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC21-01 | [MAC21](macos.md#m7-d17-delivery-and-update-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC21-02 | [MAC21](macos.md#m7-d17-delivery-and-update-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC23-01 | [MAC23](macos.md#m6-y23-invite-activation-not-run) `P[1,2]; T1.R[1,2,3,4,5].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC23-02 | [MAC23](macos.md#m6-y23-invite-activation-not-run) `P[1,2]; T1.R[1,2,3,4,5].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC06-03 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `U[8]` | MAC-dmg / Intel x86_64 (optional) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC06-04 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `U[8]` | MAC-zip / Intel x86_64 (optional) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC07-03 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `T1.R[9].C2` | MAC-dmg / non-US physical layout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC07-04 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `T1.R[9].C2` | MAC-zip / non-US physical layout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC02-MAC-dmg-CGEvent | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[1].C2` | MAC-dmg / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC02-MAC-dmg-AppleScript | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[2].C2` | MAC-dmg / AppleScript | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC02-MAC-zip-CGEvent | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[1].C2` | MAC-zip / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC02-MAC-zip-AppleScript | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[2].C2` | MAC-zip / AppleScript | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-1-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C2` | MAC-dmg / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-1-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C3` | MAC-dmg / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-2-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C2` | MAC-dmg / Chrome / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-2-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C3` | MAC-dmg / Chrome / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-3-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C2` | MAC-dmg / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-dmg-3-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C3` | MAC-dmg / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-1-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C2` | MAC-zip / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-1-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C3` | MAC-zip / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-2-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C2` | MAC-zip / Chrome / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-2-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C3` | MAC-zip / Chrome / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-3-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C2` | MAC-zip / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC03-MAC-zip-3-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C3` | MAC-zip / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-1-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C2` | MAC-dmg / TextEdit / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-1-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C3` | MAC-dmg / TextEdit / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-2-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C2` | MAC-dmg / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-2-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C3` | MAC-dmg / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-3-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C2` | MAC-dmg / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-dmg-3-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C3` | MAC-dmg / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-1-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C2` | MAC-zip / TextEdit / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-1-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C3` | MAC-zip / TextEdit / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-2-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C2` | MAC-zip / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-2-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C3` | MAC-zip / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-3-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C2` | MAC-zip / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC05-MAC-zip-3-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C3` | MAC-zip / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC20-MAC-dmg-Anthropic | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C2` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC20-MAC-dmg-Ollama | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Safari-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Safari-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Safari-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Safari-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Chrome-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Chrome-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Chrome-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Chrome-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Terminal-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Terminal-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Terminal-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-dmg-Terminal-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC20-MAC-zip-Anthropic | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C2` | MAC-zip / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC20-MAC-zip-Ollama | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | MAC-zip / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Safari-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Safari-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Safari-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Safari-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Chrome-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Chrome-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Chrome-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Chrome-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Terminal-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Terminal-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Terminal-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-MAC22-MAC-zip-Terminal-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Linux native

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-LIN01-01 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN01-02 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN01-03 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN04-01 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN04-02 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN04-03 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN10-01 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN10-02 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN10-03 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN11-01 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN11-02 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN11-03 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,11].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN12-01 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN12-02 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN12-03 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN13-01 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN13-02 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN13-03 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN14-01 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN14-02 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN14-03 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN15-01 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN15-02 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN15-03 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN16-01 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN16-02 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN16-03 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN17-01 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | X11 / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN17-02 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | GNOME-W / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN17-03 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | KDE-W / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN18-01 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN18-02 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN18-03 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN03-01 | [LIN03](linux.md#invite-activation-m6-y24-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | GNOME-W / browser and launcher | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN03-02 | [LIN03](linux.md#invite-activation-m6-y24-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | KDE-W / browser and launcher | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN05-GNOME-W | [LIN05](linux.md#secret-storage-m4-a4-not-run) `B[1,2]; P[1]; T1.R[1,3,4,5,6,7,8,9].C3` | GNOME-W / GNOME Keyring | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN05-KDE-W | [LIN05](linux.md#secret-storage-m4-a4-not-run) `B[1,2]; P[1]; T1.R[2,3,4,5,6,7,8,9].C3` | KDE-W / KWallet Secret Service | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN06-GNOME-W | [LIN06](linux.md#assistant-settings-m4-a14-not-run) `P[1]; T1.R[1,3,4,5,6].C3` | GNOME-W / GNOME Keyring | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN06-KDE-W | [LIN06](linux.md#assistant-settings-m4-a14-not-run) `P[1]; T1.R[2,3,4,5,6].C3` | KDE-W / KWallet Secret Service | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-X11-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-X11-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-GNOME-W-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-GNOME-W-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-KDE-W-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN07-KDE-W-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN08-01 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | X11 / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN08-02 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | GNOME-W / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN08-03 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | KDE-W / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN09-1 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[1].C3` | KDE-W / tray | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN09-2 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[2].C3` | GNOME-W / AppIndicator | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN09-3 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[3].C3` | GNOME-W / no tray | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Linux delivery

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-LIN02-01 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN02-02 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN02-03 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN02-04 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN02-05 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-01 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-02 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-03 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-04 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-05 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN19-01 | [LIN19](linux.md#delivery-plumbing-m1b) `P[1,2]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN19-02 | [LIN19](linux.md#delivery-plumbing-m1b) `P[1,2]` | wlroots-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN20-01 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN20-02 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | GNOME-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN20-03 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN21-01 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool current dialect / browser | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN21-02 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool current dialect / terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN21-03 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool 0.1.8 dialect / browser | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN21-04 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool 0.1.8 dialect / terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN22-01 | [LIN22](linux.md#decisions-and-validation-boundary) `B[7]; P[2]` | X11 / wlroots-W contract reconciliation | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-X11-browser-norm-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / browser/chat / normal / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-X11-browser-full-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / browser/chat / full-screen / multiple monitors / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-X11-terminal-norm-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / terminal / normal / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-X11-terminal-full-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / terminal / full-screen / multiple monitors / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-browser-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-browser-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-terminal-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-GNOME-W-terminal-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-browser-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-browser-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-terminal-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-terminal-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-KDE-W-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-GNOME-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-GNOME-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-GNOME-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-GNOME-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-KDE-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-KDE-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-KDE-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-LIN23-FP-KDE-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-GNOME-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-ALIAS-KDE-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C GNOME and KDE

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-GN01-portal | [GN01](gnome.md#gnome-portal-owner-checks) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | GNOME-W / native portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-GN01-native | [GN01](gnome.md#gnome-portal-owner-checks) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | GNOME-W / native no-GlobalShortcuts | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-GN02-01 | [GN02](gnome.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5].C3` | GNOME-W / native | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD01-01 | [KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD01-02 | [KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-W-absent | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[1,12,14,15,16]` | KDE-W / portal absent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-W-v1 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,7,9,10,11,12,13,14,15,16]` | KDE-W / GlobalShortcuts v1 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-W-v2 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,8,9,10,11,12,13,14,15,16]` | KDE-W / GlobalShortcuts v2 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-X11-absent | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[1,12,14,15,16]` | KDE-X11 / portal absent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-X11-v1 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,7,9,10,11,12,13,14,15,16]` | KDE-X11 / GlobalShortcuts v1 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-KDE-X11-v2 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,8,9,10,11,12,13,14,15,16]` | KDE-X11 / GlobalShortcuts v2 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD04-01 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD04-02 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD04-03 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Flatpak

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-GN01-01 | [GN01](gnome.md#gnome-portal-owner-checks) `P[5,6]; U[11,12,13,14,15,16,17]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-GN02-02 | [GN02](gnome.md#m7-current-desktop-procedures) `P[1,2]; T1.R[6].C3` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD02-01 | [KD02](kde.md#portalnative-transition-matrix) `U[6]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-KD03-01 | [KD03](kde.md#flatpak-tray-and-library-boundary) `P[1,2]; U[1,2,3,4]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP01-01 | [FP01](flatpak.md#flatpak-owner-procedure) `P[1,2]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP01-02 | [FP01](flatpak.md#flatpak-owner-procedure) `P[1,2]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP02-FP-GNOME | [FP02](flatpak.md#install-permissions-and-state) `N[1,2,3,4]; T1.R[1,2,3,4,5].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP02-FP-KDE | [FP02](flatpak.md#install-permissions-and-state) `N[1,2,3,4]; T1.R[1,2,3,4,5].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP03-FP-GNOME | [FP03](flatpak.md#actions-and-invite-staging) `N[1,2,3,4]; T1.R[1,2,3].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP03-FP-KDE | [FP03](flatpak.md#actions-and-invite-staging) `N[1,2,3,4]; T1.R[1,2,3].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP04-FP-GNOME | [FP04](flatpak.md#portals-clipboard-and-settings) `N[1,2,3,4]; T1.R[1,2,3,4].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-FP04-FP-KDE | [FP04](flatpak.md#portals-clipboard-and-settings) `N[1,2,3,4]; T1.R[1,2,3,4].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Desktop assistant

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AS01-1-MAC-dmg | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[1].C2; T1.R[1].C3; T1.R[1].C4; T1.R[1].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-2-MAC-dmg | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[2].C2; T1.R[2].C3; T1.R[2].C4; T1.R[2].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-3-X11 | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | X11 / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-3-GNOME-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | GNOME-W / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-3-KDE-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | KDE-W / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-4-X11 | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | X11 / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-4-GNOME-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | GNOME-W / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS01-4-KDE-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | KDE-W / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS03-MAC-dmg | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS03-GNOME-W | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS03-KDE-W | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS03-X11 | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS04-01 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | MAC-dmg / Keychain / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS04-02 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | GNOME-W / Secret Service / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS04-03 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | KDE-W / KWallet Secret Service / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS04-04 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | X11 / file tier and environment override / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-01 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-02 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-03 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-04 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-05 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-06 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-07 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS05-08 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-01 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-02 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-03 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-04 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-05 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-06 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-07 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AS06-08 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Server and desktop sync

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-SRV01-01 | [SRV01](server.md#server-deployment-acceptance) `B[1,2,3,4,5]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV02-01 | [SRV02](server.md#fresh-host-via-updatesh-not-run) `N[1,2,3,4,5]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV03-01 | [SRV03](server.md#real-domain-https-and-two-update-re-runs-not-run) `N[1,2,3,4,5]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV04-01 | [SRV04](server.md#backuprestore-drill-not-run) `N[1,2,3,4]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV07-01 | [SRV07](server.md#host-the-sync-server) `P[1,2,3,4,5,6,7,8,9,10,11,12,13]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV08-01 | [SRV08](server.md#server-backup-and-restore) `P[1,2,3,4]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV05-01 | [SRV05](server.md#desktop-login-push-and-pull-after-m6-not-run) `N[1,2,3,4]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV05-02 | [SRV05](server.md#desktop-login-push-and-pull-after-m6-not-run) `N[1,2,3,4]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV06-01 | [SRV06](server.md#client-filenames-after-m6-not-run) `P[1]; T1.R[1,2].C2` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SRV06-02 | [SRV06](server.md#client-filenames-after-m6-not-run) `P[1]; T1.R[1,2].C2` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC01-01 | [SYNC01](sync.md#desktop-sync-setup-and-verification) `P[1]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC01-02 | [SYNC01](sync.md#desktop-sync-setup-and-verification) `P[1]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC02-01 | [SYNC02](sync.md#set-up-a-disposable-verification-pair) `N[1,2,3,4,5,6,7]; P[1,2]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC02-02 | [SYNC02](sync.md#set-up-a-disposable-verification-pair) `N[1,2,3,4,5,6,7]; P[1,2]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC05-01 | [SYNC05](sync.md#required-owner-acceptance-ledger) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C1` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-SYNC05-02 | [SYNC05](sync.md#required-owner-acceptance-ledger) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C1` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android prerequisites

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND-identity | [AND01](android.md#android-acceptance) `P[1]`<br>[AND02](android.md#m8-acceptance-record) `P[1]`<br>[AND10](android.md#unicode-runtime-checks) `P[1,2,3]`<br>[AND18](android.md#android-assistant-m11-not-run-owner) `P[1]`<br>[AND19](android.md#assistant-disclosures) `P[1,2,3]` | Final signed minified APK / source prerequisites | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND04-01 | [AND04](android.md#release-apk-verification) `P[1,2,3,4,5,6]; T1.R[2,3,4].C2` | API 26–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND04-02 | [AND04](android.md#release-apk-verification) `P[1,2,3,4,5,6]; T1.R[2,3,4].C2` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND11-01 | [AND11](android.md#minimum-api-device-check-not-run-owner) `P[1,2]; T1.R[1,2,3,4,5].C3` | API 26 minimum / production validator caller | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android local library

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND07-01 | [AND07](android.md#m8-seeds-library-and-editorhistory-not-run-owner) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C2` | API 26–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND07-02 | [AND07](android.md#m8-seeds-library-and-editorhistory-not-run-owner) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C2` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android native sync and storage

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND12-01 | [AND12](android.md#assistant-transport-device-checks-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6]` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND12-02 | [AND12](android.md#assistant-transport-device-checks-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6]` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND14-01 | [AND14](android.md#android-sync-tls-and-device-token-checks-m10-z6-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND14-02 | [AND14](android.md#android-sync-tls-and-device-token-checks-m10-z6-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND13-01 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND13-02 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 28–30 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND13-03 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 31–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND13-04 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 34+ StrongBox | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND16-01 | [AND16](android.md#m10-z4-private-filesystem-durability-not-run) `P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8].C2` | Physical private-library/state filesystem / record actual API | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND22-01 | [AND22](android.md#android-sync-scheduling-m10-z20-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C2` | API 26–30 ordinary work | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND22-02 | [AND22](android.md#android-sync-scheduling-m10-z20-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C2` | API 31+ expedited/quota fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND23-01 | [AND23](android.md#android-invite-links-m10-z23-not-run) `P[1]; T1.R[1,2,3,4,5,6].C2` | Actual phone / cold, foreground, background / record API | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android entry and IME

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND05-01 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C2` | API 34 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-01-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-01-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-01-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-01-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-01-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-01-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-01-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-01-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-02 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C2` | API 34 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-02-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-02-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-02-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-02-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-02-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-02-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-02-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-02-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-03 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C3` | API 35 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-03-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-03-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-03-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-03-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-03-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-03-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-03-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-03-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-04 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C3` | API 35 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-04-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-04-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-04-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-04-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-04-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-04-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-04-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-04-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-05 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C4` | API 36 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-05-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-05-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-05-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-05-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-05-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-05-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-05-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-05-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-06 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C4` | API 36 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-06-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-06-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-06-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-06-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-06-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-06-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-06-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-06-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-07 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C5` | below34 (26/27 preferred) / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-07-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-07-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-07-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-07-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-07-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-07-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-07-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-07-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-08 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C5` | below34 (26/27 preferred) / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-08-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-08-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-08-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-08-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-08-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-08-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-08-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-08-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-09 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 26/32 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-10 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 33 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-01 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[5]` | API 26/27 legacy window token / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-11 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 26/32 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND05-12 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 33 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND15-02 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[5]` | API 26/27 legacy window token / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-01 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3` | API 26 minimum / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND06-02 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3` | API 37 target coverage (when available) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android selection and share

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND08-01-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-01-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-01-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-01-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-01-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-01-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-01-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-02-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-02-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-02-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-02-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-02-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-02-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-02-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-03-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-03-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-03-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-03-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-03-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-03-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-03-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-04-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-04-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-04-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-04-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-04-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-04-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-04-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-05-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-05-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-05-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-05-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-05-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-05-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-05-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-06-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-06-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-06-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-06-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-06-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-06-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-06-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-07-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-07-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-07-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-07-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-07-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-07-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-07-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-08-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-08-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-08-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND08-08-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-08-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-08-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND09-08-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android assistant

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND20-1 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Write | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND20-2 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Review | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND20-3 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND20-4 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Write | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND20-5 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[5].C3; T2.R[5].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Review | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND20-6 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[6].C3; T2.R[6].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Android connected sync

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AND24-API26-27 | [AND24](android.md#android-sync-m10-not-run-owner) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T2.R[1,2,3,4,5,6,7,8,9,10].C2` | API 26/27 / phone and desktop / two users | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AND24-API28+-StrongBox-capable | [AND24](android.md#android-sync-m10-not-run-owner) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T2.R[1,2,3,4,5,6,7,8,9,10].C2` | API 28+ StrongBox-capable / phone and desktop / two users | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### C Milestone reconciliation

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| C-AC201-01 | [AC201](m2-acceptance.md#m2-daily-use-acceptance) `B[1,2,3,4]; P[1,2,4]; T1.R[5]; T3.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC201-02 | [AC201](m2-acceptance.md#m2-daily-use-acceptance) `B[1,2,3,4]; P[1,2,4]; T1.R[5]; T3.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC301-01 | [AC301](m3-acceptance.md#m3-library-window-acceptance) `B[1,2]; P[1,2,4]; T2.R[1,2,3,4,5,6,7].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC301-02 | [AC301](m3-acceptance.md#m3-library-window-acceptance) `B[1,2]; P[1,2,4]; T2.R[1,2,3,4,5,6,7].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC401-01 | [AC401](m4-acceptance.md#m4-assistant-acceptance) `B[1,2,3]; P[1,5,7]; T1.R[5,6]; T4.R[1,2,3,4,5,6,7,8,9].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC401-02 | [AC401](m4-acceptance.md#m4-assistant-acceptance) `B[1,2,3]; P[1,5,7]; T1.R[5,6]; T4.R[1,2,3,4,5,6,7,8,9].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC501-01 | [AC501](m5-acceptance.md#m5-server-acceptance) `B[1,2,3]; P[1,7,9]; T1.R[1,4,5]; T4.R[7,39]; T5.R[1,2,3,4,5,6].C2` | Deployed Docker / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC701-01 | [AC701](m7-acceptance.md#m7-acceptance-ledger) `P[1,2]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC702-01 | [AC702](m7-acceptance.md#recording-a-run) `P[1,2,3]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC706-01 | [AC706](m7-acceptance.md#procedure-ownership-and-remaining-work) `B[1,2,3]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC703-01 | [AC703](m7-acceptance.md#owner-prerequisites) `P[1]; T1.R[1,2,3,4,5,6].C2` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-01 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-02 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-03 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[8,9,10,11,12].C2` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-04 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[13,14,15,16,17].C2` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-05 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[18,19,20,21,22].C2` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-06 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[23,24,25,26,27].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| C-AC704-07 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[28,29,30,31,32].C2` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

## Post-publication phase from actual v1.0.0

Jump to [macOS](#p-macos), [Linux native](#p-linux-native), [Linux
delivery](#p-linux-delivery), [GNOME and KDE](#p-gnome-and-kde),
[Flatpak](#p-flatpak), [Desktop assistant](#p-desktop-assistant), [Server and
desktop sync](#p-server-and-desktop-sync), [Android
prerequisites](#p-android-prerequisites), [Android local
library](#p-android-local-library), [Android native sync and
storage](#p-android-native-sync-and-storage), [Android entry and
IME](#p-android-entry-and-ime), [Android selection and
share](#p-android-selection-and-share), [Android
assistant](#p-android-assistant), [Android connected
sync](#p-android-connected-sync), [Milestone
reconciliation](#p-milestone-reconciliation).

Use the actual release downloads for every execution row below. Rerun
installation/update and all affected behavior; C-row evidence cannot be copied
as a P-row observation. Preserve a separate historical v0.1.0 evidence record
for D-HISTORY unless the owner has committed an authorized plan amendment.

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-TAG | [publication contract](../../CICD.md#ci-and-releases) | GitHub release / v1.0.0 | NOT RUN | Owner-created tag points to reviewed candidate SHA; stable, non-draft, latest release with approved dated notes and Android/Flatpak disclosures | NOT RUN | NOT RUN | NOT RUN |
| P-ASSETS | [publication contract](../../CICD.md#ci-and-releases) | All nine actual v1.0.0 downloads | NOT RUN | Exact dmg, zip, shared macOS manifest, deb/checksum, Flatpak/checksum and APK/checksum; four manifests pass; bytes equal verified workflow artifacts; safe provenance records | NOT RUN | NOT RUN | NOT RUN |
| P-IMAGE-AMD64 | [publication contract](../../CICD.md#ci-and-releases) | GHCR / linux/amd64 | NOT RUN | 1.0.0, 1.0 and latest resolve to verified manifest; exactly amd64+arm64, matching version/revision/created labels; anonymous pull and real deployment/health on amd64 | NOT RUN | NOT RUN | NOT RUN |
| P-IMAGE-ARM64 | [publication contract](../../CICD.md#ci-and-releases) | GHCR / linux/arm64 | NOT RUN | Independently verify all three tags and manifest metadata, public visibility, anonymous pull and deployment/health on arm64 | NOT RUN | NOT RUN | NOT RUN |
| P-RETRY | [publication contract](../../CICD.md#ci-and-releases) | Owner / publication failure or retry disposition | NOT RUN | Inspect release/draft/tag and already-promoted images before any retry; record no-retry disposition if none; no automatic retag or alias rollback | NOT RUN | NOT RUN | NOT RUN |

### P macOS

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-MAC01-01 | [MAC01](macos.md#macos-delivery-acceptance) `B[1,2,3,4,5,6,7]; P[1,2,3]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC01-02 | [MAC01](macos.md#macos-delivery-acceptance) `B[1,2,3,4,5,6,7]; P[1,2,3]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC04-01 | [MAC04](macos.md#implementation-notes-and-remaining-gates) `B[5,6]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC04-02 | [MAC04](macos.md#implementation-notes-and-remaining-gates) `B[5,6]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC06-01 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `B[1,2,3,4]; N[1,2,3,4,5]; P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC06-02 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `B[1,2,3,4]; N[1,2,3,4,5]; P[1]; U[1,2,3,4,5,6,7]` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC07-01 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC07-02 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC08-01 | [MAC08](macos.md#m2-forget-values-controls-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC08-02 | [MAC08](macos.md#m2-forget-values-controls-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC09-01 | [MAC09](macos.md#m2-onboarding-and-library-recovery-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC09-02 | [MAC09](macos.md#m2-onboarding-and-library-recovery-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC10-01 | [MAC10](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC10-02 | [MAC10](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC11-01 | [MAC11](macos.md#m2-input-method-composition-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC11-02 | [MAC11](macos.md#m2-input-method-composition-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC12-01 | [MAC12](macos.md#m2-conditional-clipboard-privacy-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC12-02 | [MAC12](macos.md#m2-conditional-clipboard-privacy-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC13-01 | [MAC13](macos.md#m3-m1-library-window-shell-not-run) `B[1,2,3,4]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC13-02 | [MAC13](macos.md#m3-m1-library-window-shell-not-run) `B[1,2,3,4]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC14-01 | [MAC14](macos.md#m3-m2-library-editor-tabs-not-run) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC14-02 | [MAC14](macos.md#m3-m2-library-editor-tabs-not-run) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC15-01 | [MAC15](macos.md#m3-macos-history-and-file-commands-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC15-02 | [MAC15](macos.md#m3-macos-history-and-file-commands-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC16-01 | [MAC16](macos.md#m6-y20-account-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC16-02 | [MAC16](macos.md#m6-y20-account-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC17-01 | [MAC17](macos.md#m4-a3-keychain-secrets-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC17-02 | [MAC17](macos.md#m4-a3-keychain-secrets-not-run) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC18-01 | [MAC18](macos.md#m3-m4-library-import-not-run) `B[1,2,3]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC18-02 | [MAC18](macos.md#m3-m4-library-import-not-run) `B[1,2,3]; P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC19-01 | [MAC19](macos.md#m4-a13-assistant-settings-not-run) `B[1,2,3,4]; P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC19-02 | [MAC19](macos.md#m4-a13-assistant-settings-not-run) `B[1,2,3,4]; P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC21-01 | [MAC21](macos.md#m7-d17-delivery-and-update-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC21-02 | [MAC21](macos.md#m7-d17-delivery-and-update-settings-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC23-01 | [MAC23](macos.md#m6-y23-invite-activation-not-run) `P[1,2]; T1.R[1,2,3,4,5].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC23-02 | [MAC23](macos.md#m6-y23-invite-activation-not-run) `P[1,2]; T1.R[1,2,3,4,5].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC06-03 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `U[8]` | MAC-dmg / Intel x86_64 (optional) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC06-04 | [MAC06](macos.md#m2-macos-artifacts-and-installation-not-run) `U[8]` | MAC-zip / Intel x86_64 (optional) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC07-03 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `T1.R[9].C2` | MAC-dmg / non-US physical layout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC07-04 | [MAC07](macos.md#m2-settings-general-and-shortcuts-not-run) `T1.R[9].C2` | MAC-zip / non-US physical layout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC02-MAC-dmg-CGEvent | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[1].C2` | MAC-dmg / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC02-MAC-dmg-AppleScript | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[2].C2` | MAC-dmg / AppleScript | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC02-MAC-zip-CGEvent | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[1].C2` | MAC-zip / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC02-MAC-zip-AppleScript | [MAC02](macos.md#accessibility-and-setup) `N[1,2,3,4,5,6]; P[1]; U[1,2,3,4,5,6]; T1.R[2].C2` | MAC-zip / AppleScript | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-1-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C2` | MAC-dmg / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-1-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C3` | MAC-dmg / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-2-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C2` | MAC-dmg / Chrome / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-2-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C3` | MAC-dmg / Chrome / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-3-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C2` | MAC-dmg / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-dmg-3-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C3` | MAC-dmg / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-1-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C2` | MAC-zip / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-1-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[1].C3` | MAC-zip / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-2-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C2` | MAC-zip / Chrome / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-2-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[2].C3` | MAC-zip / Chrome / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-3-2 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C2` | MAC-zip / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC03-MAC-zip-3-3 | [MAC03](macos.md#delivery-matrix) `P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]; T1.R[3].C3` | MAC-zip / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-1-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C2` | MAC-dmg / TextEdit / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-1-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C3` | MAC-dmg / TextEdit / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-2-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C2` | MAC-dmg / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-2-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C3` | MAC-dmg / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-3-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C2` | MAC-dmg / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-dmg-3-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C3` | MAC-dmg / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-1-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C2` | MAC-zip / TextEdit / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-1-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[1].C3` | MAC-zip / TextEdit / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-2-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C2` | MAC-zip / Safari / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-2-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[2].C3` | MAC-zip / Safari / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-3-2 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C2` | MAC-zip / Terminal / normal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC05-MAC-zip-3-3 | [MAC05](macos.md#m2h-picker-and-fill-form-not-run) `B[1,2,3]; P[1,2]; U[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]; T1.R[3].C3` | MAC-zip / Terminal / full-screen Space | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC20-MAC-dmg-Anthropic | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C2` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC20-MAC-dmg-Ollama | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Safari-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Safari-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Safari-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Safari-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Safari / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Chrome-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Chrome-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Chrome-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Chrome-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Chrome / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Terminal-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Terminal-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Terminal-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-dmg-Terminal-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-dmg / Terminal / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC20-MAC-zip-Anthropic | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C2` | MAC-zip / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC20-MAC-zip-Ollama | [MAC20](macos.md#m4-library-assistant-flows-73-76-117) `B[1,2,3]; P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | MAC-zip / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Safari-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Safari-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Safari-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Safari-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Safari / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Chrome-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Chrome-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Chrome-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Chrome-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Chrome / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Terminal-norm-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / normal / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Terminal-norm-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / normal / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Terminal-full-CGEvent | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / full-screen Space / CGEvent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-MAC22-MAC-zip-Terminal-full-AppleScript | [MAC22](macos.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | MAC-zip / Terminal / full-screen Space / AppleScript fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Linux native

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-LIN01-01 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN01-02 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN01-03 | [LIN01](linux.md#linux-picker-and-delivery-checks) `P[1]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN04-01 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN04-02 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN04-03 | [LIN04](linux.md#library-import-m3-not-run) `B[1,2]; P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN10-01 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN10-02 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN10-03 | [LIN10](linux.md#onboarding-and-library-recovery-m2-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN11-01 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN11-02 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN11-03 | [LIN11](linux.md#settings-m2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,11].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN12-01 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN12-02 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN12-03 | [LIN12](linux.md#picker-and-fill-m2f-not-run) `P[1]; U[1,2,3,4,5,6,7,8]; T1.R[1].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN13-01 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN13-02 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN13-03 | [LIN13](linux.md#library-browser-shell-m3l1-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN14-01 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN14-02 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN14-03 | [LIN14](linux.md#library-editor-tabs-m3l2-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN15-01 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN15-02 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN15-03 | [LIN15](linux.md#history-and-file-commands-m3l3-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN16-01 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN16-02 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN16-03 | [LIN16](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) `B[1,2,3]; N[1,2,3,4,5]; T1.R[1,2,3,4].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN17-01 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | X11 / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN17-02 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | GNOME-W / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN17-03 | [LIN17](linux.md#input-method-composition-m2-not-run) `B[1,2,3]; N[1,2,3,4]; T1.R[1,2].C3` | KDE-W / real IBus or Fcitx conversion engine | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN18-01 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN18-02 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN18-03 | [LIN18](linux.md#conditional-clipboard-privacy-m2-not-run) `B[1,2,3]; P[1]; T1.R[1,2,3,4].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN03-01 | [LIN03](linux.md#invite-activation-m6-y24-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | GNOME-W / browser and launcher | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN03-02 | [LIN03](linux.md#invite-activation-m6-y24-not-run) `P[1]; T1.R[1,2,3,4,5,6].C3` | KDE-W / browser and launcher | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN05-GNOME-W | [LIN05](linux.md#secret-storage-m4-a4-not-run) `B[1,2]; P[1]; T1.R[1,3,4,5,6,7,8,9].C3` | GNOME-W / GNOME Keyring | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN05-KDE-W | [LIN05](linux.md#secret-storage-m4-a4-not-run) `B[1,2]; P[1]; T1.R[2,3,4,5,6,7,8,9].C3` | KDE-W / KWallet Secret Service | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN06-GNOME-W | [LIN06](linux.md#assistant-settings-m4-a14-not-run) `P[1]; T1.R[1,3,4,5,6].C3` | GNOME-W / GNOME Keyring | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN06-KDE-W | [LIN06](linux.md#assistant-settings-m4-a14-not-run) `P[1]; T1.R[2,3,4,5,6].C3` | KDE-W / KWallet Secret Service | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-X11-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-X11-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-GNOME-W-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-GNOME-W-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-KDE-W-Anthropic | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C3` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN07-KDE-W-Ollama | [LIN07](linux.md#library-assistant-flows-m4-a16-not-run) `P[1,2]; T1.R[1,2,3,4,5,6,7,8,9,10].C4` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN08-01 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | X11 / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN08-02 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | GNOME-W / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN08-03 | [LIN08](linux.md#release-deb-installation-m2-not-run) `B[1,2,3,4]; N[1,2,3,4,5,6]; P[1]; T1.R[1,2,3,4].C3` | KDE-W / Ubuntu24.04+ amd64 / historical version gate D-HISTORY | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN09-1 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[1].C3` | KDE-W / tray | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN09-2 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[2].C3` | GNOME-W / AppIndicator | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN09-3 | [LIN09](linux.md#tray-m2-not-run) `P[1]; T1.R[3].C3` | GNOME-W / no tray | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Linux delivery

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-LIN02-01 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN02-02 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN02-03 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN02-04 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN02-05 | [LIN02](linux.md#delivery-and-update-settings-m7-d18-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-01 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-02 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-03 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-04 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-05 | [LIN23](linux.md#m7-current-desktop-procedures) `P[1,2,3]; T1.R[1,2,3,4,5,6,7].C3` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN19-01 | [LIN19](linux.md#delivery-plumbing-m1b) `P[1,2]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN19-02 | [LIN19](linux.md#delivery-plumbing-m1b) `P[1,2]` | wlroots-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN20-01 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN20-02 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | GNOME-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN20-03 | [LIN20](linux.md#x11) `P[1]; U[1,2,3,4,5,6,7,8,9,10,11]` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN21-01 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool current dialect / browser | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN21-02 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool current dialect / terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN21-03 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool 0.1.8 dialect / browser | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN21-04 | [LIN21](linux.md#wlroots-with-ydotool) `U[1,2,3,4,5,6]` | wlroots-W / ydotool 0.1.8 dialect / terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN22-01 | [LIN22](linux.md#decisions-and-validation-boundary) `B[7]; P[2]` | X11 / wlroots-W contract reconciliation | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-X11-browser-norm-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / browser/chat / normal / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-X11-browser-full-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / browser/chat / full-screen / multiple monitors / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-X11-terminal-norm-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / terminal / normal / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-X11-terminal-full-xdotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3` | X11 / terminal / full-screen / multiple monitors / xdotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-browser-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-browser-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / browser/chat / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-terminal-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-GNOME-W-terminal-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[GN01](gnome.md#gnome-portal-owner-checks) `U[7,8,9,10]`<br>[GN02](gnome.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | GNOME-W / terminal / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-browser-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-browser-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-terminal-norm-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / normal / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-terminal-full-ydotool | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / full-screen / multiple monitors / ydotool | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-KDE-W-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `U[7,8,9,10]`<br>[KD04](kde.md#m7-current-desktop-procedures) `T1.R[3,4].C3` | KDE-W / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-GNOME-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-GNOME-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-GNOME-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-GNOME-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C2` | FP-GNOME / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-KDE-browser-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / browser/chat / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-KDE-browser-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / browser/chat / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-KDE-terminal-norm-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / terminal / normal / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-LIN23-FP-KDE-terminal-full-portal | [LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2,3,6].C3`<br>[FP04](flatpak.md#portals-clipboard-and-settings) `N[2]; T1.R[2].C4` | FP-KDE / terminal / full-screen / multiple monitors / portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-GNOME-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | GNOME-X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-1 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[1].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Gnome-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-2 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[2].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS gnome-terminal-server | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-3 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[3].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS konsole | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-4 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[4].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Xfce4-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-5 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[5].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS mate-terminal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-6 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[6].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Tilix | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-7 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[7].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS Alacritty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-8 | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]; T1.R[8].C2`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / WM_CLASS kitty | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-unknown-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / unknown class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-lookalike-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / lookalike class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-missing-class | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / missing class | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-class-query-timeout | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / class-query timeout | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-XTerm | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / XTerm | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-URxvt | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / URxvt | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-ALIAS-KDE-X11-fallback-st | [AC705](m7-acceptance.md#x11-alias-evidence) `P[1]`<br>[LIN23](linux.md#m7-current-desktop-procedures) `T1.R[2].C3` | KDE-X11 / st | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P GNOME and KDE

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-GN01-portal | [GN01](gnome.md#gnome-portal-owner-checks) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | GNOME-W / native portal | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-GN01-native | [GN01](gnome.md#gnome-portal-owner-checks) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | GNOME-W / native no-GlobalShortcuts | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-GN02-01 | [GN02](gnome.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5].C3` | GNOME-W / native | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD01-01 | [KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD01-02 | [KD01](kde.md#kde-shortcut-selection-and-delivery-owner-check) `P[1,2,3,4]; U[1,2,3,4,5,6,7,8,9,10]` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-W-absent | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[1,12,14,15,16]` | KDE-W / portal absent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-W-v1 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,7,9,10,11,12,13,14,15,16]` | KDE-W / GlobalShortcuts v1 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-W-v2 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,8,9,10,11,12,13,14,15,16]` | KDE-W / GlobalShortcuts v2 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-X11-absent | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[1,12,14,15,16]` | KDE-X11 / portal absent | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-X11-v1 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,7,9,10,11,12,13,14,15,16]` | KDE-X11 / GlobalShortcuts v1 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-KDE-X11-v2 | [KD02](kde.md#portalnative-transition-matrix) `P[1]; U[1,2,3,4,5]; T1.R[2,3,4,5,6,8,9,10,11,12,13,14,15,16]` | KDE-X11 / GlobalShortcuts v2 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD04-01 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD04-02 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | KDE-X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD04-03 | [KD04](kde.md#m7-current-desktop-procedures) `P[1,2]; T1.R[1,2,3,4,5,6].C3` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Flatpak

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-GN01-01 | [GN01](gnome.md#gnome-portal-owner-checks) `P[5,6]; U[11,12,13,14,15,16,17]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-GN02-02 | [GN02](gnome.md#m7-current-desktop-procedures) `P[1,2]; T1.R[6].C3` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD02-01 | [KD02](kde.md#portalnative-transition-matrix) `U[6]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-KD03-01 | [KD03](kde.md#flatpak-tray-and-library-boundary) `P[1,2]; U[1,2,3,4]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP01-01 | [FP01](flatpak.md#flatpak-owner-procedure) `P[1,2]` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP01-02 | [FP01](flatpak.md#flatpak-owner-procedure) `P[1,2]` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP02-FP-GNOME | [FP02](flatpak.md#install-permissions-and-state) `N[1,2,3,4]; T1.R[1,2,3,4,5].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP02-FP-KDE | [FP02](flatpak.md#install-permissions-and-state) `N[1,2,3,4]; T1.R[1,2,3,4,5].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP03-FP-GNOME | [FP03](flatpak.md#actions-and-invite-staging) `N[1,2,3,4]; T1.R[1,2,3].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP03-FP-KDE | [FP03](flatpak.md#actions-and-invite-staging) `N[1,2,3,4]; T1.R[1,2,3].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP04-FP-GNOME | [FP04](flatpak.md#portals-clipboard-and-settings) `N[1,2,3,4]; T1.R[1,2,3,4].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-FP04-FP-KDE | [FP04](flatpak.md#portals-clipboard-and-settings) `N[1,2,3,4]; T1.R[1,2,3,4].C4` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Desktop assistant

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AS01-1-MAC-dmg | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[1].C2; T1.R[1].C3; T1.R[1].C4; T1.R[1].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-2-MAC-dmg | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[2].C2; T1.R[2].C3; T1.R[2].C4; T1.R[2].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | MAC-dmg / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-3-X11 | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | X11 / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-3-GNOME-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | GNOME-W / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-3-KDE-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4; T1.R[3].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | KDE-W / Anthropic / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-4-X11 | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | X11 / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-4-GNOME-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | GNOME-W / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS01-4-KDE-W | [AS01](assistant.md#m4-assistant-owner-checks) `B[1,2,3,4,5]; P[1,2]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4; T1.R[4].C5`<br>[AS02](assistant.md#library-flows) `P[1]; U[1,2,3,4,5,6,7]` | KDE-W / Ollama / Test, Write, Review, Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS03-MAC-dmg | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS03-GNOME-W | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS03-KDE-W | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS03-X11 | [AS03](assistant.md#key-tiers-and-profile-lifecycle) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C3` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS04-01 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | MAC-dmg / Keychain / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS04-02 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | GNOME-W / Secret Service / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS04-03 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | KDE-W / KWallet Secret Service / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS04-04 | [AS04](assistant.md#manual-sentinel-scan) `P[1,2,3,4]` | X11 / file tier and environment override / every source checkpoint | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-01 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-02 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-03 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-04 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-05 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-06 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-07 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS05-08 | [AS05](assistant.md#native-controls-and-desktop-behavior-not-run) `P[1]; T1.R[1,2,3,4].C2` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-01 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | MAC-dmg / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-02 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | MAC-dmg / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-03 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | X11 / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-04 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | X11 / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-05 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | GNOME-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-06 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | GNOME-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-07 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | KDE-W / Anthropic | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AS06-08 | [AS06](assistant.md#automated-proof-and-remaining-owner-work) `P[2]` | KDE-W / Ollama | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Server and desktop sync

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-SRV01-01 | [SRV01](server.md#server-deployment-acceptance) `B[1,2,3,4,5]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV02-01 | [SRV02](server.md#fresh-host-via-updatesh-not-run) `N[1,2,3,4,5]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV03-01 | [SRV03](server.md#real-domain-https-and-two-update-re-runs-not-run) `N[1,2,3,4,5]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV04-01 | [SRV04](server.md#backuprestore-drill-not-run) `N[1,2,3,4]; P[1]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV07-01 | [SRV07](server.md#host-the-sync-server) `P[1,2,3,4,5,6,7,8,9,10,11,12,13]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV08-01 | [SRV08](server.md#server-backup-and-restore) `P[1,2,3,4]` | Linux Docker / real-domain HTTPS / disposable database | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV05-01 | [SRV05](server.md#desktop-login-push-and-pull-after-m6-not-run) `N[1,2,3,4]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV05-02 | [SRV05](server.md#desktop-login-push-and-pull-after-m6-not-run) `N[1,2,3,4]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV06-01 | [SRV06](server.md#client-filenames-after-m6-not-run) `P[1]; T1.R[1,2].C2` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SRV06-02 | [SRV06](server.md#client-filenames-after-m6-not-run) `P[1]; T1.R[1,2].C2` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC01-01 | [SYNC01](sync.md#desktop-sync-setup-and-verification) `P[1]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC01-02 | [SYNC01](sync.md#desktop-sync-setup-and-verification) `P[1]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC02-01 | [SYNC02](sync.md#set-up-a-disposable-verification-pair) `N[1,2,3,4,5,6,7]; P[1,2]` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC02-02 | [SYNC02](sync.md#set-up-a-disposable-verification-pair) `N[1,2,3,4,5,6,7]; P[1,2]` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC05-01 | [SYNC05](sync.md#required-owner-acceptance-ledger) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C1` | macOS peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-SYNC05-02 | [SYNC05](sync.md#required-owner-acceptance-ledger) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C1` | Linux peer / two users / deployed HTTPS | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android prerequisites

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND-identity | [AND01](android.md#android-acceptance) `P[1]`<br>[AND02](android.md#m8-acceptance-record) `P[1]`<br>[AND10](android.md#unicode-runtime-checks) `P[1,2,3]`<br>[AND18](android.md#android-assistant-m11-not-run-owner) `P[1]`<br>[AND19](android.md#assistant-disclosures) `P[1,2,3]` | Final signed minified APK / source prerequisites | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND04-01 | [AND04](android.md#release-apk-verification) `P[1,2,3,4,5,6]; T1.R[2,3,4].C2` | API 26–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND04-02 | [AND04](android.md#release-apk-verification) `P[1,2,3,4,5,6]; T1.R[2,3,4].C2` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND04-published | [AND04](android.md#release-apk-verification) `T1.R[1].C2` | Actual v1.0.0 release download | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND11-01 | [AND11](android.md#minimum-api-device-check-not-run-owner) `P[1,2]; T1.R[1,2,3,4,5].C3` | API 26 minimum / production validator caller | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android local library

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND07-01 | [AND07](android.md#m8-seeds-library-and-editorhistory-not-run-owner) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C2` | API 26–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND07-02 | [AND07](android.md#m8-seeds-library-and-editorhistory-not-run-owner) `P[1]; T1.R[1,2,3,4,5,6,7,8,9].C2` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android native sync and storage

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND12-01 | [AND12](android.md#assistant-transport-device-checks-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6]` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND12-02 | [AND12](android.md#assistant-transport-device-checks-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6]` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND14-01 | [AND14](android.md#android-sync-tls-and-device-token-checks-m10-z6-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND14-02 | [AND14](android.md#android-sync-tls-and-device-token-checks-m10-z6-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12].C3` | API 34+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND13-01 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 26/27 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND13-02 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 28–30 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND13-03 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 31–33 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND13-04 | [AND13](android.md#android-native-secret-store-checks-m11-l8-not-run) `P[1,2,3,4,5]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C3` | API 34+ StrongBox | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND16-01 | [AND16](android.md#m10-z4-private-filesystem-durability-not-run) `P[1,2,3,4]; T1.R[1,2,3,4,5,6,7,8].C2` | Physical private-library/state filesystem / record actual API | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND22-01 | [AND22](android.md#android-sync-scheduling-m10-z20-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C2` | API 26–30 ordinary work | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND22-02 | [AND22](android.md#android-sync-scheduling-m10-z20-not-run) `P[1,2,3]; T1.R[1,2,3,4,5,6,7,8].C2` | API 31+ expedited/quota fallback | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND23-01 | [AND23](android.md#android-invite-links-m10-z23-not-run) `P[1]; T1.R[1,2,3,4,5,6].C2` | Actual phone / cold, foreground, background / record API | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android entry and IME

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND05-01 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C2` | API 34 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-01-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-01-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-01-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-01-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-01-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-01-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-01-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-01-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-02 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C2` | API 34 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-02-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-02-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-02-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-02-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-02-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-02-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-02-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C2`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 34 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-02-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C2` | API 34 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-03 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C3` | API 35 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-03-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-03-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-03-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-03-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-03-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-03-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-03-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-03-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-04 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C3` | API 35 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-04-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-04-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-04-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-04-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-04-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-04-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-04-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C3`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 35 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-04-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C3` | API 35 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-05 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C4` | API 36 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-05-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-05-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-05-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-05-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-05-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-05-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-05-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[5].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-05-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-06 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C4` | API 36 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-06-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-06-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-06-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-06-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-06-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-06-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-06-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[6].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C4`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | API 36 / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-06-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C4` | API 36 / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-07 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C5` | below34 (26/27 preferred) / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-07-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-07-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-07-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-07-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-07-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-07-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-07-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[7].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Gboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-07-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Gboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-08 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2`<br>[AND03](android.md#m9-acceptance-record) `P[1,5,6,7,8,9,10]; T3.R[4].C5` | below34 (26/27 preferred) / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-08-1 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Chrome | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-08-1 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[1].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-08-2 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / ChatGPT | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-08-2 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[2].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / ChatGPT / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-08-3 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C5`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Claude | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-08-3 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[3].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Claude / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-08-4 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[8].C6`<br>[AND03](android.md#m9-acceptance-record) `T3.R[1,6].C5`<br>[AND17](android.md#m9-insertion-integration-and-privacy-proof-n8) `P[5,6,7]; T1.R[1,2,3,4,5].C2` | below34 (26/27 preferred) / Samsung Keyboard / Termux | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-08-4 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T2.R[4].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[5].C5` | below34 (26/27 preferred) / Samsung Keyboard / Termux / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-09 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 26/32 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-10 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 33 / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-01 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[5]` | API 26/27 legacy window token / Gboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-11 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 26/32 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND05-12 | [AND05](android.md#m9-keyboard-and-tile-setup-not-run) `P[1]; T1.R[1,2,3,4,5,6,7,8,9,10,11].C2` | API 33 / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND15-02 | [AND15](android.md#m9-ime-insertion-and-switch-back-not-run) `B[5]` | API 26/27 legacy window token / Samsung Keyboard | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-01 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3` | API 26 minimum / tile, shortcut, widget | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND06-02 | [AND06](android.md#m8-quick-entry-points-not-run-owner) `B[1,2,3,4]; P[1,2,3]; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C2; T1.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15].C3` | API 37 target coverage (when available) **optional** | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android selection and share

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND08-01-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-01-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-01-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-01-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-01-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-01-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-01-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-02-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-02-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-02-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-02-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C2` | API 34 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-02-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-02-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-02-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C2` | API 34 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-03-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-03-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-03-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-03-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-03-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-03-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-03-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-04-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-04-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-04-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-04-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C3` | API 35 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-04-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-04-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-04-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C3` | API 35 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-05-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-05-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-05-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-05-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-05-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-05-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-05-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-06-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-06-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-06-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-06-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C4` | API 36 / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-06-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-06-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-06-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C4` | API 36 / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-07-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-07-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-07-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-07-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Gboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-07-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-07-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-07-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Gboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-08-1 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[1].C2; T1.R[1].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome editable web field | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-08-2 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[2].C3; T1.R[2].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Chrome page text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-08-3 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[3].C2; T1.R[3].C3; T1.R[3].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / native EditText | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND08-08-4 | [AND08](android.md#text-selection-entry-checks-m9-n5-not-run) `B[1,2,3,4,5,6]; P[1,2,3,4,5]; T1.R[4].C2; T1.R[4].C3; T1.R[4].C4`<br>[AND03](android.md#m9-acceptance-record) `T3.R[2].C5` | below34 (26/27 preferred) / Samsung Keyboard / Compose foundation1.9+ | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-08-1 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[1,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / native plain text | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-08-2 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[2,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / styled supporting host | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND09-08-3 | [AND09](android.md#share-entry-checks-m9-n6-not-run) `P[1,2,3,4]; T1.R[3,4,5,6,7,8,9,10,11,12].C3`<br>[AND03](android.md#m9-acceptance-record) `T3.R[3].C5` | below34 (26/27 preferred) / Samsung Keyboard / browser URL/HTML/attachment | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android assistant

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND20-1 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[1].C3; T2.R[1].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Write | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND20-2 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[2].C3; T2.R[2].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Review | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND20-3 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[3].C3; T2.R[3].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / Anthropic / Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND20-4 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[4].C3; T2.R[4].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Write | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND20-5 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[5].C3; T2.R[5].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Review | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND20-6 | [AND20](android.md#evidence-to-record) `P[1,2,3,4,5,6,7]; T1.R[1,2,3,4,5,6,7,8].C2; T2.R[6].C3; T2.R[6].C4`<br>[AND21](android.md#runtime-sentinel-scan-and-automated-proof) `P[1]` | Actual phone / keyless Ollama / Improve | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Android connected sync

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AND24-API26-27 | [AND24](android.md#android-sync-m10-not-run-owner) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T2.R[1,2,3,4,5,6,7,8,9,10].C2` | API 26/27 / phone and desktop / two users | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AND24-API28+-StrongBox-capable | [AND24](android.md#android-sync-m10-not-run-owner) `P[1,2,3]; T1.R[1,2,3,4,5,6].C2; T2.R[1,2,3,4,5,6,7,8,9,10].C2` | API 28+ StrongBox-capable / phone and desktop / two users | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

### P Milestone reconciliation

| ID | Source and keys | Environment | Tester/date | Expected | Actual | Result | Evidence |
|---|---|---|---|---|---|---|---|
| P-AC201-01 | [AC201](m2-acceptance.md#m2-daily-use-acceptance) `B[1,2,3,4]; P[1,2,4]; T1.R[5]; T3.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC201-02 | [AC201](m2-acceptance.md#m2-daily-use-acceptance) `B[1,2,3,4]; P[1,2,4]; T1.R[5]; T3.R[1,2,3,4,5,6,7,8,9,10,11,12,13,14].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC301-01 | [AC301](m3-acceptance.md#m3-library-window-acceptance) `B[1,2]; P[1,2,4]; T2.R[1,2,3,4,5,6,7].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC301-02 | [AC301](m3-acceptance.md#m3-library-window-acceptance) `B[1,2]; P[1,2,4]; T2.R[1,2,3,4,5,6,7].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC401-01 | [AC401](m4-acceptance.md#m4-assistant-acceptance) `B[1,2,3]; P[1,5,7]; T1.R[5,6]; T4.R[1,2,3,4,5,6,7,8,9].C2` | macOS / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC401-02 | [AC401](m4-acceptance.md#m4-assistant-acceptance) `B[1,2,3]; P[1,5,7]; T1.R[5,6]; T4.R[1,2,3,4,5,6,7,8,9].C2` | Linux / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC501-01 | [AC501](m5-acceptance.md#m5-server-acceptance) `B[1,2,3]; P[1,7,9]; T1.R[1,4,5]; T4.R[7,39]; T5.R[1,2,3,4,5,6].C2` | Deployed Docker / required detailed rows | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC701-01 | [AC701](m7-acceptance.md#m7-acceptance-ledger) `P[1,2]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC702-01 | [AC702](m7-acceptance.md#recording-a-run) `P[1,2,3]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC706-01 | [AC706](m7-acceptance.md#procedure-ownership-and-remaining-work) `B[1,2,3]` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC703-01 | [AC703](m7-acceptance.md#owner-prerequisites) `P[1]; T1.R[1,2,3,4,5,6].C2` | Owner / final main / all required environments | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC703-published | [AC703](m7-acceptance.md#owner-prerequisites) `T1.R[7].C2` | Actual published downloads and first GHCR package | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-01 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-dmg | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-02 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[1,2,3,4,5,6,7].C2` | MAC-zip | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-03 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[8,9,10,11,12].C2` | GNOME-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-04 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[13,14,15,16,17].C2` | KDE-W | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-05 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[18,19,20,21,22].C2` | X11 | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-06 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[23,24,25,26,27].C2` | FP-GNOME | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |
| P-AC704-07 | [AC704](m7-acceptance.md#desktop-and-flatpak-runs) `P[1]; T1.R[28,29,30,31,32].C2` | FP-KDE | NOT RUN | Linked keys | NOT RUN | NOT RUN | NOT RUN |

## Closure rule

M12 closes only when **every required row has committed evidence in both
phases**: every required C row, every required P row, and the owner decisions
and named-gap dispositions above. Required NOT RUN, FAIL or BLOCKED keeps it
open. Optional Intel rows remain visibly optional; accepted unsupported cases
need the source rule and observed fallback evidence, never a fabricated PASS.
Reconcile exact final main, current CI/review and artifact identities after
every change; rerun affected rows when code or bytes change. Commit results
and evidence references before declaring M12 or its prerequisite milestones
closed. Only the owner creates/pushes the tag or decides cleanup/retry after
publication failure. This document records no authorization to tag today.
