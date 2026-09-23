#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bazzite-only containment diagnostic. No PDF parsing or application integration.

Compile sandbox_probe.c in al-note-dev, then run this supervisor on the host.
All process starts use argument arrays; no worker receives a shell or host paths.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import struct
import subprocess
import tempfile
import time
import uuid

SYSTEMD = '/usr/bin/systemd-run'
SYSTEMCTL = '/usr/bin/systemctl'
BWRAP = '/usr/bin/bwrap'
MAX_OUTPUT = 4096
MAX_FRAME = 1024


def unit_properties(unit):
    result = subprocess.run(
        [SYSTEMCTL, '--user', 'show', unit, '-p', 'ActiveState', '-p', 'SubState',
         '-p', 'Result', '-p', 'ControlGroup'],
        capture_output=True, text=True, timeout=3, check=False)
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


def read_limits(unit):
    group = unit_properties(unit).get('ControlGroup')
    if not group:
        raise ValueError('isolation cgroup unavailable')
    root = Path('/sys/fs/cgroup') / group.lstrip('/')
    try:
        return {name: (root / name).read_text().strip()
                for name in ('memory.max', 'memory.swap.max', 'pids.max')}
    except OSError as error:
        raise ValueError('isolation controllers unavailable') from error


def command_line(runtime, unit, seconds, worker='probe', memory='64M', tasks=16):
    for executable in (SYSTEMD, SYSTEMCTL, BWRAP):
        if not os.access(executable, os.X_OK):
            raise RuntimeError('required isolation support unavailable')
    libraries = []
    for name in ('libdl.so.2', 'libpthread.so.0', 'libm.so.6', 'libstdc++.so.6', 'libgcc_s.so.1'):
        if (runtime / name).is_file():
            libraries += ['--ro-bind', str(runtime / name), '/lib64/' + name]
    return [SYSTEMD, '--user', '--quiet', '--wait', '--pipe',
            '--service-type=exec', '--unit', unit,
            '-p', f'MemoryMax={memory}', '-p', 'MemorySwapMax=0', '-p', f'TasksMax={tasks}',
            '-p', f'RuntimeMaxSec={seconds}', '-p', 'TimeoutStopSec=0.2',
            '-p', 'KillMode=control-group', '-p', 'LimitCORE=0',
            '-p', 'LimitNOFILE=64', '-p', 'UMask=0077',
            BWRAP, '--unshare-all', '--die-with-parent', '--new-session',
            '--clearenv', '--cap-drop', 'ALL',
            '--ro-bind', str(runtime), '/runtime',
            '--dir', '/lib64', '--ro-bind', str(runtime / 'libc.so.6'), '/lib64/libc.so.6',
            '--ro-bind', str(runtime / 'ld-linux-x86-64.so.2'), '/lib64/ld-linux-x86-64.so.2',
            *libraries, '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
            '--chdir', '/tmp', '/runtime/' + worker]


