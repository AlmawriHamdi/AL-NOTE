#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Acquisition boundaries using synthetic, non-executable resource bytes."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from linux_pdf.provision_package import provision, publish_exclusive


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / 'package'
        self.data = b'inert worker test bytes'
        self.manifest = json.dumps({'version': 1, 'files': {'worker': {
            'size': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}}}).encode()
        self.members = [('manifest.json', self.manifest, tarfile.REGTYPE),
                        ('worker', self.data, tarfile.REGTYPE)]

    def archive(self, members=None, suffix=b''):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name, data, kind in self.members if members is None else members:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = len(data) if kind == tarfile.REGTYPE else 0
                member.mode = 0o400 if name == 'manifest.json' else 0o500
                if kind in (tarfile.LNKTYPE, tarfile.SYMTYPE):
                    member.linkname = '/tmp/should-never-be-followed'
                archive.addfile(member, io.BytesIO(data))
        encoded = output.getvalue() + suffix
        path = self.root / 'archive.tar'
        path.write_bytes(encoded)
        record = {'archive_bytes': len(encoded),
                  'archive_sha256': hashlib.sha256(encoded).hexdigest(),
                  'manifest_sha256': hashlib.sha256(self.manifest).hexdigest(),
                  'archive_url': 'https://github.com/AlmawriHamdi/AL-NOTE/releases/download/test/package.tar'}
        return path, record

    def rejected(self, path, record):
        with self.assertRaises((ValueError, OSError, tarfile.TarError)):
            provision(self.destination, record, self.manifest, path)
        self.assertFalse(self.destination.exists())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['archive.tar'])

    def test_valid_offline_and_verified_cache(self):
        path, record = self.archive()
        provision(self.destination, record, self.manifest, path)
        self.assertEqual((self.destination / 'worker').read_bytes(), self.data)
        self.assertEqual((self.destination / 'worker').stat().st_mode & 0o777, 0o500)
        with patch('urllib.request.urlopen') as network:
            provision(self.destination, record, self.manifest)
            network.assert_not_called()

    def test_network_acquisition_checks_bytes(self):
        path, record = self.archive()
        response = io.BytesIO(path.read_bytes())
        response.geturl = lambda: 'https://release-assets.githubusercontent.com/test'
        with patch('urllib.request.urlopen', return_value=response) as network:
            provision(self.destination, record, self.manifest)
            network.assert_called_once_with(record['archive_url'], timeout=30)
        self.assertEqual((self.destination / 'worker').read_bytes(), self.data)

    def test_reject_non_https_final_response(self):
        path, record = self.archive()
        response = io.BytesIO(path.read_bytes())
        response.geturl = lambda: 'http://example.com/test'
        with patch('urllib.request.urlopen', return_value=response):
            with self.assertRaises(ValueError):
                provision(self.destination, record, self.manifest)
        self.assertFalse(self.destination.exists())
        self.assertTrue(response.closed)

    def test_failed_network_read_discards_partial_output(self):
        path, record = self.archive()

        class BrokenResponse(io.BytesIO):
            def geturl(self):
                return 'https://release-assets.githubusercontent.com/test'

            def read(self, size=-1):
                if self.tell():
                    raise OSError('controlled connection failure')
                return super().read(17)

        response = BrokenResponse(path.read_bytes())
        with patch('urllib.request.urlopen', return_value=response):
            with self.assertRaises(OSError):
                provision(self.destination, record, self.manifest)
        self.assertTrue(response.closed)
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_publication_failure_discards_staged_output(self):
        path, record = self.archive()
        with patch('linux_pdf.provision_package.publish_exclusive', side_effect=OSError('controlled failure')):
            self.rejected(path, record)

    def test_short_long_corrupt_input(self):
        for transform in (lambda b: b[:-1], lambda b: b + b'x',
                          lambda b: b'x' + b[1:]):
            with self.subTest(transform=transform):
                path, record = self.archive()
                path.write_bytes(transform(path.read_bytes()))
                self.rejected(path, record)

    def test_missing_duplicate_extra_and_unsafe_members(self):
        for members in (self.members[:-1], self.members + [self.members[-1]],
                        self.members + [('extra', b'x', tarfile.REGTYPE)],
                        [('.. /x', b'x', tarfile.REGTYPE)],
                        [('../escape', b'x', tarfile.REGTYPE)],
                        [('/escape', b'x', tarfile.REGTYPE)],
                        [('a/../worker', self.data, tarfile.REGTYPE)],
                        [('a\\worker', self.data, tarfile.REGTYPE)]):
            with self.subTest(members=members):
                self.rejected(*self.archive(members))

    def test_links_directories_and_special_files_reject(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE,
                     tarfile.FIFOTYPE, tarfile.CHRTYPE):
            with self.subTest(kind=kind):
                self.rejected(*self.archive([self.members[0], ('worker', b'', kind)]))

    def test_resource_hash_and_size_are_independent_of_archive_digest(self):
        for data in (b'x', b'x' * len(self.data)):
            self.rejected(*self.archive([self.members[0], ('worker', data, tarfile.REGTYPE)]))

    def test_unparsed_trailer_rejects(self):
        self.rejected(*self.archive(suffix=b'private trailing bytes'))

    def test_hidden_gnu_extension_header_rejects(self):
        path, record = self.archive()
        data = path.read_bytes()
        header = tarfile.TarInfo('././@LongLink')
        header.type = tarfile.GNUTYPE_LONGNAME
        header.size = len(b'manifest.json\0')
        # tarfile resolves this hidden header to the otherwise approved name.
        extension = header.tobuf(tarfile.GNU_FORMAT) + b'manifest.json\0'.ljust(512, b'\0')
        data = extension + data
        path.write_bytes(data)
        record.update(archive_bytes=len(data), archive_sha256=hashlib.sha256(data).hexdigest())
        self.rejected(path, record)

    def test_wrong_manifest_limit_type_and_origin(self):
        path, record = self.archive()
        for field, value in (('manifest_sha256', '0' * 64), ('archive_bytes', True),
                             ('archive_bytes', 100_000_000), ('archive_bytes', 5.0),
                             ('archive_url', 'https://example.com/package.tar')):
            with self.subTest(field=field, value=value):
                self.rejected(path, dict(record, **{field: value}))

    def test_corrupt_existing_package_is_preserved(self):
        path, record = self.archive()
        provision(self.destination, record, self.manifest, path)
        worker = self.destination / 'worker'
        worker.chmod(0o600)
        worker.write_bytes(b'corrupt')
        worker.chmod(0o500)
        with patch('urllib.request.urlopen') as network:
            with self.assertRaises(ValueError):
                provision(self.destination, record, self.manifest)
            network.assert_not_called()
        self.assertEqual(worker.read_bytes(), b'corrupt')

    def test_symlink_destination_rejects(self):
        path, record = self.archive()
        self.destination.symlink_to(self.root / 'absent')
        with self.assertRaises(ValueError):
            provision(self.destination, record, self.manifest, path)
        self.assertTrue(self.destination.is_symlink())
        self.assertFalse((self.root / 'absent').exists())

    def test_atomic_publication_never_overwrites_even_empty_directory(self):
        stage = self.root / 'stage'
        stage.mkdir()
        (stage / 'worker').write_bytes(self.data)
        self.destination.mkdir()
        with self.assertRaises(FileExistsError):
            publish_exclusive(stage, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertEqual((stage / 'worker').read_bytes(), self.data)


if __name__ == '__main__':
    unittest.main()
