#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Controlled native geometry and ordinary-test-PDF checks inside the prototype.

Reuses the accepted 40 fixture bytes and their independently specified rectangle
and marked-centroid expectations. Does not enroll new fixtures in application
admission. The supplied engine must pass run_pdf.prepare_runtime first.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import zlib

from run_pdf import operate, prepare_runtime

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    'contained': [10, 20, 110, 90], 'overlap': [0, 0, 150, 80],
    'oversized': [0, 0, 200, 100], 'reversed': [10, 20, 90, 80],
    'reversedMedia': [0, 0, 200, 100], 'inherited': [-40, -30, 160, 70],
    'inheritedMedia': [-100, -200, 500, 600], 'negative': [-40, -30, 160, 70],
    'fractional': [10.1, 20.2, 210.3, 120.4], 'disjoint': None,
}


def generated_document(repetitions=1):
    """Three pages, ordinary text and compressed graphics; no external inputs."""
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Count 3 /Kids [4 0 R 6 0 R 8 0 R] /MediaBox [0 0 612 792] >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    for index in range(3):
        objects.append(('<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >> '
                        f'/Contents {5 + index * 2} 0 R >>').encode())
        stream = zlib.compress((f'BT /F1 24 Tf 50 700 Td (Controlled ordinary page {index + 1}) Tj ET\n' +
                                '1 0 0 rg 20 30 10 20 re f\n0 0 1 rg 70 60 20 10 re f\n' * repetitions).encode())
        objects.append(f'<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n'.encode() + stream + b'\nendstream')
    output = bytearray(b'%PDF-1.7\n')
    offsets = []
    for index, body in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f'{index} 0 obj\n'.encode() + body + b'\nendobj\n')
    xref = len(output)
    output.extend(f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode())
    for offset in offsets:
        output.extend(f'{offset:010d} 00000 n \n'.encode())
    output.extend(f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return bytes(output)


def check(worker, guard, library, output):
    output.mkdir(parents=True, exist_ok=True)
    # Diagnostic evidence alone is not a security token: run containment as an
    # auditor prerequisite, then validate the engine manifest before launch.
    rows = []
    with tempfile.TemporaryDirectory(prefix='alnote-pdf-runtime-') as directory:
        runtime = Path(directory)
        prepare_runtime(runtime, worker, guard, library)
        for case, bounds in CASES.items():
            for rotation in (0, 90, 180, 270):
                label = f'{case}-{rotation}'
                source = (ROOT / 'test/fixtures/phase8/admitted' / (label + '.pdf')).read_bytes()
                result = operate(runtime, source)
                if bounds is None:
                    assert not result['ok'], (label, result)
                    rows.append({'case': label, 'rejected': True})
                    continue
                assert result['ok'], (label, result)
                box = result['frames'][1]['pages'][0]
                expected = [struct.unpack('f', struct.pack('f', n))[0] for n in bounds]
                assert box['bounds'] == expected and box['rotation'] == rotation, (label, box)
                width, height = int(box['width'] * 2 + 0.5), int(box['height'] * 2 + 0.5)
                rendered = operate(runtime, source, 'render', width=width, height=height)
                assert rendered['ok'], (label, rendered)
                pixels = rendered['frames'][2]
                marks = [[0, 0, 0], [0, 0, 0]]
                for offset in range(0, len(pixels), 4):
                    red, green, blue = pixels[offset:offset + 3]
                    mark = 0 if red > 240 and blue < 10 and green < 10 else 1 if blue > 240 and red < 10 and green < 10 else None
                    if mark is not None:
                        pixel = offset // 4
                        marks[mark][0] += 1
                        marks[mark][1] += pixel % width + 0.5
                        marks[mark][2] += pixel // width + 0.5
                centroids = []
                left, bottom, right, top = expected
                for index, (x, y) in enumerate(((25, 40), (80, 65))):
                    local = {0: (x - left, top - y), 90: (y - bottom, x - left),
                             180: (right - x, y - bottom), 270: (top - y, right - x)}[rotation]
                    predicted = (local[0] * width / box['width'], local[1] * height / box['height'])
                    count, sum_x, sum_y = marks[index]
                    assert count > 100, (label, 'missing mark', index)
                    actual = (sum_x / count, sum_y / count)
                    assert max(abs(a - b) for a, b in zip(actual, predicted)) <= 0.6, (label, actual, predicted)
                    centroids.append([*actual, *predicted])
                rows.append({'case': label, 'centroids': centroids,
                             'inspect_elapsed_ms': result['elapsed_ms'],
                             'render_elapsed_ms': rendered['elapsed_ms'],
                             'startup_ms': rendered['startup_ms'],
                             'inspection_us': rendered['frames'][1]['inspection_us'],
                             'render_us': rendered['frames'][1]['render_us']})
                (output / 'pdf-results.json').write_text(json.dumps(rows, indent=2))
        ordinary = generated_document()
        (output / 'generated-ordinary.pdf').write_bytes(ordinary)
        registry = (ROOT / 'lib/documents/pdf/src/reviewed_pdf_fixture_digests.dart').read_text()
        assert hashlib.sha256(ordinary).hexdigest() not in registry
        inspected = operate(runtime, ordinary)
        assert inspected['ok'] and len(inspected['frames'][1]['pages']) == 3, inspected
        rendered = operate(runtime, ordinary, 'render', page=2, width=612, height=792)
        assert rendered['ok'], rendered
        assert any(x < 100 for x in rendered['frames'][2]), 'ordinary page must contain visible ink'
        pixels = rendered['frames'][2]
        text_ink = sum(pixels[(y * 612 + x) * 4] < 100
                       for y in range(60, 105) for x in range(40, 550))
        assert text_ink > 100, 'ordinary Helvetica text must render, not just graphics'
        for malformed in (b'not a PDF', b'%PDF-1.7\n1 0 obj\n<< /Type /Catalog'):
            rejected = operate(runtime, malformed)
            assert not rejected['ok'], rejected
        restarted = operate(runtime, ordinary)
        assert restarted['ok'], restarted
        rows.append({'case': 'generated-ordinary', 'pages': 3,
                     'sha256': hashlib.sha256(ordinary).hexdigest(),
                     'inspect_elapsed_ms': inspected['elapsed_ms'],
                     'render_elapsed_ms': rendered['elapsed_ms'],
                     'inspection_us': rendered['frames'][1]['inspection_us'],
                     'render_us': rendered['frames'][1]['render_us']})
        heavy = generated_document(100000)
        (output / 'generated-heavy.pdf').write_bytes(heavy)
        assert hashlib.sha256(heavy).hexdigest() not in registry
        control = operate(runtime, heavy, 'render', width=612, height=792)
        assert control['ok'], control
        cancelled = operate(runtime, heavy, 'render', width=612, height=792, cancel_after=0.05)
        assert not cancelled['ok'] and not cancelled['frames'], cancelled
        assert cancelled['reason'] == 'cancelled' and cancelled['sent_bytes'] > len(heavy), cancelled
        assert operate(runtime, ordinary)['ok'], 'restart after native-work cancellation'
        rows.append({'case': 'heavy-cancellation', 'sha256': hashlib.sha256(heavy).hexdigest(),
                     'source_bytes': len(heavy), 'control_elapsed_ms': control['elapsed_ms'],
                     'control_render_us': control['frames'][1]['render_us'],
                     'cancelled': cancelled})
    (output / 'pdf-results.json').write_text(json.dumps(rows, indent=2))
    print('PASS: 40 accepted geometry cases; generated ordinary PDF; malformed rejection and restart')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('worker', 'guard', 'library', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    arguments = parser.parse_args()
    check(arguments.worker, arguments.guard, arguments.library, arguments.output)
