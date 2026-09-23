#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify an already acquired isolated package. This is NOT a provisioning route."""
import argparse
import hashlib
import json
from pathlib import Path
import stat

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / 'tool/linux_pdf/packaged_resources.json'


def pinned_manifest():
    data = PIN.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    dart = (ROOT / 'lib/documents/pdf/src/linux/linux_pdf_resource_pin.dart').read_text()
    cmake = (ROOT / 'linux/CMakeLists.txt').read_text()
    if f"'{digest}'" not in dart or f'\\"{digest}\\"' not in cmake:
        raise ValueError('manifest/Dart/CMake pins disagree')
    return data


def verify_directory(directory, expected_manifest):
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('package directory missing or symlinked')
    manifest = json.loads(expected_manifest)
    files = manifest['files']
    if type(manifest['version']) is not int or manifest['version'] != 1 or not 0 < len(files) <= 256:
        raise ValueError('unsupported manifest')
    expected = dict(files)
    expected['manifest.json'] = {'size': len(expected_manifest),
                                 'sha256': hashlib.sha256(expected_manifest).hexdigest()}
    directories = {str(parent) for name in expected for parent in Path(name).parents
                   if str(parent) != '.'}
    found = set()
    for count, path in enumerate(directory.rglob('*'), 1):
        if count > 512:
            raise ValueError('package entry limit')
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            if path.relative_to(directory).as_posix() not in directories:
                raise ValueError('unexpected package directory')
            continue
        name = path.relative_to(directory).as_posix()
        if not stat.S_ISREG(info.st_mode) or name not in expected:
            raise ValueError(f'unexpected/non-regular package resource: {name}')
        if info.st_mode & 0o222:
            raise ValueError(f'writable package resource: {name}')
        record = expected[name]
        size = record['size']
        if type(size) is not int or not 0 < size <= 32 * 1024 * 1024 or info.st_size != size:
            raise ValueError(f'package resource length mismatch: {name}')
        with path.open('rb') as stream:
            data = stream.read(size + 1)
        if len(data) != size or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'package resource digest mismatch: {name}')
        found.add(name)
    if found != set(expected):
        raise ValueError('required package resources missing')
    return hashlib.sha256(expected_manifest).hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        digest = verify_directory(args.directory, pinned_manifest())
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Isolated package rejected: {error}\n')
    print(f'Verified all pinned package resources; manifest {digest}')
