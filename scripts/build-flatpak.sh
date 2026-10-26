#!/usr/bin/env bash
# Repack an explicit tested amd64 deb into a GNOME 50 x86_64 Flatpak.
# Usage: scripts/build-flatpak.sh <path/to.deb> [expected-app-version]
# Without an expected version, derive it from this deb's control metadata.
# Requires flatpak, flatpak-builder, dpkg-deb, python3 and the user-installed
# org.gnome.Platform//50 and org.gnome.Sdk//50 from Flathub. Never builds Swift
# or installs runtimes. Relative deb paths are relative to the caller.
# Output: dist/monkeyspaw_<app-version>_x86_64.flatpak and .flatpak.sha256
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID=ch.lkmc.monkeyspaw
FLATHUB_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo
die() { printf 'build-flatpak.sh: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || die 'Usage: scripts/build-flatpak.sh <path/to.deb> [expected-app-version]'
[[ -f "$1" && -r "$1" ]] || die "Deb is not a readable file: $1"
DEB="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
for tool in python3 dpkg-deb flatpak flatpak-builder sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool is missing: $tool"
done
[[ "$(dpkg-deb --field "$DEB" Package)" == monkeyspaw ]] || die 'Expected a monkeyspaw deb'
[[ "$(dpkg-deb --field "$DEB" Architecture)" == amd64 ]] || die 'Only amd64 debs can be repacked as x86_64'
INPUT_VERSION="$(dpkg-deb --field "$DEB" Version)"
VERSION="$(python3 "$ROOT/scripts/check-version.py" --app-version "${2:-${INPUT_VERSION//\~/-}}")"
[[ "$VERSION" != *+* ]] || die 'Build metadata (+...) is not supported for release artifacts'
DEB_VERSION="$(python3 "$ROOT/scripts/check-version.py" --deb-version "$VERSION")"
[[ "$INPUT_VERSION" == "$DEB_VERSION" ]] || die 'Deb version does not match the requested app version'
for runtime in org.gnome.Platform org.gnome.Sdk; do
    flatpak info --user "$runtime/x86_64/50" >/dev/null 2>&1 || \
        die "Missing $runtime/x86_64/50; install GNOME 50 from Flathub with flatpak install --user"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-flatpak.XXXXXX")"
BUNDLE="monkeyspaw_${VERSION}_x86_64.flatpak"
OUTPUT="$ROOT/dist/$BUNDLE"
publishing=false
cleanup() {
    local status=$?
    rm -rf -- "$WORK"
    if [[ "$publishing" == true && "$status" -ne 0 ]]; then
        rm -f -- "$OUTPUT" "$OUTPUT.sha256"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

dpkg-deb --extract "$DEB" "$WORK/debroot"
extra="$(find "$WORK/debroot" -mindepth 1 -maxdepth 1 ! -name usr -print -quit)"
[[ -z "$extra" ]] || die 'Deb contains paths outside /usr that the repack would drop'
# The deb builder emits regular files. Reject links before any staged edit can
# follow one outside the private tree, or silently drop a required asset.
link="$(find "$WORK/debroot" -type l -print -quit)"
[[ -z "$link" ]] || die 'Deb payload contains an unsupported symbolic link'
[[ -f "$WORK/debroot/usr/bin/monkeyspaw" && -x "$WORK/debroot/usr/bin/monkeyspaw" ]] || \
    die 'Deb has no executable at /usr/bin/monkeyspaw'
# The license notices travel with the payload into /app/share/doc/monkeyspaw.
for path in "share/applications/$APP_ID.desktop" "share/dbus-1/services/$APP_ID.service" \
    share/doc/monkeyspaw/copyright share/doc/monkeyspaw/Third-Party-Notices.txt; do
    [[ -f "$WORK/debroot/usr/$path" && -s "$WORK/debroot/usr/$path" ]] || die "Deb is missing /usr/$path"
done
for size in 16 24 32 48 64 128 256 512; do
    path="share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
    [[ -f "$WORK/debroot/usr/$path" && -s "$WORK/debroot/usr/$path" ]] || die "Deb is missing /usr/$path"
done
for frame in 00 01 02 03 04 05 06 07 08; do
    path="share/monkeyspaw/wish-paw/wish-paw-$frame@2x.png"
    [[ -f "$WORK/debroot/usr/$path" && -s "$WORK/debroot/usr/$path" ]] || die "Deb is missing /usr/$path"
done

mkdir "$WORK/stage"
cp -a "$WORK/debroot/usr/." "$WORK/stage/"
desktop="$WORK/stage/share/applications/$APP_ID.desktop"
service="$WORK/stage/share/dbus-1/services/$APP_ID.service"
grep -Fxq "Name=$APP_ID" "$service" || die 'Deb service has the wrong D-Bus identity'
grep -Fxq 'Exec=/usr/bin/monkeyspaw --gapplication-service' "$service" || die 'Deb service has an unexpected Exec'
# Touch only the two known integration files. Keep desktop actions, URI fields,
# copyright, icons and executable bytes, including embedded /usr paths, intact.
sed -i -e 's@^Exec=/usr/bin/monkeyspaw\([[:space:]]\|$\)@Exec=monkeyspaw\1@' \
    -e 's|^TryExec=/usr/bin/monkeyspaw$|TryExec=monkeyspaw|' "$desktop"
sed -i 's|^Exec=/usr/bin/monkeyspaw --gapplication-service$|Exec=/app/bin/monkeyspaw --gapplication-service|' "$service"
grep -Fxq 'Exec=monkeyspaw %u' "$desktop" || die 'Deb desktop must forward one URI with %u'
grep -Fxq 'MimeType=x-scheme-handler/monkeyspaw;' "$desktop" || die 'Deb desktop has no invite URI handler'
cp "$ROOT/flatpak/$APP_ID.yml" "$WORK/$APP_ID.yml"

flatpak-builder --user --arch=x86_64 --disable-rofiles-fuse \
    --state-dir="$WORK/state" --repo="$WORK/repo" \
    "$WORK/build" "$WORK/$APP_ID.yml"
cmp "$WORK/debroot/usr/bin/monkeyspaw" "$WORK/build/files/bin/monkeyspaw"
# --runtime mounts Platform, not the SDK used by flatpak-builder --run.
# A missing library or wrong packaged version blocks bundling, without fallback.
# shellcheck disable=SC2016 # The sandbox shell expands this program.
flatpak build --runtime --die-with-parent "$WORK/build" sh -eu -c '
    dependencies=$(ldd /app/bin/monkeyspaw)
    printf "%s\n" "$dependencies"
    case "$dependencies" in *"not found"*) exit 1 ;; esac
    test "$(LD_BIND_NOW=1 /app/bin/monkeyspaw --version)" = "monkeyspaw $1"
' _ "$VERSION"
flatpak build-bundle --arch=x86_64 --runtime-repo="$FLATHUB_REPO" \
    "$WORK/repo" "$WORK/$BUNDLE" "$APP_ID"
[[ -s "$WORK/$BUNDLE" ]] || die 'flatpak build-bundle produced no bundle'
(cd "$WORK" && sha256sum "$BUNDLE" > "$BUNDLE.sha256")

mkdir -p "$ROOT/dist"
publishing=true
mv -f "$WORK/$BUNDLE" "$OUTPUT"
mv -f "$WORK/$BUNDLE.sha256" "$OUTPUT.sha256"
printf '==> Built %s and %s.sha256\n' "$OUTPUT" "$OUTPUT"
