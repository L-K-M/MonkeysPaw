# CI and releases

For installation and first use, see the [platform guides](README.md#install).
[Security](SECURITY.md) covers trust boundaries and signing;
[Privacy](PRIVACY.md) covers requests and retention. The
[M7 ledger](docs/platform/m7-acceptance.md) tracks owner prerequisites and
installed-artifact checks separately from CI. No owner acceptance is inferred
from the pipeline description below.

`.github/workflows/ci.yml` runs on main pushes, all PRs and manual dispatches,
and is callable by the release workflow from the same commit. It builds Core
without GTK on Linux, runs Core/Linux tests and the X11 smoke test, tests Core
and the hosted app on macOS, proves deb installability on Ubuntu 24.04 and
universal macOS packaging with Xcode 26.0, and tests the server and its image.
The bare-runner Flatpak job repacks the deb job's exact tested amd64 artifact
with GNOME Platform/SDK 50. It installs that bundle, compares the executable
to the deb, inspects desktop/service/icons/MIME and permissions, and exercises
cold/resident toggle, repeat, D-Bus Open and launcher fallback. GTK accessibility
must show the encoded invite's destination and enabled Accept controls; a
loopback recorder must receive no request before Accept. No invite is accepted
by this proof, and no bearer or URI is logged. Browser association, real portal
consent and focus behavior remain owner checks.
The Android job runs the five-task JVM/lint/debug/R8 gate, then stages and
verifies the signed release APK/checksum as well as uploading the debug APK.
Both workflows use `scripts/verify-android-release.py` to require the app ID,
full packaged version, committed code, minimum/target APIs and the ADR's
public signer fingerprint. It also checks exact checksum contents. SDK tools
are pinned to build tools `36.0.0`; no signing secrets are needed on fork PRs.
See [§14](docs/plan/14-repository-packaging-ci-release.md) for each gate.

`.github/workflows/release.yml` runs on `v*` tags, manual dispatches and PRs
touching either workflow, packaging inputs, Android, shared fixtures/seeds or
`server/Dockerfile`. It calls CI before packaging. Once S20's compose smoke
job lands in `ci.yml`, this existing
`uses: ./.github/workflows/ci.yml` call also gates GitHub undrafting on that
job from the release commit, without another workflow edit.
`scripts/check-version.py --check-tag <tag>` requires the tag's numeric core
to match every committed `MARKETING_VERSION` and the README version marker.
It also checks Android's single numeric `versionName` and literal positive
Int `versionCode`. Stable tags match exactly; prereleases match by numeric core.
The tag supplies the artifact version without editing the checkout.
Release tags use `vX.Y.Z[-prerelease]`; the gate rejects build metadata
(`+...`) before packaging, matching the macOS packager's format.

Linux builds the deb and `.deb.sha256` in `swift:6.4-noble`. After Linux passes,
macOS builds the universal dmg, zip and `.sha256` with the run number as its
bundle build number. Signing is ad-hoc unless `MACOS_SIGNING_IDENTITY` names an
identity already installed in the runner's keychain; `MACOS_SIGNING_KEYCHAIN`
optionally selects that keychain. Signing env is exported only for non-empty
secrets, and never on PRs. Certificate provisioning and notarization remain
outside this workflow. The owner chose ad-hoc signing without Developer ID
or notarization for v1.0.0 on 2026-10-19; real first-launch checks remain open.

The release `flatpak` job downloads that release deb and checksum, without
rebuilding Swift. It verifies the package version, runtime linking and installed
binary, then emits `monkeyspaw_<full-version>_x86_64.flatpak` and
`.flatpak.sha256`, retaining prerelease hyphens. Both Flatpak jobs use bare
Ubuntu runners, bounded bwrap/user-namespace setup, read-only tokens and
cleanup that restores the original sysctl and removes sandbox state. GNOME 50
unavailability or ABI failure blocks the run; no runtime fallback is selected.

Install or replace the downloaded bundle using the
[Linux guide](README.linux.md#flatpak); a single-file bundle supplies no app
update feed. The desktop update checker opens a release page only. It does
not download/install packages or invoke a package manager. macOS packaging
records the full version in `MonkeysPawReleaseVersion` before signing while
keeping the numeric `CFBundleShortVersionString`; the artifact gate checks
both so beta-to-stable comparisons retain the suffix.

`android-build` runs after tests and version verification, in parallel with
Linux packaging. It uses the same pinned wrapper validation, Temurin 17,
SDK packages and Gradle setup as ordinary CI. JVM tests, debug lint and R8
release assembly use the full release version; the K18 packager then stages
`monkeyspaw-v<full-version>.apk` and `.apk.sha256`. The 45-minute timeout,
two-worker/3 GiB limits and setup-gradle-only cache policy remain unchanged;
cache writes stay restricted to main. Timing changes require CI evidence.

After Linux passes, `server-images` builds alongside macOS packaging with two
native runners: `ubuntu-24.04` for `linux/amd64` and `ubuntu-24.04-arm` for
`linux/arm64`. There is no QEMU/binfmt setup. Each build receives `VERSION`,
`REVISION` from the checked-out commit SHA and `CREATED` from that commit's
timestamp, rather than the run's wall clock. It checks source, revision,
version, created and licenses OCI labels, loads its OCI archive into Docker,
checks that `/usr/share/doc/monkeyspaw-server/` holds the third-party notices
and that the licenses label names every term they carry, and smoke-tests
container health plus `/api/health` status 200 using a throwaway admin
password file mounted read-only at `/run/secrets/`.

Only smoke-tested OCI archives and digests are uploaded as
`MonkeysPaw-server-image-{amd64,arm64}` workflow artifacts. They stay outside
the `MonkeysPaw-release-*` asset glob and are retained for three days as
validation artifacts, separate from GitHub Release downloads. Both native
image builds and smoke tests remain release gates. The owner removed GHCR
publication on 2026-10-19: no image is pushed to GHCR or any other registry,
and no multiarch registry manifest is assembled. Registry distribution is
not provided yet. Build a versioned local image with
`scripts/build.sh server-image`; `update.sh` also builds the repo-owned image
locally for Compose deployment.

Each packager uploads a workflow artifact, downloads it, and byte-compares
every file against its build outputs. Ordinary CI also round-trips its
release APK/checksum and Flatpak bundle/checksum. The assembly job requires
exactly seven desktop assets (deb/checksum, Flatpak/checksum and dmg/zip/manifest)
plus the two Android assets (APK/checksum), nine nonempty files in total.
It rejects extra files, including hidden entries, and requires each checksum manifest to name
every corresponding payload exactly once before checking all four manifests.
Assembly and GitHub publishing require the verified Flatpak output and both
native image build/smoke results. A failed image gate keeps the release
unpublished. The publish job creates
a draft with all nine assets, downloads them again from the release, and
byte-compares each before publishing. A failed upload or
comparison leaves the release unpublished. Hyphenated tags are prereleases
and are explicitly excluded from `latest`.
Generated release notes link to `CHANGELOG.md` at the full release tag, retain
Android checksum/sideload and public-signer guidance, and include Flatpak
checksum/install instructions and Linux x86_64/GNOME Platform 50 requirements.
Assembly waits for both native image builds. Android failure reports use
`MonkeysPaw-android-release-reports`, outside the release asset glob and
distinct from ordinary CI reports, so retained reports cannot contaminate
asset assembly after a successful job retry. Signing-ADR changes select
`core-linux` to check fingerprint agreement.

PRs, including forks, always run the dry-run path. Manual `dry_run` defaults
to true: all tests, packaging, both native image builds and smoke tests, and workflow-artifact
comparisons run; GitHub publishing is skipped. Images are never pushed,
including on real releases. On a branch, artifacts use the committed version. Selecting a tag
also exercises its alignment check. To publish manually, select an existing
`v*` tag and set `dry_run` to false; publishing from a branch fails.
Use manual publishing for a new release or a retry of the current release.

The owner removed the historical published `v0.1.0` installation gate on
2026-10-19. The [M12 release install rows](docs/platform/m12-acceptance.md#post-publication-phase-from-actual-v100)
still require actual `v1.0.0` installations. After CI, candidate checks and
owner release authorization in that ledger, the owner can cut `v1.0.0` from
current main with:

```bash
scripts/release.sh 1.0.0 --push
```

The release stub delegates to the installed `lkm-release` engine
from [release-tool](https://github.com/L-K-M/release-tool). It bumps the Xcode
version, runs `scripts/sync-android-version.sh` with `RELEASE_NEW_VERSION`,
updates the README marker, commits and tags, and pushes the commit and tag.
The hook sets Android's numeric `versionName` and increments `versionCode`
once when the version changes. An aligned retry does nothing; malformed input,
duplicate declarations and code overflow leave the Gradle file untouched.
The engine rolls back tracked bump edits if the hook fails.
Monitor both the main CI run and tag release run. If publishing fails after
draft creation, inspect the draft and failed check before deleting the draft
and rerunning; the workflow refuses to overwrite an existing release.

`scripts/release.sh --check` reports configuration and skips the hook. Running
without `--push` still commits and tags, so integration tests use disposable
repositories rather than an implementation checkout.

Local builds use `scripts/build.sh [mac|deb|flatpak|android|server-image ...] [--install] [--no-open]`,
with file outputs in `dist/`. `--install` installs what the run built: the
macOS app into `/Applications`, the deb with `sudo apt-get`, the Flatpak bundle
for your user only when `deb` is not targeted (both share the app ID), and the
APK with `adb install -r` on the one ready device (`ANDROID_SERIAL` selects
one). `server-image` installs nothing; deploy the server with `./update.sh`.
Install failures fail the run after every build. The default skips targets this host cannot build;
explicitly named targets fail when requirements are missing. The default builds
deb then Flatpak once when both are feasible. `flatpak` requires x86_64 Linux, the deb toolchain,
Flatpak/flatpak-builder and user-installed GNOME Platform/SDK 50; it reuses only
this run's exact deb, regardless of target order. To repack an already tested
deb, run `scripts/build-flatpak.sh <deb> [expected-app-version]`; absent an
expected version, its control metadata supplies the version.

`server-image` requires Docker, git and a reachable Linux Docker engine on
Linux or macOS. It builds `server/Dockerfile` for the engine's default platform
as `monkeyspaw-server:<committed-version>` in Docker's image store and prints
that reference in the Summary. Its `VERSION`, `REVISION` and `CREATED` build
args use the committed version, HEAD SHA and HEAD's `%cI` commit timestamp,
matching the release image contract. Missing Docker, a failing `docker info`,
or a non-Linux engine skips the default target and fails a named target.
Registry distribution is not provided yet; the release workflow only builds
and smoke-tests each native architecture.

`scripts/build.sh app [flags]` retains the app-only `lkm-build` path. Download each platform's checksum file
with its archives and verify it before installing.

`scripts/package-android.sh [version]` builds the signed release APK via the
checked-in wrapper with two workers. It requires JDK 17+, SDK platform
`android-37.0` and build tools `36.0.0`; SDK downloads are disabled. Set `JAVA_HOME`
and `ANDROID_HOME`, or use `sdk.dir` in `android/local.properties`. `--check`
checks configuration without running Gradle. The optional version accepts
`[v]X.Y.Z[-prerelease]` with the committed numeric core. It passes the full
normalized version through Gradle's validated `releaseVersion` property and
stages `dist/monkeyspaw-v<full-version>.apk` plus `.apk.sha256`. The APK's
`versionName` retains the suffix and `versionCode` stays the committed integer,
never a CI run number. Repeated same-core prereleases need increasing committed
codes and engine support before owner use (§20 F20). Release notes prepend
Android sideload/checksum guidance and public-signing disclosure to GitHub's
generated notes. Device install/update acceptance remains owner-run.

The workflow uses pinned action SHAs, credential-free checkouts, job timeouts
and a default read-only token. Release concurrency is `release-${{ github.ref }}`
without cancellation. The GitHub publish job alone gets `contents: write`;
no job requests `packages: write`. The publish job executes no checked-out
code. The reusable CI concurrency includes its
caller name so release testing and ordinary CI cannot cancel one another.

Both `ci.yml` and `release.yml` build and smoke-test images without publishing
them. Flathub supplies the GNOME runtime, while GitHub Releases
distributes the app bundle and checksum; there is no Flathub app publication.
