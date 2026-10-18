#!/usr/bin/env bash
# Real tiny deb fixtures, fake Flatpak tools: no runtime downloads or Swift build.
set -euo pipefail

checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-flatpak-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$fixture/repo/scripts" "$fixture/repo/flatpak" "$fixture/bin" \
    "$fixture/input" "$fixture/tmp" "$fixture/payload/DEBIAN"
cp "$checkout/scripts/build-flatpak.sh" "$checkout/scripts/check-version.py" "$fixture/repo/scripts/"
cp "$checkout/flatpak/ch.lkmc.monkeyspaw.yml" "$fixture/repo/flatpak/"
REAL_DPKG_DEB="$(command -v dpkg-deb)"
REAL_SHA256SUM="$(command -v sha256sum)"
export REAL_DPKG_DEB REAL_SHA256SUM
export FAKE_FIXTURE="$fixture" TMPDIR="$fixture/tmp" PATH="$fixture/bin:$PATH"
builder="$fixture/repo/scripts/build-flatpak.sh"
app_id=ch.lkmc.monkeyspaw
version=0.2.0-rc-1
deb="$fixture/input/tested deb.deb"

mkdir -p "$fixture/payload/usr/bin" "$fixture/payload/usr/share/applications" \
    "$fixture/payload/usr/share/dbus-1/services" "$fixture/payload/usr/share/doc/monkeyspaw"
cat > "$fixture/payload/usr/bin/monkeyspaw" <<'SH'
#!/usr/bin/env bash
# Binary-like content must stay unchanged: /usr/do-not-rewrite
printf 'monkeyspaw %s\n' "${FAKE_BINARY_VERSION:-0.2.0-rc-1}"
SH
chmod +x "$fixture/payload/usr/bin/monkeyspaw"
cat > "$fixture/payload/usr/share/applications/$app_id.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Monkey's Paw
Exec=/usr/bin/monkeyspaw %u
TryExec=/usr/bin/monkeyspaw
Icon=ch.lkmc.monkeyspaw
StartupWMClass=ch.lkmc.monkeyspaw
DBusActivatable=true
MimeType=x-scheme-handler/monkeyspaw;
Comment=Keep /usr/share and URI/action fields unchanged
Actions=toggle;repeat;
[Desktop Action toggle]
Name=Toggle Panel
Exec=gapplication action ch.lkmc.monkeyspaw toggle
[Desktop Action repeat]
Name=Repeat Last Prompt
Exec=gapplication action ch.lkmc.monkeyspaw repeat
DESKTOP
cat > "$fixture/expected.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Monkey's Paw
Exec=monkeyspaw %u
TryExec=monkeyspaw
Icon=ch.lkmc.monkeyspaw
StartupWMClass=ch.lkmc.monkeyspaw
DBusActivatable=true
MimeType=x-scheme-handler/monkeyspaw;
Comment=Keep /usr/share and URI/action fields unchanged
Actions=toggle;repeat;
[Desktop Action toggle]
Name=Toggle Panel
Exec=gapplication action ch.lkmc.monkeyspaw toggle
[Desktop Action repeat]
Name=Repeat Last Prompt
Exec=gapplication action ch.lkmc.monkeyspaw repeat
DESKTOP
cat > "$fixture/payload/usr/share/dbus-1/services/$app_id.service" <<'SERVICE'
[D-BUS Service]
Name=ch.lkmc.monkeyspaw
Exec=/usr/bin/monkeyspaw --gapplication-service
SERVICE
printf 'Keep /usr/share copyright bytes\n' > "$fixture/payload/usr/share/doc/monkeyspaw/copyright"
for size in 16 24 32 48 64 128 256 512; do
    icon="usr/share/icons/hicolor/${size}x${size}/apps/$app_id.png"
    mkdir -p "$fixture/payload/$(dirname "$icon")"
    printf 'icon %s\n' "$size" > "$fixture/payload/$icon"
done
make_deb() {
    cat > "$fixture/payload/DEBIAN/control" <<CONTROL
Package: ${4:-monkeyspaw}
Version: ${3:-0.2.0~rc~1}
Architecture: ${2:-amd64}
Maintainer: Test <test@example.invalid>
Description: Test fixture
CONTROL
    "$REAL_DPKG_DEB" --build "$fixture/payload" "$1" >/dev/null
}
make_deb "$deb"

