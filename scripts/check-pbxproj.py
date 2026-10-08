#!/usr/bin/env python3
"""Check project and shared scheme object IDs without Xcode."""

import argparse
from collections import Counter
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
import re
import shutil
import sys
import tempfile


ID = r"[0-9A-Fa-f]{24}"
TOKENS = re.compile(rf"\b{ID}\b")
DEFINITIONS = re.compile(rf"\b({ID})\s*=\s*\{{\s*isa\s*=\s*\w+\s*;")
COMMENTS_OR_STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*', re.DOTALL)
BLUEPRINT_IDS = re.compile(rf"""\bBlueprintIdentifier\s*=\s*["']({ID})["']""")


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

    schemes = sorted((path.parent / "xcshareddata/xcschemes").glob("*.xcscheme"))
    scheme_errors = False
    for scheme in schemes:
        try:
            scheme_source = scheme.read_text(encoding="utf-8")
        except OSError as error:
            print(f"{scheme}: {error}", file=sys.stderr)
            return 1

        missing = sorted(set(BLUEPRINT_IDS.findall(scheme_source)) - definitions.keys())
        for key in missing:
            print(f"{scheme}: BlueprintIdentifier {key} referenced but not defined",
                  file=sys.stderr)
        scheme_errors = scheme_errors or bool(missing)

    if duplicates or undefined or scheme_errors:
        return 1

    print(f"{path}: {len(definitions)} unique object IDs; every reference resolves; "
          f"shared schemes checked: {len(schemes)}")
    return 0


def self_test(path: Path) -> int:
    path = path.resolve()
    # Copy the project so a negative test cannot corrupt the committed scheme.
    with tempfile.TemporaryDirectory(prefix="check-pbxproj-") as temporary:
        project = Path(temporary) / path.parent.name
        shutil.copytree(path.parent, project)
        copied_path = project / path.name
        if check(copied_path) != 0:
            return 1

        existing_ids = set(TOKENS.findall(copied_path.read_text(encoding="utf-8")))
        candidate = 0
        while f"{candidate:024X}" in existing_ids:
            candidate += 1
        corrupted_id = f"{candidate:024X}"

        for scheme in sorted((project / "xcshareddata/xcschemes").glob("*.xcscheme")):
            source = scheme.read_text(encoding="utf-8")
            match = BLUEPRINT_IDS.search(source)
            if match is None:
                continue

            source = source[:match.start(1)] + corrupted_id + source[match.end(1):]
            scheme.write_text(source, encoding="utf-8")
            diagnostic = StringIO()
            with redirect_stderr(diagnostic):
                result = check(copied_path)
            if result != 1 or corrupted_id not in diagnostic.getvalue():
                print("Negative self-test failed: corrupted BlueprintIdentifier was not rejected",
                      file=sys.stderr)
                return 1

            print("Negative self-test passed: corrupted BlueprintIdentifier rejected")
            return 0

        print(f"{path}: negative self-test needs a scheme BlueprintIdentifier", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path", nargs="?", type=Path,
        default=Path(__file__).resolve().parent.parent / "MonkeysPaw.xcodeproj/project.pbxproj",
    )
    parser.add_argument("--self-test", action="store_true",
                        help="expect rejection of a corrupted scheme ID in a temporary copy")
    arguments = parser.parse_args()
    if arguments.self_test:
        return self_test(arguments.path)
    return check(arguments.path)


if __name__ == "__main__":
    sys.exit(main())
