# CI and releases

`.github/workflows/ci.yml` runs on main pushes, all PRs and manual dispatches,
and is callable by the release workflow from the same commit. It builds Core
without GTK on Linux, runs Core/Linux tests and the X11 smoke test, tests Core
and the hosted app on macOS, proves deb installability on Ubuntu 24.04 and
universal macOS packaging with Xcode 26.0, and tests the server and its image.
See [§14](docs/plan/14-repository-packaging-ci-release.md) for each gate.

`.github/workflows/release.yml` runs on `v*` tags, manual dispatches and PRs
touching its workflow or packaging inputs. It calls CI before packaging.
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

Each packager uploads a workflow artifact, downloads it, and byte-compares
every file against its build outputs. The assembly job requires all five
assets and checks both checksum manifests. On a real release, the publish
job creates a draft with all five assets, downloads them again from the
release, and byte-compares each before publishing. A failed upload or
comparison leaves the release unpublished. Hyphenated tags are prereleases
and are explicitly excluded from `latest`.

PRs always run the dry-run path. Manual `dry_run` defaults to true: all tests,
packaging and workflow-artifact comparisons run, and the publish job is
skipped. On a branch, artifacts use the committed version. Selecting a tag
also exercises its alignment check. To publish manually, select an existing
`v*` tag and set `dry_run` to false; publishing from a branch fails.

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

Local builds use `scripts/build.sh [mac|deb ...] [--no-open]`, with outputs in
`dist/`. The default skips targets this host cannot build; explicitly named
targets fail when requirements are missing. `scripts/build.sh app [flags]`
retains the app-only `lkm-build` path. Download each platform's checksum file
with its archives and verify it before installing.

The workflow uses pinned action SHAs, credential-free checkouts, job timeouts
and read-only build tokens. Release concurrency is `release-${{ github.ref }}`
without cancellation. The publish job alone keeps `contents: write`, and
does not execute checked-out code. The reusable CI concurrency includes its
caller name so release testing and ordinary CI cannot cancel one another.

Server image publication to ghcr arrives in M5, flatpak in M7 and APKs in M8.
The existing CI image job builds and smoke-tests only; it does not publish.
