#!/usr/bin/env python3
"""Check committed versions and tag-to-deb mapping, or print a build version.

    python3 scripts/check-version.py
    python3 scripts/check-version.py --app-version v0.1.0-beta.1
    python3 scripts/check-version.py --deb-version v0.1.0-beta.1
    python3 scripts/check-version.py --check-tag v0.1.0
    python3 scripts/check-version.py --committed-version
"""

import argparse
from pathlib import Path
import re
import sys


ANDROID_MAX_VERSION_CODE = 2_147_483_647


def numeric_version(value):
    number = r"(?:0|[1-9][0-9]*)"
    if not re.fullmatch(rf"{number}\.{number}\.{number}", value):
        raise ValueError("Committed versions must be numeric X.Y.Z without leading zeroes")
    return value


def android_version_declarations(text):
    """Read the two committed literals, retaining their spans for the bump hook."""
    declarations = []
    for key, literal in (("versionName", r'"(?P<value>[^"\r\n]*)"'),
                         ("versionCode", r"(?P<value>[1-9][0-9]*)")):
        lines = list(re.finditer(rf"(?m)^[ \t]*{key}[ \t]*=[^\r\n]*", text))
        if len(lines) != 1:
            raise ValueError(f"Android must declare exactly one {key}")
        declaration = re.fullmatch(
            rf"[ \t]*{key}[ \t]*=[ \t]*{literal}[ \t]*(?://[^\r\n]*)?", lines[0][0])
        if declaration is None:
            raise ValueError(f"Android {key} must be a single literal")
        start, end = declaration.span("value")
        declarations.append((declaration["value"], lines[0].start() + start,
                             lines[0].start() + end))

    numeric_version(declarations[0][0])
    code = declarations[1][0]
    if len(code) > 10 or int(code) > ANDROID_MAX_VERSION_CODE:
        raise ValueError("Android versionCode exceeds the positive Int range")
    return declarations


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


def check_versions(root, tag=None, quiet=False):
    project = (root / "MonkeysPaw.xcodeproj/project.pbxproj").read_text()
    versions = re.findall(r"\bMARKETING_VERSION\s*=\s*([^;\s]+)\s*;", project)
    readme = (root / "README.md").read_text()
    markers = re.findall(r"<!-- version -->(.*?)<!-- /version -->", readme)
    if len(markers) != 1 or not versions or set(versions) != {markers[0]}:
        raise ValueError("MARKETING_VERSION and the single README version marker must agree")

    numeric_version(markers[0])
    gradle = (root / "android/app/build.gradle.kts").read_text()
    android_name, _ = android_version_declarations(gradle)
    if android_name[0] != markers[0]:
        raise ValueError("Android versionName and the committed desktop version must agree")
    if tag is not None:
        if not tag.startswith("v"):
            raise ValueError("Release tag must start with v")
        version = app_version(tag)
        # The macOS packager accepts a numeric version and prerelease suffix,
        # but no build metadata. Reject it before starting either build.
        if "+" in version:
            raise ValueError("Release tags cannot include build metadata (+...)")
        core = re.match(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        if core is None:
            raise ValueError(f"Release tag {tag} has no numeric X.Y.Z core")
        numeric_core = core[0]
        if numeric_core != markers[0]:
            raise ValueError(f"Tag {tag} has numeric core {numeric_core}, "
                             f"but committed version is {markers[0]}")

    for tag, expected in (("v0.1.0", "0.1.0"), ("v0.1.0-beta.1", "0.1.0~beta.1"),
                          ("v0.2.0-rc-1", "0.2.0~rc~1")):
        if deb_version(tag) != expected:
            raise ValueError(f"Deb version mapping failed for {tag}")

    if not quiet:
        print(f"==> Desktop/Android version {markers[0]} and tag-to-deb mapping agree")
    return markers[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--app-version", metavar="VERSION")
    mode.add_argument("--deb-version", metavar="VERSION")
    mode.add_argument("--check-tag", metavar="TAG")
    mode.add_argument("--committed-version", action="store_true",
                      help="validate the committed versions and print the single value")
    arguments = parser.parse_args()
    try:
        if arguments.app_version is not None:
            print(app_version(arguments.app_version))
        elif arguments.deb_version is not None:
            print(deb_version(arguments.deb_version))
        elif arguments.committed_version:
            print(check_versions(Path(__file__).resolve().parent.parent, None, quiet=True))
        else:
            check_versions(Path(__file__).resolve().parent.parent, arguments.check_tag)
    except (OSError, ValueError) as error:
        print(f"!! {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
