#!/usr/bin/env bash
# Regenerate the macOS AppIcon PNGs from media-sources/icon.png with sips.
# iconutil also writes build/MonkeysPaw.icns for local packaging; Xcode builds
# its bundled icon from the asset catalog. Run from any directory on macOS.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "!! make-icons.sh requires macOS (sips and iconutil)" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon_source="$repo_root/media-sources/icon.png"
asset_icon_dir="$repo_root/MonkeysPaw/Resources/Assets.xcassets/AppIcon.appiconset"
asset_manifest="$asset_icon_dir/Contents.json"

if [[ ! -f "$icon_source" ]]; then
  echo "!! Source icon not found: $icon_source" >&2
  exit 1
fi

if [[ ! -f "$asset_manifest" ]]; then
  echo "!! App icon manifest not found: $asset_manifest" >&2
  exit 1
fi

icon_work_dir="$(mktemp -d)"
trap 'rm -rf "$icon_work_dir"' EXIT
iconset_dir="$icon_work_dir/MonkeysPaw.iconset"
mkdir -p "$iconset_dir" "$asset_icon_dir" "$repo_root/build"
asset_filenames=()

echo "==> Generating macOS app icons"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    asset_filename="icon_${size}x${size}@${scale}x.png"
    # iconutil omits the scale suffix for standard-resolution iconset members.
    iconset_filename="icon_${size}x${size}.png"
    if [[ "$scale" == 2 ]]; then
      iconset_filename="icon_${size}x${size}@2x.png"
    fi

    /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" "$icon_source" \
      --out "$iconset_dir/$iconset_filename" >/dev/null
    cp "$iconset_dir/$iconset_filename" "$asset_icon_dir/$asset_filename"
    asset_filenames+=("$asset_filename")
  done
done

echo "==> Checking generated icons against Contents.json"
python3 - "$asset_manifest" "${asset_filenames[@]}" <<'PY'
import json
from pathlib import Path
import sys

manifest_path = Path(sys.argv[1])
try:
    contents = json.loads(manifest_path.read_text(encoding="utf-8"))
    declared = {image["filename"] for image in contents["images"] if "filename" in image}
except (OSError, ValueError, KeyError, TypeError) as error:
    print(f"!! Cannot read app icon manifest {manifest_path}: {error}", file=sys.stderr)
    sys.exit(1)

# Track this run's output so stale files cannot hide an unproduced declaration.
produced = set(sys.argv[2:])
missing = sorted(declared - produced)
undeclared = sorted(produced - declared)
for filename in missing:
    print(f"!! {manifest_path}: declared icon was not produced: {filename}", file=sys.stderr)
for filename in undeclared:
    print(f"!! {manifest_path}: produced icon is not declared: {filename}", file=sys.stderr)
if missing or undeclared:
    sys.exit(1)
PY

/usr/bin/iconutil --convert icns --output "$repo_root/build/MonkeysPaw.icns" "$iconset_dir"
