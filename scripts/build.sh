#!/usr/bin/env bash
# Build every Monkey's Paw artifact this host can produce.
#
# Usage: scripts/build.sh [mac|deb|flatpak|android|server-image ...] [--no-open]
#   No targets: build every feasible target; skip unavailable toolchains.
#   Named targets: an unavailable toolchain fails the run.
#   mac        universal Release dmg, zip and .sha256 (macOS, Xcode, create-dmg)
#   deb        Ubuntu 24.04+ deb and .deb.sha256 (Linux, Swift 6.4, GTK 4, dpkg-dev)
#   flatpak    GNOME 50 x86_64 bundle and checksum, reusing this run's deb
#   android    signed release APK and .apk.sha256 (wrapper, JDK 17+, Android SDK)
#   server-image  versioned local server image (Docker with a Linux engine, git)
#   --no-open  do not open dist/ in Finder after a successful macOS build
#   --help     print this header
#
# Versions come from the committed Xcode settings; packaging needs no lkm-build.
# Files go to dist/; server-image goes to Docker's image store and prints its tag.
# Set SWIFT to another Swift executable for deb builds. Install Linux tooling
# as described in docs/plan/14-repository-packaging-ci-release.md.
# Set JAVA_HOME/ANDROID_HOME for Android, or configure android/local.properties.
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
    mac|deb|flatpak|android|server-image)
      explicit=true
      case " ${targets[*]:-} " in
        *" $argument "*) ;;
        *) targets+=("$argument") ;;
      esac
      ;;
    --no-open) no_open=true ;;
    -h|--help) usage; exit 0 ;;
    --clean|--debug|--run|--install|--zip|--dmg)
      printf '!! %s belongs to the app engine: use scripts/build.sh app %s\n' "$argument" "$argument" >&2; exit 2 ;;
    *) printf '!! Unknown argument: %s (see --help)\n' "$argument" >&2; exit 2 ;;
  esac
done
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(mac deb flatpak android server-image)
fi

repo_root="$(cd "$(dirname "$script_path")/.." && pwd)" || exit 1
cd "$repo_root" || exit 1
host="$(uname -s)" || exit 1
# check-version.py also rejects diverging Debug/Release or README versions.
version="$(python3 scripts/check-version.py --committed-version)" || exit 1
[[ -n "$version" ]] || { echo '!! Missing committed version' >&2; exit 1; }
server_image="monkeyspaw-server:$version"

reason=
feasible() {
  local target=$1 tool docker_os
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
    flatpak)
      feasible deb || return 1
      [[ "$(uname -m)" == x86_64 ]] || { reason='requires x86_64'; return 1; }
      for tool in flatpak flatpak-builder; do
        command -v "$tool" >/dev/null 2>&1 || { reason="missing $tool"; return 1; }
      done
      for tool in org.gnome.Platform org.gnome.Sdk; do
        flatpak info --user "$tool/x86_64/50" >/dev/null 2>&1 || {
          reason="requires $tool/x86_64/50 (install GNOME 50 from Flathub)"; return 1;
        }
      done
      ;;
    android)
      reason="$(/bin/bash scripts/package-android.sh --check 2>&1)" || {
        reason="${reason#!! }"; return 1;
      }
      ;;
    server-image)
      for tool in docker git; do
        command -v "$tool" >/dev/null 2>&1 || { reason="missing $tool"; return 1; }
      done
      docker_os="$(docker info --format '{{.OSType}}' 2>/dev/null)" || {
        reason='docker info failed; start Docker or check its context'; return 1;
      }
      [[ "$docker_os" == linux ]] || { reason='requires a Linux Docker engine'; return 1; }
      ;;
  esac
}

# Track the exact output of one deb invocation, even if flatpak precedes deb.
# Removing only that output before building prevents a no-output success from
# reusing a package left by an earlier run.
deb_attempted=false
deb_succeeded=false
deb_path=
build_deb() {
  if [[ "$deb_attempted" == true ]]; then [[ "$deb_succeeded" == true ]]; return; fi
  deb_attempted=true
  local deb_version architecture
  deb_version="$(python3 scripts/check-version.py --deb-version "$version")" || return 1
  architecture="$(dpkg --print-architecture)" || return 1
  deb_path="dist/monkeyspaw_${deb_version}_${architecture}.deb"
  rm -f -- "$deb_path" "$deb_path.sha256" || return 1
  /bin/bash packaging/build-deb.sh "$version" || return 1
  [[ -s "$deb_path" && -s "$deb_path.sha256" ]] || return 1
  (cd dist && sha256sum --strict -c "$(basename "$deb_path").sha256") || return 1
  deb_succeeded=true
}

build_flatpak() {
  build_deb || return 1
  /bin/bash scripts/build-flatpak.sh "$deb_path" "$version"
}

build_server_image() {
  local revision created
  revision="$(git rev-parse HEAD)" || return 1
  created="$(git show -s --format=%cI HEAD)" || return 1
  # Custom builders may otherwise leave a successful build only in their cache.
  docker build --load --tag "$server_image" \
    --build-arg "VERSION=$version" --build-arg "REVISION=$revision" \
    --build-arg "CREATED=$created" -f server/Dockerfile .
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
    deb) build_command=(build_deb) ;;
    flatpak) build_command=(build_flatpak) ;;
    android) build_command=(/bin/bash scripts/package-android.sh "$version") ;;
    server-image) build_command=(build_server_image) ;;
  esac
  if "${build_command[@]}"; then
    if [[ "$target" == server-image ]]; then
      results+=("$target: ok (Docker image: $server_image)")
    else
      results+=("$target: ok (dist/)")
      built=$((built + 1))
    fi
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
