#!/usr/bin/env bash
# Regenerate the macOS AppIcon PNGs from media-sources/icon.png with sips.
# iconutil also writes build/MonkeysPaw.icns for local packaging; Xcode builds
# its bundled icon from the asset catalog. Run from any directory on macOS.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: make-icons.sh requires macOS (sips and iconutil)" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon_source="$repo_root/media-sources/icon.png"
asset_icon_dir="$repo_root/MonkeysPaw/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$icon_source" ]]; then
  echo "error: source icon not found: $icon_source" >&2
  exit 1
fi

icon_work_dir="$(mktemp -d)"
trap 'rm -rf "$icon_work_dir"' EXIT
iconset_dir="$icon_work_dir/MonkeysPaw.iconset"
mkdir -p "$iconset_dir" "$asset_icon_dir" "$repo_root/build"

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
  done
done

/usr/bin/iconutil --convert icns --output "$repo_root/build/MonkeysPaw.icns" "$iconset_dir"
