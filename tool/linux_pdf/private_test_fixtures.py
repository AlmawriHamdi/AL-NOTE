#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Deterministic controlled PDFs for private tests; never fixture admission."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'test/fixtures/phase8/linux-private'


def rc4(key, data):
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) % 256
        state[i], state[j] = state[j], state[i]
    i = j = 0
    output = bytearray()
    for byte in data:
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        output.append(byte ^ state[(state[i] + state[j]) % 256])
    return bytes(output)


def pdf(kind, password=None, page_count=1):
    # R2 40-bit encryption is test data only, not application encryption support.
    padding = bytes.fromhex('28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a')
    identifier = hashlib.md5(b'AL NOTE private controlled test').digest()
    encryption = None
    key = None
    if password is not None:
        user = (password.encode() + padding)[:32]
        owner = rc4(hashlib.md5((b'owner' + padding)[:32]).digest()[:5], user)
        key = hashlib.md5(user + owner + struct.pack('<i', -4) + identifier).digest()[:5]
        value = rc4(key, padding)
        encryption = b'<< /Filter /Standard /V 1 /R 2 /Length 40 /O <' + owner.hex().encode() + b'> /U <' + value.hex().encode() + b'> /P -4 >>'
    operations = b''
    if kind in ('text', 'mixed'):
        operations += b'BT /F1 24 Tf 30 230 Td (Private ordinary PDF) Tj ET\n'
    if kind in ('scanned', 'mixed'):
        operations += b'q 200 0 0 150 100 40 cm /Im1 Do Q\n'
    if kind == 'mixed':
        operations += b'0 0 1 rg 25 35 35 100 re f\n'
    if key is not None:
        object_key = hashlib.md5(key + b'\x04\x00\x00\x00\x00').digest()[:10]
        operations = rc4(object_key, operations)
    pixels = bytes(v for y in range(32) for x in range(32) for v in ((220, 30, 20) if (x // 4 + y // 4) % 2 else (20, 100, 230)))
    pixels = zlib.compress(pixels)
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [' + b'3 0 R ' * page_count + b'] /Count ' + str(page_count).encode() + b' >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>',
        b'<< /Length ' + str(len(operations)).encode() + b' >>\nstream\n' + operations + b'\nendstream',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        b'<< /Type /XObject /Subtype /Image /Width 32 /Height 32 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ' + str(len(pixels)).encode() + b' >>\nstream\n' + pixels + b'\nendstream',
    ]
    if encryption is not None:
        objects.append(encryption)
    output = bytearray(b'%PDF-1.4\n%AL NOTE private test\n')
    offsets = [0]
    for number, value in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(str(number).encode() + b' 0 obj\n' + value + b'\nendobj\n')
    xref = len(output)
    output.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        output.extend(f'{offset:010d} 00000 n \n'.encode())
    trailer = f'trailer\n<< /Size {len(offsets)} /Root 1 0 R'.encode()
    if encryption is not None:
        trailer += b' /Encrypt 7 0 R /ID [<' + identifier.hex().encode() + b'><' + identifier.hex().encode() + b'>]'
    output.extend(trailer + f' >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return bytes(output)


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    files = {kind + '.pdf': pdf(kind) for kind in ('text', 'scanned', 'mixed')}
    files['password.pdf'] = pdf('text', password='private-test')
    files['encrypted-empty-password.pdf'] = pdf('text', password='')
    files['too-many-pages.pdf'] = pdf('text', page_count=1001)
    records = {}
    for name, data in files.items():
        (DEST / name).write_bytes(data)
        records[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    (DEST / 'manifest.json').write_text(json.dumps(records, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
