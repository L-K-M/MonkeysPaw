## 14. Repository, packaging, CI, release

Follows `lkm-project-conventions`. This section describes the end state.
Rollout by milestone:

| Milestone | Pipeline added |
|---|---|
| M0 | ci.yml: Core tests (macOS + Linux), Linux app build (`swift:6.4-noble`), macOS app build (Xcode 26), server build + tests, server image build (`push: false`) with a `/api/health` check |
| M1 | linux.yml: GTK lifecycle under Xvfb, driver fakes, GDBus mock-bus tests |
| M2 | release.yml: dmg (universal) + deb; scripts/build.sh |
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
  and the README marker are the committed version. CI derives the deb
  version, the server `VERSION` build arg, and the image tags from the git
  tag.
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
  - Linux jobs run in the `swift:6.4-noble` container. The Linux Core test
    job is the portability gate.
  - The flatpak job runs on the bare runner, because bwrap needs a sysctl
    that a container cannot set (Vervellum).
- **release.yml.**
  - Trigger: tag `v*`. Gated on tests.
  - The draft release is published only after every job uploads:
    - macOS: a universal `.dmg`, plus `.zip` (Vervellum).
    - Linux: a `.deb` built by `packaging/build-deb.sh` with
      `--static-swift-stdlib` and `dpkg-shlibdeps`.
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
- **Linux floor.** Ubuntu 24.04+ (GTK 4.14), like Vervellum; the deb is
  built on noble. Ubuntu 22.04 (GTK 4.6) is Q8.
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
