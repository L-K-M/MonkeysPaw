#!/usr/bin/env python3
"""Check pbxproj object IDs without Xcode or an OpenStep plist dependency."""

import argparse
from collections import Counter
from pathlib import Path
import re
import sys


ID = r"[0-9A-Fa-f]{24}"
TOKENS = re.compile(rf"\b{ID}\b")
DEFINITIONS = re.compile(rf"\b({ID})\s*=\s*\{{\s*isa\s*=\s*\w+\s*;")
COMMENTS_OR_STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*', re.DOTALL)


def check(path: Path) -> int:
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as error:
        print(f"{path}: {error}", file=sys.stderr)
        return 1

    # Preserve quoted strings, including URLs; ignore IDs mentioned in comments.
    source = COMMENTS_OR_STRINGS.sub(
        lambda match: match[0] if match[0].startswith('"') else " ", source
    )
    # TargetAttributes contains ID keys too. Only object definitions have an isa.
    definitions = Counter(DEFINITIONS.findall(source))
    undefined = sorted(set(TOKENS.findall(source)) - definitions.keys())
    duplicates = sorted(key for key, count in definitions.items() if count != 1)

    if not definitions:
        print(f"{path}: no object definitions found", file=sys.stderr)
        return 1

    for key in duplicates:
        print(f"{path}: {key} defined {definitions[key]} times", file=sys.stderr)
    for key in undefined:
        print(f"{path}: {key} referenced but not defined", file=sys.stderr)

    if duplicates or undefined:
        return 1

    print(f"{path}: {len(definitions)} unique object IDs; every reference resolves")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path", nargs="?", type=Path,
        default=Path(__file__).resolve().parent.parent / "MonkeysPaw.xcodeproj/project.pbxproj",
    )
    return check(parser.parse_args().path)


if __name__ == "__main__":
    sys.exit(main())
