import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile
import uuid
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'Scripts'))
from build_release import build
from check_public import public_files

class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)/'project'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('dist', '.git', '__pycache__'))
    def tearDown(self):
        self.temp.cleanup()
    def test_local_payloads_never_enter_release(self):
        sentinel = uuid.uuid4().hex
        for name in ['ReferenceDataset/reference.json', 'ReferenceDataset/files.sha256',
                     'ReferenceDataset/xy-mosaic/private.png', '.local/private.ini']:
            p = self.root/name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(sentinel)
        archive = build(self.root)
        with zipfile.ZipFile(archive) as z:
            self.assertFalse(any(sentinel.encode() in z.read(n) for n in z.namelist()))
    def test_allowlist_cannot_enable_reference_payload(self):
        p=self.root/'ReferenceDataset/reference.json';p.write_text('{}')
        with (self.root/'public-files.txt').open('a') as f:f.write('ReferenceDataset/reference.json\n')
        with self.assertRaises(ValueError):public_files(self.root)
    def test_modified_synthetic_payload_rejected(self):
        p=next((self.root/'TestDataset').rglob('*.png'));p.write_bytes(b'changed')
        with self.assertRaises(ValueError):public_files(self.root)

if __name__ == '__main__':unittest.main()
