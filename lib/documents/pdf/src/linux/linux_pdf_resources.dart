// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../../core/outcomes/cancellation.dart';
import '../../../files/src/sha256_adapter.dart';
import 'linux_pdf_isolate.dart';
import 'linux_pdf_resource_pin.dart';

/// A verified private runtime snapshot. No parser receives installation paths.
final class LinuxPdfResources {
  LinuxPdfResources(this.bundle);
  final Directory bundle;

  static Directory get installedBundle => Directory(
    '${File(Platform.resolvedExecutable).parent.path}/data/pdf_linux',
  );

  // Only pinned bytes are reused, never installation paths or parser state.
  // The cache belongs to this backend; a new backend starts without a cache.
  Map<String, Uint8List>? _verified;
  Map<String, String>? _fingerprints;

  Future<Directory> stage(CancellationToken token) async {
    final path = bundle.path;
    final verified = _verified;
    final fingerprints = _fingerprints;
    final result = await runLinuxPdfTask(
      (cancellation) => _prepare(path, verified, fingerprints, cancellation),
      token,
    );
    _verified = result.$2;
    _fingerprints = result.$3;
    final stage = Directory(result.$1);
    if (token.isCancelled) {
      await stage.delete(recursive: true);
      throw const FormatException('cancelled');
    }
    return stage;
  }

  // The backend already runs off the UI isolate and avoids a nested handoff.
  Future<Directory> stageLocally(CancellationToken token) => _stage(token);

  static Future<(String, Map<String, Uint8List>, Map<String, String>)> _prepare(
    String path,
    Map<String, Uint8List>? verified,
    Map<String, String>? fingerprints,
    CancellationToken token,
  ) async {
    final resources = LinuxPdfResources(Directory(path))
      .._verified = verified
      .._fingerprints = fingerprints;
    final stage = await resources._stage(token);
    return (stage.path, resources._verified!, resources._fingerprints!);
  }

  Future<Directory> _stage(CancellationToken token) async {
    void check() {
      if (token.isCancelled) throw const FormatException('cancelled');
    }

    check();
    final manifest = await _read(File('${bundle.path}/manifest.json'), 65536);
    if (_digest(manifest) != linuxPdfManifestSha256) {
      throw const FormatException('resource manifest');
    }
    final decoded = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
    final files = decoded['files'] as Map<String, dynamic>;
    final fingerprints = <String, String>{};
    for (final name in files.keys) {
      check();
      final file = File('${bundle.path}/$name');
      _checkFile(file);
      final stat = file.statSync();
      fingerprints[name] =
          '${stat.size}:${stat.mode}:${stat.modified}:${stat.changed}';
    }
    final reusable =
        _verified != null &&
        _fingerprints != null &&
        fingerprints.length == _fingerprints!.length &&
        fingerprints.entries.every((e) => _fingerprints![e.key] == e.value);
    if (!reusable) {
      _verified = null;
      _fingerprints = null;
    }
    final captured = <String, Uint8List>{};
    final stage = await Directory.systemTemp.createTemp('alnote-pdf-');
    try {
      // Dart's createTemp honors the process umask. Tighten the empty directory
      // before writing any executable/resource bytes into it.
      await _chmod(['700', '--', stage.path]);
      if ((stage.statSync().mode & 0x1ff) != 0x1c0) {
        throw const FormatException('private runtime permissions');
      }
      for (final entry in files.entries) {
        check();
        final name = entry.key;
        // Notices remain in the distribution and are verified as package data;
        // the sandbox gets only its fixed executable/runtime resources.
        if (!RegExp(r'^[a-zA-Z0-9_./-]+$').hasMatch(name) ||
            name.startsWith('/') ||
            name.split('/').contains('..')) {
          throw const FormatException('resource name');
        }
        final record = entry.value as Map<String, dynamic>;
        final size = record['size'];
        if (size is! int || size <= 0 || size > 32 * 1024 * 1024) {
          throw const FormatException('resource size');
        }
        Uint8List? bytes;
        if (reusable) {
          bytes = _verified![name];
        } else {
          bytes = await _read(File('${bundle.path}/$name'), size);
          final digest = (await calculateCapturedSha256Cooperatively(
            bytes,
            check,
          )).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
          if (bytes.length != size || digest != record['sha256']) {
            throw const FormatException('resource identity');
          }
        }
        check();
        if (!name.startsWith('notices/')) {
          // Await the closed write; private ephemeral executables need visibility,
          // not durable fsync of a temporary cache before every navigation.
          captured[name] = bytes!;
          await File('${stage.path}/$name').writeAsBytes(bytes);
        }
      }
      final paths = stage.listSync().map((file) => file.path).toList();
      await _chmod(['500', '--', ...paths]);
      check();
      _verified = captured;
      _fingerprints = fingerprints;
      return stage;
    } on Object {
      await stage.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _chmod(List<String> arguments) async {
    final process = await Process.start('/usr/bin/chmod', arguments);
    final out = process.stdout.drain<void>();
    final err = process.stderr.drain<void>();
    try {
      await process.stdin.close();
      if (await process.exitCode.timeout(const Duration(seconds: 3)) != 0) {
        throw const FormatException('runtime permissions');
      }
      await Future.wait([out, err]).timeout(const Duration(seconds: 3));
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 3));
    }
  }

  static String _digest(List<int> bytes) =>
      calculateCapturedSha256(bytes)
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();

  static void _checkFile(File file) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        (file.statSync().mode & 0x12) != 0) {
      throw const FormatException('resource ownership permissions');
    }
  }

  static Future<Uint8List> _read(File file, int maximum) async {
    _checkFile(file);
    final input = await file.open();
    try {
      // Open once, bounded read, hash and stage the same captured bytes.
      final bytes = await input.read(maximum + 1);
      if (bytes.isEmpty || bytes.length > maximum) {
        throw const FormatException('resource size');
      }
      return bytes;
    } finally {
      await input.close();
    }
  }
}
