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

## Owner checks still needed

- macOS menu-bar light/dark appearance and manual settings-sheet interaction.
- Physical TalkBack/VoiceOver, external keyboards and OEM navigation.
- Android 13+ themed-icon rendering on a supporting launcher.
