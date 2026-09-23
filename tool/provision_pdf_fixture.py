#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetch only the pinned fixture-test library. Never changes an SDK or admission."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import stat
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'tool/pdf_fixture_resources.json'


def target():
    if platform.machine().lower() not in ('x86_64', 'amd64'):
        raise ValueError('fixture provisioning supports x64 only')
    return json.loads(PIN.read_text())['targets'][platform.system().lower()]


def verify(path, record):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size != record['bytes']:
        raise ValueError('fixture must be a regular file of the pinned length')
    with path.open('rb') as stream:
        data = stream.read(record['bytes'] + 1)
    if len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
        raise ValueError('fixture digest mismatch')
    return path.resolve()


def library_from_archive(data, record):
    if len(data) != record['archive_bytes'] or hashlib.sha256(data).hexdigest() != record['archive_sha256']:
        raise ValueError('fixture archive digest/length mismatch')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        members = [item for item in archive.getmembers()
                   if item.name.removeprefix('./') == record['member']]
        if len(members) != 1 or not members[0].isfile() or members[0].size != record['bytes']:
            raise ValueError('fixture archive member mismatch')
        with archive.extractfile(members[0]) as stream:
            library = stream.read(record['bytes'] + 1)
    if len(library) != record['bytes'] or hashlib.sha256(library).hexdigest() != record['sha256']:
        raise ValueError('fixture member digest mismatch')
    return library


def provision(directory, record, archive_path=None):
    directory.mkdir(parents=True, exist_ok=True)
    if directory.is_symlink():
        raise ValueError('fixture destination must not be a symlink')
    destination = directory / record['filename']
    if destination.exists() or destination.is_symlink():
        # A corrupt cache is a rejection, not permission to refresh its trust.
        return verify(destination, record)
    if archive_path is not None:
        with archive_path.open('rb') as stream:
            data = stream.read(record['archive_bytes'] + 1)
    else:
        with urllib.request.urlopen(record['archive_url'], timeout=30) as response:
            if not response.geturl().startswith('https://'):
                raise ValueError('fixture download requires HTTPS')
            data = response.read(record['archive_bytes'] + 1)
    library = library_from_archive(data, record)
    with tempfile.TemporaryDirectory(prefix='.fixture-', dir=directory) as temporary:
        staged = Path(temporary) / record['filename']
        staged.write_bytes(library)
        verify(staged, record)
        # Atomic, exclusive publication on the same filesystem. The temporary
        # name is then removed; no partial destination or overwrite is possible.
        os.link(staged, destination)
    return verify(destination, record)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'build/pdf-fixture')
    parser.add_argument('--archive', type=Path, help='Offline archive; same pinned verification')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    record = target()
    try:
        path = (verify(args.directory / record['filename'], record) if args.verify_only
                else provision(args.directory, record, args.archive))
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f'Fixture setup rejected: {error}\n')
    print(path)
