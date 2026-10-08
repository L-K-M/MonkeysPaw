## 15. Milestones

**How each milestone is built.**

- **Implementation.** Each milestone lands as a sequence of small PRs.
  Every PR is implemented by codex (`gpt-6.1-sol`, reasoning effort `max`)
  from the milestone spec in this plan.
- **Review.** Devin (`swe-2-max`) reviews each PR adversarially, and the
  GLM review workflow runs once it exists.
- **Validation and merge.** The supervising agent validates every PR before
  merging: it builds, runs the tests, reads the diff against this plan, and
  rejects scope creep.
- **Closing a milestone.** A milestone closes when its acceptance criteria
  are demonstrated on main.
- **Owner-run checks.** Checks that need real hardware or paid keys are
  marked "owner-run". Their filled-in checklists are committed under
  `docs/platform/`.

| # | Milestone | Scope | Acceptance |
|---|---|---|---|
| M0 | Skeleton | `Package.swift` (MonkeysPawCore + Yams, CGtk, Linux app), Xcode project linking the local package, `server/` package with `/api/health`, repo furniture (§14), ci.yml (M0 jobs), logging. macOS menu-bar agent and Linux GtkApplication, each showing an empty panel from the menu or tray. | CI green on all M0 jobs. The server image builds in a container without GTK. `swift test` passes on macOS and Linux. Owner-run: both apps launch and show the panel. |
| M1a | Delivery: macOS | Carbon hotkey; the NSPanel recipe; frontmost tracking; activation with verify-and-retry; CGEvent paste with AppleScript fallback; AX check; `DeliveryService` with ladder and failure cache; Setup rows; self-test; one canned prompt. | Service tests assert the §6.3 order and fallback. Owner-run: the self-test passes; the canned text lands in Safari, Chrome, and Terminal, also over a full-screen app (`docs/platform/macos.md`). |
| M1b | Delivery: Linux plumbing | GtkApplication D-Bus activation and actions; gsettings keybinding installer (GNOME); GDBus shim; notifications; GdkClipboard; ydotool and xdotool drivers; Setup rows; self-test. | linux.yml green: Xvfb lifecycle, fake executables, mock-bus tests. CI X11 smoke: `gapplication action … toggle`, pick, and xdotool paste into an xterm. |
| M1c | Delivery: GNOME portals | GlobalShortcuts portal (GNOME ≥ 48); RemoteDesktop keysym paste with restore token; GNOME ladder order. | Mock-portal tests pass. Owner-run on GNOME Wayland: the self-test reports a backend that verifiably pasted; ladder results go in `docs/platform/gnome.md`. A copy-only result needs a written root cause. |
| M1d | Delivery: KDE | KGlobalAccel actions; portal shortcuts on Plasma ≥ 6.3; KDE ladder order; hotkey conflict check. | Mock-bus tests pass. Owner-run on Plasma Wayland, recorded as in M1c (`docs/platform/kde.md`). |
| M2 | Library + fill: **daily use** | Format, grammar, validator, renderer, builtins; library folder, watcher, index, fuzzy search, ranking; picker and fill form with live preview; remembered values; first-run library step + seeds; Settings: General and Shortcuts; §11.5 picker and library states; `spec/fixtures/` corpus for format, grammar, render, validation, and ranking (§10.7); release.yml (dmg + deb). | A prompt saved in an editor appears in the picker within 1 s. Keystroke budgets pass as presentation-model tests. Swift tests consume every fixture. Tag `v0.1.0` produces an installable dmg and deb. |
| M3 | Library window | Browse by folder, tag, favourite; editor with live validation, field inspector, history and restore, rename/move/delete, external-change conflict dialog; import of `.md`, `.prompt`, `.prompty`; first-run tour. | Create → edit → rename → restore round-trips on disk (integration test on a temp library). An external write during an unsaved edit shows the conflict dialog (presentation-model test). |
| M4 | Assistant | Provider settings and test connection; model picker; secret store on both OSes; transport with the §7.1 rules; write, review, improve with structured output, validation, merge rule, diff, accept/reject, provenance; Settings: Assistant. | Stub-transport tests pass for both protocols and every §7.2 stop reason. A test scans the repo, config dir, and data dir after saving a key and finds it nowhere. Owner-run: write, review, and improve work against Anthropic and a local Ollama (`docs/platform/assistant.md`). |
| M5 | Server | `SyncAPI` DTOs in Core; `dump-schema` → `spec/schema/` with a CI drift check; fixtures for paths, canonical form, and DTOs; path validation and canonical form in Core; schema and migrations; accounts, devices, groups, memberships, invites, audit events; prompts API with compare-and-swap, revisions, moves; per-scope pull with snapshot mode; `database_id`; login backoff; admin CLI; backups; compose.yaml, .env.example, update.sh, Caddyfile; ghcr publishing; compose smoke job. | Server tests cover every §8.2 matrix row, every §8.3 response code, and every §8.4 rule: compare-and-swap ordering, per-scope visibility, snapshot triggers, path validation, canonical form. Compose smoke passes in CI (up, health, login, push, pull). `shellcheck update.sh` clean. Owner-run: `./update.sh` on a fresh host brings it up healthy and keeps the `tls` profile on re-run. |
| M6 | Sync client | `SyncService` and state (§9.2); sign-in, devices, sign-out; first sync and adoption (§9.4); personal sync; group folders; viewer read-only; canonical form; conflicts, `Conflicts/`, and the resolve view; error states; scope moves by drag or folder move; invites (the `monkeyspaw://` scheme on both OSes; owners create and manage members); Settings: Account; sync status in the footer. | Every §13.1 scenario passes against the in-process server. Owner-run: two devices and two users share a group prompt through the deployed server. |
| M7 | Desktop polish | The repeat action; X11 terminal detection; optional clipboard restore; Settings: Delivery; the update check (Vervellum `Core/Updates`); flatpak; SECURITY.md, PRIVACY.md, CICD.md, per-platform READMEs. | The owner-run matrix passes on macOS, GNOME, KDE, and X11. |
| M8 | Android foundation | `android/` Gradle root (§10.8); `:core` Kotlin port of format, grammar, render, validator, canonical form, path rules, ranking; Library, Fill, and Editor screens over app-private storage; seeds; tile, launcher shortcut, widget → fill → copy (§10.4 B); ci.yml `android` job; release.yml APK job; `sync-android-version.sh`. | `:core` tests consume every `spec/fixtures/` case that M2 and M5 created. CI green (`:core:test testDebugUnitTest lintDebug assembleDebug assembleRelease`). Owner-run: tile → fill → copy → paste works in Chrome, the ChatGPT and Claude apps, and Termux (`docs/platform/android.md`). |
| M9 | Android insertion | The picker IME with the Compose bridge, `inputType` rules, and switch-back; the text-selection action; the share target; onboarding (enable keyboard, add tile). | JVM tests for the `inputType` decision table and the selection-field choice. Owner-run on Android 14-16 plus one device below API 34, with Gboard and Samsung Keyboard: the IME inserts into the same apps as M8; multi-line into Termux offers Copy instead. |
| M10 | Android sync | The Kotlin `SyncEngine` (§9 semantics), Keystore secret store, WorkManager scheduling, sign-in, invites (accept), groups, viewer read-only, conflicts and the resolve view, network security config. | `sync/*.json` scenario fixtures pass in both engines. The §13.1 suite runs against the real server in CI for the Kotlin engine. Owner-run: a phone and a desktop share a group prompt. |
| M11 | Android assistant | The LLM clients (§7) in `:core`, write, review, and improve screens, provider settings, Keystore-held keys. | LLM request and response fixtures pass on both sides. Owner-run: write, review, and improve against Anthropic and Ollama. |
| M12 | v1.0 | Release notes; all artifacts (dmg, deb, flatpak, APK, server image) from one tag. | `scripts/build.sh` produces every artifact it can on the build host. The owner pushes `v1.0.0`. |

**Ordering.**

- M1 is risk-first: proven delivery before features.
- M5 depends only on M2's format code and can run in parallel with M3 and
  M4.
- M6 needs M5 and M4's `SecretStore` drivers, which hold the device token.
- M8 needs M2's fixtures and can run in parallel with M3-M7. It closes only
  once M5's canonical-form, path, and DTO fixtures exist.
- M10 needs M5, and benefits from M6, whose Swift engine is the reference.
- M11 needs M4.
- M12 closes v1 once M7 through M11 are done.

Deferred after v1. Each item is additive, and none needs a format change:

| Area | Deferred items |
|---|---|
| Fields | checkbox fields; optional sections; `{{> include}}`; modifiers |
| Built-ins | `{{selection}}`; `{{cursor}}` |
| Delivery | opt-in typing mode; a GNOME Shell extension for Wayland terminal detection |
| Assistant | streaming; a provider fallback chain; an eval bank |
| Server | a web admin UI; end-to-end encryption; collections inside groups; Litestream |
| Android | a key grid inside the IME for free-text fields; accessibility auto-paste (opt-in); a user-visible library folder (SAF mirror); group administration on the phone |
