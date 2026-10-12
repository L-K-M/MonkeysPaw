#!/usr/bin/env python3
"""Verify the compressed Swift table and full-fold fixtures against Unicode 17."""

import hashlib
import json
from pathlib import Path
import re
import unicodedata
from urllib.request import urlopen


SOURCE = "https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt"
SHA256 = "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"
FIXTURES = Path(__file__).resolve().parent
TABLE = FIXTURES.parents[2] / "Sources/MonkeysPawCore/Sync/SyncPathCaseFold.swift"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def valid_scalar(value):
    return 0 <= value <= 0x10FFFF and not 0xD800 <= value <= 0xDFFF


with urlopen(SOURCE, timeout=30) as response:
    data = response.read()
require(hashlib.sha256(data).hexdigest() == SHA256, "CaseFolding.txt SHA-256 mismatch")
reference = {}
for line in data.decode("utf-8").splitlines():
    fields = line.split("#", 1)[0].strip().split(";")
    if len(fields) < 3 or fields[1].strip() not in {"C", "F"}:
        continue
    value = int(fields[0], 16)
    require(value not in reference, f"Duplicate C/F source U+{value:04X}")
    reference[value] = tuple(int(part, 16) for part in fields[2].split())

source = TABLE.read_text(encoding="utf-8")
require(SOURCE in source and SHA256 in source, "Swift table source pin has changed")
actual = {}


def insert(value, replacement):
    require(value not in actual, f"Duplicate Swift source U+{value:04X}")
    require(valid_scalar(value) and replacement and all(map(valid_scalar, replacement)),
            f"Invalid Swift scalar mapping U+{value:04X}")
    actual[value] = replacement


ranges = re.findall(
    r"MappingRange\(first: 0x([0-9A-F]+), last: 0x([0-9A-F]+), step: (\d+), delta: (-?\d+)\)",
    source,
)
require(ranges and len(ranges) == source.count("MappingRange(first:"), "Unrecognized Swift range")
previous = -1
for first, last, step, delta in ranges:
    first, last, step, delta = int(first, 16), int(last, 16), int(step), int(delta)
    require(previous < first <= last and step > 0 and (last - first) % step == 0,
            f"Unsorted or invalid Swift range U+{first:04X}")
    previous = last
    for value in range(first, last + 1, step):
        insert(value, (value + delta,))

exceptions = re.findall(r'^\s*0x([0-9A-F]+): "((?:\\u\{[0-9A-F]+\})+)",$', source, re.MULTILINE)
require(exceptions and len(exceptions) == len(re.findall(r"^\s*0x.*:", source, re.MULTILINE)),
        "Unrecognized Swift exception")
previous = -1
for value, replacement in exceptions:
    value = int(value, 16)
    require(value > previous, f"Unsorted Swift exception U+{value:04X}")
    previous = value
    insert(value, tuple(int(part, 16) for part in re.findall(r"\\u\{([0-9A-F]+)\}", replacement)))

# Compare identities too: this catches extra S/T mappings and missing C/F
# entries, rather than checking only the scalars present in our table.
scalars = 0
for value in range(0x110000):
    if not valid_scalar(value):
        continue
    folded = actual.get(value, (value,))
    require(folded == reference.get(value, (value,)), f"Fold mismatch U+{value:04X}")
    repeated = tuple(part for scalar in folded for part in actual.get(scalar, (scalar,)))
    require(repeated == folded, f"Non-idempotent fold U+{value:04X}")
    scalars += 1

covered = set()
cases = sorted(FIXTURES.glob("unicode-full-fold-*/case.json"))
require(cases, "Missing full-fold fixture series")
for case in cases:
    envelope = json.loads(case.read_bytes())
    raw = (case.parent / "path.txt").read_bytes().decode("utf-8")
    path = unicodedata.normalize("NFC", raw)
    key = "".join(chr(part) for char in path for part in reference.get(ord(char), (ord(char),)))
    key = unicodedata.normalize("NFC", key)
    expected = envelope["expected"]
    require(expected["path"].encode("utf-8") == path.encode("utf-8"), f"NFC path mismatch: {case.parent.name}")
    require(expected["path_key"].encode("utf-8") == key.encode("utf-8"), f"Fold key mismatch: {case.parent.name}")
    covered.update(map(ord, raw))

required = set(reference) | {value for replacement in reference.values() for value in replacement}
missing = required - covered
require(not missing, "Full-fold fixtures miss " + ", ".join(f"U+{value:04X}" for value in sorted(missing)))
print(f"Verified Unicode 17.0.0 C+F: {len(actual)} mappings, {scalars} valid scalars, "
      f"{len(cases)} fixtures; sorted, unique, valid and idempotent; no S/T mappings.")
