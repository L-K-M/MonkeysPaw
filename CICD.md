# CI and releases

`.github/workflows/ci.yml` runs on main pushes, all PRs and manual dispatches,
and is callable by the release workflow from the same commit. It builds Core
without GTK on Linux, runs Core/Linux tests and the X11 smoke test, tests Core
and the hosted app on macOS, proves deb installability on Ubuntu 24.04 and
universal macOS packaging with Xcode 26.0, and tests the server and its image.
See [§14](docs/plan/14-repository-packaging-ci-release.md) for each gate.

`.github/workflows/release.yml` runs on `v*` tags, manual dispatches and PRs
touching its workflow, packaging inputs or `server/**`. It calls CI before
packaging. Once S20's compose smoke job lands in `ci.yml`, this existing
`uses: ./.github/workflows/ci.yml` call also gates image publishing and GitHub
undrafting on that job from the release commit, without another workflow edit.
`scripts/check-version.py --check-tag <tag>` requires the tag's numeric core
to match every committed `MARKETING_VERSION` and the README version marker.
The tag supplies the artifact version without editing the checkout.
Release tags use `vX.Y.Z[-prerelease]`; the gate rejects build metadata
(`+...`) before either packager runs, matching the macOS packager's format.

Linux builds the deb and `.deb.sha256` in `swift:6.4-noble`. After Linux passes,
macOS builds the universal dmg, zip and `.sha256` with the run number as its
bundle build number. Signing is ad-hoc unless `MACOS_SIGNING_IDENTITY` names an
identity already installed in the runner's keychain; `MACOS_SIGNING_KEYCHAIN`
optionally selects that keychain. Signing env is exported only for non-empty
secrets, and never on PRs. Certificate provisioning and notarization remain
outside this workflow.

After Linux passes, `server-images` builds alongside macOS packaging with two
native runners: `ubuntu-24.04` for `linux/amd64` and `ubuntu-24.04-arm` for
`linux/arm64`. There is no QEMU/binfmt setup. Each build receives `VERSION`,
`REVISION` from the checked-out commit SHA and `CREATED` from that commit's
timestamp, rather than the run's wall clock. It checks source, revision,
version, created and Unlicense OCI labels, loads its OCI archive into Docker,
and smoke-tests container health plus `/api/health` status 200 using a
throwaway admin password file mounted read-only at `/run/secrets/`.

Only smoke-tested OCI archives and digests are uploaded as
`MonkeysPaw-server-image-{amd64,arm64}` workflow artifacts. They stay outside
the `MonkeysPaw-release-*` asset glob: images are registry objects, never a
sixth release asset. The `image-publish` job waits for tests, verify, Linux,
macOS, artifacts and both native image builds. It logs in to ghcr with the
job's token via stdin, uses Skopeo to preserve and push the untagged digests,
then uses `docker buildx imagetools create` to promote the multiarch manifest.
Every published tag is checked for exactly amd64 and arm64 with the expected
digests. No image tag is pushed before every build and verification gate passes.

Stable `vX.Y.Z` releases publish
`ghcr.io/l-k-m/monkeyspaw-server:{X.Y.Z,X.Y,latest}`. Hyphenated prereleases
publish only their exact version tag, such as `:0.1.0-beta.1`, without `X.Y`
or `latest`. The verify job self-tests this tag mapping. The first ghcr
publication is private; the owner must make the package public once in its
package settings. `update.sh` still builds the repo-owned server image locally.

Each packager uploads a workflow artifact, downloads it, and byte-compares
every file against its build outputs. The assembly job requires all five
assets and checks both checksum manifests. On a real release, image promotion
and manifest verification finish before the GitHub publish job runs, so a
failed image publish keeps the release unpublished. The publish job creates
a draft with all five assets, downloads them again from the release, and
byte-compares each before publishing. A failed upload or
comparison leaves the release unpublished. Hyphenated tags are prereleases
and are explicitly excluded from `latest`.

Registry promotion and GitHub publishing are separate operations: if GitHub
publishing fails afterward, verified image tags can already be published.

PRs always run the dry-run path. Manual `dry_run` defaults to true: all tests,
packaging, both native image builds and smoke tests, and workflow-artifact
comparisons run; both publish jobs are skipped without registry login or
push. On a branch, artifacts use the committed version. Selecting a tag
also exercises its alignment check. To publish manually, select an existing
`v*` tag and set `dry_run` to false; publishing from a branch fails.
Use manual publishing for a new release or a retry of the current release.
Republishing an older stable tag can move `latest` and `X.Y` backward before
GitHub refuses the duplicate release.

After integrating the workflow and passing CI plus the owner installation
checklist in [docs/platform/macos.md](docs/platform/macos.md), cut `v0.1.0` from
current main with:

```bash
scripts/release.sh 0.1.0 --push
```

The unchanged release stub delegates to the installed `lkm-release` engine
from [release-tool](https://github.com/L-K-M/release-tool). It bumps the Xcode
version and README marker, commits and tags, and pushes the commit and tag.
Monitor both the main CI run and tag release run. If publishing fails after
draft creation, inspect the draft and failed check before deleting the draft
and rerunning; the workflow refuses to overwrite an existing release.
Check the ghcr tags too, since image promotion precedes GitHub publishing.

Local builds use `scripts/build.sh [mac|deb ...] [--no-open]`, with outputs in
`dist/`. The default skips targets this host cannot build; explicitly named
targets fail when requirements are missing. `scripts/build.sh app [flags]`
retains the app-only `lkm-build` path. Download each platform's checksum file
with its archives and verify it before installing.

The workflow uses pinned action SHAs, credential-free checkouts, job timeouts
and read-only build tokens. Release concurrency is `release-${{ github.ref }}`
without cancellation. The GitHub publish job alone keeps `contents: write`;
only `image-publish` gets `packages: write`, with `contents: read`. Neither
publish job executes checked-out code. The reusable CI concurrency includes its
caller name so release testing and ordinary CI cannot cancel one another.

Flatpak publication arrives in M7 and APKs in M8. The existing `ci.yml` image
job still builds and smoke-tests only; release image publishing lives in
`release.yml`.