cat > "$fixture/bin/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'deb %s %s\n' "$1" "$2" >> "$FAKE_FIXTURE/invocations"
if [[ "$1" == --extract && "${FAKE_FAILURE:-}" == extract ]]; then exit 31; fi
exec "$REAL_DPKG_DEB" "$@"
SH
cat > "$fixture/bin/flatpak-builder" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'builder\n' >> "$FAKE_FIXTURE/invocations"
[[ "$1 $2 $3" == '--user --arch=x86_64 --disable-rofiles-fuse' ]]
[[ "$4" == --state-dir=* && "$5" == --repo=* && $# -eq 7 ]]
build=$6
manifest=$7
[[ "${FAKE_FAILURE:-}" != builder ]] || exit 32
mkdir -p "${4#--state-dir=}" "${5#--repo=}"
mkdir "$build"
cp -a "$(dirname "$manifest")/stage" "$build/files"
cmp "$FAKE_FIXTURE/payload/usr/bin/monkeyspaw" "$build/files/bin/monkeyspaw"
cmp "$FAKE_FIXTURE/expected.desktop" "$build/files/share/applications/ch.lkmc.monkeyspaw.desktop"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$build/files/share/applications/ch.lkmc.monkeyspaw.desktop"
fi
grep -Fxq 'Exec=/app/bin/monkeyspaw --gapplication-service' \
    "$build/files/share/dbus-1/services/ch.lkmc.monkeyspaw.service"
cmp "$FAKE_FIXTURE/payload/usr/share/doc/monkeyspaw/copyright" "$build/files/share/doc/monkeyspaw/copyright"
diff -r "$FAKE_FIXTURE/payload/usr/share/icons" "$build/files/share/icons"
if [[ "${FAKE_FAILURE:-}" == changed-binary ]]; then
    printf 'changed\n' >> "$build/files/bin/monkeyspaw"
fi
if [[ "${FAKE_FAILURE:-}" == signal ]]; then kill -TERM "$PPID"; fi
SH
cat > "$fixture/bin/flatpak" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'flatpak %s\n' "$*" >> "$FAKE_FIXTURE/invocations"
case "$1" in
    info)
        [[ "$2" == --user && $# -eq 3 ]]
        [[ "$3" == org.gnome.Platform/x86_64/50 || "$3" == org.gnome.Sdk/x86_64/50 ]]
        [[ "${FAKE_MISSING_RUNTIME:-}" != "$3" ]] || exit 33
        ;;
    build)
        [[ "$2 $3" == '--runtime --die-with-parent' ]]
        build=$4
        shift 4
        [[ "$1 $2 $3" == 'sh -eu -c' ]]
        program=${4//\/app\//$build/files/}
        shift 4
        sh -eu -c "$program" "$@"
        ;;
    build-bundle)
        [[ "$2" == --arch=x86_64 ]]
        [[ "$3" == --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo ]]
        [[ -d "$4" && "$6" == ch.lkmc.monkeyspaw && $# -eq 6 ]]
        printf 'new bundle\n' > "$5"
        [[ "${FAKE_FAILURE:-}" != bundle ]] || exit 34
        ;;
    *) exit 35 ;;
esac
SH
cat > "$fixture/bin/ldd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == */build/files/bin/monkeyspaw ]]
[[ "${FAKE_FAILURE:-}" != ldd ]] || exit 36
if [[ "${FAKE_FAILURE:-}" == missing-library ]]; then
    printf 'libgtk-4.so.1 => not found\n'
else
    printf 'libgtk-4.so.1 => /usr/lib/libgtk-4.so.1\n'
fi
SH
cat > "$fixture/bin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_FAILURE:-}" != checksum ]] || exit 37
exec "$REAL_SHA256SUM" "$@"
SH
chmod +x "$fixture/bin/"*

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_cleanup() {
    [[ -z "$(find "$fixture/tmp" -mindepth 1 -print -quit)" ]] || fail 'Temporary work survived exit'
    [[ ! -e "$fixture/repo/.flatpak-builder" ]] || fail 'Builder state leaked into the checkout'
}
expect_failure() {
    local label=$1 output status
    shift
    rm -rf "$fixture/repo/dist"
    : > "$fixture/invocations"
    if output=$("$@" 2>&1); then fail "$label unexpectedly succeeded: $output"; else status=$?; fi
    [[ "$status" -eq "${EXPECTED_STATUS:-1}" ]] || fail "$label exited $status: $output"
    [[ ! -e "$fixture/repo/dist" ]] || fail "$label published an artifact"
    assert_cleanup
    printf 'PASS: %s\n' "$label"
}

expect_failure 'explicit deb required' bash "$builder"
expect_failure 'missing path never guesses another deb' bash "$builder" "$fixture/input/missing.deb" "$version"
[[ ! -s "$fixture/invocations" ]] || fail 'Missing path consulted another deb or Flatpak'
expect_failure 'directory is not a deb' bash "$builder" "$fixture/input" "$version"
expect_failure 'invalid version' bash "$builder" "$deb" '../invalid'
expect_failure 'release build metadata rejected' bash "$builder" "$deb" '0.2.0+build'
make_deb "$fixture/input/arm64.deb" arm64
expect_failure 'wrong architecture' bash "$builder" "$fixture/input/arm64.deb" "$version"
expect_failure 'wrong version' bash "$builder" "$deb" '0.2.0'
make_deb "$fixture/input/foreign.deb" amd64 '0.2.0~rc~1' foreign
expect_failure 'wrong package' bash "$builder" "$fixture/input/foreign.deb" "$version"
for runtime in org.gnome.Platform org.gnome.Sdk; do
    expect_failure "missing $runtime 50" env FAKE_MISSING_RUNTIME="$runtime/x86_64/50" bash "$builder" "$deb" "$version"
done

mkdir "$fixture/payload/etc"
make_deb "$fixture/input/outside.deb"
rmdir "$fixture/payload/etc"
expect_failure 'payload outside /usr' bash "$builder" "$fixture/input/outside.deb" "$version"
ln -s /usr/bin/monkeyspaw "$fixture/payload/usr/bin/link"
make_deb "$fixture/input/link.deb"
rm "$fixture/payload/usr/bin/link"
expect_failure 'unsupported symbolic link' bash "$builder" "$fixture/input/link.deb" "$version"
mv "$fixture/payload/usr/bin/monkeyspaw" "$fixture/binary"
make_deb "$fixture/input/missing-binary.deb"
mv "$fixture/binary" "$fixture/payload/usr/bin/monkeyspaw"
expect_failure 'wrong binary path' bash "$builder" "$fixture/input/missing-binary.deb" "$version"
cp "$fixture/payload/usr/share/applications/$app_id.desktop" "$fixture/original.desktop"
sed -i '/^MimeType=/d' "$fixture/payload/usr/share/applications/$app_id.desktop"
make_deb "$fixture/input/missing-mime.deb"
expect_failure 'missing invite MIME export' bash "$builder" "$fixture/input/missing-mime.deb" "$version"
cp "$fixture/original.desktop" "$fixture/payload/usr/share/applications/$app_id.desktop"
sed -i 's|^Exec=/usr/bin/monkeyspaw %u$|Exec=/usr/bin/monkeyspaw|' "$fixture/payload/usr/share/applications/$app_id.desktop"
make_deb "$fixture/input/missing-uri.deb"
expect_failure 'missing URI forwarding' bash "$builder" "$fixture/input/missing-uri.deb" "$version"
cp "$fixture/original.desktop" "$fixture/payload/usr/share/applications/$app_id.desktop"

for failure in extract builder changed-binary missing-library ldd bundle checksum signal; do
    case "$failure" in
        extract) status=31 ;;
        builder) status=32 ;;
        ldd) status=36 ;;
        bundle) status=34 ;;
        checksum) status=37 ;;
        signal) status=143 ;;
        *) status=1 ;;
    esac
    EXPECTED_STATUS="$status" expect_failure "$failure failure and cleanup" \
        env FAKE_FAILURE="$failure" bash "$builder" "$deb" "$version"
