# Monkey's Paw

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Latest release:** v<!-- version -->1.0.0<!-- /version --> · [Download](https://github.com/L-K-M/MonkeysPaw/releases/latest)

Pick a Markdown prompt, fill its placeholders and deliver the result. Native
macOS and Linux apps paste into your current field; Android offers a picker
keyboard and Copy entry points. An optional Assistant writes/reviews prompts.
You can host your own sync server.

![macOS prompt picker with a prompt list and Wish Card preview](docs/screenshots/picker-macos.png)

**Before desktop launch:** automatic stable-release checks default on. GitHub
receives your IP and app version, without prompts or account details. Turn
checks off in Settings → General; Check Now works while off. Updates open a
release page for you to install yourself. Read [Privacy](PRIVACY.md) and
[Security](SECURITY.md), including credential tiers and signing limits.

## Install

Download each artifact with its checksum from
[Releases](https://github.com/L-K-M/MonkeysPaw/releases), verify it, then follow
your guide:

| Platform | Install and setup |
|---|---|
| macOS 14+ | [dmg/zip, Accessibility and menu-bar app](README.mac.md) |
| GNOME | [Portal or explicit native fallback shortcuts](README.gnome.md) |
| KDE Plasma | [Native/portal shortcut choice and paste](README.kde.md) |
| Linux X11, wlroots or Flatpak | [deb/bundle installation and limits](README.linux.md) |
| Android API 26+ | [APK, keyboard, tile, selection and share](README.android.md) |

macOS packaging is ad-hoc signed by default, without notarization. Android
uses a committed **public signing key**: the signature does not establish
publisher identity. Flatpak grants read/write access to your whole home.

## First hotkey

On desktop, start the app and use Setup to assign and verify the picker
shortcut. **Ctrl+Alt+P** (Control+Option+P on macOS) is the default/suggestion;
Linux registration depends on your desktop. Search and choose with Return,
fill fields and deliver. Multiline Return edits text; use the platform guide's
delivery shortcut. Copy keeps the result for manual paste. Repeat starts
unbound; assign it in Settings → Shortcuts.

Your default library is Documents/MonkeysPaw. Use Library to create and edit
prompts or General to choose a folder. See the
[prompt format](docs/plan/05-prompt-library.md) and
[shared fixtures](spec/README.md).

## Host the sync server

Follow the [Docker Compose hosting, TLS and backup guide](docs/platform/server.md#host-the-sync-server).
The operator can read server prompts and backups; there is no end-to-end
encryption. Desktop Account, invite handling, sync status, groups and conflict
resolution are available on main. Automated device-token privacy fixtures
passed native CI. The [desktop sync guide](docs/platform/sync.md) records the
automated proof and open checks of deployed servers, signed installations,
real keyrings and physical devices, which remain M6 Y34 work.
Android implements optional server sign-in, explicit-consent invite
acceptance, groups with viewer read-only access, conflict resolution and
WorkManager background sync. Phone/desktop acceptance remains open in the
[M10 checklist](docs/platform/android.md#android-sync-m10-not-run-owner),
tracked in [PLAN.md](PLAN.md).

## Troubleshooting

For paste failures, use the copied result, correct permissions/tools and run
**Test paste** to reset failed backends. Tool exit status alone does not prove
receipt. Follow your platform guide above, the [Assistant checklist](docs/platform/assistant.md),
[Android checklist](docs/platform/android.md) or [server procedures](docs/platform/server.md).
Read [Security](SECURITY.md) for trust boundaries and signing limits.

[Builds and releases](CICD.md) describes local prerequisites, CI and artifacts;
`scripts/build.sh --install` builds and installs from source.
The [M7 acceptance ledger](docs/platform/m7-acceptance.md) starts entirely
NOT RUN; code and green automated checks do not close owner acceptance.

## License

Monkey's Paw's own code is released under the [Unlicense](LICENSE). The builds
bundle third-party code that keeps its own licenses: the desktop apps bundle
Yams with its vendored libyaml (MIT) and tables generated from the Unicode
Character Database (Unicode License v3), and the Linux packages add the
statically linked Swift runtime and ICU (Unicode License v3). The Android app
bundles AndroidX, Jetpack Compose, Kotlin, Dagger/Hilt, OkHttp and ICU4J
libraries (mostly Apache-2.0; ICU4J under the Unicode License v3), plus OkHttp's
copy of the Public Suffix List (MPL-2.0). The server image adds the server's
Swift packages, including swift-crypto and swift-nio-ssl with their copies of
BoringSSL (Apache-2.0; OpenSSL, ISC and MIT licenses), and the system packages
it installs. Their notices ship inside each artifact:

- macOS: `MonkeysPaw.app/Contents/Resources/Third-Party-Notices.txt`, linked
  from About Monkey's Paw
- Linux packages: `Third-Party-Notices.txt` and `copyright` in
  `/usr/share/doc/monkeyspaw/` (Flatpak: `/app/share/doc/monkeyspaw/`)
- Android: Settings > Open-source licenses
- Server image: `/usr/share/doc/monkeyspaw-server/Third-Party-Notices.txt`;
  system packages keep their notices in `/usr/share/doc/*/copyright`

The Unlicense covers Monkey's Paw's own code only. The upstream license texts
under `docs/licenses/`, `scripts/licenses/`, `packaging/licenses/`,
`server/licenses/` and `android/app/config/licenses/` belong to the components
they name, and the Gradle wrapper (`android/gradlew`, `android/gradlew.bat`,
`android/gradle/wrapper/gradle-wrapper.jar`) is Gradle's, under Apache-2.0.
