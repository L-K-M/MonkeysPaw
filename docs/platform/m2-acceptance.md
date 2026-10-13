# M2 daily-use acceptance

This maps every [§15 M2 acceptance item](../plan/15-milestones.md) to its
automated gate. M2 remains open until the `v0.1.0` artifacts and owner-run
checks below are recorded. Record the commit, CI run, artifact hashes and
tester with the results.

- Commit / CI run:
- Release or dry-run workflow run:
- Artifact version / SHA-256:
- Platform / date / tester:

| Acceptance item | Proof | CI job in [ci.yml](../../.github/workflows/ci.yml) |
|---|---|---|
| An external editor save appears in the Linux picker within 1 s | [LinuxPickerViewTests](../../Tests/MonkeysPawLinuxTests/LinuxPickerViewTests.swift): `testExternalInPlaceSaveReachesPickerWithinOneSecondThroughGFileMonitor` and `testExternalAtomicReplaceReachesPickerWithinOneSecondThroughGFileMonitor`. Real GFileMonitor → LibraryWatcher debounce → index → results and GTK preview. | `linux-app`, required display and private D-Bus session |
| An external editor save appears in the macOS picker within 1 s | [MacPickerViewTests](../../MonkeysPawTests/MacPickerViewTests.swift): `testExternalSaveReachesPickerWithinOneSecondThroughFSEvents` (atomic create) and `testExternalInPlaceSaveReachesPickerWithinOneSecondThroughFSEvents`. Real FSEvents → debounce → index → results and preview. | `macos-app`, hosted tests |
| §2 keystroke budgets pass as presentation-model tests | [PickerModelTests](../../Tests/MonkeysPawCoreTests/Fill/PickerModelTests.swift), mapped below. | `linux-app` Core tests and `core-macos` |
| Swift consumes every fixture | [PromptConformanceTests](../../Tests/MonkeysPawCoreTests/PromptConformanceTests.swift): `testEveryFixture` enumerates exactly eight categories: `format`, `grammar`, `render`, `validation`, `ranking`, `import`, `paths`, `canonical`; every category is nonempty and every JSON/source file is consumed exactly once. Mutation tests reject unknown/missing categories, orphan sources, duplicate consumption and malformed cases. | `linux-app` Core tests and `core-macos` |
| Tag `v0.1.0` produces an installable dmg and deb | `deb` builds, inspects, installs and checks a prerelease deb; `macos-artifacts` verifies universal slices, signatures, versions, dmg contents, zip equivalence and launches both packaged copies. [release.yml](../../.github/workflows/release.yml) runs CI on the release commit, verifies the tag, builds the tag's deb/dmg/zip, checks uploaded bytes and checksums, then verifies the draft's assets before publishing the release. | `deb`, `macos-artifacts`; release jobs `tests`, `verify`, `linux`, `macos`, `artifacts`, `publish` |

Watcher timing starts immediately before the write, including temporary-file
creation for atomic replacement. Tests print elapsed seconds; macOS also
keeps an XCTest timing attachment. The diagnostic wait allows five seconds,
while the acceptance assertion remains strictly **less than one second**.
Linux tests require the display and private-bus gates; a skipped run provides
no timing proof. The hosted macOS changes require compilation and execution
in `macos-app` CI; this Linux host cannot run them.

| §2 scenario | Presentation-model test |
|---|---|
| Fieldless top result: hotkey, Return (2 keys) | `testFieldlessTopBudgetHotkeyReturnAndUsageLearning` |
| Reuse values: hotkey, Return, Return (3 keys) | `testReuseValuesBudgetHotkeyReturnReturn` |
| Change one field: 3 keys plus typing | `testChangeOneFieldBudgetThreeKeysPlusTyping` |
| Rare prompt: hotkey, 2–4 letters, Return, fill, Return | `testRarelyUsedPromptFoundWithTwoToFourLetters`, independently delivers for each query length |
| Cancel picker: one Escape | `testCancelFromPickerBudgetOneEscapeNeverDelivers` |
| Leave fill: Escape keeps values; second Escape closes without paste | `testEscapeChainKeepsValuesAndNeverDelivers` |

Owner-run gates:

