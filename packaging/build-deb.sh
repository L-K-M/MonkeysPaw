#!/usr/bin/env bash
# Build Monkey's Paw for Linux and package it for Ubuntu 24.04 or newer.
# Run on noble, the oldest supported Ubuntu: linked library versions set the floor.
# Requires Swift 6.4, libgtk-4-dev, pkg-config, python3, dpkg-dev and binutils.
# Uses committed icons; regenerate them with scripts/make-linux-icons.sh (Pillow).
# Set SWIFT to the Swift executable when it is not on PATH.
#
#   packaging/build-deb.sh [version]
#
# Version is [v]X.Y.Z[-prerelease], from the argument or GITHUB_REF_NAME.
# The binary reports X.Y.Z[-prerelease]; the deb uses X.Y.Z[~prerelease].
# Output: dist/monkeyspaw_<deb-version>_<architecture>.deb and .deb.sha256
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="ch.lkmc.monkeyspaw"

if [[ $# -gt 1 || -z "${1:-${GITHUB_REF_NAME:-}}" ]]; then
    echo "!! Usage: packaging/build-deb.sh [version] (or set GITHUB_REF_NAME)" >&2
    exit 1
fi

python3 "$ROOT/scripts/check-version.py"
VERSION="$(python3 "$ROOT/scripts/check-version.py" --app-version "${1:-$GITHUB_REF_NAME}")"
DEB_VERSION="$(python3 "$ROOT/scripts/check-version.py" --deb-version "$VERSION")"
dpkg --validate-version "$DEB_VERSION"
ARCH="$(dpkg --print-architecture)"
STAGE="$ROOT/build/deb/monkeyspaw_${DEB_VERSION}_${ARCH}"
VERSION_SOURCE="$ROOT/Sources/MonkeysPawLinux/PackagedBuildVersion.generated.swift"
deps_work=""

# Never overwrite another in-progress package build's version source. Cleanup
# on failure too, so an ordinary development build cannot inherit a release.
if ! (set -o noclobber; printf 'enum PackagedBuildVersion { static let value = "%s" }\n' \
    "$VERSION" > "$VERSION_SOURCE") 2>/dev/null; then
    echo "!! Version source already exists: $VERSION_SOURCE" >&2
    echo "!! Another package build may be running; if not, a killed build left it behind: delete it and retry." >&2
    exit 1
fi
cleanup() {
    rm -f "$VERSION_SOURCE"
    if [[ -n "$deps_work" ]]; then
        rm -rf "$deps_work"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"
swift_build=("${SWIFT:-swift}" build -c release --product monkeyspaw
    --scratch-path "$ROOT/build/deb-swift" --static-swift-stdlib
    # Swift 6.4's swift-build omits Foundation support archives in static links (§16).
    --build-system native -Xswiftc -DMONKEYSPAW_PACKAGED_VERSION)

echo "==> Building $VERSION (release, static Swift runtime and Foundation)"
"${swift_build[@]}"
BINARY="$("${swift_build[@]}" --show-bin-path)/monkeyspaw"
if [[ ! -x "$BINARY" ]]; then
    echo "!! Binary was not built: $BINARY" >&2
    exit 1
fi

# GTK and glibc stay dynamic. Swift and Foundation must not depend on the
# builder's toolchain at runtime, including ICU and dispatch support libraries.
dynamic_libraries="$(readelf -d "$BINARY")"
if [[ "$dynamic_libraries" =~ \(NEEDED\).*lib(swift|Foundation|CoreFoundation|dispatch|BlocksRuntime|_) ]]; then
    echo "!! Binary still links a dynamic Swift or Foundation library" >&2
    exit 1
fi
if [[ "$("$BINARY" --version)" != "monkeyspaw $VERSION" ]]; then
    echo "!! Binary does not report the requested version" >&2
    exit 1
fi

echo "==> Staging"
rm -rf "$STAGE"
install -d "$STAGE/DEBIAN" "$STAGE/usr/bin" \
    "$STAGE/usr/share/applications" "$STAGE/usr/share/dbus-1/services" \
    "$STAGE/usr/share/doc/monkeyspaw"
install -m 0755 "$BINARY" "$STAGE/usr/bin/monkeyspaw"
strip --strip-unneeded "$STAGE/usr/bin/monkeyspaw"
install -m 0644 "$ROOT/packaging/linux/$APP_ID.desktop" "$STAGE/usr/share/applications/"
# Cold gapplication actions rely on this service's absolute Exec and service flag.
install -m 0644 "$ROOT/packaging/linux/$APP_ID.service" "$STAGE/usr/share/dbus-1/services/"
for size in 16 24 32 48 64 128 256 512; do
    install -D -m 0644 "$ROOT/packaging/icons/hicolor/${size}x${size}/apps/$APP_ID.png" \
        "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done
# Notices for what --static-swift-stdlib links into the binary: the SwiftPM
# pins with libyaml and the Unicode tables, ICU and the Swift runtime. Both
# generators fail on a missing text, and the runtime check fails when the
# binary links an ICU version or runtime that the notices do not name.
DOC="$STAGE/usr/share/doc/monkeyspaw"
SWIFT_RESOURCES="$("${SWIFT:-swift}" -print-target-info 2>/dev/null | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
# runtimeResourcePath is <prefix>/usr/lib/swift; the license is in <prefix>/usr/share/swift.
export SWIFT_LICENSE="$SWIFT_RESOURCES/../../share/swift/LICENSE.txt"
python3 -I "$ROOT/scripts/swiftpm-notices.py" --title monkeyspaw \
    --resolved "$ROOT/Package.resolved" --checkouts "$ROOT/build/deb-swift/checkouts" \
    --overrides "$ROOT/packaging/licenses/third-party-notices.json" \
    --output "$DOC/Third-Party-Notices.txt"
python3 -I "$ROOT/scripts/deb-copyright.py" generate "$ROOT/packaging/licenses/components.json" \
    --copyright-out "$DOC/copyright"
python3 -I "$ROOT/scripts/deb-copyright.py" check "$DOC/copyright" --no-common-licenses
for notices in "$DOC/Third-Party-Notices.txt" "$DOC/copyright"; do
    python3 -I "$ROOT/scripts/static-runtime-notices.py" check "$STAGE/usr/bin/monkeyspaw" --notices "$notices"
done
chmod 0644 "$DOC/Third-Party-Notices.txt" "$DOC/copyright"
printf 'monkeyspaw (%s) unstable; urgency=low\n\n  * Release %s.\n\n -- L-K-M <noreply@lkmc.ch>  %s\n' \
    "$DEB_VERSION" "$VERSION" "$(date -R)" \
    | gzip -9n > "$STAGE/usr/share/doc/monkeyspaw/changelog.gz"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$STAGE/usr/share/applications/$APP_ID.desktop"
else
    echo "-- desktop-file-validate unavailable; desktop validation skipped"
fi

echo "==> Resolving dependencies"
if ! command -v dpkg-shlibdeps >/dev/null 2>&1; then
    echo "!! dpkg-shlibdeps is required (Ubuntu: install dpkg-dev); staging is in $STAGE" >&2
    exit 1
fi
deps_work="$(mktemp -d)"
mkdir -p "$deps_work/debian"
cat > "$deps_work/debian/control" <<'SHLIBS'
Source: monkeyspaw
Section: utils
Priority: optional
Maintainer: L-K-M <noreply@lkmc.ch>

Package: monkeyspaw
Architecture: any
Description: Pick and fill prompts from a Markdown library
SHLIBS
# Fail on missing library metadata; a hand-written fallback can silently use
# pre-t64 package names and produce a deb that cannot install on noble.
(cd "$deps_work" && dpkg-shlibdeps -O -e"$STAGE/usr/bin/monkeyspaw") > "$deps_work/deps"
DEPENDS="$(sed -n 's/^shlibs:Depends=//p' "$deps_work/deps")"
if [[ -z "$DEPENDS" ]]; then
    echo "!! dpkg-shlibdeps returned no dependencies" >&2
    exit 1
fi
# gapplication is invoked by desktop shortcuts rather than linked into the ELF.
# X11 focus capture also needs xprop from the recommended x11-utils package.
DEPENDS="$DEPENDS, libglib2.0-bin"
INSTALLED_SIZE="$(du -ks "$STAGE/usr" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: monkeyspaw
Version: $DEB_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Recommends: libsecret-tools, ydotool, xdotool, x11-utils
Installed-Size: $INSTALLED_SIZE
Maintainer: L-K-M <noreply@lkmc.ch>
Homepage: https://github.com/L-K-M/MonkeysPaw
Description: Pick and fill prompts from a Markdown library
 Summon the panel with a desktop shortcut, pick a prompt and fill its
 placeholders, then paste the result into the text field you were using.
 Prompts are Markdown files with YAML front matter that you can edit with
 your own tools.
CONTROL

echo "==> Packaging"
mkdir -p "$ROOT/dist"
OUTPUT="$ROOT/dist/monkeyspaw_${DEB_VERSION}_${ARCH}.deb"
# Package payloads must be root-owned even when the builder is unprivileged.
dpkg-deb --root-owner-group --build "$STAGE" "$OUTPUT"
(cd "$ROOT/dist" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "==> Built $OUTPUT and $OUTPUT.sha256"
dpkg-deb --info "$OUTPUT"
