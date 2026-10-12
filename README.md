# Monkey's Paw

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Release version:** v<!-- version -->0.1.0<!-- /version --> · [Download](https://github.com/L-K-M/MonkeysPaw/releases/latest)

Monkey's Paw is a prompt repository for macOS and Linux, with Android planned.
The desktop apps let you pick a prompt, fill its placeholders, and paste
the result into the text field you were using. Prompts live in Markdown files
with YAML front matter, so you can edit them with your own tools. An optional
LLM assistant will help write and improve prompts, and a self-hosted server
will sync them between devices and share them within groups.

The portable Core format APIs preserve unknown front-matter metadata and
exact body bytes. Canonical writing does not preserve comments inside front
matter. Format and grammar conformance cases live under
[`spec/fixtures/`](spec/fixtures/), documented in [`spec/README.md`](spec/README.md).

**Status:** The desktop picker/fill loop, General and Shortcuts Settings,
onboarding and library recovery, Forget controls, Linux tray, five-category
conformance corpus and release workflow are merged per [PLAN.md](PLAN.md).
The v0.1.0 tag and [owner-run platform checks](docs/platform/m2-acceptance.md)
remain before M2 closes. M3 follows with the Library window, editor, history,
import and first-run tour.

## Install on Linux

On Ubuntu 24.04 or newer, download the `.deb` and its `.deb.sha256` from a
release. Run `sha256sum -c monkeyspaw_<version>_<arch>.deb.sha256` in the download directory,
then install with `sudo apt install ./monkeyspaw_<version>_<arch>.deb` and run
`monkeyspaw`. To build a local package, run
`scripts/build.sh deb`; see the
[packaging requirements](docs/plan/14-repository-packaging-ci-release.md).

Prerelease deb filenames use `~` in place of the version's hyphen. For
`v0.1.0-beta.1` on amd64, download `monkeyspaw_0.1.0~beta.1_amd64.deb`
and its `.deb.sha256`, then run:

```sh
sha256sum -c monkeyspaw_0.1.0~beta.1_amd64.deb.sha256
sudo apt install ./monkeyspaw_0.1.0~beta.1_amd64.deb
```

## Install on macOS

Download `MonkeysPaw-<version>.dmg`, `.zip` and `.sha256` from the
[releases](https://github.com/L-K-M/MonkeysPaw/releases). In the download
directory, run `shasum -a 256 -c MonkeysPaw-<version>.sha256`; both archives
must report **OK**. Open the dmg and drag `MonkeysPaw.app` to Applications.
Builds are ad-hoc signed unless the release says otherwise, and are not
notarized. For Gatekeeper approval and installation checks, see the
[macOS checklist](docs/platform/macos.md). Local packaging uses
`scripts/build.sh mac`; the app-only engine remains at `scripts/build.sh app`.

The [CI and release guide](CICD.md) describes dry runs and cutting a release.
