#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Standalone Linux prototype supervisor. Never imported by AL NOTE.

Requires the reviewed controlled-build manifest (absent until that gate passes).
Only callers explicitly supplying public/generated test bytes may use this tool.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import struct
import subprocess
import tempfile
import time
import uuid

from check_containment import SYSTEMCTL, command_line, read_limits, unit_properties

MAX_INPUT = 50000000
MAX_PIXELS = 4096 * 4096
MAX_HEADER = 256 * 1024
MANIFEST = Path(__file__).with_name('controlled_engine.json')


def prepare_runtime(destination, worker, guard, library):
    # No command-line hash override and no fallback to the authenticated-but-
    # source-unbound publisher archive. This gate is deliberately still closed.
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get('source_commit') != 'f91ca5a72358bb0b00b4da9481b21fe668157614':
        raise ValueError('source pin mismatch')
    if manifest.get('source_correspondence_verified') is not True:
        raise ValueError('source provenance unavailable')
    with library.open('rb') as stream:
        data = stream.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != manifest['library_sha256']:
        raise ValueError('engine digest mismatch')
    (destination / 'libpdfium.so').write_bytes(data)
    for source, name in ((worker, 'worker'), (guard, 'libguard.so')):
        shutil.copyfile(source, destination / name)
    for name in ('libc.so.6', 'ld-linux-x86-64.so.2', 'libdl.so.2', 'libpthread.so.0',
                 'libm.so.6', 'libgcc_s.so.1'):
        shutil.copyfile(Path('/lib64') / name, destination / name)
    for path in destination.iterdir():
        path.chmod(0o500)


def geometry(value):
    if not isinstance(value, dict) or value.get('kind') != 'resolvedBounds':
        raise ValueError('invalid geometry')
    bounds = value.get('bounds')
    if not isinstance(bounds, list) or len(bounds) != 4:
        raise ValueError('invalid bounds')
    numbers = bounds + [value.get('width'), value.get('height')]
    # JSON integers have arbitrary precision. Bound them before isfinite's
    # conversion to float, which can itself overflow on hostile metadata.
    if any(type(n) not in (int, float) or abs(n) > 2000000 or not math.isfinite(n) for n in numbers):
        raise ValueError('invalid coordinates')
    left, bottom, right, top = bounds
    rotation = value.get('rotation')
    if type(rotation) is not int or rotation not in (0, 90, 180, 270) or right <= left or top <= bottom:
        raise ValueError('invalid rotation/extent')
    expected = (right - left, top - bottom)
    if rotation in (90, 270):
        expected = expected[::-1]
    if (value['width'], value['height']) != expected:
        raise ValueError('inconsistent exact geometry')
    return value


