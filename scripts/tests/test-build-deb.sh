#!/usr/bin/env bash
# Real dpkg packaging over a fake toolchain: no Swift build or binary tools.
set -euo pipefail

checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-deb-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$fixture/repo/packaging/linux" \
    "$fixture/repo/scripts" "$fixture/repo/Sources/MonkeysPawLinux" \
    "$fixture/repo/MonkeysPaw/Resources" "$fixture/repo/MonkeysPaw.xcodeproj" \
    "$fixture/repo/android/app" "$fixture/bin"
cp "$checkout/packaging/build-deb.sh" "$fixture/repo/packaging/"
cp "$checkout/scripts/check-version.py" "$fixture/repo/scripts/"
cp "$checkout/packaging/linux/ch.lkmc.monkeyspaw.desktop" \
    "$checkout/packaging/linux/ch.lkmc.monkeyspaw.service" "$fixture/repo/packaging/linux/"
cp -R "$checkout/MonkeysPaw/Resources/WishPaw" "$fixture/repo/MonkeysPaw/Resources/"
builder="$fixture/repo/packaging/build-deb.sh"
app_id=ch.lkmc.monkeyspaw
version=0.1.0-beta.1
deb_version=0.1.0~beta.1

# The no-argument check-version.py call validates the committed versions.
printf '<!-- version -->1.0.0<!-- /version -->\n' > "$fixture/repo/README.md"
printf 'MARKETING_VERSION = 1.0.0;\n' > "$fixture/repo/MonkeysPaw.xcodeproj/project.pbxproj"
printf 'versionCode = 2\nversionName = "1.0.0"\n' > "$fixture/repo/android/app/build.gradle.kts"
for size in 16 24 32 48 64 128 256 512; do
    icon="$fixture/repo/packaging/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon"
    printf 'icon %s\n' "$size" > "$icon/$app_id.png"
done

export FAKE_FIXTURE="$fixture" FAKE_REPO="$fixture/repo" FAKE_BIN_PATH="$fixture/bin-path"
export SWIFT="$fixture/bin/swift" PATH="$fixture/bin:$PATH"
cat > "$fixture/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -print-target-info ]]; then
    printf '{"paths": {"runtimeResourcePath": "%s/toolchain/usr/lib/swift"}}\n' "$FAKE_FIXTURE"
    exit 0
fi
if [[ "${!#}" == --show-bin-path ]]; then
    printf '%s\n' "$FAKE_BIN_PATH"
    exit 0
fi
mkdir -p "$FAKE_BIN_PATH"
version="$(sed -n 's/.*value = "\([^"]*\)".*/\1/p' \
    "$FAKE_REPO/Sources/MonkeysPawLinux/PackagedBuildVersion.generated.swift")"
[[ -n "$version" ]]
printf '#!/usr/bin/env bash\nprintf "monkeyspaw %%s\\n" "%s"\n' "$version" \
    > "$FAKE_BIN_PATH/monkeyspaw"
chmod +x "$FAKE_BIN_PATH/monkeyspaw"
SH
cat > "$fixture/bin/readelf" <<'SH'
#!/usr/bin/env bash
printf '0x0000000000000001 (NEEDED)             Shared library: [libgtk-4.so.1]\n'
SH
cat > "$fixture/bin/strip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture/bin/dpkg-shlibdeps" <<'SH'
#!/usr/bin/env bash
printf 'shlibs:Depends=libgtk-4-1 (>= 4.14.2), libglib2.0-0t64 (>= 2.80.0)\n'
SH
chmod +x "$fixture/bin/"*

# License notices have their own tests; here they only need to land where
# the builder stages them.
cat > "$fixture/repo/scripts/swiftpm-notices.py" <<'PY'
import sys
open(sys.argv[sys.argv.index("--output") + 1], "w").write("notices\n")
PY
cat > "$fixture/repo/scripts/deb-copyright.py" <<'PY'
import sys
if sys.argv[1] == "generate":
    open(sys.argv[sys.argv.index("--copyright-out") + 1], "w").write("copyright\n")
PY
printf 'pass\n' > "$fixture/repo/scripts/static-runtime-notices.py"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_clean() {
    local source="$fixture/repo/Sources/MonkeysPawLinux/PackagedBuildVersion.generated.swift"
    [[ ! -e "$source" ]] || fail 'Version source survived the build'
}

frame_source="$fixture/repo/MonkeysPaw/Resources/WishPaw"
mv "$frame_source/wish-paw-03@2x.png" "$fixture/frame"
if output="$(bash "$builder" "v$version" 2>&1)"; then
    fail 'A missing WishPaw frame unexpectedly built'
fi
grep -Fq 'wish-paw-03@2x.png' <<< "$output" || fail "Missing-frame error did not name the input: $output"
[[ ! -e "$fixture/repo/dist" ]] || fail 'Failed build published a deb'
assert_clean
mv "$fixture/frame" "$frame_source/wish-paw-03@2x.png"
printf 'PASS: missing WishPaw frame fails before the build and names the input\n'

bash "$builder" "v$version"
arch="$(dpkg --print-architecture)"
deb="$fixture/repo/dist/monkeyspaw_${deb_version}_${arch}.deb"
[[ -f "$deb" ]] || fail 'No deb was produced'
(cd "$(dirname "$deb")" && sha256sum -c "$(basename "$deb").sha256")

payload="$fixture/payload"
dpkg-deb --extract "$deb" "$payload"
[[ -x "$payload/usr/bin/monkeyspaw" ]] || fail 'Binary lost its executable bit'
frame_dir="$payload/usr/share/monkeyspaw/wish-paw"
for frame in 00 01 02 03 04 05 06 07 08; do
    staged="$frame_dir/wish-paw-$frame@2x.png"
    [[ -f "$staged" ]] || fail "Missing packaged frame: $staged"
    [[ "$(stat -c %a "$staged")" == 644 ]] || fail "Wrong mode on $staged"
    cmp "$frame_source/wish-paw-$frame@2x.png" "$staged" || fail "Frame bytes changed: $staged"
done
[[ "$(find "$frame_dir" -type f | wc -l)" -eq 9 ]] || fail 'Unexpected files under wish-paw/'
assert_clean
printf 'PASS: all nine WishPaw frames ship at /usr/share/monkeyspaw/wish-paw mode 0644\n'
printf 'Deb script tests passed.\n'
