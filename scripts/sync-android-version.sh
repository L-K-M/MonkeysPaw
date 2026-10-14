#!/usr/bin/env bash
# lkm-release post-bump hook: sync the numeric version and advance the code once.
# Requires RELEASE_NEW_VERSION; an already aligned version is a no-op.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import os
from pathlib import Path
import runpy
import sys
import tempfile

root = Path(sys.argv[1])
try:
    checker = runpy.run_path(str(root / "scripts/check-version.py"))
    requested = os.environ.get("RELEASE_NEW_VERSION", "")
    if not requested:
        raise ValueError("RELEASE_NEW_VERSION is required")
    version = checker["numeric_version"](requested)
    gradle = root / "android/app/build.gradle.kts"
    if gradle.is_symlink():
        raise ValueError("Android version file must not be a symlink")
    original = gradle.read_bytes().decode("utf-8")
    name, code = checker["android_version_declarations"](original)
    if name[0] == version:
        sys.exit(0)
    new_code = int(code[0]) + 1
    if new_code > checker["ANDROID_MAX_VERSION_CODE"]:
        raise ValueError("Android versionCode cannot be incremented without overflow")

    updated = original
    for value, start, end in sorted(((version, name[1], name[2]),
                                    (str(new_code), code[1], code[2])),
                                   key=lambda replacement: replacement[1], reverse=True):
        updated = updated[:start] + value + updated[end:]

    # Replace both literals together, preserving the original on validation/I/O failure.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=gradle.parent, prefix=".version-", delete=False) as output:
            temporary = Path(output.name)
            output.write(updated.encode("utf-8"))
            output.flush()
            os.fchmod(output.fileno(), gradle.stat().st_mode & 0o777)
            os.fsync(output.fileno())
        temporary.replace(gradle)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
except (OSError, ValueError) as error:
    print(f"!! {error}", file=sys.stderr)
    sys.exit(1)
PY
