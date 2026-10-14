#!/usr/bin/env bash
# Build the signed release APK and its checksum into dist/.
# Usage: scripts/package-android.sh [version] | --check | --help
# Uses the committed version by default; accepts [v]X.Y.Z[-prerelease] with
# the same numeric core. versionCode remains the committed integer.
# Requires the checked-in wrapper, JDK 17+, SDK platform android-37.0 and
# build-tools 36.0.0. Set JAVA_HOME and ANDROID_HOME, or use sdk.dir in
# android/local.properties. --check validates configuration without building.
set -euo pipefail

fail() { printf '!! %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# //'; }

[[ $# -le 1 ]] || fail 'Usage: scripts/package-android.sh [version] | --check'
check_only=false
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --check) check_only=true ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || fail 'Android packaging requires python3'
if [[ $# -eq 0 || "$check_only" == true ]]; then
  version="$(python3 "$repo_root/scripts/check-version.py" --committed-version)"
else
  version="$(python3 "$repo_root/scripts/check-version.py" --app-version "$1")"
fi
python3 "$repo_root/scripts/check-version.py" --check-tag "v$version" >/dev/null

[[ -x "$repo_root/android/gradlew" ]] || fail 'missing executable Android wrapper: android/gradlew'
for file in gradle-wrapper.jar gradle-wrapper.properties; do
  [[ -f "$repo_root/android/gradle/wrapper/$file" ]] || fail "missing Android wrapper file: $file"
done

if [[ -n "${JAVA_HOME:-}" ]]; then
  java="$JAVA_HOME/bin/java"
  javac="$JAVA_HOME/bin/javac"
else
  java="$(command -v java)" || fail 'requires JDK 17+ (set JAVA_HOME)'
  javac="$(command -v javac)" || fail 'requires JDK 17+ with javac (set JAVA_HOME)'
fi
[[ -x "$java" && -x "$javac" ]] || fail 'requires JDK 17+ with java and javac (check JAVA_HOME)'
java_version="$("$java" -version 2>&1)" || fail 'could not run JDK java -version'
javac_version="$("$javac" -version 2>&1)" || fail 'could not run JDK javac -version'
java_pattern='version "([0-9]+)'
javac_pattern='^javac ([0-9]+)'
[[ "$java_version" =~ $java_pattern && "${BASH_REMATCH[1]}" -ge 17 ]] || fail 'requires JDK 17+ (java is too old or unreadable)'
[[ "$javac_version" =~ $javac_pattern && "${BASH_REMATCH[1]}" -ge 17 ]] || fail 'requires JDK 17+ (javac is too old or unreadable)'

# Gradle gives local.properties precedence over SDK environment variables.
# shortcut: sdk.dir supports single-line =/: entries; extend for other Java property syntax.
sdk="$(python3 - "$repo_root/android/local.properties" <<'PY'
import os
from pathlib import Path
import re
import sys

properties = Path(sys.argv[1])
entries = re.findall(r"(?m)^[ \t]*sdk\.dir[ \t]*[=:][ \t]*(.*)$", properties.read_text()) \
    if properties.exists() else []
print(re.sub(r"\\(.)", r"\1", entries[-1]) if entries else
      os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or "")
PY
)" || fail 'could not read Android SDK configuration'
[[ -n "$sdk" && -d "$sdk" ]] || fail 'missing Android SDK (set ANDROID_HOME or android/local.properties sdk.dir)'
[[ -f "$sdk/platforms/android-37.0/android.jar" ]] || fail 'missing Android SDK platform: platforms;android-37.0'
[[ -x "$sdk/build-tools/36.0.0/aapt2" ]] || fail 'missing Android SDK build tools: build-tools;36.0.0'
if command -v sha256sum >/dev/null 2>&1; then
  checksum=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  checksum=(shasum -a 256)
else
  fail 'Android packaging requires sha256sum or shasum'
fi
[[ "$check_only" == false ]] || exit 0

export ANDROID_HOME="$sdk"
cd "$repo_root/android"
./gradlew --max-workers=2 :app:assembleRelease "-PreleaseVersion=$version" -Pandroid.builder.sdkDownload=false
apk="$repo_root/android/app/build/outputs/apk/release/app-release.apk"
[[ -s "$apk" ]] || fail 'Android release build did not produce app-release.apk'

staging="$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-android.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
artifact="monkeyspaw-v$version.apk"
cp "$apk" "$staging/$artifact"
(cd "$staging" && "${checksum[@]}" "$artifact" > "$artifact.sha256")
mkdir -p "$repo_root/dist"
mv "$staging/$artifact" "$staging/$artifact.sha256" "$repo_root/dist/"
printf '==> Staged dist/%s and .apk.sha256\n' "$artifact"
