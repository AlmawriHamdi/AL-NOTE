#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real worker failures used by the opt-in Canvas prototype regression."""
import json
from pathlib import Path
import sys
import tempfile
import struct

from run_pdf import operate, prepare_runtime
from unittest.mock import patch
from check_pdf import generated_document

root = Path(__file__).resolve().parents[2]
evidence = Path('/tmp/al-note-linux-prototype')
mode = sys.argv[1]
protocol_modes = ('short-input', 'integer-metadata', 'oversized-coordinate')
if mode not in ('malformed', 'timeout', 'cancelled', 'missing', 'limits', *protocol_modes):
    raise ValueError('unknown failure control')
with tempfile.TemporaryDirectory(prefix='alnote-pdf-failure-') as directory:
    runtime = Path(directory)
    worker = 'protocol-worker' if mode in protocol_modes else 'pdf-worker'
    prepare_runtime(runtime, evidence / worker, evidence / 'libguard.so',
                    root / 'build/linux-pdf-controlled/pdfium/out/alnote/libpdfium.so')
    fixture = 'truncated-controlled.pdf' if mode == 'malformed' else 'blank-workflow.pdf'
    source = (root / 'test/fixtures/phase8/admitted' / fixture).read_bytes()
    options = {}
    if mode in protocol_modes:
        page = {'kind': 'resolvedBounds', 'bounds': [0, 0, 1, 1],
                'rotation': 0, 'width': 1, 'height': 1}
        response = {'version': 1, 'id': 1, 'status': 'ok', 'pages': [page]}
        if mode == 'short-input':
            source = b'x' * 1000000
        elif mode == 'integer-metadata':
            response['id'] = True
        else:
            page['bounds'] = [0, 0, 10**400, 1]
        payload = json.dumps(response).encode()
        (runtime / 'response').write_bytes(struct.pack('!I', len(payload)) + payload)
        (runtime / 'mode').write_text('3' if mode == 'short-input' else '6')
    if mode == 'timeout':
        options['timeout'] = 0.001
    elif mode == 'cancelled':
        source = generated_document(100000)
        options.update(operation='render', cancel_after=0.05)
    elif mode == 'missing':
        (runtime / 'worker').unlink()
    if mode == 'limits':
        with patch('run_pdf.read_limits', return_value={}):
            result = operate(runtime, source, **options)
        assert result['sent_bytes'] == 0
    else:
        result = operate(runtime, source, **options)
    if result['ok'] or result['frames']:
        raise AssertionError('failure control unexpectedly published success')
    if mode == 'timeout':
        assert result['service']['Result'] == 'timeout'
    if mode == 'cancelled':
        assert result['reason'] == 'cancelled' and result['sent_bytes'] > len(source)
    if mode in protocol_modes:
        expected = {'short-input': 'incomplete request transport',
                    'integer-metadata': 'worker rejected',
                    'oversized-coordinate': 'invalid coordinates'}
        assert result['reason'] == expected[mode]
    (evidence / ('failure-' + mode + '.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
