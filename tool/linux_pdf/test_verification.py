#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Negative authentication checks against staged public artifacts, never PDFs."""
import json
from pathlib import Path
import shutil
import io
import tempfile
import unittest
from unittest.mock import patch

from verify_engine import verify

EVIDENCE = Path('/tmp/al-note-linux-prototype')


class VerificationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='alnote-pdf-auth-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ('pdfium-linux-x64.tgz', 'attestation.json', 'trusted_root.json'):
            shutil.copyfile(EVIDENCE / name, self.root / name)

    def verify(self, executable=False):
        return verify(self.root, executable, self.root / 'trusted_root.json')

    def test_authentic_archive(self):
        self.assertEqual(self.verify(), {'artifact_authenticated': True,
                                        'source_correspondence_verified': False,
                                        'engine_executed': False})

    def test_source_gate(self):
        with self.assertRaisesRegex(ValueError, 'source checkout'):
            self.verify(executable=True)

    def test_changed_download(self):
        path = self.root / 'pdfium-linux-x64.tgz'
        with path.open('r+b') as stream:
            stream.write(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
            self.verify()

    def test_changed_cache(self):
        path = self.root / 'authenticated-archive/lib/libpdfium.so'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'wrong cached engine')
        with self.assertRaisesRegex(ValueError, 'cached library digest mismatch'):
            self.verify()

    def test_untrusted_root(self):
        (self.root / 'trusted_root.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'trusted root digest mismatch'):
            self.verify()

    def test_changed_signed_statement(self):
        import base64
        import subprocess
        path = self.root / 'attestation.json'
        bundle = json.loads(path.read_text())
        statement = json.loads(base64.b64decode(bundle['dsseEnvelope']['payload']))
        statement['predicate']['buildDefinition']['resolvedDependencies'][0]['digest']['gitCommit'] = '0' * 40
        bundle['dsseEnvelope']['payload'] = base64.b64encode(json.dumps(statement).encode()).decode()
        path.write_text(json.dumps(bundle))
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_missing_isolation_support(self):
        from check_containment import command_line
        with patch('check_containment.os.access', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'isolation support unavailable'):
                command_line(self.root, 'test.service', 1)

    def test_oversize_request_before_launch(self):
        from check_containment import run_probe
        with patch('check_containment.subprocess.Popen') as launch:
            with self.assertRaisesRegex(ValueError, 'input size limit'):
                run_probe(self.root, 'x' * 65)
            launch.assert_not_called()

    def test_acquisition_and_cache_both_authenticate(self):
        from fetch_engine import fetch
        destination = self.root / 'fresh'
        archive = (self.root / 'pdfium-linux-x64.tgz').read_bytes()
        bundle = (self.root / 'attestation.json').read_bytes()
        def response(url, timeout):
            self.assertEqual(timeout, 30)
            return io.BytesIO(bundle if url.endswith('.json') else archive)
        with patch('fetch_engine.urllib.request.urlopen', side_effect=response) as download:
            self.assertTrue(fetch(destination, self.root / 'trusted_root.json')['artifact_authenticated'])
            self.assertEqual(download.call_count, 2)
            self.assertTrue(fetch(destination, self.root / 'trusted_root.json')['artifact_authenticated'])
            self.assertEqual(download.call_count, 2, 'cache hit must not redownload')
            (destination / 'pdfium-linux-x64.tgz').write_bytes(b'changed cached archive')
            with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
                fetch(destination, self.root / 'trusted_root.json')
            self.assertEqual(download.call_count, 2, 'corrupt cache must fail closed')

    def test_rejected_download_is_not_published(self):
        from fetch_engine import fetch
        destination = self.root / 'rejected'
        with patch('fetch_engine.urllib.request.urlopen', side_effect=lambda *a, **k: io.BytesIO(b'bad bytes')):
            with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
                fetch(destination, self.root / 'trusted_root.json')
        self.assertEqual(list(destination.iterdir()), [])

    def test_receiving_geometry_stays_exact(self):
        from run_pdf import geometry
        valid = {'bounds': [10.1, 20.2, 210.3, 120.4], 'rotation': 0,
                 'width': 210.3 - 10.1, 'height': 120.4 - 20.2, 'kind': 'resolvedBounds'}
        self.assertEqual(geometry(valid), valid)
        for change in ({'width': valid['width'] + 0.00001}, {'rotation': True},
                       {'bounds': [0, 0, float('inf'), 1]}, {'height': -1}):
            with self.assertRaises(ValueError):
                geometry({**valid, **change})

    def test_wall_clock_cannot_be_disabled(self):
        from run_pdf import operate
        with patch('run_pdf.subprocess.Popen') as launch:
            for timeout in (0, -1, 31, float('inf'), float('nan'), True):
                with self.assertRaisesRegex(ValueError, 'wall-clock limit'):
                    operate(self.root, b'controlled', timeout=timeout)
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
