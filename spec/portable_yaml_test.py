"""Focused process tests for the same two-loader command used by CI."""

from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
