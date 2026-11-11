"""Check sealed evaluation request profiles without interpreting their math."""

import hashlib
import json
from pathlib import Path
import sys


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def parse(text):
    return json.loads(text, object_pairs_hook=unique_object)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(directory):
    manifest = parse((directory / "manifest.json").read_text(encoding="utf-8"))
    require(manifest["schema"] == "plurimath.evaluation-corpus/1", "unknown manifest schema")
    profiles = manifest["profiles"]
    require(bool(profiles), "empty profile inventory")
    require({entry.name for entry in directory.iterdir()} == {*profiles, "manifest.json"},
            "profile inventory differs from the manifest")
    count = 0
    for name, seal in profiles.items():
        require(Path(name).name == name and name.endswith(".json"), f"invalid profile name: {name}")
        raw = (directory / name).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == seal["sha256"], f"{name}: checksum mismatch")
        cases = parse(raw)["cases"]
        require(len(cases) == seal["cases"], f"{name}: case count mismatch")
        ids = set()
        for row in cases:
            case = row["id"]
            require(isinstance(case, str) and case and case not in ids, f"{name}: invalid or duplicate case ID {case!r}")
            ids.add(case)
            require(("request" in row) != ("request_json" in row), f"{case}: expected one request representation")
            response = parse(row["expected_wire"])
            require(response["schema"] == manifest["profile"], f"{case}: unexpected response schema")
            require(type(response["ok"]) is bool, f"{case}: expected Boolean outcome")
            outcome = "result" if response["ok"] else "error"
            require({key for key in response if key in ("result", "error")} == {outcome},
                    f"{case}: mismatched outcome envelope")
            canonical = json.dumps(response, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))
            require(row["expected_wire"] == canonical, f"{case}: noncanonical response")
        count += len(cases)
    return len(profiles), count


if __name__ == "__main__":
    evaluation = Path(__file__).resolve().parents[1] / "evaluation"
    directories = [Path(sys.argv[1])] if len(sys.argv) > 1 else [
        manifest.parent for manifest in sorted(evaluation.glob("*/manifest.json"))
    ]
    try:
        require(bool(directories), "no evaluation profiles found")
        results = [validate(directory) for directory in directories]
    except (OSError, KeyError, TypeError, ValueError) as error:
        sys.exit(f"Evaluation corpus: {error}")
    print(f"Validated {sum(profiles for profiles, _ in results)} evaluation profiles, "
          f"{sum(rows for _, rows in results)} cases")
