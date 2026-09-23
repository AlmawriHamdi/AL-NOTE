// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:isolate';

import '../../../../core/outcomes/cancellation.dart';

/// Cancellation is cooperative: never kill an isolate that owns a runtime or
/// worker. Exit transfers the result without copying its large typed buffers.
Future<T> runLinuxPdfTask<T>(
  Future<T> Function(CancellationToken) task,
  CancellationToken token, {
  void Function(bool)? onCleanupState,
}) async {
  final messages = ReceivePort();
  final result = Completer<T>();
  SendPort? commands;
  void cancel(String? _) => commands?.send(null);
  token.addListener(cancel);
  final subscription = messages.listen((dynamic message) {
    if (message is Map && message['cleanup'] is bool) {
      onCleanupState?.call(message['cleanup'] as bool);
    } else if (message is SendPort) {
      commands = message;
      if (token.isCancelled) commands!.send(null);
    } else if (message is List && message.length == 2 && message[0] == true) {
      result.complete(message[1] as T);
    } else if (!result.isCompleted) {
      result.completeError(
        const FormatException('isolated preparation failed'),
      );
    }
  });
  try {
    await Isolate.spawn(
      _execute<T>,
      (messages.sendPort, task),
      onError: messages.sendPort,
      onExit: messages.sendPort,
    );
    return await result.future;
  } finally {
    token.removeListener(cancel);
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _execute<T>(
  (SendPort, Future<T> Function(CancellationToken)) input,
) async {
  _ownerMessages = input.$1;
  final commands = ReceivePort();
  final cancellation = CancellationController();
  commands.listen((_) => cancellation.cancel());
  input.$1.send(commands.sendPort);
  try {
    final result = await input.$2(cancellation.token);
    commands.close();
    Isolate.exit(input.$1, [true, result]);
  } on Object {
    commands.close();
    Isolate.exit(input.$1, [false, null]);
  }
}

SendPort? _ownerMessages;

/// Carries lifecycle evidence only; selected bytes cannot send these messages.
void reportLinuxPdfCleanupState(bool unconfirmed) =>
    _ownerMessages?.send({'cleanup': unconfirmed});
