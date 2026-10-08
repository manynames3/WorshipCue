#!/usr/bin/env python3
"""Build a deterministic Lambda archive, keeping dependencies on the external drive."""
import argparse
import hashlib
import io
from pathlib import Path
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
WHEEL_URL = 'https://files.pythonhosted.org/packages/3c/2c/c43c03eaf630435f023f1dc61ec4a4a78951ad5530a62c71cc89bde307b7/pypdf-6.19.0-py3-none-any.whl'
WHEEL_HASH = '7e5d6e730e7dae87d560a2cee218b852f6498c8be61966f3cd02ead971e48d14'


def package(destination):
    if sys.version_info < (3, 11):
        raise SystemExit('Packaging requires Python 3.11 or newer.')
    destination.mkdir(parents=True, exist_ok=True)
    wheel_path = destination / 'pypdf-6.19.0-py3-none-any.whl'
    data = wheel_path.read_bytes() if wheel_path.exists() else urllib.request.urlopen(WHEEL_URL, timeout=30).read()
    if hashlib.sha256(data).hexdigest() != WHEEL_HASH:
        raise SystemExit('Approved dependency checksum mismatch.')
    wheel_path.write_bytes(data)
    entries = {p.name: p.read_bytes() for p in (ROOT / 'src').glob('*.py')}
    with zipfile.ZipFile(io.BytesIO(data)) as wheel:
        for name in wheel.namelist():
            if name.endswith('/'):
                continue
            path = Path(name)
            if path.is_absolute() or '..' in path.parts or not (name.startswith('pypdf/') or name.startswith('pypdf-6.19.0.dist-info/')):
                raise SystemExit('Unexpected dependency archive entry.')
            content = wheel.read(name)
            entries[name] = content
            vendor_path = destination / 'vendor' / name
            vendor_path.parent.mkdir(parents=True, exist_ok=True)
            vendor_path.write_bytes(content)
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            bundle.writestr(info, content)
    data = archive.getvalue()
    digest = hashlib.sha256(data).hexdigest()
    path = destination / f'backend-{digest}.zip'
    path.write_bytes(data)
    (destination / 'package.json').write_text(__import__('json').dumps({'path':str(path), 'sha256':digest})+'\n')
    print(f'Built checksum-pinned backend package ({len(data)} bytes).')
    return path


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT.parent.parent / 'DeveloperTools/WorshipCue/AWS')
    package(parser.parse_args().output.resolve())
