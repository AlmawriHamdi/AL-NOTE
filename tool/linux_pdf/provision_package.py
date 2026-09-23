#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Acquire a separately reviewed Linux resource archive without changing pins.

The distribution record is deliberately separate from the resource manifest.
Publishing an archive does not approve any new worker or library bytes.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile
import time
import urllib.request

if __package__:
    from .verify_package import ROOT, pinned_manifest, verify_directory
else:
    from verify_package import ROOT, pinned_manifest, verify_directory

MAX_ARCHIVE_BYTES = 64 * 1024 * 1024


def validate_record(record, manifest):
    size = record['archive_bytes']
    if type(size) is not int or not 0 < size <= MAX_ARCHIVE_BYTES:
        raise ValueError('archive size outside receiving limit')
    if not re.fullmatch(r'[0-9a-f]{64}', record['archive_sha256']):
        raise ValueError('invalid archive digest')
    if record['manifest_sha256'] != hashlib.sha256(manifest).hexdigest():
        raise ValueError('archive record does not match approved resource manifest')
    if not record['archive_url'].startswith(
            'https://github.com/AlmawriHamdi/AL-NOTE/releases/download/'):
        raise ValueError('unexpected resource origin')


def no_symlink_destination(path):
    if path.is_symlink():
        raise ValueError('symlinked provisioning destination')


def capture_archive(source, target, record):
    """Bound bytes/time before parsing anything; never buffer a whole resource."""
    digest = hashlib.sha256()
    remaining = record['archive_bytes']
    deadline = time.monotonic() + 300
    while remaining:
        if time.monotonic() > deadline:
            raise ValueError('archive download deadline')
        chunk = source.read(min(65536, remaining))
        if not chunk:
            raise ValueError('short archive')
        target.write(chunk)
        digest.update(chunk)
        remaining -= len(chunk)
    if source.read(1):
        raise ValueError('oversized archive')
    if digest.hexdigest() != record['archive_sha256']:
        raise ValueError('archive digest mismatch')


def stage_archive(archive_path, stage, manifest):
    expected = dict(json.loads(manifest)['files'])
    expected['manifest.json'] = {
        'size': len(manifest), 'sha256': hashlib.sha256(manifest).hexdigest()}
    if not 0 < len(expected) <= 257:
        raise ValueError('resource count limit')
    found = set()
    end = 0
    with tarfile.open(archive_path, mode='r:') as archive:
        for member in archive:
            name = member.name
            parts = PurePosixPath(name).parts
            if (not parts or name != '/'.join(parts) or
                    any(part in ('..', '.') for part in parts) or
                    name.startswith('/') or '\\' in name or
                    name not in expected or name in found):
                raise ValueError('unexpected, duplicate or unsafe archive name')
            record = expected[name]
            if (member.type != tarfile.REGTYPE or member.pax_headers or
                    member.linkname or member.size != record['size'] or
                    type(record['size']) is not int or
                    not 0 < member.size <= 32 * 1024 * 1024 or
                    member.uid != 0 or member.gid != 0 or
                    member.uname or member.gname or member.mtime != 0):
                raise ValueError('unexpected archive member metadata')
            mode = 0o500 if '/' not in name and name != 'manifest.json' else 0o400
            if (member.mode != mode or member.offset != end or
                    member.offset_data != member.offset + 512):
                raise ValueError('unexpected archive mode or extension header')
            destination = stage / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, destination.open('xb') as target:
                digest = hashlib.sha256()
                remaining = member.size
                while remaining:
                    data = source.read(min(65536, remaining))
                    if not data:
                        raise ValueError('truncated archive member')
                    target.write(data)
                    digest.update(data)
                    remaining -= len(data)
            if digest.hexdigest() != record['sha256']:
                raise ValueError('resource digest mismatch')
            destination.chmod(mode)
            found.add(name)
            end = member.offset_data + ((member.size + 511) // 512) * 512
    if found != set(expected):
        raise ValueError('missing archive resources')
    # Only canonical USTAR records and zero padding are accepted. This rejects
    # hidden second archives and unparsed suffixes as well as extension records.
    padding = ((end + 1024 + 10239) // 10240) * 10240 - end
    with archive_path.open('rb') as source:
        source.seek(end)
        tail = source.read(padding + 1)
    if len(tail) != padding or any(tail):
        raise ValueError('noncanonical archive trailer')
    verify_directory(stage, manifest)


def publish_exclusive(stage, destination):
    """Linux atomic directory publication; never replace any concurrent result."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                      ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def provision(destination, record, manifest, archive_path=None):
    validate_record(record, manifest)
    # Ancestors are caller-owned filesystem configuration (e.g. Bazzite's
    # /home -> /var/home). Canonicalize them before creating private staging;
    # the package itself may never be a symlink.
    destination = destination.parent.resolve() / destination.name
    no_symlink_destination(destination)
    if destination.exists():
        verify_directory(destination, manifest)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pdf-acquire-', dir=destination.parent) as temporary:
        root = Path(temporary)
        archive = root / 'package.tar'
        if archive_path is not None:
            if not stat.S_ISREG(archive_path.lstat().st_mode):
                raise ValueError('archive must be a regular file')
            source = archive_path.open('rb')
        else:
            source = urllib.request.urlopen(record['archive_url'], timeout=30)
        with source, archive.open('xb') as target:
            if archive_path is None and not source.geturl().startswith('https://'):
                raise ValueError('download requires HTTPS')
            capture_archive(source, target, record)
        stage = root / 'resources'
        stage.mkdir(mode=0o700)
        stage_archive(archive, stage, manifest)
        no_symlink_destination(destination)
        publish_exclusive(stage, destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--distribution', type=Path,
                        default=ROOT / 'tool/linux_pdf/distribution.json',
                        help='Reviewed archive record; does not replace compiled resource pins')
    parser.add_argument('--directory', type=Path, default=ROOT / 'build/linux-pdf-resources')
    parser.add_argument('--archive', type=Path, help='Offline input; same archive/resource verification')
    args = parser.parse_args()
    try:
        result = provision(args.directory, json.loads(args.distribution.read_text()),
                           pinned_manifest(), args.archive)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, tarfile.TarError) as error:
        parser.exit(1, f'Isolated package acquisition rejected: {error}\n')
    print(result)
