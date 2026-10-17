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
  Sections: install, the first hotkey, hosting and troubleshooting links.
  The compose walkthrough and backup instructions live in
  [docs/platform/server.md](../platform/server.md#host-the-sync-server).
  Per-platform setup lives in [README.android.md](../../README.android.md),
  [README.mac.md](../../README.mac.md), [README.gnome.md](../../README.gnome.md),
  [README.kde.md](../../README.kde.md) and [README.linux.md](../../README.linux.md)
  (X11/wlroots/Flatpak). README discloses default-on update traffic before
  launch and links [SECURITY.md](../../SECURITY.md), [PRIVACY.md](../../PRIVACY.md)
  and [CICD.md](../../CICD.md).
- **Agent and repo furniture.**
  - `AGENTS.md`: the repo brief (build/test commands, the portability rule,
    GLib/main-actor traps, the paste/window footguns from §6, the layering
    rule) plus the canonical shared-rules block.
  - `CLAUDE.md`: copied verbatim from a peer repo.
  - `CHANGELOG.md`: Keep a Changelog.
  - `CICD.md`: workflows, the tag → release flow, the ghcr notes.
  - [M7 acceptance ledger](../platform/m7-acceptance.md): exact main/artifact
    and owner-session evidence, initially NOT RUN. CI does not prove real
    focus, consent, clipboard or installed-browser behavior. The owner must
    enable GitHub private vulnerability reporting before release (§21 G23).
    Earlier owner NOT RUN rows remain; D20 records actual results on main.
  - `.github/dependabot.yml`: swift, docker, github-actions, and `gradle`
    for `/android`, with the androidx and kotlin+ksp groups.
  - `zai-code-review.yml`: copied byte-identical. It reviews from the PR
    after the one that adds it.
- **Identifiers.** macOS bundle `ch.lkmc.MonkeysPaw`; Linux and flatpak app id
  `ch.lkmc.monkeyspaw`; binary `monkeyspaw`; server image `monkeyspaw-server`.
  Product name `MonkeysPaw`, display name "Monkey's Paw" (Q5).
- **Versioning.** `RELEASE_KIND=xcode` (Vervellum stub): `MARKETING_VERSION`
  and the README marker are the committed numeric `X.Y.Z` version. The
  `RELEASE_POST_BUMP=scripts/sync-android-version.sh` hook uses
  `RELEASE_NEW_VERSION` to align Android's committed `versionName` and
  increment its positive Int `versionCode` once per changed version. An
  aligned retry is a no-op; validation and overflow failures edit nothing.
  Release CI derives the macOS artifact version, the deb version, the server `VERSION` build arg,
  and the image tags from the git tag without editing committed settings.
  `python3 scripts/check-version.py` checks that every `MARKETING_VERSION`
  agrees with the single README marker and Android's numeric `versionName`,
  requires a single literal positive Int `versionCode`, and verifies
  `v0.1.0` → `0.1.0` and `v0.1.0-beta.1` → `0.1.0~beta.1`.
  Packaging injects the tag's app version
  into a temporary Swift source file for `monkeyspaw --version`; it removes
  the file on exit. `AppIdentity.fallbackVersion` is the development-build
  value only. The deb's tilde does not change the binary's hyphenated version.
  Android packaging injects the full validated `X.Y.Z[-prerelease]` via
  Gradle's `releaseVersion` property without changing source or the committed
  code. Stable tags match exactly; prerelease tags match by numeric core.
  APK names and packaged `versionName` retain the suffix; code never comes
  from a CI run number. Repeated same-core prereleases require increasing
  committed codes and engine support before owner use (§20 F20).
- **Desktop update checks (M7, §21 G16/G17).** All desktop installs,
  including betas, check only the stable GitHub `releases/latest` endpoint
  through the shared `HTTPTransporting` default Assistant policy (§12).
  Compare strict `vX.Y.Z[-prerelease]` tags with the full installed version:
  numeric prerelease identifiers sort numerically, and a stable release
  sorts above its same-core beta. Ignore drafts/prereleases and all response
  URLs/assets/notes. Missing/invalid versions are typed unavailable results,
  never a guessed `0.0.0`; unversioned development/tests skip traffic.
  The Linux composition root injects its packaged hyphenated app version.
  macOS adds/reads `MonkeysPawReleaseVersion` in every packaged plist before
  signing, retaining numeric `CFBundleShortVersionString`; source builds
  may supply a declared version, without guessing a discarded suffix.
  General passively shows last successful check/result and Update available.
  HTTP 404 means no stable release; malformed responses, offline, other
  transport/status errors and 403/429 rate limits remain distinct from
  up to date. Check Now bypasses automatic cadence/off, never single-flight
  or rate-limit backoff. View release alone opens a constructed URL beneath
  `https://github.com/L-K-M/MonkeysPaw/releases/tag/` through the native
  opening port. No downloader, installer, package-manager command, sudo
  or restart is part of this service. D15 is the Core contract; D17/D18
  own platform wiring/controls, and D19 owns installation/privacy text.
- **Toolchains.** Linux CI uses `swift:6.4-noble`, the same image as the
  server builder. macOS uses Xcode 26.x, pinned in workflows. Swift tools
  version 5.9 manifests keep Swift 5 language mode for desktop targets
  (D15).
- **Dependencies.** Desktop: Yams only. Server: Hummingbird,
  hummingbird-auth (bcrypt), hummingbird-fluent, fluent-sqlite-driver. All
  are pinned with `Package.resolved` committed.
- **Sync suite ownership (E34).** Only the server package declares
  `MonkeysPawSyncIntegrationTests`, with explicit Core, server-library and
  HummingbirdTesting dependencies and Swift 5 test mode. Server production
  and existing server tests remain Swift 6. The server dependency closure has
  no GTK; the root package has no server products. Root Swift and Kotlin
  conformance own ten content categories and explicitly delegate `sync/`.
  The integration suite executes every sync fixture, including all variants,
  against the real router; M10 ports the data contract and expectations.
- **Seeds.** Edit the Markdown under `seed/`, then run
  `python3 scripts/generate-seeds.py` and commit the generated Core catalog
  alongside the sources. The standard-library-only generator excludes root
  `seed/README.md` using §5.1's library rules. Core tests compare every
  embedded path and byte with the eligible files; no packaging resource step
  is needed on macOS or Linux (§4.4).
- **ci.yml.**
  - A first `changes` job selects affected jobs on pull requests using
    `scripts/ci-changes.py` and a full-history checkout. The diff compares
    base and head through their merge base, with rename detection disabled
    so both the old and new paths contribute. Each build job requires
    `changes` and its own true output; its check name and commands stay unchanged.
    The server test step label identifies both server and client sync scenarios.
    Android-only PRs run `android`; app Gradle version changes also run the
    `core-linux` and `deb` version checks. Pure documentation PRs run no
    build jobs.
    `README.md` remains an input to the Linux version checks. The Android
    signing ADR selects `core-linux` for fingerprint agreement. Xcode project
    changes also run `core-linux` and `deb`. Linux source changes keep Core
    portability and server jobs enabled because the parent Swift manifest
    validates target paths and Docker copies the full source tree.
  - Core/package changes run all Swift consumers; `spec/` and `seed/` also
    run Android. Android also runs for Core's `SyncPathCaseFold.swift` table,
    which its JVM conformance tests read directly. Platform, server and
    script paths select their consumers.
    Unknown paths, `.github/workflows/`, `.github/actions/`, and the selector
    or its test enable every job. Script failures fail `changes`, never
    silently skip the gates. Pushes, manual runs and reusable calls run all
    jobs; the reusable `full-ci` input defaults to true so release PR dry
    runs also keep all gates despite retaining the caller's PR event.
    Skipped jobs retain their check identities and count as passing for
    GitHub and the supervisor's merge script. GLM review stays independent.
    Standard-library unittest coverage under `scripts/tests/` checks the
    mapping, merge-base/rename behavior, output format and workflow wiring.
  - Also callable with `workflow_call`: release runs use the same test gates
    from the tagged commit. Concurrency includes the caller workflow name,
    so a release's test run cannot cancel ordinary PR CI.
  - The hardening trio: `permissions: contents: read`, concurrency that
    cancels superseded PR runs only, and `timeout-minutes` on every job.
  - Actions are pinned to commit SHAs, with `persist-credentials: false`.
  - macOS job: `macos-26`, with Xcode pinned.
  - `macos-artifacts` builds Release artifacts with test version `0.1.0-beta.7`
    and build number `42` on PRs and main, using Xcode 26.0 and system
    `/bin/bash` for the script and shell checks. It checks both architectures,
    strict code signatures, bundle versions and `LSUIElement`,
    mounts the dmg read-only, checks the app and `/Applications` link,
    extracts the zip and compares the app contents. Each packaged copy must
    stay alive for five seconds before termination; the image is detached.
    Both artifacts are uploaded for three days. Hosted tests remain in
    `macos-app`; this gate does not prove Gatekeeper, real installation or
    delivery on a Mac (§15 and `docs/platform/macos.md`).
  - Linux Swift jobs run in the `swift:6.4-noble` container. The Linux Core test
    job is the portability gate.
  - The existing server job builds/tests the server package. Its single
    `swift test --package-path server` invocation also executes the complete
    sync corpus; no second full-suite command is added. It then runs
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
  - The Flatpak job downloads the deb job's exact tested artifact and runs
    on bare Ubuntu for bwrap's user namespaces. A bounded probe must pass;
    any temporary sysctl change is restored in always-run cleanup. It installs
    GNOME Platform/SDK 50, checks runtime ELF linking/version and tool presence,
    installs the generated bundle, and compares its binary with the deb.
    Exported desktop/service/icons, actions, MIME registration and permissions
    must match. Under a required display/private bus, installed cold/resident
    toggle/repeat and D-Bus Open/launcher fallback reach the existing invite
    review. Accessibility checks destination and enabled Accept; a loopback
    request recorder proves no launch redemption. Bearers must not persist.
    Bundle/checksum upload/download must compare byte-for-byte. Real browsers,
    portals, consent and focus remain owner-run; CI never sets a MIME default.
- **release.yml.**
  - Trigger: tag `v*`, or `workflow_dispatch` with `dry_run` defaulting to
    true. PRs touching Android, shared fixtures/seeds, packaging,
    `server/Dockerfile` or either CI/release
    workflow run the dry-run path too. Every path first calls `ci.yml`, then
    checks committed versions. A real tag's numeric core must equal the
    committed `MARKETING_VERSION`, README marker and Android `versionName`;
    `python3 scripts/check-version.py --check-tag v0.1.0` enforces this.
    Release tags use `vX.Y.Z[-prerelease]`; build metadata (`+...`) is
    rejected before packaging because the macOS packager does not accept it.
    Branch/PR dry runs use the committed version. A manual publish requires
    selecting an existing `v*` tag and setting `dry_run` to false.
  - Concurrency is `release-${{ github.ref }}`, without cancellation.
    Workflow permissions default to `contents: read`. Only GitHub publishing gets
    `contents: write`; only image publishing gets `packages: write`, with
    `contents: read`. Actions are SHA-pinned, checkouts do not persist
    credentials, and each runner job has a timeout.
  - The draft release is published only after all build and verification
    gates pass and the server image tags are promoted and verified. Server
    images are ghcr objects rather than release files. Release assets:

    - macOS: a universal `.dmg`, plus `.zip` and their `.sha256` manifest.
    - Linux: a `.deb` built by `packaging/build-deb.sh` with
      `--static-swift-stdlib` (plus `--build-system native` until swift-build
      links static Foundation; §16) and `dpkg-shlibdeps`, plus `.deb.sha256`.
    - Android: the signed R8 `monkeyspaw-v<full-version>.apk` and `.apk.sha256`.
    - Flatpak: `monkeyspaw_<full-version>_x86_64.flatpak` and `.flatpak.sha256`,
      repacked from the Linux job's exact installed/version-verified amd64 deb.
      Its bare-runner read-only job builds no Swift, verifies the GNOME 50
      runtime and installed binary, and round-trips both uploaded files.
  - In M2 the Linux job runs first; the macOS job `needs` it, so a broken
    deb fails the tag before a release exists. Native server image builds
    run alongside macOS packaging after the Linux and version gates;
    Android follows tests/version verification without waiting for Linux;
    Flatpak follows the tested release deb, alongside macOS/image packaging.
  - Server image builds run natively on `ubuntu-24.04` (amd64) and hosted
    `ubuntu-24.04-arm` (arm64), without QEMU/binfmt. Each passes `VERSION`,
    `REVISION` (commit SHA) and `CREATED` (commit timestamp), checks OCI
    labels, then smoke-tests container health and `/api/health` 200 with a
    throwaway admin password file bind-mounted read-only. OCI archives and
    digests use separate workflow artifacts outside `MonkeysPaw-release-*`.
  - Image publishing requires tests, verify, Linux, Flatpak, macOS, Android,
    artifacts and both native image builds. It pushes untagged digests, creates a
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
  - Each packaging job downloads its workflow artifact and byte-compares
    every file, including checksums, against the originals. Android also
    validates APK ID/full version/committed code/API levels and the recorded
    public signer before upload. Ordinary CI round-trips both the signed
    R8 APK pair and the Flatpak pair. An assembly job requires seven desktop assets
    plus the explicit two Android assets, exactly nine nonempty files,
    rejects missing/extra files (including hidden entries), requires exact
    payload membership in each manifest and checks all four manifests.
    Assembly and both publish jobs depend on the verified Flatpak job.
    The publish job repeats the identical asset gate, creates a draft with all
    nine assets, downloads every release asset and
    byte-compares against those verified build outputs before undrafting.
    Any failure leaves the release unpublished. PRs and manual dry runs do
    every build and workflow-artifact verification, including both image
    smoke tests, and skip both publish jobs without logging in to ghcr.
    This includes fork PRs. Both publish jobs require a tag and a true
    publish output. Release notes include Android checksum/sideload guidance
    and the public-signing disclosure alongside generated changes.
  - To cut the first release after CI and owner installation checks pass,
    run `scripts/release.sh 0.1.0 --push` on current main with the shared
    `lkm-release` engine installed. It bumps committed versions and pushes
    the release commit and `v0.1.0` tag. CI derives the artifact version from
    `${GITHUB_REF_NAME#v}` without modifying committed settings. See `CICD.md`.
    `--check` reports engine configuration without executing the hook;
    omitting `--push` still commits and tags. Test hook/commit/tag effects
    only in disposable repositories (§20 F19).
  - Deb `Depends:` comes from `dpkg-shlibdeps` (Ubuntu 24.04's t64 renames),
    plus `libglib2.0-bin`. `Recommends:` `libsecret-tools`, `ydotool`,
    `xdotool`, `x11-utils`. Prerelease versions use a tilde (every prerelease hyphen
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
- **Local build orchestration.** `scripts/build.sh [mac|deb|flatpak|android ...] [--no-open]`
  builds every artifact this host can produce by default. An unavailable
  toolchain skips a default target but fails an explicitly named target.
  Outputs go to `dist/`, followed by one Summary block. On macOS it opens
  `dist/` when an artifact was built, unless `--no-open` was passed.
  `mac` calls the packager above; `deb` calls the builder below with the
  committed version; `flatpak` reuses that invocation's exact deb, building it
  once if needed even when targets are repeated or reversed. Failed or missing
  deb output cannot reuse a stale artifact. The default builds deb then Flatpak
  once when the toolchains and user-installed GNOME 50 runtime/SDK are available;
  a named unavailable target fails. `android` calls `scripts/package-android.sh`
  with that version. `scripts/build.sh app [lkm-build flags]` preserves the
  app-only engine path, including `--clean`, `--debug`, `--run`, `--install`,
  `--zip` and `--dmg`. Server packaging remains separate.
- **Local Android packaging.** `scripts/package-android.sh [version]` builds
  `:app:assembleRelease` through `android/gradlew` with two workers. It
  requires executable wrapper/JDK 17+ tools, SDK platform `android-37.0`
  and build tools `36.0.0`; SDK downloads are disabled. `JAVA_HOME` selects
  the JDK; `sdk.dir` in `android/local.properties` takes precedence over
  `ANDROID_HOME`/`ANDROID_SDK_ROOT`. The default version is committed; an
  explicit `[v]X.Y.Z[-prerelease]` must have the same numeric core. The
  wrapper receives the normalized version as `-PreleaseVersion=...`, leaving
  the code unchanged. Outputs are `dist/monkeyspaw-v<full-version>.apk`
  and `.apk.sha256`. `--check` validates configuration without building.
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
  `gapplication` and recommends `libsecret-tools, ydotool, xdotool, x11-utils`.
  `dpkg-deb --root-owner-group` writes
  `dist/monkeyspaw_<deb-version>_<architecture>.deb` and its `.deb.sha256`
  checksum. Regenerate the committed 16, 24, 32, 48, 64, 128, 256 and 512 pixel
  PNGs from `media-sources/icon.png` with `scripts/make-linux-icons.sh` (Python 3 and
  Pillow; Ubuntu package `python3-pil`); macOS icons still use
  `scripts/make-icons.sh`.
- **Flatpak.** App id `ch.lkmc.monkeyspaw`, runtime `org.gnome.Platform` 50,
  SDK `org.gnome.Sdk` 50, command `monkeyspaw`, x86_64 only (M7 G18).
  `scripts/build-flatpak.sh <deb-path> [expected-app-version]` repacks an explicit
  tested amd64 deb. Its control metadata supplies the version; an explicit
  expected version must match. It copies `/usr` under
  `/app`, preserving executable bytes, icons and copyright, and rewrites
  only desktop/service executable paths. No Swift build runs in Flatpak.
  GNOME 50 runtime dependency/version checks must pass; unavailable GNOME
  50 or an ABI mismatch requires a new plan decision, never a runtime fallback.
  Outputs are `dist/monkeyspaw_<app-version>_x86_64.flatpak` and
  `.flatpak.sha256`, with hyphenated prereleases preserved. `finish-args`:
  - `--share=ipc` (X11/MIT-SHM; the Vervellum pairing)
  - `--share=network` (LLM, sync)
  - `--socket=wayland --socket=fallback-x11`
  - `--talk-name=org.freedesktop.secrets`
  - `--talk-name=org.kde.StatusNotifierWatcher` (optional tray)
  - `--filesystem=home` (read/write access to the whole home for a user-chosen library)

  Portal/manual shortcuts use the filtered session bus; there are no host
  dconf grants, unrestricted buses, KGlobalAccel, host-spawn or native
  injection grants (M7 G19). The tray owns only
  `ch.lkmc.monkeyspaw.StatusNotifierItem-<pid>-1`, on a dedicated connection
  when a session-bus address is available; stop releases the name and exports.
  A second item cannot displace the owner. Runtime tool availability does
  not permit host settings writes. CI checks the exact manifest and installed
  permission sets, including the absence of foreign-name ownership grants.

  Sandbox config/data use `~/.var/app/ch.lkmc.monkeyspaw/{config,data}/monkeyspaw`,
  including when XDG overrides are absent or point to native roots. Native
  state and file-backed secrets are not imported. The default remains
  `Documents/MonkeysPaw` under home; an outside-home XDG Documents setting
  falls back to `~/Documents`. A sandbox library must be under home both
  as selected and after resolving existing symlinks. Document-portal paths
  and external folders are refused before changing the active graph, picker,
  watcher or saved choice, with a typed folder error and home/native guidance
  (M7 G20). A filesystem override does not remove this home-only boundary.
  Native installations retain their existing folder behavior.

  Use one active install route per user. Native and Flatpak share the same
  D-Bus identity, so a host action may activate whichever installation is
  registered. Quit the other route before testing; no second identity or
  automatic takeover is provided. Portals handle dialogs, URIs, notifications,
  shortcut and delivery consent; sandbox delivery remains portal -> copy.

  The staged desktop retains E28's `MimeType=x-scheme-handler/monkeyspaw;`,
  `Exec=monkeyspaw %u` and all desktop actions. The service keeps its Name and
  uses `Exec=/app/bin/monkeyspaw --gapplication-service`; Flatpak exports/rewrites
  the host files. Opening an invite only stages it in Account, shows the
  destination and requires explicit Accept. No MIME default is set. E28's
  one-use URI fallback still exposes the link in launcher argv and potentially
  browser history; tokens/URIs must never appear in application or test logs.

  CI asserts that `secret-tool` and `gsettings` exist in the runtime.
  Documented limits:
  - ydotool is unreachable from the sandbox.
  - Autostart from inside the sandbox does not register with the host.
  - The library must be under `$HOME`.

  Installation and explicit bundle replacement are documented in
  [README.linux.md](../../README.linux.md#flatpak). A single-file bundle has
  no app update feed. Real GNOME-/KDE-host permissions, Secret Service,
  consent, URI association and readback require the
  [Flatpak owner procedure](../platform/flatpak.md) and M7 ledger evidence.
  The dedicated sync guide remains Y34/Z27 work; no sync acceptance follows
  from Flatpak's installed-URI CI proof.
