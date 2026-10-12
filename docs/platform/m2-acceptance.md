# M2 daily-use acceptance

This maps every [§15 M2 acceptance item](../plan/15-milestones.md) to its
automated gate. M2 remains open until the `v0.1.0` artifacts and owner-run
checks below are recorded. Record the commit, CI run, artifact hashes and
tester with the results.

| Acceptance item | Proof | CI job in [ci.yml](../../.github/workflows/ci.yml) |
|---|---|---|
| An external editor save appears in the Linux picker within 1 s | [LinuxPickerViewTests](../../Tests/MonkeysPawLinuxTests/LinuxPickerViewTests.swift): `testExternalInPlaceSaveReachesPickerWithinOneSecondThroughGFileMonitor` and `testExternalAtomicReplaceReachesPickerWithinOneSecondThroughGFileMonitor`. Real GFileMonitor → LibraryWatcher debounce → index → results and GTK preview. | `linux-app`, required display and private D-Bus session |
| An external editor save appears in the macOS picker within 1 s | [MacPickerViewTests](../../MonkeysPawTests/MacPickerViewTests.swift): `testExternalSaveReachesPickerWithinOneSecondThroughFSEvents` (atomic create) and `testExternalInPlaceSaveReachesPickerWithinOneSecondThroughFSEvents`. Real FSEvents → debounce → index → results and preview. | `macos-app`, hosted tests |
| §2 keystroke budgets pass as presentation-model tests | [PickerModelTests](../../Tests/MonkeysPawCoreTests/Fill/PickerModelTests.swift), mapped below. | `linux-app` Core tests and `core-macos` |
| Swift consumes every fixture | [PromptConformanceTests](../../Tests/MonkeysPawCoreTests/PromptConformanceTests.swift): `testEveryFixture` enumerates exactly `format`, `grammar`, `render`, `validation`, `ranking`; every category is nonempty and every JSON/source file is consumed exactly once. Mutation tests reject unknown/missing categories, orphan sources, duplicate consumption and malformed cases. | `linux-app` Core tests and `core-macos` |
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
| Download and install the `v0.1.0` dmg, including checksum, Gatekeeper, launch after eject and relaunch | **NOT RUN** | [macOS checklist](macos.md) |
| Download and install the `v0.1.0` deb on a supported Linux desktop, verify checksum/version and launch | **NOT RUN** | [Linux checklist](linux.md) |
| Real desktop hotkey, focus restoration and exact paste into browser/terminal, including macOS full-screen Spaces and GNOME/KDE Wayland | **NOT RUN** | [macOS](macos.md), [GNOME](gnome.md), [KDE](kde.md), [Linux](linux.md) |
| VoiceOver inside the macOS panel | **NOT RUN** | [macOS checklist](macos.md) |
| Orca/AT-SPI on Linux: search, results, fill controls, preview and actions | **NOT RUN** | [Linux checklist](linux.md) |
| Real IME composition in search and text/multiline fields: Return/Escape remain with composition until committed | **NOT RUN** | [macOS](macos.md), [Linux](linux.md) |

The repository still carries development version `0.0.0`. A dry run or a
prerelease package does not establish the exact `v0.1.0` release gate; that
tag and the owner installations remain pending.
