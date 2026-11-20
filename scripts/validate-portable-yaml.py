#!/usr/bin/env python3
"""Compare the JSON values read by Psych (YAML 1.1) and ruamel.yaml (1.2).

Requires the existing .github/validator/requirements.txt environment and Ruby.
Accepts files or directories; directories select all *.yaml recursively.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

PSYCH = Path(__file__).with_name("yaml-to-json.rb")


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
    files = set()
    failures = 0
    for path in args.paths:
        selected = sorted(path.rglob("*.yaml")) if path.is_dir() else [path]
        if not selected:
            print(f"FAIL {path}: no YAML files", file=sys.stderr)
            failures += 1
        files.update(selected)
    for path in sorted(files):
        try:
            validate(path)
        except (OSError, ValueError, YAMLError, RecursionError) as error:
            print(f"FAIL {path}: {error}", file=sys.stderr)
            failures += 1
    print(f"Portable YAML: {len(files)} files checked, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
