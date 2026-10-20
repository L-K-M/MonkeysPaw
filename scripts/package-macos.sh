#!/usr/bin/env bash
# Build and sign a universal Release app, then package verified dmg and zip files.
# Usage: scripts/package-macos.sh [version [build-number]]
# Requires macOS and Xcode. create-dmg (brew install create-dmg) lays out
# the dmg window; without it a local build packages a plain hdiutil image.
# CI requires create-dmg so releases keep the laid-out window.
# With no arguments, use the committed Xcode version and build number.
# An explicit version may have a v prefix; the optional second argument sets
# the build number. The full version is kept in MonkeysPawReleaseVersion;
# CFBundleShortVersionString retains the numeric marketing version.
# MACOS_SIGNING_IDENTITY selects an installed identity; unset/empty means ad-hoc.
# MACOS_SIGNING_KEYCHAIN optionally selects its keychain when using an identity.
# CI callers must export signing variables only when their secrets are non-empty.
# Uses xcodebuild directly: no lkm-build installation or certificate import needed.
# XCODEBUILD selects another xcodebuild than /usr/bin/xcodebuild.
set -euo pipefail

fail() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# //'
  exit 0
fi

[[ $# -le 2 ]] || fail 'Usage: scripts/package-macos.sh [version [build-number]]'
[[ "$(uname -s)" == Darwin ]] || fail 'package-macos.sh requires macOS and Xcode'
if command -v create-dmg >/dev/null 2>&1; then
  dmg_tool=create-dmg
elif [[ "${CI:-false}" == true ]]; then
  fail 'Install create-dmg with: brew install create-dmg'
else
  dmg_tool=hdiutil
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/MonkeysPaw.xcodeproj"
version="${1:-$(awk '$1 == "MARKETING_VERSION" { sub(/;$/, "", $3); gsub(/"/, "", $3); print $3; exit }' "$project/project.pbxproj")}"
version="${version#v}"
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$'
[[ "$version" =~ $version_pattern ]] || fail 'Version must be X.Y.Z, optionally with a prerelease suffix'
marketing_version="${version%%-*}"
build_number="${2:-$(awk '$1 == "CURRENT_PROJECT_VERSION" { sub(/;$/, "", $3); gsub(/"/, "", $3); print $3; exit }' "$project/project.pbxproj")}"
build_pattern='^[1-9][0-9]*(\.[0-9]+){0,2}$'
[[ "$build_number" =~ $build_pattern ]] || fail 'Build number must have one to three numeric components, starting with a positive integer'

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-package.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT
derived_data="$work_directory/DerivedData"
staging_directory="$work_directory/image"
app="$staging_directory/MonkeysPaw.app"
mkdir -p "$staging_directory" "$work_directory/artifacts"

printf '==> Building MonkeysPaw %s (%s) for arm64 and x86_64\n' "$version" "$build_number"
"${XCODEBUILD:-/usr/bin/xcodebuild}" \
  -project "$project" -scheme MonkeysPaw -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  MARKETING_VERSION="$marketing_version" CURRENT_PROJECT_VERSION="$build_number" \
  INFOPLIST_KEY_MonkeysPawReleaseVersion="$version" \
  CODE_SIGNING_ALLOWED=NO build

built_app="$derived_data/Build/Products/Release/MonkeysPaw.app"
[[ -d "$built_app" ]] || fail 'Release build did not produce MonkeysPaw.app'
/usr/bin/ditto "$built_app" "$app"
# -archs, not a multi-arch -verify_arch: Xcode 27's lipo rejects
# "-verify_arch arm64 x86_64" with "requires exactly one input file".
architectures=" $(/usr/bin/lipo -archs "$app/Contents/MacOS/MonkeysPaw") "
for architecture in arm64 x86_64; do
  [[ "$architectures" == *" $architecture "* ]] || fail "Release build lacks the $architecture slice (has:$architectures)"
done

# Preserve the raw release version even if Xcode omits a custom generated key.
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MonkeysPawReleaseVersion $version" "$plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :MonkeysPawReleaseVersion string $version" "$plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MonkeysPawReleaseVersion' "$plist")" == "$version" ]] || fail 'Raw release version mismatch'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$marketing_version" ]] || fail 'Marketing version mismatch'

signing_identity="${MACOS_SIGNING_IDENTITY:--}"
# Xcode signing is disabled above, so explicitly retain the paste entitlement
# and Hardened Runtime when signing the staged app, including ad-hoc builds.
signing_arguments=(--force --sign "$signing_identity" --options runtime
  --entitlements "$repo_root/MonkeysPaw/MonkeysPaw.entitlements")
if [[ "$signing_identity" != - ]]; then
  signing_arguments+=(--timestamp)
  if [[ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]]; then
    signing_arguments+=(--keychain "$MACOS_SIGNING_KEYCHAIN")
  fi
fi
/usr/bin/codesign "${signing_arguments[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

zip="$work_directory/artifacts/MonkeysPaw-$version.zip"
dmg="$work_directory/artifacts/MonkeysPaw-$version.dmg"
printf '==> Packaging zip and dmg\n'
/usr/bin/ditto -c -k --keepParent "$app" "$zip"

volume_name="MonkeysPaw $version"
if [[ "$dmg_tool" == hdiutil ]]; then
  # Same contents as the release image (the app and an Applications link
  # to drag it onto), without create-dmg's window layout.
  printf -- '-- create-dmg not installed; packaging a plain dmg\n'
  ln -s /Applications "$staging_directory/Applications"
  /usr/bin/hdiutil create -volname "$volume_name" -srcfolder "$staging_directory" \
    -format UDZO "$dmg" >/dev/null || fail 'hdiutil could not create the dmg'
else
  dmg_arguments=(--volname "$volume_name" --window-size 540 380
    --icon-size 100 --icon MonkeysPaw.app 150 185 --app-drop-link 390 185)
  if [[ "${CI:-false}" == true ]]; then
    # Finder's AppleScript styling needs a GUI session; keep CI headless.
    dmg_arguments+=(--skip-jenkins)
  fi
  # create-dmg expects a folder containing the app, not the app bundle itself.
  # Its status can be unreliable on headless hosts. A fresh, verified image is
  # required even when it reports success; old dist files cannot satisfy this.
  if ! create-dmg "${dmg_arguments[@]}" "$dmg" "$staging_directory"; then
    printf '!! create-dmg reported failure; checking the newly created image\n' >&2
  fi
fi
[[ -s "$dmg" ]] || fail "$dmg_tool did not produce an image"
/usr/bin/hdiutil verify "$dmg"
[[ -s "$zip" ]] || fail 'ditto did not produce a zip'

mkdir -p "$repo_root/dist"
mv -f "$zip" "$dmg" "$repo_root/dist/"
# Testers record the exact bytes they installed (docs/platform/macos.md).
(cd "$repo_root/dist" && /usr/bin/shasum -a 256 "MonkeysPaw-$version.zip" "MonkeysPaw-$version.dmg" \
  > "MonkeysPaw-$version.sha256")
printf '==> Created:\n  %s\n  %s\n  %s\n' \
  "dist/MonkeysPaw-$version.zip" "dist/MonkeysPaw-$version.dmg" "dist/MonkeysPaw-$version.sha256"
