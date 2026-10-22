# Native desktop redesign

Design and lifecycle decisions: [§24](../plan/24-native-desktop-design.md).
Implementation: [PR #305](https://github.com/L-K-M/MonkeysPaw/pull/305).

## Build and run

On macOS, install Xcode 26 and run from the repository root:

```sh
scripts/build.sh mac --no-open
```

Open the resulting disk image in `dist/` and copy `MonkeysPaw.app` to
Applications. For a development build and hosted tests:

```sh
xcodebuild -project MonkeysPaw.xcodeproj -scheme MonkeysPaw \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO clean test
```

On Ubuntu 24.04 or later, install Swift 6.4, then run:

```sh
sudo apt-get install libgtk-4-dev pkg-config
swift build --product monkeyspaw
.build/debug/monkeyspaw
```

On the Paseo host, replace `swift` with `/home/paseo/.local/bin/swift64`.
Build a deb with `scripts/build.sh deb`. Packaging and signing requirements
remain in [CICD.md](../../CICD.md).

## Verification

macOS CI builds the actual app, runs hosted AppKit tests and packages both
architectures. `MacUITourTests` renders the composed windows, sheets, picker
and Settings panes in light and dark appearances. The `MacUITour` CI artifact
contains these PNGs, menu commands and window metadata. The tour uses copied
seed prompts and disposable application data.

Hosted tests cover menu validation, responder-chain editing, undo/redo,
find, selection and dragging, draft guards, file commands, external changes,
inspector visibility, Settings routing, picker intents and window lifecycle.
The packaging job launches both the disk-image and zip copies.

Linux checks use a private D-Bus session and Xvfb. In addition to GTK tests,
the app was exercised with pointer and keyboard input through creation,
typing, undo/redo, save, rename, duplicate, Edit/Preview, inspector switching,
unsaved-close cancellation and clipboard-only delivery followed by native
paste and disk readback. Dark and high-contrast GTK themes were inspected.
Test libraries and preferences were isolated.

## Remaining owner checks

This host is Linux. macOS screenshots and hosted tests establish native
rendering and automated interaction, not hands-on use of a personal Mac.
Full-screen Spaces, Dock interaction, VoiceOver, display accessibility
settings, real input methods and cross-app paste permissions still require
the [macOS checklist](macos.md). Real Wayland compositors, Orca and input
methods require the [Linux checklist](linux.md).

Prompt formats and storage remain unchanged. Saving stays explicit because
it creates history and sync boundaries. Unsaved changes use the existing
draft guards; crash recovery and simultaneous document windows were not added.