def operate(runtime, source, operation='inspect', page=0, width=400, height=300,
            timeout=30, cancel_after=None):
    if type(timeout) not in (int, float) or not 0 < timeout <= 30 or not math.isfinite(timeout):
        raise ValueError('wall-clock limit')
    if cancel_after is not None and (type(cancel_after) not in (int, float) or
                                    not 0 < cancel_after <= 30 or not math.isfinite(cancel_after)):
        raise ValueError('cancellation interval')
    if type(source) is not bytes or not 0 < len(source) <= MAX_INPUT:
        raise ValueError('immutable input limit')
    if operation not in ('inspect', 'render') or type(page) is not int or not 0 <= page < 1000:
        raise ValueError('invalid operation')
    if type(width) is not int or type(height) is not int or not 0 < width <= 4096 or not 0 < height <= 4096:
        raise ValueError('render limit')
    identifier = 1  # One request per process; unit identity separates operations.
    request = json.dumps({'version': 1, 'id': identifier, 'operation': operation,
                          'page': page, 'width': width, 'height': height}).encode()
    # Memoryviews retain one immutable source buffer; writes are at most 64 KiB.
    inputs = [memoryview(struct.pack('!I', len(request))), memoryview(request),
              memoryview(struct.pack('!I', len(source))), memoryview(source)]
    expected_sent = sum(len(part) for part in inputs)
    unit = 'alnote-pdf-worker-' + uuid.uuid4().hex + '.service'
    start = time.monotonic()
    process = subprocess.Popen(command_line(runtime, unit, timeout, 'worker', '1G', 32),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, close_fds=True)
    selector = selectors.DefaultSelector()
    os.set_blocking(process.stdin.fileno(), False)
    for stream, event, tag in ((process.stdout, selectors.EVENT_READ, 'out'),
                               (process.stderr, selectors.EVENT_READ, 'err')):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, event, tag)
    buffer = bytearray()
    frames = []
    stderr_size = 0
    total_output = 0
    sent = 0
    total_sent = 0
    limits = {}
    ready = None
    cancel_at = None
    stopped = None
    rejection = None
    try:
        while selector.get_map():
            now = time.monotonic()
            deadline = min(start + timeout + 2, cancel_at or float('inf'))
            if now >= deadline:
                rejection = 'cancelled' if cancel_at is not None and now >= cancel_at else 'timeout'
                break
            for key, _ in selector.select(deadline - now):
                if key.data == 'in':
                    try:
                        count = os.write(key.fd, inputs[0][sent:sent + 65536])
                    except BrokenPipeError:
                        raise ValueError('incomplete request transport') from None
                    if count <= 0:
                        raise ValueError('incomplete request transport')
                    sent += count
                    total_sent += count
                    if sent == len(inputs[0]):
                        inputs.pop(0)
                        sent = 0
                        if not inputs:
                            if cancel_after is not None:
                                cancel_at = time.monotonic() + cancel_after
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                    continue
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == 'err':
                    stderr_size += len(data)
                    if stderr_size > 4096:
                        raise ValueError('diagnostic limit')
                    continue
                total_output += len(data)
                if total_output > 2 * MAX_HEADER + 12 + width * height * 4:
                    raise ValueError('total output limit')
                buffer.extend(data)
                while len(buffer) >= 4:
                    length = struct.unpack('!I', buffer[:4])[0]
                    maximum = width * height * 4 if len(frames) == 2 and operation == 'render' else MAX_HEADER
                    if not 0 < length <= maximum or len(frames) >= (3 if operation == 'render' else 2):
                        raise ValueError('frame limit')
                    if len(buffer) < length + 4:
                        break
                    payload = bytes(buffer[4:length + 4])
                    del buffer[:length + 4]
                    if len(frames) < 2:
                        value = json.loads(payload)
                        if not isinstance(value, dict):
                            raise ValueError('invalid response')
                        for field in ('initialization_us', 'inspection_us', 'render_us'):
                            if field in value and (type(value[field]) is not int or value[field] < 0):
                                raise ValueError('invalid integer timing')
                        if not frames:
                            if value.get('ready') is not True:
                                raise ValueError('worker unavailable')
                            ready = time.monotonic()
                            limits = read_limits(unit)
                            if limits != {'memory.max': '1073741824', 'memory.swap.max': '0', 'pids.max': '32'}:
                                raise ValueError('isolation limits not enforced')
                            # No request/PDF byte enters the worker before the
                            # actual kernel controller values are confirmed.
                            selector.register(process.stdin, selectors.EVENT_WRITE, 'in')
                        else:
                            if inputs or total_sent != expected_sent:
                                raise ValueError('incomplete request transport')
                            if (type(value.get('version')) is not int or type(value.get('id')) is not int or
                                    value.get('version') != 1 or value.get('id') != identifier or value.get('status') != 'ok'):
                                raise ValueError('worker rejected')
                            if operation == 'inspect':
                                pages = value.get('pages')
                                if not isinstance(pages, list) or not 0 < len(pages) <= 1000:
                                    raise ValueError('page limit')
                                for item in pages:
                                    geometry(item)
                            else:
                                geometry(value.get('page'))
                                if (any(type(value.get(field)) is not int for field in ('width', 'height', 'bytes')) or
                                        (value.get('width'), value.get('height'), value.get('bytes')) != (width, height, width * height * 4)):
                                    raise ValueError('raster mismatch')
                        frames.append(value)
                    else:
                        if length != width * height * 4:
                            raise ValueError('raster length')
                        frames.append(payload)
        if buffer:
            rejection = rejection or 'truncated response'
    except (ValueError, OSError, RecursionError, OverflowError) as error:
        rejection = str(error)
    finally:
        if process.poll() is None:
            stopped = time.monotonic()
            subprocess.run([SYSTEMCTL, '--user', 'kill', '--signal=KILL', unit],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=False)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            rejection = 'reap failure'
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()
    end = time.monotonic()
    properties = unit_properties(unit)
    if properties.get('ActiveState') not in ('inactive', 'failed'):
        raise RuntimeError('worker not confirmed stopped')
    group = properties.get('ControlGroup')
    if group:
        members = Path('/sys/fs/cgroup') / group.lstrip('/') / 'cgroup.procs'
        if members.exists() and members.read_text().strip():
            raise RuntimeError('worker processes remain')
    subprocess.run([SYSTEMCTL, '--user', 'reset-failed', unit],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=False)
    if process.returncode != 0 or len(frames) != (3 if operation == 'render' else 2):
        rejection = rejection or 'worker failed'
    if inputs or total_sent != expected_sent:
        rejection = rejection or 'incomplete request transport'
    # Publication requires full transport, validated output and successful reap.
    return {'ok': rejection is None, 'reason': rejection, 'frames': frames if rejection is None else [],
            'startup_ms': (ready - start) * 1000 if ready is not None else None,
            'elapsed_ms': (end - start) * 1000,
            'termination_ms': (end - stopped) * 1000 if stopped is not None else None,
            'service': properties, 'exit': process.returncode, 'limits': limits,
            'sent_bytes': total_sent}
