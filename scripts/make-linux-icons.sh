#!/usr/bin/env bash
# Regenerate the committed Linux hicolor PNGs from media-sources/icon.png.
# Run from any directory with Python 3 and Pillow (Ubuntu: python3-pil).
# The eight sizes match Vervellum, including GNOME's 24, 48 and 64 pixel icons.
#
#   scripts/make-linux-icons.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Generating Linux app icons"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("!! Pillow is required (Ubuntu: apt install python3-pil)")

root = Path(sys.argv[1])
with Image.open(root / "media-sources/icon.png") as opened:
    # Pillow ignores LANCZOS for palette/bilevel images; resample in RGBA.
    source = opened.convert("RGBA")
    for size in (16, 24, 32, 48, 64, 128, 256, 512):
        directory = root / "packaging/icons/hicolor" / f"{size}x{size}" / "apps"
        directory.mkdir(parents=True, exist_ok=True)
        source.resize((size, size), Image.Resampling.LANCZOS).save(
            directory / "ch.lkmc.monkeyspaw.png", optimize=True
        )
        print(f"-- {size}x{size}")
PY
