#!/usr/bin/env python3
"""Verify a staged APK/checksum against committed versions and the public signer.

Usage: python3 scripts/verify-android-release.py APK X.Y.Z[-prerelease]
Set ANDROID_HOME (or ANDROID_SDK_ROOT) to the SDK with build-tools 36.0.0,
and put the JDK's bin directory on PATH for apksigner.
"""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys


# Fixed by docs/decisions/0001-android-zero-secret-signing.md, not the build's key.
SIGNER_SHA256 = "76a19df68d562789f6ea990b23232875b70a98c9996ba81e794ccab063edd765"


def tool_output(tool, arguments):
    result = subprocess.run([str(tool.resolve(strict=True)), *arguments],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=60)
    if result.returncode != 0:
        raise ValueError(f"{tool.name} rejected the APK")
    return result.stdout


def verify(apk, version, root, tools):
    spec = importlib.util.spec_from_file_location("check_version", Path(__file__).with_name("check-version.py"))
    versions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(versions)
    versions.check_versions(root, f"v{version}", quiet=True)
    _, code = versions.android_version_declarations((root / "android/app/build.gradle.kts").read_text())
    if apk.name != f"monkeyspaw-v{version}.apk" or not apk.is_file() or apk.stat().st_size == 0:
        raise ValueError("Expected a nonempty APK with the full release version in its filename")

    digest = hashlib.sha256()
    with apk.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    checksum = apk.with_suffix(".apk.sha256").read_text()
    if checksum != f"{digest.hexdigest()}  {apk.name}\n":
        raise ValueError("APK checksum must contain exactly its SHA-256 and relative filename")

    badging = tool_output(tools / "aapt2", ["dump", "badging", str(apk.resolve())])
    packages = re.findall(r"^package: (.+)$", badging, re.MULTILINE)
    expected = {"name": "ch.lkmc.monkeyspaw", "versionCode": code[0], "versionName": version}
    if len(packages) != 1:
        raise ValueError("Expected exactly one APK package declaration")
    fields = re.findall(r"\b(name|versionCode|versionName)='([^']*)'", packages[0])
    if len(fields) != len(expected) or dict(fields) != expected:
        raise ValueError("APK application ID, versionName or committed versionCode differs")
    for key, value in (("minSdkVersion", "26"), ("targetSdkVersion", "37")):
        if re.findall(rf"^{key}:'([^']*)'$", badging, re.MULTILINE) != [value]:
            raise ValueError(f"APK {key} differs from the pinned Android API")

    signature = tool_output(tools / "apksigner", ["verify", "--verbose", "--print-certs", str(apk.resolve())])
    fingerprints = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$",
                              signature, re.MULTILINE)
    if [value.lower() for value in fingerprints] != [SIGNER_SHA256]:
        raise ValueError("APK must have exactly the recorded public signer")
    return f"{version} (code {code[0]}), SHA-256 {digest.hexdigest()}, signer {SIGNER_SHA256}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("version")
    arguments = parser.parse_args()
    try:
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        if not sdk:
            raise ValueError("Set ANDROID_HOME to verify the APK with pinned SDK tools")
        evidence = verify(arguments.apk, arguments.version, Path(__file__).resolve().parents[1],
                          Path(sdk) / "build-tools/36.0.0")
        print(f"==> Verified Android {evidence}")
    except (OSError, SyntaxError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"!! {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