| Check | Status | Record results in |
|---|---|---|
| Download and install the `v0.1.0` dmg, including checksum, Gatekeeper, launch after eject and relaunch | **NOT RUN** | [macOS artifacts and installation](macos.md#m2-macos-artifacts-and-installation-not-run) |
| Download and install the `v0.1.0` deb on a supported Linux desktop, verify checksum/version, launch, relaunch and uninstall | **NOT RUN** | [Linux release deb installation](linux.md#release-deb-installation-m2-not-run) |
| Real desktop hotkey, focus restoration and exact paste into browser/terminal, including macOS full-screen Spaces and GNOME/KDE Wayland | **NOT RUN** | [macOS](macos.md), [GNOME](gnome.md), [KDE](kde.md), [Linux](linux.md) |
| Settings: General folder/default/reveal, cancellation, errors and reusable window | **NOT RUN** | [macOS General rows](macos.md#m2-settings-general-and-shortcuts-not-run): Choose, Cancel, invalid folder, Use Default and Show in Finder. [Linux General rows](linux.md#settings-m2-not-run): Choose folder through Open Folder and both Settings entry points. |
| Settings: Shortcuts binding, conflict/failure, actual activation verification and Setup access | **NOT RUN** | [macOS Shortcuts rows](macos.md#m2-settings-general-and-shortcuts-not-run): Open Setup, record/rebind and conflicting shortcut. [Linux Shortcuts rows](linux.md#settings-m2-not-run): Open Setup, GNOME portal and KDE; use the [GNOME](gnome.md) / [KDE](kde.md) delivery checks for real activation. |
| Per-prompt and global Forget: defaults, drafts, confirmation, failures and current picker after a library switch | **NOT RUN** | [macOS Forget controls](macos.md#m2-forget-values-controls-not-run); Linux [Forget all values row](linux.md#settings-m2-not-run) and [Forget values in picker and fill row](linux.md#picker-and-fill-m2f-not-run). |
| Onboarding and library recovery: fresh/legacy setup, folder/seed decisions, resume, startup and runtime loss | **NOT RUN** | [macOS onboarding and recovery rows](macos.md#m2-onboarding-and-library-recovery-not-run), [Linux onboarding and recovery rows](linux.md#onboarding-and-library-recovery-m2-not-run) |
| Linux tray: KDE, GNOME with AppIndicator and stock GNOME entry points | **NOT RUN** | [Linux tray rows](linux.md#tray-m2-not-run), including library status and Quit |
| macOS status-menu library row: active folder, disabled unavailable state and replacement-folder recovery | **NOT RUN** | [macOS status-menu rows](macos.md#m2-onboarding-and-library-recovery-not-run): “The status menu says Open Library” and “After runtime loss, choose a healthy folder”. |
| VoiceOver: picker/fill, Settings and onboarding | **NOT RUN** | [macOS VoiceOver procedure](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run) |
| Orca/AT-SPI: picker/fill, Settings and onboarding | **NOT RUN** | [Linux Orca procedure](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) |
| Real IME composition in search and text/multiline fields: Return confirms and Escape cancels composition without app actions | **NOT RUN** | [macOS IME procedure](macos.md#m2-input-method-composition-not-run), [Linux IBus/Fcitx procedure](linux.md#input-method-composition-m2-not-run) |
| Conditional clipboard privacy (§5.3): zero reads without the builtin or on mere selection; one read per form open/fieldless use, reused by edits and repeated builtin occurrences | **NOT RUN** | [macOS clipboard privacy rows](macos.md#m2-conditional-clipboard-privacy-not-run), [Linux clipboard privacy rows](linux.md#conditional-clipboard-privacy-m2-not-run) |
| Visible keyboard focus and reduced motion (§11.6) in picker/fill, Settings and onboarding | **NOT RUN** | macOS [Visible focus and Reduced motion rows](macos.md#m2-voiceover-visible-focus-and-reduced-motion-not-run), Linux [Visible focus and Reduced motion rows](linux.md#orca-visible-focus-and-reduced-motion-m2-not-run) |

Version alignment, a dry run or a prerelease package does not establish the
exact `v0.1.0` release gate; that tag and the owner installations remain pending.
Record candidate checks from the main dry-run artifacts, then record the
published `v0.1.0` artifacts and installed copies against their exact commit,
run and hashes.
