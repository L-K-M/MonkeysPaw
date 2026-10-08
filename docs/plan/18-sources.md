## 18. Sources

Research reports produced for this plan (not committed):
- Tauri-era desktop, LLM, landscape, and platform reports, with two judges
  and two reviews.
- The Swift desktop, Swift platform, server precedent, and server tech
  reports.
- The Android delivery, fleet Android, and shared-core-on-Android reports.

Key evidence:

| Topic | Source |
|---|---|
| Swift core + SwiftUI + GTK4 split, C shim, portability rule, GLib traps, Keychain and secret-tool ladder, NSPanel recipe, Carbon hotkey, `ShortcutInstaller`, deb + flatpak | L-K-M/Vervellum: `Package.swift`, `Sources/VervellumKit/{Core,Linux}`, `Sources/CGtk/shim.h`, `Vervellum/{Panel,Hotkeys,Security}`, `AGENTS.md`, `packaging/`, `scripts/build-flatpak.sh` |
| CGEvent paste, AX-focus wait, cooperative activation, LLM client and Maker loop | L-K-M/Invoque: `InvoqueBridge.swift`, `AppActivator.swift`, `AccessibilityAuthorizer.swift`, `Maker/*` |
| GNOME/KDE shortcut and paste mechanics, ydotool dialects, paste timing post-mortems, a sync server deployment | L-K-M/Copywraith: `src-tauri/src/{paste.rs, linux/*}`, `memory/{PASTE_PROBLEM,WINDOW}.md`, `server/`, `update.sh` |
| compose, update.sh, Dockerfile, ghcr publishing conventions | L-K-M/dl-tool, ManorsAndMenaces, ia-get-docker, whatsapp-backup, Paseo; lkm-project-conventions §5 |
| Mutter drops uinput chords; portal paste works; KDE portal staleness; `YDOTOOL_SOCKET` | OpenWhispr issues #956, #2475, #1614, #957 |
| Portal APIs | xdg-desktop-portal docs: GlobalShortcuts, RemoteDesktop, Request; GNOME 48 release notes; xdg-desktop-portal-kde MR !80 |
| Server stack | Hummingbird 2 releases and docs; hummingbird-auth; hummingbird-fluent; fluent-sqlite-driver; SQLite backup docs |
| Sync model prior art | Bitwarden organizations and collections; Joplin Server delta sync; Standard Notes sync; Obsidian Sync; Raycast Teams; 1Password vaults |
| Placeholder and file-format conventions | Anthropic Console templates, Google Dotprompt, Microsoft Prompty, Espanso forms, Raycast placeholders, Claude Code commands |
| Anthropic API details | Claude API reference: models, `output_config.format`, stop reasons, fallbacks |
| Android stack, CI, signing, releases | L-K-M/HalloMiao (`AGENTS.md`, `CICD.md`, `gradle/libs.versions.toml`, workflows); Kararead `DEPENDABOT.md` (AGP 9 deadlock); Neutrodyne (OkHttp, monorepo) |
| Android insertion | Android docs: `InputMethodService` (`switchToPreviousInputMethod`, API 28), `ACTION_PROCESS_TEXT`, Quick Settings tiles (`requestAddTileService`), clipboard behaviour since Android 13; Chromium `SelectionPopupControllerImpl`; Compose foundation 1.9 `ProcessTextKey`; Termux `TerminalView`; Play accessibility policy |
| Android storage and secrets | SAF performance (CommonsWare, SAFTraversal); WorkManager periodic minimum; the `security-crypto` deprecation (1.1.0-alpha07); network security config |
| Swift on Android (rejected for v1) | Swift SDK for Android and the workgroup FAQ; `swift-java` 0.3 and its minSdk issue #419 |
