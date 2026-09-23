#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Authenticate staged Linux engine bytes; never load or execute the engine.

The repository manifest is review input, never populated from downloaded bytes.
--require-executable intentionally fails until source correspondence is reviewed.
No change to the application's existing native-asset hook or admission policy.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

MANIFEST = Path(__file__).with_name('engine_manifest.json')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(directory, require_executable=False, trusted_root=None):
    manifest = json.loads(MANIFEST.read_text())
    archive = directory / 'pdfium-linux-x64.tgz'
    bundle = directory / 'attestation.json'
    if archive.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('archive too large')
    if digest(archive) != manifest['archive_sha256']:
        raise ValueError('archive digest mismatch')
    if bundle.stat().st_size > 1024 * 1024:
        raise ValueError('bundle too large')
    trusted_arguments = []
    if trusted_root is not None:
        # This root was obtained by the successful TUF-backed verification.
        # Pinning it supports reproducible offline checks of this one release.
        if digest(trusted_root) != '6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66':
            raise ValueError('trusted root digest mismatch')
        trusted_arguments = ['--trusted-root', str(trusted_root)]
    subprocess.run([
        '/usr/bin/cosign', 'verify-blob-attestation', '--bundle', str(bundle),
        '--certificate-identity', manifest['workflow_identity'],
        '--certificate-oidc-issuer', manifest['oidc_issuer'],
        '--certificate-github-workflow-sha', manifest['recipe_commit'],
        '--type', 'https://slsa.dev/provenance/v1',
        '--digest', manifest['archive_sha256'], '--digestAlg', 'sha256',
        *trusted_arguments,
    ], check=True, timeout=60)
    statement = json.loads(base64.b64decode(
        json.loads(bundle.read_text())['dsseEnvelope']['payload'], validate=True))
    dependencies = statement['predicate']['buildDefinition']['resolvedDependencies']
    if not any(x.get('digest', {}).get('gitCommit') == manifest['recipe_commit']
               for x in dependencies):
        raise ValueError('recipe provenance mismatch')
    # Inspect members without extracting. Reject aliases, duplicates and links.
    with tarfile.open(archive) as tar:
        names = set()
        total = 0
        library_digest = None
        for member in tar:
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or member.name in names:
                raise ValueError('invalid archive path')
            names.add(member.name)
            if not member.isfile() and not member.isdir():
                raise ValueError('unsupported archive member')
            total += member.size
            if total > 32 * 1024 * 1024 or len(names) > 256:
                raise ValueError('archive expansion limit')
            if member.name == 'lib/libpdfium.so':
                with tar.extractfile(member) as stream:
                    library_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if library_digest != manifest['library_sha256']:
            raise ValueError('library digest mismatch')
    cached = directory / 'authenticated-archive/lib/libpdfium.so'
    if cached.exists() and (cached.is_symlink() or digest(cached) != library_digest):
        raise ValueError('cached library digest mismatch')
    if require_executable and not manifest['source_correspondence_verified']:
        raise ValueError('source checkout is not bound by available provenance; execution denied')
    return {'artifact_authenticated': True, 'source_correspondence_verified':
            manifest['source_correspondence_verified'], 'engine_executed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--require-executable', action='store_true')
    parser.add_argument('--trusted-root', type=Path)
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.directory, arguments.require_executable,
                            arguments.trusted_root)))
