## 14. Repository, packaging, CI, release

Follows `lkm-project-conventions`. This section describes the end state.
Rollout by milestone:

| Milestone | Pipeline added |
|---|---|
| M0 | ci.yml: Core tests (macOS + Linux), Linux app build (`swift:6.4-noble`), macOS app build (Xcode 26), server build + tests, server image build (`push: false`) with a `/api/health` check |
| M1 | ci.yml `linux-app` job: GTK lifecycle under Xvfb, driver fakes, GDBus mock-bus tests |
| M2 | ci.yml: macOS artifact proof; release.yml: dmg (universal) + zip + deb; scripts/package-macos.sh |
| M5 | server image publish to ghcr; compose config check and compose smoke job; `spec/schema/` drift check |
| M7 | flatpak repack and release upload |
| M8 | ci.yml `android` job (wrapper validation, `:core:test`, unit tests, lint, debug + release assemble); release.yml APK job; dependabot `gradle` for `/android` |

- **README.md.** The LLM disclosure callout, then the version marker.
  Sections: install, the first hotkey, hosting a server (the compose
  walkthrough), troubleshooting. Per-platform notes go in `README.android.md`, `README.mac.md`,
  `README.gnome.md`, and `README.kde.md`.
- **Agent and repo furniture.**
  - `AGENTS.md`: the repo brief (build/test commands, the portability rule,
    GLib/main-actor traps, the paste/window footguns from §6, the layering
    rule) plus the canonical shared-rules block.
  - `CLAUDE.md`: copied verbatim from a peer repo.
  - `CHANGELOG.md`: Keep a Changelog.
  - `CICD.md`: workflows, the tag → release flow, the ghcr notes.
  - `.github/dependabot.yml`: swift, docker, github-actions, and `gradle`
    for `/android`, with the androidx and kotlin+ksp groups.
  - `zai-code-review.yml`: copied byte-identical. It reviews from the PR
    after the one that adds it.
- **Identifiers.** macOS bundle `ch.lkmc.MonkeysPaw`; Linux and flatpak app id
  `ch.lkmc.monkeyspaw`; binary `monkeyspaw`; server image `monkeyspaw-server`.
  Product name `MonkeysPaw`, display name "Monkey's Paw" (Q5).
- **Versioning.** `RELEASE_KIND=xcode` (Vervellum stub): `MARKETING_VERSION`
  and the README marker are the committed version. Release CI derives the
  macOS artifact version, the deb version, the server `VERSION` build arg,
  and the image tags from the git tag without editing committed settings.
  `python3 scripts/check-version.py` checks that every `MARKETING_VERSION`
  agrees with the single README marker and verifies `v0.1.0` → `0.1.0` and
  `v0.1.0-beta.1` → `0.1.0~beta.1`. Packaging injects the tag's app version
  into a temporary Swift source file for `monkeyspaw --version`; it removes
  the file on exit. `AppIdentity.fallbackVersion` is the development-build
  value only. The deb's tilde does not change the binary's hyphenated version.
- **Toolchains.** Linux CI uses `swift:6.4-noble`, the same image as the
  server builder. macOS uses Xcode 26.x, pinned in workflows. Swift tools
  version 5.9 manifests keep Swift 5 language mode for desktop targets
  (D15).
- **Dependencies.** Desktop: Yams only. Server: Hummingbird,
  hummingbird-auth (bcrypt), hummingbird-fluent, fluent-sqlite-driver. All
  are pinned with `Package.resolved` committed.
- **ci.yml.**
  - The hardening trio: `permissions: contents: read`, concurrency that
    cancels superseded PR runs only, and `timeout-minutes` on every job.
  - Actions are pinned to commit SHAs, with `persist-credentials: false`.
  - macOS job: `macos-26`, with Xcode pinned.
  - `macos-artifacts` builds Release artifacts with test version `0.1.0`
    and build number `42` on PRs and main, using Xcode 26.0 and system
    `/bin/bash` for the script and shell checks. It checks both architectures,
    strict code signatures, bundle versions and `LSUIElement`,
    mounts the dmg read-only, checks the app and `/Applications` link,
    extracts the zip and compares the app contents. Each packaged copy must
    stay alive for five seconds before termination; the image is detached.
    Both artifacts are uploaded for three days. Hosted tests remain in
    `macos-app`; this gate does not prove Gatekeeper, real installation or
    delivery on a Mac (§15 and `docs/platform/macos.md`).
  - Linux jobs run in the `swift:6.4-noble` container. The Linux Core test
    job is the portability gate.
  - The `deb` job builds a fixed prerelease, inspects control fields and
    installed paths, requires noble's `libglib2.0-0t64` plus
    `libglib2.0-bin`, rejects dynamic Swift/Foundation dependencies, installs
    with apt, and checks the installed binary's version.
  - The flatpak job runs on the bare runner, because bwrap needs a sysctl
    that a container cannot set (Vervellum).
