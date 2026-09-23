#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build-time resource packaging only. Never invoked by the application.

A candidate is inert until its exact manifest digest is reviewed and compiled
into AL NOTE. Normal packaging compares every byte to the checked-in manifest.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / 'tool/linux_pdf/packaged_resources.json'


def package(worker, guard, transport, destination, candidate=False):
    controlled = json.loads((ROOT / 'tool/linux_pdf/controlled_engine.json').read_text())
    engine = ROOT / 'build/linux-pdf-controlled/pdfium/out/alnote/libpdfium.so'
    if hashlib.sha256(engine.read_bytes()).hexdigest() != controlled['library_sha256']:
        raise ValueError('controlled engine digest mismatch')
    sources = {'worker': worker, 'transport': transport, 'libguard.so': guard, 'libpdfium.so': engine}
    for name in ('libc.so.6', 'ld-linux-x86-64.so.2', 'libdl.so.2',
                 'libpthread.so.0', 'libm.so.6', 'libgcc_s.so.1'):
        sources[name] = Path('/lib64') / name
    for group in ('glibc', 'libgcc'):
        for path in sorted((Path('/usr/share/licenses') / group).iterdir()):
            if path.is_file():
                sources[f'notices/{group}/{path.name}'] = path
    for path in sorted((ROOT / 'build/linux-pdf-controlled/notices').rglob('*')):
        if path.is_file():
            sources['notices/pdfium/' + str(path.relative_to(ROOT / 'build/linux-pdf-controlled/notices'))] = path
    sources['notices/alnote/LICENSE'] = ROOT / 'LICENSE'
    # Retain notices for the resolved Dart graph (a conservative superset of
    # worker dependencies), including the SDK runtime. No network acquisition.
    config_path = ROOT / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    for entry in config['packages']:
        uri = entry['rootUri']
        directory = (Path(unquote(urlparse(uri).path)) if uri.startswith('file:')
                     else (config_path.parent / uri).resolve())
        for filename in ('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING', 'NOTICE'):
            path = directory / filename
            if path.is_file():
                sources[f"notices/dart-packages/{entry['name']}/{filename}"] = path
        if entry['name'] == 'flutter':
            sources['notices/dart-sdk/LICENSE'] = directory.parent.parent / 'bin/cache/dart-sdk/LICENSE'
    records = {}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='pdf-candidate-') as directory:
        stage = Path(directory)
        for name, source in sources.items():
            with source.open('rb') as stream:
                data = stream.read(32 * 1024 * 1024 + 1)
            if not 0 < len(data) <= 32 * 1024 * 1024:
                raise ValueError('resource limit')
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o500 if '/' not in name else 0o400)
            records[name] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        encoded = (json.dumps({'version': 1, 'engine_source': controlled['source_commit'],
                               'files': records}, sort_keys=True, indent=2) + '\n').encode()
        if not candidate and encoded != PIN.read_bytes():
            raise ValueError('package differs from reviewed manifest; independent resource review required')
        (stage / 'manifest.json').write_bytes(encoded)
        (stage / 'manifest.json').chmod(0o400)
        if destination.exists():
            raise ValueError('destination already exists; use a new destination')
        shutil.copytree(stage, destination)
        destination.chmod(0o700)
        print('manifest sha256:', hashlib.sha256(encoded).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--guard', type=Path, required=True)
    parser.add_argument('--transport', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--candidate', action='store_true')
    args = parser.parse_args()
    package(args.worker, args.guard, args.transport, args.destination, args.candidate)
