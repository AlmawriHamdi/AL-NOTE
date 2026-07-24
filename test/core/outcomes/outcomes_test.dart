// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Result', () {
    test('maps success values with preserved error typing', () {
      const result = Ok<int, String>(4);

      final mapped = result.map<String>((value) => 'value:$value');

      expect(mapped, const Ok<String, String>('value:4'));
    });

    test('maps errors while preserving success values', () {
      const result = Err<int, String>('bad');

      final mapped = result.mapError<int>((error) => error.length);

      expect(mapped, const Err<int, int>(3));
    });

    test('fold handles both variants', () {
      const success = Ok<int, String>(5);
      const failure = Err<int, String>('failure');

      expect(
        success.fold<String>(
          onOk: (value) => 'ok:$value',
          onErr: (error) => 'err:$error',
        ),
        'ok:5',
      );
      expect(
        failure.fold<String>(
          onOk: (value) => 'ok:$value',
          onErr: (error) => 'err:$error',
        ),
        'err:failure',
      );
    });

    test('mapping success preserves the structured failure instance', () {
      final failure = StructuredFailure(
        code: 'test.outcomes.preserved',
        category: FailureCategory.state,
        retryDisposition: RetryDisposition.never,
        message: 'Preserve this failure.',
      );
      final result = Err<int, StructuredFailure>(failure);

      final mapped = result.map<String>((value) => '$value');

      expect((mapped as Err<String, StructuredFailure>).error, same(failure));
    });
  });

  group('StructuredFailure', () {
    test('accepts stable lowercase namespaced codes', () {
      final failure = StructuredFailure(
        code: 'core.random.platform_failure',
        category: FailureCategory.platform,
        retryDisposition: RetryDisposition.retryable,
        message: 'Random failed.',
      );

      expect(failure.code, 'core.random.platform_failure');
    });

    test('rejects codes that are not lowercase and namespaced', () {
      expect(
        () => StructuredFailure(
          code: 'InvalidCode',
          category: FailureCategory.unknown,
          retryDisposition: RetryDisposition.never,
          message: 'Invalid.',
        ),
        throwsArgumentError,
      );
    });
  });

  group('OperationOutcome', () {
    test('keeps completion, failure, and cancellation distinct', () {
      final failure = StructuredFailure(
        code: 'test.outcomes.failed',
        category: FailureCategory.dependency,
        retryDisposition: RetryDisposition.retryable,
        message: 'Failed.',
      );
      const completed = Completed<int, StructuredFailure>(1);
      final failed = Failed<int, StructuredFailure>(failure);
      const cancelled = Cancelled<int, StructuredFailure>('user-requested');

      expect(completed, isA<Completed<int, StructuredFailure>>());
      expect(failed, isA<Failed<int, StructuredFailure>>());
      expect(cancelled, isA<Cancelled<int, StructuredFailure>>());
      expect(failed.failure, same(failure));
      expect(
        cancelled.fold<String>(
          onCompleted: (value) => 'completed',
          onFailed: (value) => 'failed',
          onCancelled: (reason) => 'cancelled:$reason',
        ),
        'cancelled:user-requested',
      );
    });
  });

  group('CancellationController', () {
    test('is idempotent and preserves the first reason synchronously', () {
      final controller = CancellationController();
      final observed = <String?>[];
      controller.token.addListener(observed.add);

      expect(controller.cancel('first'), isTrue);
      expect(controller.cancel('second'), isFalse);

      expect(controller.token.isCancelled, isTrue);
      expect(controller.token.reason, 'first');
      expect(observed, <String?>['first']);
    });

    test('immediately informs listeners added after cancellation', () {
      final controller = CancellationController();
      expect(controller.cancel('already-cancelled'), isTrue);
      String? observed;

      controller.token.addListener((reason) {
        observed = reason;
      });

      expect(observed, 'already-cancelled');
    });

    test('removed listeners are not invoked', () {
      final controller = CancellationController();
      var calls = 0;
      void listener(String? reason) {
        calls += 1;
      }

      controller.token.addListener(listener);
      controller.token.removeListener(listener);
      controller.cancel();

      expect(calls, 0);
    });

    test('attempts later listeners before rethrowing the first exception', () {
      final controller = CancellationController();
      final firstError = StateError('listener failed');
      var laterListenerCalled = false;
      StackTrace? originalStackTrace;
      StackTrace? observedStackTrace;
      controller.token.addListener((reason) {
        try {
          throw firstError;
        } on Object catch (_, stackTrace) {
          originalStackTrace = stackTrace;
          rethrow;
        }
      });
      controller.token.addListener((reason) {
        laterListenerCalled = true;
      });

      Object? observedError;
      try {
        controller.cancel('first');
      } on Object catch (error, stackTrace) {
        observedError = error;
        observedStackTrace = stackTrace;
      }

      expect(observedError, same(firstError));
      expect(observedStackTrace.toString(), originalStackTrace.toString());
      expect(laterListenerCalled, isTrue);
      expect(controller.token.isCancelled, isTrue);
      expect(controller.token.reason, 'first');
      expect(controller.cancel('second'), isFalse);
    });

    test('reentrant cancellation loses and preserves the first reason', () {
      final controller = CancellationController();
      bool? reentrantResult;
      controller.token.addListener((reason) {
        reentrantResult = controller.cancel('reentrant');
      });

      expect(controller.cancel('first'), isTrue);

      expect(reentrantResult, isFalse);
      expect(controller.token.reason, 'first');
    });

    test(
      'listener addition and removal use cancellation snapshot semantics',
      () {
        final controller = CancellationController();
        final events = <String>[];

        void addedDuringNotification(String? reason) {
          events.add('added:$reason');
        }

        void removedDuringNotification(String? reason) {
          events.add('removed:$reason');
        }

        void firstListener(String? reason) {
          events.add('first:$reason');
          controller.token.addListener(addedDuringNotification);
          controller.token.removeListener(removedDuringNotification);
        }

        controller.token.addListener(firstListener);
        controller.token.addListener(removedDuringNotification);

        expect(controller.cancel('winning'), isTrue);
        expect(events, <String>[
          'first:winning',
          'added:winning',
          'removed:winning',
        ]);
        expect(controller.token.reason, 'winning');
      },
    );
  });
}
