# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `scripts/build.sh --install` installs what the run built: the macOS app,
  the deb or (when the deb is not targeted) the Flatpak bundle, and the APK on
  the connected device.

### Changed

- Compose runs only the sync server behind your existing HTTPS proxy.
  Removed bundled Caddy and added Nginx Proxy Manager network/setup guidance.
- Local macOS builds no longer need create-dmg. Without it, the dmg has the
  app and the Applications link but no window layout. CI still requires it.

### Fixed

- macOS packaging checks the universal slices with `lipo -archs`; Xcode 27's
  `lipo` rejected the multi-arch `-verify_arch` form and failed the build.

## [1.0.0] - 2026-10-20

### Added

- macOS 14+ menu-bar app and Linux GTK app with global shortcuts, a searchable
  prompt picker, fill forms with live preview, remembered fields, paste and Copy.
  Setup and Test paste help configure permissions and delivery backends.
- Desktop Library with folders, tags and favourites; a Markdown editor with
  validation and field inspection; local history and restore; rename, move and
  delete; external-edit conflict handling; and `.md`, `.prompt` and `.prompty`
  import. First-run setup offers a library folder, starter prompts and a tour.
- Assistant on desktop and Android: write, review and improve prompts with
  Anthropic or an OpenAI-compatible provider, including Ollama. Provider
  settings, connection tests, validated drafts, diffs and explicit acceptance
  keep generated changes under your control.
- Optional self-hosted sync server with accounts, devices, owner/editor/viewer
  groups, invites, prompt revisions, admin commands, Docker Compose deployment
  with HTTPS, and backup/restore tools.
- Personal and group sync on macOS, Linux and Android, with Account settings,
  explicit invite acceptance, sync status, viewer read-only access and conflict
  resolution. Desktop group administration manages memberships and invites;
  Android adds WorkManager background sync.
- Android API 26+ app with a searchable Library, Markdown editor, history,
  starter prompts and fill-to-Copy. Quick Settings tile, launcher shortcut and
  widget open the picker; a picker keyboard, text-selection action and text
  share target provide additional insertion and capture paths.
- Release packaging for universal Apple Silicon/Intel macOS dmg and zip,
  Ubuntu 24.04+ amd64 deb, x86_64 Flatpak and Android APK, with SHA-256 manifests.
- The implementation plan and design record in `PLAN.md` and `docs/plan/`.
- M0a foundation: repository guidance, shared Swift Core with Yams, portable
  logging and identity, server health endpoint and CLI, Dockerfile, and CI.

### Changed

- Desktop delivery adds Repeat with its own initially unbound shortcut,
  Linux Standard/Terminal paste choices and optional previous-text clipboard
  restore, off by default. Restore has timing and simultaneous-copy
  [limits](PRIVACY.md#forget-repeat-and-clipboard).
- Desktop stable-release checks default on and send GitHub your IP and app
  version. Turn off automatic checks or use Check Now in Settings → General.
  View release opens a browser; download and install updates yourself.

### Security

- Saved credentials use macOS Keychain, Linux Secret Service or Android
  Keystore-backed encryption. Linux has a labelled **unencrypted** file tier
  when `secret-tool` is absent; a failing installed service does not authorize
  a plaintext downgrade. See [credential storage](SECURITY.md#credentials).
- Assistant requests require an explicit action; remembered field values and
  rendered previews are not automatically sent. `private: true` blocks Review
  and Improve, but does not exclude personal prompts from optional sync.
  Synced prompts and server backups are readable by the operator; there is no
  end-to-end encryption. See [Privacy](PRIVACY.md).
- Android APKs use the committed **public signing key**, which does not prove
  publisher identity. Obtain APKs from this repository's releases; see the
  [signing decision](docs/decisions/0001-android-zero-secret-signing.md).

### Installation and known limits

- Download the platform artifacts with their checksum files and verify them
  before installing or replacing an existing copy. Follow the
  [macOS](README.mac.md#install-and-open), [Linux](README.linux.md) or
  [Android](README.android.md#install-or-update) guide. Android updates are
  manual; the app has no automatic release checker.
- macOS builds are ad-hoc signed and **not notarized**. Drag the app to
  Applications. If Gatekeeper blocks a trusted download, use System Settings →
  Privacy & Security → Open Anyway when offered. Grant Accessibility in Setup;
  replacing the app may require a renewed grant.
- Flatpak requires GNOME Platform 50 and grants read/write access to your whole
  home. Its library must stay under home, including symlink targets; its state
  is separate from native installs. Keep one active installation route per user.
  Install updates by replacing the verified bundle; it has no app update feed.
  See the [Flatpak guide](README.linux.md#flatpak).
- Wayland shortcut/paste support depends on actual portal capabilities,
  permissions and desktop tools. Copy is the fallback; Linux relies on
  compositor refocus, and Wayland cannot detect terminals. Flatpak uses
  portal → Copy, without native input injection or host autostart. Follow the
  [GNOME](README.gnome.md), [KDE](README.kde.md) or [Linux](README.linux.md) guide.
- Android's picker keyboard does not type free text and hides prompts in
  password fields. Unsupported insertion cases offer Copy; background sync can
  be delayed by Android. Group administration remains on desktop. See the
  [Android guide](README.android.md).
- The release workflow builds and smoke-tests the server image, but publishes
  **no registry image**. Self-hosters build locally with
  `scripts/build.sh server-image` and follow the
  [hosting and backup guide](docs/platform/server.md#host-the-sync-server).
- Required owner acceptance checks remain open for real desktop/device
  installation, permissions, focus, accessibility, providers, deployed sync
  and backup/restore. This release preparation does not establish acceptance;
  see the [v1.0 sign-off ledger](docs/platform/m12-acceptance.md).

[Unreleased]: https://github.com/L-K-M/MonkeysPaw/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/L-K-M/MonkeysPaw/releases/tag/v1.0.0
