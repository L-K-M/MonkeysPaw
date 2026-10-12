#!/usr/bin/env bash
# Build every Monkey's Paw artifact this host can produce, into dist/.
#
# Usage: scripts/build.sh [mac|deb ...] [--no-open]
#   No targets: build every feasible target; skip unavailable toolchains.
#   Named targets: an unavailable toolchain fails the run.
#   mac        universal Release dmg, zip and .sha256 (macOS, Xcode, create-dmg)
#   deb        Ubuntu 24.04+ deb and .deb.sha256 (Linux, Swift 6.4, GTK 4, dpkg-dev)
#   --no-open  do not open dist/ in Finder after a successful macOS build
#   --help     print this header
#
# Versions come from the committed Xcode settings; packaging needs no lkm-build.
# Set SWIFT to another Swift executable for deb builds. Install Linux tooling
# as described in docs/plan/14-repository-packaging-ci-release.md.
# Server and APK packaging will join this target list in later milestones.
#
# App-only compatibility path: scripts/build.sh app [lkm-build flags]
# Delegates to the installed lkm-build engine, preserving --clean, --debug,
# --run, --install, --zip and --dmg. Set LKM_BUILD_BIN to override the engine.
# Shared engine: https://github.com/L-K-M/release-tool
# Exit nonzero if any target fails; report all targets in one Summary block.
set -uo pipefail

script_path="${BASH_SOURCE[0]}"
usage() {
  awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$script_path"
}

if [[ "${1:-}" == app ]]; then
  shift
  export BUILD_APP_NAME="MonkeysPaw"
  export BUILD_KIND="xcode"
  export BUILD_XCODE_PROJECT="MonkeysPaw.xcodeproj"
  export BUILD_XCODE_SCHEME="MonkeysPaw"
  export BUILD_INVOKED_AS="scripts/build.sh app"
  engine="${LKM_BUILD_BIN:-lkm-build}"
  command -v "$engine" >/dev/null 2>&1 || {
    echo '!! lkm-build not found: install https://github.com/L-K-M/release-tool' >&2
    exit 1
  }
  exec "$engine" "$@"
fi

targets=()
explicit=false
no_open=false
for argument in "$@"; do
  case "$argument" in
    mac|deb) targets+=("$argument"); explicit=true ;;
    --no-open) no_open=true ;;
    -h|--help) usage; exit 0 ;;
    --clean|--debug|--run|--install|--zip|--dmg)
      printf '!! %s belongs to the app engine: use scripts/build.sh app %s\n' "$argument" "$argument" >&2; exit 2 ;;
    *) printf '!! Unknown argument: %s (see --help)\n' "$argument" >&2; exit 2 ;;
  esac
done
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(mac deb)
fi

repo_root="$(cd "$(dirname "$script_path")/.." && pwd)" || exit 1
cd "$repo_root" || exit 1
host="$(uname -s)" || exit 1
# check-version.py also rejects diverging Debug/Release or README versions.
version="$(python3 scripts/check-version.py --committed-version)" || exit 1
[[ -n "$version" ]] || { echo '!! Missing committed version' >&2; exit 1; }

reason=
feasible() {
  local target=$1 tool
  case "$target" in
    mac)
      [[ "$host" == Darwin ]] || { reason='requires macOS'; return 1; }
      command -v create-dmg >/dev/null 2>&1 || {
        reason='install create-dmg with: brew install create-dmg'; return 1;
      }
      /usr/bin/xcodebuild -version >/dev/null 2>&1 || {
        reason='requires Xcode (select it with xcode-select)'; return 1;
      }
      ;;
    deb)
      [[ "$host" == Linux ]] || { reason='requires Linux'; return 1; }
      for tool in "${SWIFT:-swift}" python3 pkg-config dpkg dpkg-deb dpkg-shlibdeps readelf strip sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || {
          reason="missing $tool (see the Linux packaging requirements)"; return 1;
        }
      done
      pkg-config --exists gtk4 || { reason='requires libgtk-4-dev'; return 1; }
      ;;
  esac
}

results=()
failed=0
built=0
for target in "${targets[@]}"; do
  if ! feasible "$target"; then
    if [[ "$explicit" == true ]]; then
      results+=("$target: FAILED ($reason)")
      failed=1
    else
      results+=("$target: skipped ($reason)")
    fi
    continue
  fi

  printf '==> Building %s\n' "$target"
  case "$target" in
    mac) build_command=(/bin/bash scripts/package-macos.sh) ;;
    deb) build_command=(/bin/bash packaging/build-deb.sh "$version") ;;
  esac
  if "${build_command[@]}"; then
    results+=("$target: ok (dist/)")
    built=$((built + 1))
  else
    results+=("$target: FAILED (packaging failed)")
    failed=1
  fi
done

if [[ "$host" == Darwin && "$built" -gt 0 && "$no_open" == false ]]; then
  open "$repo_root/dist" || printf '!! Could not open dist/ in Finder\n' >&2
fi

printf '\nSummary\n'
printf '  %s\n' "${results[@]}"
[[ "$failed" -eq 0 ]]
