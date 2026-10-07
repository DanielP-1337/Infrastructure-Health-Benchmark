"""Create a source release using the public allowlist, never a recursive ZIP."""
from pathlib import Path
import hashlib
import zipfile
from check_public import ROOT, public_files, check_git


def build(root=ROOT):
    names = public_files(root)
    check_git(root, names)
    version = (root / 'VERSION').read_text().strip()
    if version != '0.1.8':
        raise ValueError('Review release version before packaging')
    out = root / 'dist'
    out.mkdir(exist_ok=True)
    archive = out / f'Infrastructure-Health-Benchmark-{version}.zip'
    prefix = f'Infrastructure-Health-Benchmark-{version}/'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in sorted(names):
            info = zipfile.ZipInfo(prefix + name, (2026, 10, 7, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, (root/name).read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n', encoding='ascii')
    return archive


if __name__ == '__main__':
    print(build())
