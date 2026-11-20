"""Focused process tests for the same two-loader command used by CI."""

from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

COMMAND = Path(__file__).resolve().parents[1] / "scripts/validate-portable-yaml.py"


class PortableYamlTest(unittest.TestCase):
    def run_check(self, content=None, nested=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            if content is not None:
                path = root / "payload.yaml"
                if nested:
                    path = root / "stages/latex/generations/000001/payloads/smoke.yaml"
                    path.parent.mkdir(parents=True)
                path.write_text(content, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(COMMAND), str(root)],
                capture_output=True, text=True, check=False,
            )

    def test_portable_nested_stage_payload(self):
        result = self.run_check(
            'cases:\n- id: "smoke"\n  input: "yes 1:20 017 α"\n'
            '  values: [true, false, null, 17, 1.5, 0.00001]\n'
            '  outputs: ["0e0", "1e21", "1.123_456_789"]\n', nested=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 files checked, 0 failures", result.stdout)

    def test_ambiguous_scalars(self):
        for scalar in ["yes", "on", "1:20", "017", "0o17", "1e-3",
                       "0e0", "1e21", "1.123_456_789"]:
            with self.subTest(scalar=scalar):
                result = self.run_check(f"value: {scalar}\n")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("different JSON values", result.stderr)

    def test_yaml_values_outside_the_portable_subset(self):
        for content in [
            "value: first\nvalue: second\n",  # duplicate key
            "value: &anchor [1]\nother: *anchor\n",  # alias
            "value: 2026-01-01\n",  # date
            "value: .nan\n", "value: .inf\n",
            "1: value\n",  # non-string key
            "value: !custom tagged\n",
            "value: first\n---\nvalue: second\n",  # extra document
            'value: "\\uD800"\n',  # invalid Unicode
        ]:
            with self.subTest(content=content):
                result = self.run_check(content)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("FAIL", result.stderr)

    def test_empty_directory_fails(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no YAML files", result.stderr)

    def test_missing_file_fails(self):
        result = subprocess.run(
            [sys.executable, str(COMMAND), "/missing-testsuite-payload.yaml"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL", result.stderr)


class SealedExemptionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.command = scripts / COMMAND.name
        shutil.copyfile(COMMAND, self.command)
        shutil.copyfile(COMMAND.with_name("yaml-to-json.rb"), scripts / "yaml-to-json.rb")
        self.path = self.root / "stages/asciimath/generations/000001/payloads/numbers.yaml"
        self.path.parent.mkdir(parents=True)
        self.path.write_text("value: 0e0\n", encoding="utf-8")
        self.entries = [{
            "generation": 1,
            "path": self.path.relative_to(self.root).as_posix(),
            "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
            "reason": "Already sealed; YAML 1.2 resolves a Psych output string as a float.",
        }]

    def run_check(self, *paths):
        self.command.with_name("portable-yaml-exemptions.json").write_text(
            json.dumps(self.entries), encoding="utf-8"
        )
        return subprocess.run(
            [sys.executable, str(self.command), *map(str, paths or [self.path])],
            capture_output=True, text=True, check=False,
        )

    def test_exact_sealed_bytes_are_exempt_with_visible_reason(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 sealed exemptions", result.stdout)
        self.assertIn(self.entries[0]["reason"], result.stdout)

    def test_changed_sealed_bytes_fail_even_when_portable(self):
        for content in ['value: 1e21\n', 'value: "0e0"\n']:
            with self.subTest(content=content):
                self.path.write_text(content, encoding="utf-8")
                result = self.run_check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("exemption digest mismatch", result.stderr)

    def test_unlisted_sealed_file_is_not_exempt(self):
        self.entries = []
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("different JSON values", result.stderr)

    def test_new_drift_is_not_covered_by_a_generation_or_digest(self):
        for relative in [
            "stages/asciimath/generations/000001/payloads/new.yaml",
            "stages/asciimath/generations/000002/payloads/numbers.yaml",
        ]:
            with self.subTest(relative=relative):
                new = self.root / relative
                new.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(self.path, new)
                result = self.run_check(new)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("different JSON values", result.stderr)

    def test_same_suffix_outside_checkout_is_not_exempt(self):
        with tempfile.TemporaryDirectory() as directory:
            other = Path(directory) / self.entries[0]["path"]
            other.parent.mkdir(parents=True)
            shutil.copyfile(self.path, other)
            result = self.run_check(other)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("different JSON values", result.stderr)

    def test_unlisted_symlink_cannot_borrow_an_exemption(self):
        other = self.path.with_name("new.yaml")
        other.symlink_to(self.path)
        result = self.run_check(other)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("different JSON values", result.stderr)

    def test_malformed_allowlist_fails_closed(self):
        original = self.entries[0].copy()
        for field, value in [
            ("generation", 2), ("generation", True), ("sha256", ""),
            ("reason", " "), ("path", "../numbers.yaml"),
        ]:
            with self.subTest(field=field, value=value):
                self.entries = [dict(original, **{field: value})]
                result = self.run_check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("FAIL exemptions", result.stderr)

    def test_duplicate_entry_is_rejected(self):
        self.entries *= 2
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("duplicate sealed payload exemption", result.stderr)


if __name__ == "__main__":
    unittest.main()
