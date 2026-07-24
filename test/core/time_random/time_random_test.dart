// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/byte_sequence_random_source.dart';
import '../../support/controllable_clock.dart';
import '../../support/uuid_sequence_generator.dart';

void main() {
  group('Clock', () {
    test('SDK clock returns UTC', () {
      const clock = SdkClock();

      expect(clock.nowUtc().isUtc, isTrue);
    });

    test('controllable clock normalizes, advances, and sets UTC time', () {
      final clock = ControllableClock(
        DateTime.parse('2026-07-24T10:00:00-04:00'),
      );

      expect(clock.nowUtc(), DateTime.utc(2026, 7, 24, 14));
      clock.advance(const Duration(minutes: 15));
      expect(clock.nowUtc(), DateTime.utc(2026, 7, 24, 14, 15));
      clock.setTime(DateTime.parse('2026-07-25T01:30:00+02:00'));
      expect(clock.nowUtc(), DateTime.utc(2026, 7, 24, 23, 30));
      expect(clock.nowUtc().isUtc, isTrue);
    });
  });

  group('RandomSource', () {
    test('SDK source rejects negative lengths with a structured result', () {
      const source = SdkSecureRandomSource();

      final result = source.nextBytes(-1);
      final failure = (result as Err<List<int>, StructuredFailure>).error;

      expect(failure.code, 'core.random.invalid_length');
      expect(failure.category, FailureCategory.validation);
    });

    test('SDK source returns the requested number of byte values', () {
      const source = SdkSecureRandomSource();

      final empty =
          (source.nextBytes(0) as Ok<List<int>, StructuredFailure>).value;
      final bytes =
          (source.nextBytes(32) as Ok<List<int>, StructuredFailure>).value;

      expect(empty, isEmpty);
      expect(bytes, hasLength(32));
      expect(bytes.every((value) => value >= 0 && value <= 255), isTrue);
    });

    test('byte-sequence source is ordered and deterministic', () {
      final source = ByteSequenceRandomSource.fromBytes(<List<int>>[
        <int>[1, 2],
        <int>[3, 4],
      ]);

      expect(
        (source.nextBytes(2) as Ok<List<int>, StructuredFailure>).value,
        <int>[1, 2],
      );
      expect(
        (source.nextBytes(2) as Ok<List<int>, StructuredFailure>).value,
        <int>[3, 4],
      );
      expect(source.remaining, 0);
    });

    test('byte-sequence source exposes deterministic failures', () {
      final failure = StructuredFailure(
        code: 'test.random.expected_failure',
        category: FailureCategory.platform,
        retryDisposition: RetryDisposition.retryable,
        message: 'Expected.',
      );
      final source = ByteSequenceRandomSource(
        <Result<List<int>, StructuredFailure>>[
          Err<List<int>, StructuredFailure>(failure),
        ],
      );

      final result = source.nextBytes(16);

      expect(
        (result as Err<List<int>, StructuredFailure>).error,
        same(failure),
      );
    });

    test('byte-sequence source reports invalid and mismatched lengths', () {
      final source = ByteSequenceRandomSource.fromBytes(<List<int>>[
        <int>[1],
      ]);

      expect(source.nextBytes(-1), isA<Err<List<int>, StructuredFailure>>());
      expect(source.nextBytes(2), isA<Err<List<int>, StructuredFailure>>());
      expect(source.nextBytes(1), isA<Err<List<int>, StructuredFailure>>());
    });
  });

  group('UuidSequenceGenerator', () {
    test('returns UUIDs in deterministic order then reports exhaustion', () {
      final first =
          (UuidIdentifier.parse('00000000-0000-4000-8000-000000000001')
                  as Ok<UuidIdentifier, StructuredFailure>)
              .value;
      final second =
          (UuidIdentifier.parse('00000000-0000-4000-8000-000000000002')
                  as Ok<UuidIdentifier, StructuredFailure>)
              .value;
      final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
        first,
        second,
      ]);

      expect(
        (generator.generateV4() as Ok<UuidIdentifier, StructuredFailure>).value,
        first,
      );
      expect(
        (generator.generateV4() as Ok<UuidIdentifier, StructuredFailure>).value,
        second,
      );
      expect(
        generator.generateV4(),
        isA<Err<UuidIdentifier, StructuredFailure>>(),
      );
      expect(generator.remaining, 0);
    });
  });
}
