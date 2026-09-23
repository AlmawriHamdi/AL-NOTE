#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Opt-in real Bazzite parent-boundary regressions; no application integration.

See phase8-linux-prototype-correction.md for diagnostic compile/run commands.
ALNOTE_PROTOCOL_WORKER selects only the trusted compiled diagnostic executable.
Existing controlled engine/guard/AOT worker artifacts are reused, never rebuilt.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import run_pdf
from check_containment import read_limits
from check_pdf import generated_document

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = Path('/tmp/al-note-linux-prototype')
LIBRARY = ROOT / 'build/linux-pdf-controlled/pdfium/out/alnote/libpdfium.so'
PAGE = {'kind': 'resolvedBounds', 'bounds': [0, 0, 1, 1],
        'rotation': 0, 'width': 1, 'height': 1}
INSPECT = {'version': 1, 'id': 1, 'status': 'ok', 'pages': [PAGE]}
RENDER = {'version': 1, 'id': 1, 'status': 'ok', 'page': PAGE,
          'width': 1, 'height': 1, 'bytes': 4}


def frame(value):
    payload = value if isinstance(value, bytes) else json.dumps(value).encode()
    return struct.pack('!I', len(payload)) + payload


class NumericTest(unittest.TestCase):
    def test_geometry_bound_before_conversion(self):
        for number in (10**400, -(10**400), 2000001, float('inf'), float('nan'), True):
            for field in ('bounds', 'width', 'height'):
                with self.subTest(number=str(number), field=field):
                    value = [0, 0, number, 1] if field == 'bounds' else number
                    with self.assertRaises(ValueError):
                        run_pdf.geometry({**PAGE, field: value})
        self.assertEqual(run_pdf.geometry(PAGE), PAGE)

    def test_integer_request_fields_before_launch(self):
        with patch('run_pdf.subprocess.Popen') as launch:
            for field in ('page', 'width', 'height'):
                for value in (True, 1.0, -1, 10**400):
                    with self.subTest(field=field, value=str(value)):
                        with self.assertRaises(ValueError):
                            run_pdf.operate(Path('/unused'), b'controlled', **{field: value})
            for field in ('timeout', 'cancel_after'):
                with self.assertRaises(ValueError):
                    run_pdf.operate(Path('/unused'), b'controlled', **{field: 10**400})
            launch.assert_not_called()


