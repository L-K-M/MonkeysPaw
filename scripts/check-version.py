#!/usr/bin/env python3
"""Check committed versions and tag-to-deb mapping, or print a build version.

    python3 scripts/check-version.py
    python3 scripts/check-version.py --app-version v0.1.0-beta.1
    python3 scripts/check-version.py --deb-version v0.1.0-beta.1
"""

import argparse
from pathlib import Path
import re
import sys


def app_version(value):
    version = value.removeprefix("v")
    number = r"(?:0|[1-9][0-9]*)"
    identifier = r"[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*"
    pattern = rf"{number}\.{number}\.{number}(?:-({identifier}))?(?:\+{identifier})?"
    match = re.fullmatch(pattern, version)
    if not match:
        raise ValueError(f"Invalid version: {value!r}; expected [v]X.Y.Z[-prerelease]")

    if match[1]:
        for part in match[1].split("."):
            if part.isdigit() and len(part) > 1 and part.startswith("0"):
                raise ValueError(f"Invalid prerelease identifier: {part!r}")

    return version


def deb_version(value):
    # Debian's last hyphen starts a revision, which sorts above the stable
    # version. A tilde instead makes the prerelease sort below that release.
    # Later hyphens inside the prerelease would land in Debian's revision slot,
    # so every hyphen becomes a tilde (v0.2.0-rc-1 -> 0.2.0~rc~1).
    version, separator, metadata = app_version(value).partition("+")
    upstream, hyphen, prerelease = version.partition("-")
    if hyphen:
        upstream += "~" + prerelease.replace("-", "~")
    return upstream + separator + metadata


def check_versions(root):
    project = (root / "MonkeysPaw.xcodeproj/project.pbxproj").read_text()
    versions = re.findall(r"\bMARKETING_VERSION\s*=\s*([^;\s]+)\s*;", project)
    readme = (root / "README.md").read_text()
    markers = re.findall(r"<!-- version -->(.*?)<!-- /version -->", readme)
    if len(markers) != 1 or not versions or set(versions) != {markers[0]}:
        raise ValueError("MARKETING_VERSION and the single README version marker must agree")

    app_version(markers[0])
    for tag, expected in (("v0.1.0", "0.1.0"), ("v0.1.0-beta.1", "0.1.0~beta.1"),
                          ("v0.2.0-rc-1", "0.2.0~rc~1")):
        if deb_version(tag) != expected:
            raise ValueError(f"Deb version mapping failed for {tag}")

    print(f"==> Committed version {markers[0]} and tag-to-deb mapping agree")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--app-version", metavar="VERSION")
    mode.add_argument("--deb-version", metavar="VERSION")
    arguments = parser.parse_args()
    try:
        if arguments.app_version is not None:
            print(app_version(arguments.app_version))
        elif arguments.deb_version is not None:
            print(deb_version(arguments.deb_version))
        else:
            check_versions(Path(__file__).resolve().parent.parent)
    except (OSError, ValueError) as error:
        print(f"!! {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