- **release.yml.**
  - Trigger: tag `v*`. Gated on tests.
  - The draft release is published only after every job uploads:
    - macOS: a universal `.dmg`, plus `.zip` (Vervellum).
    - Linux: a `.deb` built by `packaging/build-deb.sh` with
      `--static-swift-stdlib` (plus `--build-system native` until swift-build
      links static Foundation; §16) and `dpkg-shlibdeps`.
    - Flatpak: repacked from the deb (from M7).
    - Server: the ghcr image (from M5).
  - The Linux and server jobs run first; the macOS job `needs` them, so a
    broken deb fails the tag before a release exists (Vervellum).
  - macOS builds are ad-hoc signed (`codesign --sign -`) unless Q3 provides
    an identity. Signing env is exported only when the secrets are
    non-empty (Obtainintosh lesson).
  - Hyphenated tags are prereleases and never `latest`.
  - Uploaded assets are downloaded back and byte-compared (Vervellum).
  - Deb `Depends:` comes from `dpkg-shlibdeps` (Ubuntu 24.04's t64 renames),
    plus `libglib2.0-bin`. `Recommends:` `libsecret-tools`, `ydotool`,
    `xdotool`. Prerelease versions use a tilde.
- **macOS packaging.** On a Mac with Xcode and `brew install create-dmg`,
  run `scripts/package-macos.sh [version [build-number]]`. It calls
  `xcodebuild` directly so CI does not need the external `lkm-build` engine
  used by `scripts/build.sh`. Release builds use `ONLY_ACTIVE_ARCH=NO` and
  `ARCHS="arm64 x86_64"`. Without arguments, versions come from the committed
  project settings; an explicit version overrides `MARKETING_VERSION`, and
  a second argument overrides `CURRENT_PROJECT_VERSION`. Tag CI can pass
  `"${GITHUB_REF_NAME#v}"` and `"$GITHUB_RUN_NUMBER"`; prerelease suffixes stay
  in artifact names while the bundle marketing version uses `X.Y.Z`.
  - The app is signed ad-hoc by default, with Hardened Runtime and the
    committed Apple Events entitlement. A non-empty
    `MACOS_SIGNING_IDENTITY` selects an identity already installed in the
    caller's keychain; a non-empty `MACOS_SIGNING_KEYCHAIN` optionally
    selects that keychain. Certificate import and notarization are outside
    this script. CI must export signing variables only when their secrets
    are non-empty; the artifact proof job needs no signing secrets.
  - `ditto -c -k --keepParent` produces `dist/MonkeysPaw-<version>.zip`.
    `create-dmg` receives a staging folder containing `MonkeysPaw.app` and
    adds the `/Applications` link, producing
    `dist/MonkeysPaw-<version>.dmg`. CI skips Finder styling with
    `--skip-jenkins`. A nonzero `create-dmg` status is tolerated only if a
    newly created image exists and passes `hdiutil verify`; stale output
    cannot satisfy this check. Only verified artifacts are copied to `dist/`.
- **Linux floor.** Ubuntu 24.04+ (GTK 4.14), like Vervellum; the deb is
  built on noble. Ubuntu 22.04 (GTK 4.6) is Q8.
- **Building a Linux deb locally.** On Ubuntu 24.04 with Swift 6.4, install
  `libgtk-4-dev pkg-config python3 dpkg-dev binutils desktop-file-utils`,
  then run `packaging/build-deb.sh 0.1.0` from any directory (or omit the
  argument when `GITHUB_REF_NAME` contains the tag). Set `SWIFT` to another
  Swift executable, such as `/home/paseo/.local/bin/swift64` on the Paseo
  host. Building and packing need no root; installing dependencies and the
  resulting deb do. The host cannot resolve noble's dpkg library metadata
  or install with apt; the `deb` CI job is the installability proof.
  The script builds release mode with `--static-swift-stdlib` and
  `--build-system native` (§16), in `build/deb-swift/` apart from development
  artifacts. It stages the binary, desktop entry, D-Bus service, eight
  hicolor icons, copyright and changelog under `build/deb/`, validates the
  desktop entry when the validator is available, and resolves `Depends:`
  with `dpkg-shlibdeps` without a fallback. It adds `libglib2.0-bin` for
  `gapplication` and recommends `libsecret-tools, ydotool, xdotool`.
  `dpkg-deb --root-owner-group` writes
  `dist/monkeyspaw_<deb-version>_<architecture>.deb`. Regenerate the
  committed 16, 24, 32, 48, 64, 128, 256 and 512 pixel PNGs from
  `media-sources/icon.png` with `scripts/make-linux-icons.sh` (Python 3 and
  Pillow; Ubuntu package `python3-pil`); macOS icons still use
  `scripts/make-icons.sh`.
- **Flatpak.** Runtime `org.gnome.Platform` 50. `finish-args`:
  - `--share=ipc` (X11/MIT-SHM; the Vervellum pairing)
  - `--share=network` (LLM, sync)
  - `--socket=wayland --socket=fallback-x11`
  - `--talk-name=org.freedesktop.secrets`
  - `--talk-name=ca.desrt.dconf --filesystem=xdg-run/dconf --filesystem=xdg-config/dconf` (GNOME keybindings)
  - `--filesystem=home` (a user-chosen library)

  CI asserts that `secret-tool` and `gsettings` exist in the runtime.
  Documented limits:
  - ydotool is unreachable from the sandbox.
  - Autostart from inside the sandbox does not register with the host.
  - The library must be under `$HOME`.
