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
- **Seeds.** Edit the Markdown under `seed/`, then run
  `python3 scripts/generate-seeds.py` and commit the generated Core catalog
  alongside the sources. The standard-library-only generator excludes root
  `seed/README.md` using §5.1's library rules. Core tests compare every
  embedded path and byte with the eligible files; no packaging resource step
  is needed on macOS or Linux (§4.4).
- **ci.yml.**
  - Also callable with `workflow_call`: release runs use the same test gates
    from the tagged commit. Concurrency includes the caller workflow name,
    so a release's test run cannot cancel ordinary PR CI.
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
  - The existing server job builds/tests the server package, then runs
    `swift run --package-path server dump-schema` into a temporary directory.
    `diff -ru spec/schema "$schema_dir"` fails on any changed, missing or
    extra file, including the generated README and untracked files. The
    directory is removed on exit; schema rendering needs no database, GTK
    or network. Regeneration instructions and contract annotations live in
    [spec/schema/README.md](../../spec/schema/README.md).
  - The `deb` job builds a fixed prerelease, inspects control fields and
    installed paths, requires noble's `libglib2.0-0t64` plus
    `libglib2.0-bin`, rejects dynamic Swift/Foundation dependencies, installs
    with apt, and checks the installed binary's version.
  - The flatpak job runs on the bare runner, because bwrap needs a sysctl
    that a container cannot set (Vervellum).
- **release.yml.**
  - Trigger: tag `v*`, or `workflow_dispatch` with `dry_run` defaulting to
    true. PRs touching packaging, `server/**` or the release workflow run
    the dry-run path too. Every path first calls `ci.yml`, then checks
    committed versions. A real tag's numeric
    core must equal the committed `MARKETING_VERSION` and README marker;
    `python3 scripts/check-version.py --check-tag v0.1.0` enforces this.
    Release tags use `vX.Y.Z[-prerelease]`; build metadata (`+...`) is
    rejected before packaging because the macOS packager does not accept it.
    Branch/PR dry runs use the committed version. A manual publish requires
    selecting an existing `v*` tag and setting `dry_run` to false.
  - Concurrency is `release-${{ github.ref }}`, without cancellation.
    Workflow permissions are `contents: write`; every build/verification
    job reduces these to `contents: read`. Only GitHub publishing keeps
    `contents: write`; only image publishing gets `packages: write`, with
    `contents: read`. Actions are SHA-pinned, checkouts do not persist
    credentials, and each runner job has a timeout.
  - The draft release is published only after all build and verification
    gates pass and the server image tags are promoted and verified. Server
    images are ghcr objects, never a sixth release asset. Release assets:

    - macOS: a universal `.dmg`, plus `.zip` and their `.sha256` manifest.
    - Linux: a `.deb` built by `packaging/build-deb.sh` with
      `--static-swift-stdlib` (plus `--build-system native` until swift-build
      links static Foundation; §16) and `dpkg-shlibdeps`, plus `.deb.sha256`.
    - Flatpak: repacked from the deb (from M7).
  - In M2 the Linux job runs first; the macOS job `needs` it, so a broken
    deb fails the tag before a release exists. Native server image builds
    run alongside macOS packaging after the Linux and version gates;
    flatpak joins in M7.
  - Server image builds run natively on `ubuntu-24.04` (amd64) and hosted
    `ubuntu-24.04-arm` (arm64), without QEMU/binfmt. Each passes `VERSION`,
    `REVISION` (commit SHA) and `CREATED` (commit timestamp), checks OCI
    labels, then smoke-tests container health and `/api/health` 200 with a
    throwaway admin password file mounted as a secret. OCI archives and
    digests use separate workflow artifacts outside `MonkeysPaw-release-*`.
  - Image publishing requires tests, verify, Linux, macOS, artifacts and
    both native image builds. It pushes untagged digests, creates a
    multiarch manifest and verifies exactly amd64 and arm64 with the
    expected digests for each tag before GitHub publishing can run. This
    ordering keeps a failed image publish from undrafting the release;
    a later GitHub failure can leave verified image tags published.
    The owner must make the first, initially private ghcr package public.
    `update.sh` still builds the repo-owned image locally (§8.6).
  - macOS builds are ad-hoc signed (`codesign --sign -`) unless Q3 provides
    an identity. Signing env is exported only when the secrets are
    non-empty (Obtainintosh lesson).
  - Stable `vX.Y.Z` tags publish image tags `X.Y.Z`, `X.Y` and `latest` at
    `ghcr.io/l-k-m/monkeyspaw-server`. Hyphenated tags are prereleases and
    publish only the exact version image tag, never `X.Y` or `latest`.
  - Each desktop packaging job downloads its workflow artifact and byte-compares
    every file, including checksums, against the originals. An assembly job
    requires all five assets and checks both manifests. The publish job
    creates a draft with all five assets, downloads every release asset and
    byte-compares against those verified build outputs before undrafting.
    Any failure leaves the release unpublished. PRs and manual dry runs do
    every build and workflow-artifact verification, including both image
    smoke tests, and skip both publish jobs without logging in to ghcr.
  - To cut the first release after CI and owner installation checks pass,
    run `scripts/release.sh 0.1.0 --push` on current main with the shared
    `lkm-release` engine installed. It bumps committed versions and pushes
    the release commit and `v0.1.0` tag. CI derives the artifact version from
    `${GITHUB_REF_NAME#v}` without modifying committed settings. See `CICD.md`.
  - Deb `Depends:` comes from `dpkg-shlibdeps` (Ubuntu 24.04's t64 renames),
    plus `libglib2.0-bin`. `Recommends:` `libsecret-tools`, `ydotool`,
    `xdotool`. Prerelease versions use a tilde (every prerelease hyphen
    becomes `~`), so they sort below the release; dpkg compares digit runs
    numerically (`~beta.9` < `~beta.10`).
- **macOS packaging.** On a Mac with Xcode and `brew install create-dmg`,
  run `scripts/package-macos.sh [version [build-number]]`. It calls
  `xcodebuild` directly so packaging does not need the external `lkm-build`
  engine used by `scripts/build.sh app`. Release builds use
  `ONLY_ACTIVE_ARCH=NO` and `ARCHS="arm64 x86_64"`. Without arguments, versions
  come from the committed project settings; an explicit version overrides
  `MARKETING_VERSION`, and a second argument overrides `CURRENT_PROJECT_VERSION`.
  Tag CI can pass
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
    `dist/MonkeysPaw-<version>.sha256` records both files; download all three
    together and run `shasum -a 256 -c MonkeysPaw-<version>.sha256` before
    installation (`docs/platform/macos.md`).
- **Local build orchestration.** `scripts/build.sh [mac|deb ...] [--no-open]`
  builds every artifact this host can produce by default. An unavailable
  toolchain skips a default target but fails an explicitly named target.
  Outputs go to `dist/`, followed by one Summary block. On macOS it opens
  `dist/` when an artifact was built, unless `--no-open` was passed.
  `mac` calls the packager above; `deb` calls the builder below with the
  committed version. `scripts/build.sh app [lkm-build flags]` preserves the
  app-only engine path, including `--clean`, `--debug`, `--run`, `--install`,
  `--zip` and `--dmg`. Server and APK targets arrive in later milestones.
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
  `dist/monkeyspaw_<deb-version>_<architecture>.deb` and its `.deb.sha256`
  checksum. Regenerate the committed 16, 24, 32, 48, 64, 128, 256 and 512 pixel
  PNGs from `media-sources/icon.png` with `scripts/make-linux-icons.sh` (Python 3 and
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
