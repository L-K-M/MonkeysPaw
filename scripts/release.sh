#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, and tags v<version>.
# With --push, CI publishes the tag via release.yml once that workflow lands
# in M2. This M0c stub configures the shared engine; it does not publish assets.
# The tag supplies CI's release version; MARKETING_VERSION and the README marker
# keep local builds in step. See docs/plan/14-repository-packaging-ci-release.md.
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export RELEASE_APP_NAME="MonkeysPaw"
export RELEASE_KIND="xcode"
export RELEASE_XCODE_PROJECT="MonkeysPaw.xcodeproj"
export RELEASE_XCODE_SCHEME="MonkeysPaw"
export RELEASE_CI_NOTE="CI (release.yml, from M2) publishes the GitHub Release for the tag once configured."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found: clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
