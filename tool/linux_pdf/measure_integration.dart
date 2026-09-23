// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone AOT measurement of the app-owned resource/supervisor components.
// Explicit locally generated control only; never an application entry point.
import 'dart:convert';
import 'dart:io';
import '../../lib/core/outcomes/cancellation.dart';
import '../../lib/documents/files/src/sha256_adapter.dart';
import '../../lib/documents/pdf/src/linux/linux_pdf_resources.dart';
import '../../lib/documents/pdf/src/linux/linux_pdf_supervisor.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 && args.length != 2) {
    throw ArgumentError('optional bundle and generated fixture required');
  }
  final input = File(args.last).openSync();
  final source = input.readSync(46752);
  input.closeSync();
  final digest = calculateCapturedSha256(
    source,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  if (!const {
    'd84471e20a0e087529e6ef4ab84a24bb56dcf9b96caab28ef0eae85ef64cd7ac',
    'b030997ef3a8c05f6e3242c6c7068708089c7d14568fe2438ba93238cfea3d36',
  }.contains(digest))
    throw ArgumentError('generated control required');
  final bundle = args.length == 2
      ? Directory(args.first)
      : LinuxPdfResources.installedBundle;
  final rows = <Object>[];
  for (var i = 0; i < 8; i++) {
    final watch = Stopwatch()..start();
    final token = CancellationController().token;
    final stage = await LinuxPdfResources(bundle).stage(token);
    final staged = watch.elapsedMicroseconds;
    try {
      final result = await const LinuxPdfSupervisor().operate(
        runtime: stage,
        source: source,
        token: token,
        render: i != 0,
        page: i % 3,
        width: 500 + i * 30,
        height: 650 + i * 40,
      );
      if (result.length != (i == 0 ? 2 : 3)) throw StateError('invalid result');
    } finally {
      await stage.delete(recursive: true);
    }
    rows.add({
      'operation': i == 0 ? 'inspect' : 'render',
      'page': i % 3,
      'width': 500 + i * 30,
      'height': 650 + i * 40,
      'stage_us': staged,
      'total_us': watch.elapsedMicroseconds,
    });
  }
  stdout.writeln(jsonEncode(rows));
}
