#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify retained vendor bytes, focused patches and all archive omissions.

Supply the exact official pub.dev archives locally; no downloads or extraction
are performed by this checker. Recorded archive digests must match first.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archives', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / 'docs/dependency-review/pdfrx-vendor.json').read_text())
    for package in manifest:
        name = package['package']
        archive = args.archives / f'{name}.tar.gz'
        assert sha256(archive.read_bytes()) == package['archive_sha256'], f'{name}: archive digest'
        with tarfile.open(archive) as tar:
            original = {m.name.removeprefix('./'): tar.extractfile(m).read()
                        for m in tar.getmembers() if m.isfile()}
        vendor = root / 'third_party' / name
        retained = {p.relative_to(vendor).as_posix(): p.read_bytes()
                    for p in vendor.rglob('*') if p.is_file()}
        assert len(original) == package['original_files'], f'{name}: archive count'
        assert len(retained) == package['retained_files'], f'{name}: retained count'
        assert not retained.keys() - original.keys(), f'{name}: unexpected additions'
        assert sorted(original.keys() - retained.keys()) == package['omitted_files'], f'{name}: omissions'
        modified = {p: sha256(data) for p, data in retained.items() if data != original[p]}
        assert modified == package['modified_files'], f'{name}: modified bytes {modified}'
        assert sha256(retained['LICENSE']) == package['license_sha256'], f'{name}: license'
        print(f'{name}: PASS; {len(retained)} retained, {len(modified)} patched, '
              f'{len(package["omitted_files"])} omitted; archive {package["archive_sha256"]}')


if __name__ == '__main__':
    main()