done
expect_failure 'binary version differs from control metadata' env FAKE_BINARY_VERSION=0.2.0 bash "$builder" "$deb" "$version"

# A newer unrelated package is present. Only the caller's relative path, with
# spaces, may be opened; the hyphenated app version is the output name.
make_deb "$fixture/input/newest.deb" amd64 9.9.9
: > "$fixture/invocations"
(cd "$fixture/input" && bash "$builder" './tested deb.deb')
bundle="monkeyspaw_${version}_x86_64.flatpak"
[[ "$(cat "$fixture/repo/dist/$bundle")" == 'new bundle' ]] || fail 'Bundle was not generated'
(cd "$fixture/repo/dist" && "$REAL_SHA256SUM" -c "$bundle.sha256")
[[ "$(find "$fixture/repo/dist" -type f | wc -l)" -eq 2 ]] || fail 'Unexpected output files'
if grep -Fq 'newest.deb' "$fixture/invocations"; then fail 'Guessed the newest deb'; fi
assert_cleanup
printf 'PASS: explicit relative path, payload preservation, versioned checksum and successful cleanup\n'

# A failed rerun cannot reuse the prior successful output as proof of success.
if FAKE_FAILURE=bundle bash "$builder" "$deb" "$version" >/dev/null 2>&1; then fail 'Stale artifact hid a failure'; fi
[[ "$(cat "$fixture/repo/dist/$bundle")" == 'new bundle' ]] || fail 'Failure replaced the prior output'
assert_cleanup
printf 'Flatpak script tests passed.\n'
