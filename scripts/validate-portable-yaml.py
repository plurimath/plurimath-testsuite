#!/usr/bin/env python3
"""Compare the JSON values read by Psych (YAML 1.1) and ruamel.yaml (1.2).

Requires the existing .github/validator/requirements.txt environment and Ruby.
Accepts files or directories; directories select all *.yaml recursively.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

PSYCH = Path(__file__).with_name("yaml-to-json.rb")
ROOT = Path(__file__).resolve().parents[1]
EXEMPTIONS = Path(__file__).with_name("portable-yaml-exemptions.json")


def load_exemptions():
    """Only exact, reviewed sealed payloads may bypass loader comparison."""
    entries = json.loads(EXEMPTIONS.read_text(encoding="utf-8"))
    if not isinstance(entries, list):
        raise ValueError("exemptions must be a list")
    exemptions = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "generation", "path", "sha256", "reason"
        }:
            raise ValueError("invalid exemption fields")
        path = entry["path"]
        match = re.fullmatch(
            r"stages/([a-z]+)/generations/([0-9]{6})/payloads/"
            r"[a-z0-9]+(?:-[a-z0-9]+)*\.yaml", path
        ) if isinstance(path, str) else None
        if (not match or type(entry["generation"]) is not int
                or entry["generation"] < 1
                or entry["generation"] != int(match[2])
                or not isinstance(entry["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
                or not isinstance(entry["reason"], str)
                or not entry["reason"].strip()):
            raise ValueError(f"invalid sealed payload exemption: {path}")
        if path in exemptions:
            raise ValueError(f"duplicate sealed payload exemption: {path}")
        exemptions[path] = entry
    return exemptions


def sealed_exemption(path, exemptions):
    # Match the actual checkout path, never a suffix or a symlink's target.
    absolute = Path(os.path.abspath(path))
    try:
        relative = absolute.relative_to(ROOT).as_posix()
    except ValueError:
        return None
    entry = exemptions.get(relative)
    if entry is None:
        return None
    if absolute != absolute.resolve():
        raise ValueError("sealed payload exemption cannot be a symlink")
    # A matching name must never hide changed bytes, even if now portable.
    if hashlib.sha256(absolute.read_bytes()).hexdigest() != entry["sha256"]:
        raise ValueError("sealed payload exemption digest mismatch")
    return entry


def json_value(value):
    """Refuse YAML-only types and mapping keys that JSON would coerce."""
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise ValueError("non-string mapping key")
        return {key: json_value(child) for key, child in value.items()}
    if isinstance(value, list):
        return [json_value(child) for child in value]
    if value is None or type(value) in (str, bool, int, float):
        return value
    raise ValueError(f"non-JSON value: {type(value).__name__}")


def same_values(left, right):
    # Python considers True == 1; that is a different JSON value here.
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(
            same_values(left[key], right[key]) for key in left
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(
            same_values(a, b) for a, b in zip(left, right)
        )
    return left == right


def validate(path):
    loader = YAML(typ="safe", pure=True)
    loader.allow_duplicate_keys = False
    with path.open(encoding="utf-8") as stream:
        value = json_value(loader.load(stream))
    # Check finite numbers and valid Unicode even inside strings and keys.
    json.dumps(value, allow_nan=False, ensure_ascii=False).encode("utf-8")
    result = subprocess.run(
        ["ruby", "--disable-gems", str(PSYCH), str(path)],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    if result.returncode:
        raise ValueError(f"Psych failed: {result.stderr.strip()}")
    if not same_values(value, json.loads(result.stdout)):
        raise ValueError("Psych and ruamel.yaml read different JSON values")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        exemptions = load_exemptions()
    except (OSError, ValueError) as error:
        print(f"FAIL exemptions: {error}", file=sys.stderr)
        return 1
    files = set()
    failures = 0
    exempted = 0
    for path in args.paths:
        selected = sorted(path.rglob("*.yaml")) if path.is_dir() else [path]
        if not selected:
            print(f"FAIL {path}: no YAML files", file=sys.stderr)
            failures += 1
        files.update(selected)
    for path in sorted(files):
        try:
            entry = sealed_exemption(path, exemptions)
            if entry is None:
                validate(path)
            else:
                exempted += 1
                print(f"EXEMPT {entry['path']}: {entry['reason']}")
        except (OSError, ValueError, YAMLError, RecursionError) as error:
            print(f"FAIL {path}: {error}", file=sys.stderr)
            failures += 1
    print(f"Portable YAML: {len(files)} files checked, {failures} failures, "
          f"{exempted} sealed exemptions")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
