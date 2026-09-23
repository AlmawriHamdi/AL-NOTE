// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../../core/outcomes/cancellation.dart';
import 'linux_pdf_extraction.dart';
import 'linux_pdf_isolate.dart';
import 'linux_pdf_protocol.dart';

/// AL NOTE-owned single-operation supervisor. All publication follows complete
/// input transport, output validation, process reap and cgroup-empty validation.
final class LinuxPdfSupervisor {
  const LinuxPdfSupervisor({
    this.systemdRun = '/usr/bin/systemd-run',
    this.bubblewrap = '/usr/bin/bwrap',
    this.systemctl = '/usr/bin/systemctl',
  });
  // Dependency paths are app-owned; never supplied by selected/document bytes.
  final String systemdRun;
  final String bubblewrap;

  /// An operation retains the admission slot through this state. A failed
  /// controller query or elapsed service deadline never establishes cleanup.
  static bool get cleanupUnconfirmed => _cleanupUnconfirmed;
  static bool _cleanupUnconfirmed = false;
  static bool _owned = false;
  final String systemctl;

  Future<List<Object>> operate({
    required Directory runtime,
    required List<int> source,
    required CancellationToken token,
    bool render = false,
    int page = 0,
    int width = 400,
    int height = 300,
    Duration timeout = const Duration(seconds: 30),
    LinuxPdfExtractionRequest? extraction,
  }) async {
    extraction?.validate();
    if (render && extraction != null) throw const FormatException('operation');
    if (!Platform.isLinux ||
        source.isEmpty ||
        source.length > 50000000 ||
        page < 0 ||
        page >= 1000 ||
        width <= 0 ||
        width > 4096 ||
        height <= 0 ||
        height > 4096 ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30) ||
        token.isCancelled) {
      throw const FormatException('request unavailable');
    }
    for (final name in [systemdRun, systemctl, bubblewrap]) {
      if (!File(name).existsSync()) throw const LinuxPdfIsolationUnavailable();
    }
    if (_owned) throw const LinuxPdfIsolationUnavailable();
    _owned = true;
    final random = Random.secure();
    final identity = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final unit = 'alnote-pdf-$identity.service';
    final seconds = timeout.inMicroseconds / Duration.microsecondsPerSecond;
    final arguments = [
      '--user',
      '--quiet',
      '--wait',
      '--pipe',
      '--service-type=exec',
      '--unit',
      unit,
      '-p',
      'MemoryMax=1G',
      '-p',
      'MemorySwapMax=0',
      '-p',
      'TasksMax=32',
      '-p',
      'RuntimeMaxSec=$seconds',
      '-p',
      'TimeoutStopSec=0.2',
      '-p',
      'KillMode=control-group',
      '-p',
      'LimitCORE=0',
      '-p',
      'LimitNOFILE=64',
      '-p',
      'UMask=0077',
      bubblewrap,
      '--unshare-all',
      '--die-with-parent',
      '--new-session',
      '--clearenv',
      '--cap-drop',
      'ALL',
      '--ro-bind',
      runtime.path,
      '/runtime',
      '--dir',
      '/lib64',
      for (final name in [
        'libc.so.6',
        'ld-linux-x86-64.so.2',
        'libdl.so.2',
        'libpthread.so.0',
        'libm.so.6',
        'libgcc_s.so.1',
      ]) ...['--ro-bind', '${runtime.path}/$name', '/lib64/$name'],
      '--proc',
      '/proc',
      '--dev',
      '/dev',
      '--tmpfs',
      '/tmp',
      '--chdir',
      '/tmp',
      '/runtime/worker',
    ];
    final Process process;
    try {
      process = await Process.start('${runtime.path}/ld-linux-x86-64.so.2', [
        '--library-path',
        runtime.path,
        '${runtime.path}/transport',
        systemdRun,
        ...arguments,
      ]);
    } on Object {
      _owned = false;
      throw const LinuxPdfIsolationUnavailable();
    }
    final interrupted = Completer<void>();
    final ready = Completer<void>();
    Object? failure;
    void reject(Object error) {
      failure ??= error;
      if (!interrupted.isCompleted) interrupted.complete();
    }