@unittest.skipUnless(os.environ.get('ALNOTE_PROTOCOL_WORKER'), 'requires real host protocol diagnostic')
class ProtocolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='alnote-protocol-test-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.runtime = Path(cls.temporary.name)
        run_pdf.prepare_runtime(cls.runtime, Path(os.environ['ALNOTE_PROTOCOL_WORKER']),
                                EVIDENCE / 'libguard.so', LIBRARY)

    def operate(self, response, mode=0, source=b'controlled bytes', **options):
        (self.runtime / 'response').write_bytes(response)
        (self.runtime / 'mode').write_text(str(mode))
        groups = []

        def observe_limits(unit):
            group = run_pdf.unit_properties(unit).get('ControlGroup')
            if group:
                groups.append(Path('/sys/fs/cgroup') / group.lstrip('/') / 'cgroup.procs')
            return read_limits(unit)

        before_fds = len(list(Path('/proc/self/fd').iterdir()))
        with patch('run_pdf.read_limits', side_effect=observe_limits):
            result = run_pdf.operate(self.runtime, source, **options)
        self.assertEqual(len(list(Path('/proc/self/fd').iterdir())), before_fds)
        self.assertIn(result['service']['ActiveState'], ('inactive', 'failed'))
        self.assertIsNotNone(result['exit'])
        for members in groups:
            self.assertFalse(members.exists() and members.read_text().strip())
        if not result['ok']:
            self.assertEqual(result['frames'], [])
        return result

    def rejected(self, response, **options):
        result = self.operate(response, **options)
        self.assertFalse(result['ok'], result)
        return result

    def test_incomplete_request_even_with_valid_success(self):
        for mode in (3, 9, 10):
            with self.subTest(mode=mode):
                result = self.rejected(frame(INSPECT), mode=mode, source=b'x' * 1000000,
                                       timeout=.3 if mode == 9 else 30)
                # Immediate exit can remove the cgroup before readiness checks;
                # that must reject too, without an assertion in our observer.
                if mode == 3:
                    self.assertEqual(result['reason'], 'incomplete request transport')
                self.assertLess(result['sent_bytes'], 1000000)

    def test_zero_length_write_rejects(self):
        with patch('run_pdf.os.write', return_value=0):
            result = self.rejected(frame(INSPECT), mode=2)
        self.assertEqual(result['reason'], 'incomplete request transport')
        self.assertEqual(result['sent_bytes'], 0)

    def test_broken_write_rejects_and_reaps(self):
        with patch('run_pdf.os.write', side_effect=BrokenPipeError):
            result = self.rejected(frame(INSPECT), mode=2)
        self.assertEqual(result['reason'], 'incomplete request transport')
        self.assertEqual(result['sent_bytes'], 0)

    def test_exact_integer_identifiers(self):
        for field in ('version', 'id'):
            for value in (True, 1.0, False, 0, 2, 10**400):
                with self.subTest(field=field, value=str(value)):
                    self.rejected(frame({**INSPECT, field: value}))

    def test_exact_integer_raster_fields(self):
        for field in ('width', 'height', 'bytes'):
            for value in (True, float(RENDER[field]), False, 0, 4097, 10**400):
                with self.subTest(field=field, value=str(value)):
                    self.rejected(frame({**RENDER, field: value}) + frame(b'abcd'),
                                  operation='render', width=1, height=1)

    def test_exact_integer_optional_timings(self):
        for field in ('initialization_us', 'inspection_us', 'render_us'):
            for value in (True, 1.0, -1):
                with self.subTest(field=field, value=value):
                    self.rejected(frame({**INSPECT, field: value}))

    def test_oversized_geometry_reaps_descendants(self):
        for field in ('bounds', 'width', 'height'):
            with self.subTest(field=field):
                value = [0, 0, 10**400, 1] if field == 'bounds' else 10**400
                result = self.rejected(frame({**INSPECT, 'pages': [{**PAGE, field: value}]}), mode=6)
                self.assertEqual(result['reason'], 'invalid coordinates')

    def test_protocol_and_cleanup_controls(self):
        cases = [
            ('truncated', frame(INSPECT)[:-1], 0, {}),
            ('invalid-json', frame(b'{'), 0, {}),
            ('nonutf8', frame(b'\xff'), 0, {}),
            ('oversize', struct.pack('!I', 0xffffffff), 0, {}),
            ('extra-frame', frame(INSPECT) + frame(b'excess'), 0, {}),
            ('extra-byte', frame(INSPECT) + b'x', 0, {}),
            ('nonzero-exit', frame(INSPECT), 1, {}),
            ('hang', frame(INSPECT), 2, {'timeout': .3}),
            ('closed-output', frame(INSPECT), 4, {'timeout': .3}),
            ('stderr-flood', frame(INSPECT), 5, {}),
            ('early-exit', b'', 8, {}),
            ('descendant-cancel', frame(INSPECT), 6, {'cancel_after': .05}),
            ('short-raster', frame(RENDER) + frame(b'abc'), 0,
             {'operation': 'render', 'width': 1, 'height': 1}),
        ]
        for name, response, mode, options in cases:
            with self.subTest(case=name):
                self.rejected(response, mode=mode, **options)
        # A new unit still works after the rejected/terminated requests.
        result = self.operate(frame(INSPECT))
        self.assertTrue(result['ok'], result)
        self.assertGreater(result['sent_bytes'], len(b'controlled bytes'))
        self.assertTrue(self.operate(frame(RENDER) + frame(b'abcd'),
                                    operation='render', width=1, height=1)['ok'])

    def test_real_worker_inspection_and_render(self):
        with tempfile.TemporaryDirectory(prefix='alnote-real-control-') as directory:
            runtime = Path(directory)
            run_pdf.prepare_runtime(runtime, EVIDENCE / 'pdf-worker', EVIDENCE / 'libguard.so', LIBRARY)
            # Public, locally generated ordinary text/graphics; no app admission.
            source = generated_document()
            rows = []
            for operation in ('inspect', 'render'):
                result = run_pdf.operate(runtime, source, operation, width=400, height=300)
                self.assertTrue(result['ok'], result['reason'])
                self.assertEqual(result['exit'], 0)
                self.assertIn(result['service']['ActiveState'], ('inactive', 'failed'))
                self.assertGreater(result['sent_bytes'], len(source))
                if operation == 'inspect':
                    self.assertEqual(len(result['frames'][1]['pages']), 3)
                else:
                    rgba = result['frames'].pop()
                    self.assertEqual(len(rgba), 400 * 300 * 4)
                    self.assertEqual(set(rgba[3::4]), {255})
                    self.assertGreater(len(set(rgba[0::4])), 1)
                    result['rgba_sha256'] = hashlib.sha256(rgba).hexdigest()
                rows.append(result)
            print('REAL_WORKER_CONTROL ' + json.dumps(rows), flush=True)


if __name__ == '__main__':
    unittest.main()
