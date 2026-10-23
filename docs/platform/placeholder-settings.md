# Placeholder settings and paw icons

Checked on 2026-10-23 for [PR #315](https://github.com/L-K-M/MonkeysPaw/pull/315).

## Automated checks

- Swift: 38 focused Core/GTK tests passed, including 1,542 shared fixtures.
  Coverage includes implicit fields, defaults, choices, custom metadata,
  Save/history/discard, read-only headers and stale settings.
- Native GTK: nine settings tests and thirteen existing form tests passed.
  Stale-source retirement and multiline-default regressions failed before
  their fixes, then passed. The host used a private D-Bus session and Xvfb.
- Android: the full Core/app JVM, lint, debug and R8 release gate passed.
  A shortcut-resource regression failed before the contrast fix, then passed.
  Delayed-choice callback regressions also failed before stable row IDs were
  added, then passed through staged settings, Apply, Save and metadata checks.
- Script tests: 204 passed; Xcode object-ID validation passed.
- macOS: CI built the app, ran hosted tests and packaged universal artifacts.
  The hosted icon test loads the compiled 18-point template paw asset.
  A hosted regression observed delayed choice bindings editing the wrong row
  after deletion. Choice rows now retain stable identities, and removed-row
  callbacks are ignored; the same regression verifies this path.

## Android native checks

An isolated API 30 x86_64 emulator ran synthetic prompts at 720×1560/320 dpi.
The R8 release build passed:

- Opening placeholder settings from Fields, including an implicit field.
- Editing a label and cancelling without changing the draft or file.
- Changing Text to Multiline and entering a two-line default with the system
  keyboard. Apply showed an unsaved draft and left disk bytes unchanged.
- Save retained the body, identity and custom header/field/choice metadata.
  Preview displayed the saved two-line default.
- Light-mode phone renders and dark-mode settings at 200% font scaling.
  Type chips wrapped; settings scrolled with Apply/Cancel reachable.
- The Quick Settings tile displayed the monochrome paw.
- The launcher shortcut displayed the full-color paw. The first monochrome
  version disappeared on the light shortcut menu; a before/after render
  confirmed the fix using the existing launcher asset.

Captures and logs are retained in the task delivery's `screenshots/` and
`evidence/` directories.

Debug software emulation hit SystemUI/app ANRs. Recorded app main stacks
were idle or serving Compose accessibility-node requests. Interaction proof
used the R8 build with coordinate input and screenshots; it is not a
performance or accessibility-service claim.

## Follow-up verification

Executed on 2026-10-23 for [PR #317](https://github.com/L-K-M/MonkeysPaw/pull/317).
Product baseline: merged main `dd927dd8` (the same tree as #315's reviewed
head `4e1d1101`). The follow-up changes test code and this record only.

### Mac native appearance and accessibility actions: PASS

The existing `MacUITourTests.testRenderTour` now creates a real `NSStatusItem`
from the production image/menu factories. macOS 26 CI
[run 39986487152](https://github.com/L-K-M/MonkeysPaw/actions/runs/39986487152)
built and executed it. Captures were inspected:

- The visible `NSStatusBarWindow` carried the 18-point template paw and exposed
  the accessible name `Monkey's Paw` in Aqua and Dark Aqua.
- Native button captures were 34×30 pixels with identical nonempty alpha
  bounds `(11, 6, 26, 21)`: black foreground in Aqua, white in Dark Aqua.
  Transparent captures were also composited onto display backgrounds for inspection.
- Opening the item exposed an actual `NSPopupMenuWindow` with the expected
  Picker, Repeat, Library, Settings, Setup, About and Quit actions.
- Real attached placeholder sheets rendered in both appearances. In-process
  AX queries found their radio group, values, checkboxes and named actions.
  AXPress on Cancel kept the draft clean. AXPress on the default toggle and
  Apply updated the draft; Save committed it.

The status-bar window reports a 64-bit identifier outside `CGWindowID`'s
range. Its capture therefore uses native view caching, not a WindowServer
image. The test forces the control's appearance; the OS menu-bar tint and
popup background remain system-owned. This proves native widget rendering
and in-process AX actions, not VoiceOver output or a global OS-theme change.
The type group's native AX name is `Type, Type`; physical AT review remains open.

### Android 13 launcher monochrome rendering: PASS

The signed R8 release APK, SHA-256
`22eeb0ed6555f136dd3fd10a215e1c2604d9b18b6433839f0be3648520999191`,
ran on a fresh AOSP Android 13 / API33 x86_64 emulator:

- Fingerprint: `Android/sdk_phone64_x86_64/emulator64_x86_64:13/TE1A.220922.034/10940250:userdebug/test-keys`.
- Display: 720×2160, 320 dpi. Software emulation; no performance claim.
- Launcher: Lawnchair 15 Beta 3.0, version code `1500020300`, from its
  [pinned release](https://github.com/LawnchairLauncher/lawnchair/releases/tag/v15.0.0-beta3.0).
  Launcher APK SHA-256: `d4200d0985169fd79ba1bd225d653f2a2fe7b50aa07cb0d05ca64c7623f86059`.

With **System icons** selected and no icon pack installed, enabling
**General → Icon style → Tint with accent color** changed the app's full-color
icon into its supplied monochrome paw. The actual app drawer showed a dark
paw on a light accent surface, then a light paw on a dark accent surface
after system night mode changed. Its `Monkey's Paw` label remained exposed
and activation launched the app. Captures were inspected in both modes.
This launcher uses `AdaptiveIconDrawable.monochrome` for this setting on API33+;
it did not substitute a pack icon for the app.

The AOSP stock launcher had no themed-icon setting. Lawnchair 14's separate
themed-pack selector also required an icon pack, so neither was used as proof.
The Google APIs image restarted its system server during first-boot compilation
on this unaccelerated host; the successful check used the clean AOSP image.

### Physical accessibility and hardware matrix: BLOCKED

Device inventory contained emulators only. No Mac desktop-control connection
was available. In-process Mac AX actions and emulator rendering do not close:

- Physical TalkBack/VoiceOver speech and traversal.
- External keyboards, non-US layouts and OEM navigation.
- System-owned Mac menu-bar tint across real desktop themes/full-screen Spaces.

These remain open owner checks. Completing them requires a connected physical
Android device and access to a Mac desktop with the relevant AT enabled.
