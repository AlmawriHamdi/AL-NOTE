#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Acquire the pinned publisher candidate into quarantine, never execute it.

Both existing cache hits and fresh downloads must pass the same verifier.
The production native-assets hook remains unchanged in this prototype.
"""
import argparse
import json
import os
from pathlib import Path
import tempfile
import urllib.request

from verify_engine import MANIFEST, verify


def fetch(directory, trusted_root=None):
    manifest = json.loads(MANIFEST.read_text())
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    names = ('pdfium-linux-x64.tgz', 'attestation.json')
    if any((directory / name).exists() for name in names):
        # Incomplete or corrupt cache rejects; it never silently grants trust.
        return verify(directory, trusted_root=trusted_root)
    with tempfile.TemporaryDirectory(prefix='.staging-', dir=directory) as temporary:
        staging = Path(temporary)
        for name, url, limit in ((names[0], manifest['archive_url'], 16 * 1024 * 1024),
                                 (names[1], manifest['bundle_url'], 1024 * 1024)):
            with urllib.request.urlopen(url, timeout=30) as response, (staging / name).open('xb') as output:
                total = 0
                while True:
                    chunk = response.read(min(65536, limit - total + 1))
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > limit:
                        raise ValueError('download byte limit')
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
        result = verify(staging, trusted_root=trusted_root)
        # An interrupted pair publication rejects as an incomplete cache above.
        for name in names:
            os.replace(staging / name, directory / name)
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--trusted-root', type=Path)
    arguments = parser.parse_args()
    print(json.dumps(fetch(arguments.directory, arguments.trusted_root)))
