"""Validate the explicit public package boundary. No network access."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_DOCS = {'ReferenceDataset/README.txt', 'ReferenceDataset/xy-mosaic.dzi.example.xml'}


def public_files(root=ROOT):
    names = (root / 'public-files.txt').read_text(encoding='utf-8').splitlines()
    if len(names) != len(set(names)):
        raise ValueError('Duplicate public manifest entry')
    for name in names:
        rel = Path(name)
        if not name or rel.is_absolute() or '..' in rel.parts or '\\' in name:
            raise ValueError('Unsafe public manifest path')
        if rel.parts[0] in {'.local', 'dist', '.git'}:
            raise ValueError('Private directory in manifest')
        if rel.parts[0] == 'ReferenceDataset' and name not in REFERENCE_DOCS:
            raise ValueError('Reference payload cannot be published')
        p = root / rel
        if p.is_symlink() or any(x.is_symlink() for x in p.parents if x != root.parent):
            raise ValueError('Symlink in public package')
        if not p.is_file():
            raise ValueError('Missing public file: ' + name)
        if p.suffix.lower() in {'.pfx', '.p12', '.pem', '.key', '.log'}:
            raise ValueError('Disallowed public file type')
    expected = json.loads((root / 'Tests/synthetic-sha256.json').read_text())
    actual = {n: hashlib.sha256((root/n).read_bytes()).hexdigest()
              for n in names if n.startswith('TestDataset/')}
    if actual != expected:
        raise ValueError('Synthetic dataset differs from reviewed baseline')
    return names


def check_git(root, allowed):
    # Also reject private files already tracked/staged; .gitignore cannot untrack them.
    if not (root / '.git').exists():
        return
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                            check=True, stdout=subprocess.PIPE)
    tracked = set(result.stdout.decode().split('\0')) - {''}
    unexpected = tracked - set(allowed)
    if unexpected:
        raise ValueError('Unapproved tracked files; inspect git ls-files before publication')


if __name__ == '__main__':
    names = public_files()
    check_git(ROOT, names)
    print(f'Public boundary and synthetic hashes passed ({len(names)} files). Manual content review required.')