    final frames = LinuxPdfFrames(
      width: width,
      height: height,
      render: render,
      extraction: extraction,
      onReady: () {
        if (!ready.isCompleted) ready.complete();
      },
    );
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final out = process.stdout.listen(
      (bytes) {
        if (failure != null) return;
        try {
          frames.add(bytes);
        } on Object catch (error) {
          reject(error);
        }
      },
      onError: reject,
      onDone: outDone.complete,
    );
    var diagnosticBytes = 0;
    final err = process.stderr.listen(
      (bytes) {
        diagnosticBytes += bytes.length;
        if (diagnosticBytes > 4096)
          reject(const FormatException('diagnostic limit'));
      },
      onError: reject,
      onDone: errDone.complete,
    );
    // Attach immediately: IOSink failures can precede an awaited flush/close.
    final inputDone = process.stdin.done.then<void>(
      (_) {},
      onError: (Object error) {
        reject(error);
      },
    );
    final exited = process.exitCode;
    void cancel(String? _) => reject(const FormatException('cancelled'));
    token.addListener(cancel);
    final watchdog = Timer(
      timeout + const Duration(seconds: 2),
      () => reject(const FormatException('timeout')),
    );
    var transmitted = false;
    String? observedGroup;
    var isolationVerified = false;
    Future<void>? writer;
    try {
      await Future.any([ready.future, interrupted.future, exited]);
      if (!ready.isCompleted || failure != null)
        throw const FormatException('readiness');
      final properties = await _properties(unit);
      observedGroup = properties['ControlGroup'];
      if (observedGroup == null ||
          !observedGroup.startsWith('/') ||
          observedGroup.contains('..')) {
        throw const FormatException('isolation cgroup');
      }
      for (final entry in {
        'memory.max': '1073741824',
        'memory.swap.max': '0',
        'pids.max': '32',
      }.entries) {
        final actual = await File('/sys/fs/cgroup$observedGroup/${entry.key}')
            .readAsString();
        if (actual.trim() != entry.value)
          throw const FormatException('isolation limits');
      }
      isolationVerified = true;
      if (failure != null || token.isCancelled)
        throw const FormatException('cancelled');
      final request = utf8.encode(
        jsonEncode({
          'version': 1,
          'id': 1,
          'operation': render ? 'render' : 'inspect',
          'page': page,
          'width': width,
          'height': height,
          if (extraction != null) ...extraction.toProtocol(),
        }),
      );
      Future<void> transmit() async {
        try {
          for (final bytes in [request, source]) {
            final header = ByteData(4)..setUint32(0, bytes.length);
            process.stdin.add(header.buffer.asUint8List());
            await process.stdin.flush();
            for (var offset = 0; offset < bytes.length; offset += 65536) {
              if (failure != null || token.isCancelled)
                throw const FormatException('cancelled');
              final end = min(bytes.length, offset + 65536);
              // Exactly one bounded bridge chunk, never a second full source.
              process.stdin.add(bytes.sublist(offset, end));
              await process.stdin.flush();
            }
          }
          await process.stdin.close();
          await inputDone;
          if (failure == null) transmitted = true;
        } on Object catch (error) {
          reject(error);
        }
      }

      writer = transmit();
      final completed = Future.wait([
        writer,
        exited,
        outDone.future,
        errDone.future,
      ]);
      await Future.any([completed, interrupted.future]);
      if (failure != null || token.isCancelled || !transmitted) {
        throw const FormatException('incomplete request');
      }
      if (await exited != 0) throw const FormatException('worker exit');
      frames.finish();
    } on Object catch (error) {
      reject(error);
    } finally {
      if (failure != null || token.isCancelled) frames.discard();
      watchdog.cancel();
      token.removeListener(cancel);
      // First request a cgroup-wide kill. A nonzero kill can mean the service
      // already exited, so only the independently checked state proves cleanup.
      Future<bool> confirm() async {
        try {
          try {
            await _control(['--user', 'kill', '--signal=KILL', unit]);
          } on Object {
            // Continue to the independent state query; never infer success.
          }
          final properties = await _properties(unit);
          if (!['inactive', 'failed'].contains(properties['ActiveState'])) {
            return false;
          }
          for (final group in {observedGroup, properties['ControlGroup']}) {
            if (group == null || group.isEmpty) continue;
            if (!group.startsWith('/') || group.contains('..')) return false;
            final directory = Directory('/sys/fs/cgroup$group');
            if (directory.existsSync()) {
              // populated covers nested cgroups, unlike cgroup.procs alone.
              final events = await File('${directory.path}/cgroup.events')
                  .readAsString();
              if (!events.split('\n').contains('populated 0')) return false;
            }
          }
          return true;
        } on Object {
          return false;
        }
      }

      var confirmed = await confirm();
      if (!confirmed) {
        reject(
          const FormatException('backend unavailable: cleanup unconfirmed'),
        );
        frames.discard();
        _cleanupUnconfirmed = true;
        reportLinuxPdfCleanupState(true);
        // Escalate the concrete launcher too, but keep the service ownership.
        process.kill(ProcessSignal.sigkill);
      }
      // The future and its private runtime remain owned. The UI isolate remains
      // responsive, and the outer guard retains only its latest pending render.
      // One bounded controller attempt at a time; no accumulating retry queue.
      while (!confirmed) {
        await Future<void>.delayed(const Duration(seconds: 1));
        confirmed = await confirm();
      }
      var reaped = false;
      while (!reaped) {
        try {
          await exited.timeout(const Duration(seconds: 3));
          reaped = true;
        } on TimeoutException {
          _cleanupUnconfirmed = true;
          reportLinuxPdfCleanupState(true);
          reject(const FormatException('launcher reap unconfirmed'));
          process.kill(ProcessSignal.sigkill);
        }
      }
      await out.cancel();
      await err.cancel();
      try {
        await process.stdin.close().timeout(const Duration(seconds: 3));
      } on Object {
        reject(const FormatException('input close'));
      }
      if (writer != null) {
        try {
          await writer.timeout(const Duration(seconds: 3));
        } on Object {
          reject(const FormatException('input completion'));
        }
      }
      try {
        await _control(['--user', 'reset-failed', unit]);
      } on Object {
        // Already confirmed inactive/empty and reaped. Reset is housekeeping.
      }
      _cleanupUnconfirmed = false;
      reportLinuxPdfCleanupState(false);
      _owned = false;
    }
    if (failure != null || token.isCancelled || !transmitted) {
      frames.frames.clear();
      if (!isolationVerified) throw const LinuxPdfIsolationUnavailable();
      throw const FormatException('isolated PDF operation rejected');
    }
    final rejection = frames.rejection;
    if (rejection != null) {
      frames.discard();
      throw LinuxPdfRejected(rejection);
    }
    return frames.frames;
  }

  Future<Map<String, String>> _properties(String unit) async {
    final text = await _control([
      '--user',
      'show',
      unit,
      '-p',
      'ActiveState',
      '-p',
      'ControlGroup',
    ]);
    return {
      for (final line in text.split('\n'))
        if (line.contains('='))
          line.substring(0, line.indexOf('=')): line.substring(
            line.indexOf('=') + 1,
          ),
    };
  }

  Future<String> _control(List<String> arguments) async {
    final process = await Process.start(systemctl, arguments);
    final bytes = BytesBuilder(copy: false);
    var count = 0;
    Object? streamFailure;
    void fail(Object error) {
      streamFailure = error;
      process.kill(ProcessSignal.sigkill);
    }

    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final out = process.stdout.listen(
      (chunk) {
        count += chunk.length;
        if (count <= 8192) {
          bytes.add(chunk);
        } else {
          process.kill(ProcessSignal.sigkill);
        }
      },
      onError: fail,
      onDone: outDone.complete,
    );
    final err = process.stderr.listen(
      (chunk) {
        count += chunk.length;
        if (count > 8192) process.kill(ProcessSignal.sigkill);
      },
      onError: fail,
      onDone: errDone.complete,
    );
    try {
      await process.stdin.close();
      final status = await process.exitCode.timeout(const Duration(seconds: 3));
      if (status != 0) throw const FormatException('controller failure');
      await Future.wait([outDone.future, errDone.future])
          .timeout(const Duration(seconds: 3));
      if (count > 8192 || streamFailure != null) {
        throw const FormatException('controller output');
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 3));
      await out.cancel();
      await err.cancel();
    }
  }
}
