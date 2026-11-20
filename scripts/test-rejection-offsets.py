"""Bounded process regressions for exact historical offset exceptions."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/validate-rejection-offsets.rb'

class RejectionOffsets(unittest.TestCase):
    def run_case(self, edit=None, suffix=b''):
        manifest = json.loads((ROOT / 'exceptions/rejection-offsets.json').read_text())
        if edit:
            edit(manifest)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'exceptions').mkdir()
            (root / 'exceptions/rejection-offsets.json').write_text(json.dumps(manifest))
            payload = root / manifest['path']
            payload.parent.mkdir(parents=True)
            payload.write_bytes((ROOT / manifest['path']).read_bytes() + suffix)
            return subprocess.run(['ruby', str(SCRIPT), str(root)], capture_output=True, text=True)

    def test_exact_historical_bytes(self):
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Validated 2 exact', result.stdout)

    def test_edited_payload_fails(self):
        self.assertNotEqual(self.run_case(suffix=b'\n').returncode, 0)

    def test_changed_input_fails(self):
        self.assertNotEqual(self.run_case(lambda m: m['exceptions'][0].update(input='a')).returncode, 0)

    def test_duplicate_fails(self):
        self.assertNotEqual(self.run_case(lambda m: m['exceptions'].append(copy.deepcopy(m['exceptions'][0]))).returncode, 0)

    def test_missing_reason_fails(self):
        self.assertNotEqual(self.run_case(lambda m: m['oracle'].update(reason='')).returncode, 0)

if __name__ == '__main__':
    unittest.main()
