#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded provisioning/verifier regressions; synthetic bytes are never loaded."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from provision_pdf_fixture import library_from_archive, provision, verify
from linux_pdf.verify_package import pinned_manifest, verify_directory


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.library = b'controlled test bytes; not an executable'
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            member = tarfile.TarInfo('lib/libpdfium.so')
            member.size = len(self.library)
            archive.addfile(member, io.BytesIO(self.library))
        self.archive = output.getvalue()
        self.record = {'bytes': len(self.library), 'sha256': hashlib.sha256(self.library).hexdigest(),
                       'archive_bytes': len(self.archive), 'archive_sha256': hashlib.sha256(self.archive).hexdigest(),
                       'member': 'lib/libpdfium.so', 'filename': 'libpdfium.so'}
        self.source = self.root / 'fixture.tgz'
        self.source.write_bytes(self.archive)

    def test_offline_acquisition_and_verified_cache(self):
        path = provision(self.root / 'cache', self.record, self.source)
        self.assertEqual(path.read_bytes(), self.library)
        with patch('urllib.request.urlopen') as network:
            self.assertEqual(provision(self.root / 'cache', self.record), path)
            network.assert_not_called()
        self.assertEqual(list(path.parent.iterdir()), [path])

    def test_missing_library(self):
        with self.assertRaises(FileNotFoundError):
            verify(self.root / 'missing', self.record)

    def test_corrupt_archive_leaves_no_published_library(self):
        self.source.write_bytes(b'x' * len(self.archive))
        with self.assertRaises(ValueError):
            provision(self.root / 'cache', self.record, self.source)
        self.assertEqual(list((self.root / 'cache').iterdir()), [])

    def test_member_hash_must_also_match(self):
        with self.assertRaises(ValueError):
            library_from_archive(self.archive, dict(self.record, sha256='0' * 64))

    def test_wrong_existing_library_is_not_refreshed_or_trusted(self):
        path = provision(self.root / 'cache', self.record, self.source)
        path.write_bytes(b'x' * len(self.library))
        with patch('urllib.request.urlopen') as network:
            with self.assertRaises(ValueError):
                provision(path.parent, self.record)
            network.assert_not_called()
        self.assertEqual(path.read_bytes(), b'x' * len(self.library))

    def test_short_and_oversized_library(self):
        path = self.root / 'library'
        for data in [b'', self.library + b'extra']:
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                verify(path, self.record)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        self.worker = self.package / 'worker'
        self.worker.write_bytes(b'controlled package test; never executed')
        record = {'size': self.worker.stat().st_size, 'sha256': hashlib.sha256(self.worker.read_bytes()).hexdigest()}
        self.manifest = json.dumps({'version': 1, 'files': {'worker': record}}).encode()
        self.manifest_path = self.package / 'manifest.json'
        self.manifest_path.write_bytes(self.manifest)
        self.worker.chmod(0o500)
        self.manifest_path.chmod(0o400)

    def replace(self, path, data):
        path.chmod(0o600)
        path.write_bytes(data)
        path.chmod(0o400)

    def test_valid_package_and_actual_pin_agreement(self):
        self.assertEqual(verify_directory(self.package, self.manifest), hashlib.sha256(self.manifest).hexdigest())
        self.assertGreater(len(json.loads(pinned_manifest())['files']), 0)

    def test_missing_directory_and_file(self):
        with self.assertRaises(ValueError):
            verify_directory(self.root / 'absent', self.manifest)
        self.worker.unlink()
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_wrong_manifest(self):
        self.replace(self.manifest_path, b'{}')
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_same_length_corrupt_resource(self):
        self.replace(self.worker, b'x' * self.worker.stat().st_size)
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_truncated_resource(self):
        self.replace(self.worker, b'x')
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_extra_resource(self):
        extra = self.package / 'extra'
        extra.write_bytes(b'x')
        extra.chmod(0o400)
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_extra_empty_directory(self):
        (self.package / 'unexpected-empty').mkdir()
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_writable_resource(self):
        self.worker.chmod(0o600)
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)

    def test_symlinked_resource(self):
        target = self.root / 'target'
        self.worker.rename(target)
        self.worker.symlink_to(target)
        with self.assertRaises(ValueError):
            verify_directory(self.package, self.manifest)


if __name__ == '__main__':
    unittest.main()
