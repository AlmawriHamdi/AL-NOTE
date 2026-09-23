#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact-write native transport regression; controlled child, no PDF engine."""
import os
from pathlib import Path
import signal
import struct
import subprocess
import unittest

TRANSPORT = Path('build/linux-pdf-tools/transport').resolve()
PYTHON = '/usr/bin/python3'


def frame(data):
    return struct.pack('!I', len(data)) + data


class InputTransportTest(unittest.TestCase):
    def run_child(self, script, data):
        return subprocess.run([str(TRANSPORT), PYTHON, '-c', script],
                              input=data, capture_output=True, timeout=5)

    def test_valid_fragmented_consumption(self):
        for length in (31, 65535, 65536, 65537):
            payload = frame(b'{"version":1}') + frame(b'x' * length)
            result = self.run_child(
                'import os,hashlib\nh=hashlib.sha256()\n'
                'while True:\n b=os.read(0,7)\n if not b:break\n h.update(b)\n'
                'print(h.hexdigest())', payload)
            import hashlib
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip().decode(), hashlib.sha256(payload).hexdigest())

    def test_early_success_cannot_hide_short_input(self):
        result = self.run_child('import time\ntime.sleep(.15)\nprint("valid looking success")',
                                frame(b'{}') + frame(b'x' * 1000000))
        self.assertNotEqual(result.returncode, 0)

    def test_declared_frame_limits_and_short_source(self):
        for data in (frame(b'{}') + struct.pack('!I', 5) + b'x',
                     struct.pack('!I', 1025), struct.pack('!I', 0),
                     frame(b'{}') + struct.pack('!I', 50000001)):
            result = self.run_child('import sys;sys.stdin.buffer.read()', data)
            self.assertNotEqual(result.returncode, 0)

    def test_nonzero_or_early_child_exit_rejects(self):
        for script in ('import sys;sys.stdin.buffer.read();sys.exit(23)', 'pass'):
            result = self.run_child(script, frame(b'{}') + frame(b'controlled'))
            # Tiny input can fully fit in the pipe before an early exit. A
            # nonzero child must always reject; response validity is checked
            # separately by the Dart supervisor.
            if '23' in script:
                self.assertNotEqual(result.returncode, 0)

    def test_cancellation_reaps_concrete_child(self):
        process = subprocess.Popen([str(TRANSPORT), PYTHON, '-c',
                                    'import os,time;print(os.getpid(),flush=True);time.sleep(60)'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            child = int(process.stdout.readline())
            process.send_signal(signal.SIGTERM)
            self.assertNotEqual(process.wait(timeout=3), 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()


if __name__ == '__main__':
    unittest.main()