def run_probe(runtime, command, cancel_after=None, service_seconds=3):
    encoded = command.encode('ascii')
    if not 0 < len(encoded) <= 64:
        raise ValueError('input size limit')
    unit = 'alnote-pdf-probe-' + uuid.uuid4().hex + '.service'
    started = time.monotonic()
    process = subprocess.Popen(command_line(runtime, unit, service_seconds),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, close_fds=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, 'out')
    selector.register(process.stderr, selectors.EVENT_READ, 'err')
    frames = []
    pending = bytearray()
    totals = {'out': 0, 'err': 0}
    diagnostics = bytearray()
    ready_at = None
    cancel_at = None
    killed_at = None
    reason = None
    limits = {}
    # Parent watchdog is independent of the systemd service deadline.
    deadline = started + service_seconds + 4
    try:
        while selector.get_map():
            now = time.monotonic()
            if now >= deadline:
                reason = reason or 'supervisor-timeout'
                break
            if cancel_at is not None and now >= cancel_at:
                reason = 'cancelled'
                break
            next_event = min(deadline, cancel_at or deadline)
            for key, _ in selector.select(max(0, next_event - now)):
                chunk = os.read(key.fileobj.fileno(), 1024)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                channel = key.data
                totals[channel] += len(chunk)
                if totals[channel] > MAX_OUTPUT:
                    reason = 'output-limit'
                    break
                if channel == 'err':
                    diagnostics.extend(chunk)
                    continue
                pending.extend(chunk)
                while len(pending) >= 4:
                    length = struct.unpack('!I', pending[:4])[0]
                    if not 0 < length <= MAX_FRAME:
                        reason = 'invalid-frame'
                        break
                    if len(pending) < length + 4:
                        break
                    payload = bytes(pending[4:4 + length])
                    del pending[:4 + length]
                    try:
                        value = json.loads(payload)
                    except (ValueError, UnicodeError):
                        reason = 'invalid-frame'
                        break
                    if not isinstance(value, dict) or len(frames) >= 2:
                        reason = 'invalid-frame'
                        break
                    if not frames:
                        if value != {'ready': True}:
                            reason = 'invalid-frame'
                            break
                        ready_at = time.monotonic()
                        cancel_at = ready_at + cancel_after if cancel_after is not None else None
                        limits = read_limits(unit)
                        if limits != {'memory.max': '67108864', 'memory.swap.max': '0', 'pids.max': '16'}:
                            raise ValueError('isolation limits not enforced')
                        process.stdin.write(struct.pack('!I', len(encoded)) + encoded)
                        process.stdin.close()
                    frames.append(value)
                if reason:
                    break
            if reason:
                break
        if pending and reason is None:
            reason = 'truncated-frame'
    finally:
        # Kill the service cgroup, not merely the systemd-run client. Always reap.
        if process.poll() is None:
            killed_at = time.monotonic()
            subprocess.run([SYSTEMCTL, '--user', 'kill', '--signal=KILL', unit],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=3, check=False)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            reason = 'reap-failure'
        selector.close()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
    ended = time.monotonic()
    properties = unit_properties(unit)
    if properties.get('ActiveState') not in ('inactive', 'failed'):
        raise RuntimeError(f'worker not confirmed stopped: {properties}')
    group = properties.get('ControlGroup')
    if group:
        members = Path('/sys/fs/cgroup') / group.lstrip('/') / 'cgroup.procs'
        if members.exists() and members.read_text().strip():
            raise RuntimeError('worker processes remain')
    subprocess.run([SYSTEMCTL, '--user', 'reset-failed', unit],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=3, check=False)
    return {'command': command, 'exit': process.returncode, 'reason': reason,
            'frames': frames, 'limits': limits, 'service': properties,
            'startup_ms': (ready_at - started) * 1000 if ready_at else None,
            'elapsed_ms': (ended - started) * 1000,
            'termination_ms': (ended - killed_at) * 1000 if killed_at else None,
            'output_bytes': totals, 'stderr': diagnostics.decode(errors='replace')}


def check(probe, output):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix='alnote-pdf-runtime-') as folder:
        runtime = Path(folder)
        for source, name in ((probe, 'probe'),
                             (Path('/lib64/libc.so.6'), 'libc.so.6'),
                             (Path('/lib64/ld-linux-x86-64.so.2'), 'ld-linux-x86-64.so.2')):
            shutil.copyfile(source, runtime / name)
            (runtime / name).chmod(0o500)
        cases = [('probe', {}), ('tasks', {}), ('memory', {}), ('sleep', {'service_seconds': 0.8}),
                 ('sleep', {'cancel_after': 0.15}), ('crash', {}), ('flood', {}), ('badlength', {}),
                 ('probe', {})]
        for command, options in cases:
            result = run_probe(runtime, command, **options)
            results.append(result)
            (output / 'containment.json').write_text(json.dumps(results, indent=2))
            print(json.dumps(result), flush=True)
        # No runtime means exec failure. Never substitute an in-process parser.
        missing = runtime / 'probe'
        missing.unlink()
        result = run_probe(runtime, 'probe')
        results.append(result)
        assert result['exit'] != 0 and not result['frames'], result
    for index in (0, 8):
        assert results[index]['exit'] == 0, results[index]
        values = results[index]['frames'][1]
        assert set(values) == {'home_absent', 'network_denied', 'ipc_denied', 'display_absent',
                               'session_absent', 'runtime_read_only', 'environment_cleared',
                               'core_disabled', 'thread_network_denied', 'pid'}, values
        assert all(v == 1 for k, v in values.items() if k != 'pid'), values
    assert results[1]['frames'][1]['denied'] == 1, results[1]
    assert 0 < results[1]['frames'][1]['children'] < 16, results[1]
    assert results[2]['service'].get('Result') == 'oom-kill', results[2]
    assert results[3]['service'].get('Result') == 'timeout', results[3]
    assert results[4]['reason'] == 'cancelled' and results[4]['termination_ms'] < 1500, results[4]
    assert results[5]['exit'] != 0, results[5]
    assert results[6]['reason'] in ('invalid-frame', 'output-limit'), results[6]
    assert results[7]['reason'] == 'invalid-frame', results[7]
    assert results[4]['limits'] == {'memory.max': '67108864', 'memory.swap.max': '0', 'pids.max': '16'}
    (output / 'containment.json').write_text(json.dumps(results, indent=2))
    print('PASS: 10 containment cases; no PDF engine was loaded')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    check(arguments.probe.resolve(), arguments.output.resolve())
