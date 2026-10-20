#!/usr/bin/env bash
# Build every Monkey's Paw artifact this host can produce.
#
# Usage: scripts/build.sh [mac|deb|flatpak|android|server-image ...] [--install] [--no-open]
#   No targets: build every feasible target; skip unavailable toolchains.
#   Named targets: an unavailable toolchain fails the run.
#   mac        universal Release dmg, zip and .sha256 (macOS, Xcode; create-dmg
#              lays out the dmg window, else the dmg is plain)
#   deb        Ubuntu 24.04+ deb and .deb.sha256 (Linux, Swift 6.4, GTK 4, dpkg-dev)
#   flatpak    GNOME 50 x86_64 bundle and checksum, reusing this run's deb
#   android    signed release APK and .apk.sha256 (wrapper, JDK 17+, Android SDK)
#   server-image  versioned local server image (Docker with a Linux engine, git)
#   --install  after building, install what this run built:
#              mac      /Applications/MonkeysPaw.app, replaced from the zip
#              deb      sudo apt-get install (needs sudo and apt-get)
#              flatpak  flatpak install --user, only when deb is not targeted:
#                       both routes share ch.lkmc.monkeyspaw, so one per user
#              android  adb install -r on the one ready device (ANDROID_SERIAL
#                       picks one); adb comes from the SDK, then PATH
#              server-image  nothing; deploy the server with ./update.sh
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
install=false
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
    --install) install=true ;;
    --no-open) no_open=true ;;
    -h|--help) usage; exit 0 ;;
    --clean|--debug|--run|--zip|--dmg)
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

# --install helpers. Each sets reason and returns nonzero on failure.
mac_app=/Applications/MonkeysPaw.app

install_mac() {
  local zip="dist/MonkeysPaw-$version.zip" staging incoming=/Applications/.MonkeysPaw.app.incoming status
  [[ -s "$zip" ]] || { reason="missing $zip"; return 1; }
  staging="$(mktemp -d)" || { reason='mktemp failed'; return 1; }

  # Copy beside the old app, then swap, so a failed copy keeps it intact.
  /usr/bin/ditto -x -k "$zip" "$staging" \
    && rm -rf "$incoming" \
    && /usr/bin/ditto "$staging/MonkeysPaw.app" "$incoming" \
    && rm -rf "$mac_app" \
    && mv "$incoming" "$mac_app"
  status=$?
  rm -rf "$staging"
  [[ "$status" -eq 0 ]] || reason="could not replace $mac_app"
  return "$status"
}

install_deb() {
  local elevate=(sudo) tool
  [[ "$(id -u)" -ne 0 ]] || elevate=()
  for tool in ${elevate[@]+"${elevate[@]}"} apt-get; do
    command -v "$tool" >/dev/null 2>&1 || { reason="missing $tool; install ./$deb_path yourself"; return 1; }
  done

  # ./ makes apt read the local file and resolve its dependencies.
  ${elevate[@]+"${elevate[@]}"} apt-get install -y --reinstall "./$deb_path" || {
    reason='apt-get install failed'; return 1;
  }
}

install_flatpak() {
  local bundle="dist/monkeyspaw_${version}_x86_64.flatpak"
  [[ -s "$bundle" ]] || { reason="missing $bundle"; return 1; }
  flatpak install --user --assumeyes --reinstall --bundle "$bundle" || { reason='flatpak install failed'; return 1; }
}

# Prints the first adb found in sdk.dir, ANDROID_HOME, ANDROID_SDK_ROOT
# (Gradle's SDK precedence), then PATH.
android_adb() {
  local sdk_dir='' sdk
  if [[ -f android/local.properties ]]; then
    sdk_dir="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*[=:][[:space:]]*//p' android/local.properties \
      | tail -n 1 | tr -d '\r' | sed 's/\\\(.\)/\1/g')"
  fi
  for sdk in "$sdk_dir" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]] || continue
    printf '%s\n' "$sdk/platform-tools/adb"
    return 0
  done
  command -v adb
}

install_android() {
  local apk="dist/monkeyspaw-v$version.apk" adb state
  [[ -s "$apk" ]] || { reason="missing $apk"; return 1; }
  adb="$(android_adb)" || { reason='adb not found (install SDK platform-tools)'; return 1; }

  # get-state fails unless exactly one device is attached or ANDROID_SERIAL names one.
  state="$("$adb" get-state 2>/dev/null)" || { reason='no single ready device (connect one or set ANDROID_SERIAL)'; return 1; }
  [[ "$state" == device ]] || { reason="device is $state, not ready"; return 1; }
  "$adb" install -r "$apk" || { reason='adb install failed'; return 1; }
}

results=()
failed=0
built=0
built_targets=()
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
    built_targets+=("$target")
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

if [[ "$install" == true ]]; then
  for target in ${built_targets[@]+"${built_targets[@]}"}; do
    case "$target" in
      mac) install_command=(install_mac); destination="$mac_app" ;;
      deb) install_command=(install_deb); destination=apt-get ;;
      flatpak)
        case " ${targets[*]} " in
          *" deb "*)
            results+=("install flatpak: skipped (deb is also targeted; use one route per user)")
            continue
            ;;
        esac
        install_command=(install_flatpak); destination='flatpak --user'
        ;;
      android) install_command=(install_android); destination=adb ;;
      server-image)
        results+=("install server-image: skipped (deploy the server with ./update.sh)")
        continue
        ;;
    esac

    printf '==> Installing %s\n' "$target"
    if "${install_command[@]}"; then
      results+=("install $target: ok ($destination)")
    else
      results+=("install $target: FAILED ($reason)")
      failed=1
    fi
  done
fi

if [[ "$host" == Darwin && "$built" -gt 0 && "$no_open" == false ]]; then
  open "$repo_root/dist" || printf '!! Could not open dist/ in Finder\n' >&2
fi

printf '\nSummary\n'
printf '  %s\n' "${results[@]}"
[[ "$failed" -eq 0 ]]
