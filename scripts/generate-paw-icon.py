#!/usr/bin/env python3
"""Regenerate the monochrome paw identity assets from media-sources/paw-symbol.svg.

One canonical silhouette feeds every template/monochrome surface:

- MonkeysPaw/Resources/Assets.xcassets/MenuBarIcon.imageset/paw-symbol.svg:
  the same vector restated at an 18-unit size (18 pt) for the macOS menu
  bar template image.
- MonkeysPaw/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json:
  universal vector image kept as vector and rendered as a template.
- android/app/src/main/res/drawable/ic_paw.xml: white VectorDrawable for the
  Quick Settings tile, the tile-add dialog and the static shortcut.
- android/app/src/main/res/drawable/ic_paw_monochrome.xml: the same path on a
  108dp adaptive-icon canvas, scaled into the 66dp safe circle (API 33
  themed icon layer).
- android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml: the adaptive
  icon with the monochrome layer added; kept in a v33 qualifier so API 26-32
  never parse the monochrome element.

Run from any directory with Python 3; no other tools are required.
"""

import re
import sys
from pathlib import Path


ANDROID_NS = "http://schemas.android.com/apk/res/android"
# The paw's 24-unit glyph scaled into the 66dp themed-icon safe circle:
# 24 * 2.5 = 60dp, centered by (108 - 60) / 2 = 24dp.
MONO_SCALE = "2.5"
MONO_TRANSLATE = "24"


def paw_path(svg_text):
    match = re.search(r"<path\b[^>]*\bd=\"([^\"]+)\"", svg_text)
    if match is None:
        sys.exit("!! media-sources/paw-symbol.svg must contain one <path d=...>")
    return match.group(1)


def main():
    root = Path(__file__).resolve().parent.parent
    svg_path = root / "media-sources/paw-symbol.svg"
    svg = svg_path.read_text(encoding="utf-8")
    path = paw_path(svg)

    outputs = {}

    # Unitless 18 reads as 18 pt in the compiled asset catalog.
    imageset_svg = re.sub(r'width="24"', 'width="18"', svg, count=1)
    imageset_svg = re.sub(r'height="24"', 'height="18"', imageset_svg, count=1)
    outputs["MonkeysPaw/Resources/Assets.xcassets/MenuBarIcon.imageset/paw-symbol.svg"] = imageset_svg

    outputs["MonkeysPaw/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json"] = """{
  "images" : [
    {
      "filename" : "paw-symbol.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
"""

    outputs["android/app/src/main/res/drawable/ic_paw.xml"] = f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="{ANDROID_NS}"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="{path}" />
</vector>
"""

    outputs["android/app/src/main/res/drawable/ic_paw_monochrome.xml"] = f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="{ANDROID_NS}"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <group
        android:scaleX="{MONO_SCALE}"
        android:scaleY="{MONO_SCALE}"
        android:translateX="{MONO_TRANSLATE}"
        android:translateY="{MONO_TRANSLATE}">
        <path
            android:fillColor="#FF000000"
            android:pathData="{path}" />
    </group>
</vector>
"""

    outputs["android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml"] = f"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="{ANDROID_NS}">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground>
        <inset android:drawable="@mipmap/ic_launcher_legacy" android:inset="21dp" />
    </foreground>
    <monochrome android:drawable="@drawable/ic_paw_monochrome" />
</adaptive-icon>
"""

    for relative, text in outputs.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        print(f"-- {relative}")


if __name__ == "__main__":
    main()
