// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/byte_sequence_random_source.dart';

void main() {
  group('NamespacedIdentifier', () {
    test('parses valid lowercase ASCII namespaces', () {
      final result = NamespacedIdentifier.parse('al_note.document-1');

      expect(
        (result as Ok<NamespacedIdentifier, StructuredFailure>).value.value,
        'al_note.document-1',
      );
    });

    test('accepts the maximum length', () {
      final source = 'a.${List<String>.filled(253, 'b').join()}';

      expect(source.length, 255);
      expect(
        NamespacedIdentifier.parse(source),
        isA<Ok<NamespacedIdentifier, StructuredFailure>>(),
      );
    });

    test('rejects invalid forms', () {
      final invalidValues = <String>[
        'single',
        'Upper.case',
        'white space.value',
        ' leading.value',
        'a..b',
        '.a.b',
        'a.b.',
        '1a.valid',
        'a.1b',
        'a.b/c',
        'a.${List<String>.filled(254, 'b').join()}',
      ];

      for (final value in invalidValues) {
        expect(
          NamespacedIdentifier.parse(value),
          isA<Err<NamespacedIdentifier, StructuredFailure>>(),
          reason: value,
        );
      }
    });

    test('has value equality and hashing', () {
      final first =
          (NamespacedIdentifier.parse('al.note')
                  as Ok<NamespacedIdentifier, StructuredFailure>)
              .value;
      final second =
          (NamespacedIdentifier.parse('al.note')
                  as Ok<NamespacedIdentifier, StructuredFailure>)
              .value;

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(<NamespacedIdentifier>{first, second}, hasLength(1));
    });
  });

  group('UuidIdentifier', () {
    test('normalizes canonical hexadecimal case', () {
      final result = UuidIdentifier.parse(
        'A987FBC9-4BED-4078-8F07-9141BA07C9F3',
      );

      expect(
        (result as Ok<UuidIdentifier, StructuredFailure>).value.value,
        'a987fbc9-4bed-4078-8f07-9141ba07c9f3',
      );
    });

    test('rejects malformed, nil, and max UUIDs', () {
      final invalidValues = <String>[
        'a987fbc94bed40788f079141ba07c9f3',
        'a987fbc9-4bed-4078-8f07-9141ba07c9fg',
        '00000000-0000-0000-0000-000000000000',
        'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
      ];

      for (final value in invalidValues) {
        expect(
          UuidIdentifier.parse(value),
          isA<Err<UuidIdentifier, StructuredFailure>>(),
          reason: value,
        );
      }
    });

    test('has value equality and hashing', () {
      final lower =
          (UuidIdentifier.parse('a987fbc9-4bed-4078-8f07-9141ba07c9f3')
                  as Ok<UuidIdentifier, StructuredFailure>)
              .value;
      final upper =
          (UuidIdentifier.parse('A987FBC9-4BED-4078-8F07-9141BA07C9F3')
                  as Ok<UuidIdentifier, StructuredFailure>)
              .value;

      expect(lower, upper);
      expect(lower.hashCode, upper.hashCode);
      expect(<UuidIdentifier>{lower, upper}, hasLength(1));
    });
  });

  group('Rfc9562UuidV4Generator', () {
    test('uses deterministic bytes and sets version and variant bits', () {
      final source = ByteSequenceRandomSource.fromBytes(<List<int>>[
        List<int>.generate(16, (index) => index),
      ]);
      final generator = Rfc9562UuidV4Generator(source);

      final result = generator.generateV4();
      final uuid = (result as Ok<UuidIdentifier, StructuredFailure>).value;

      expect(uuid.value, '00010203-0405-4607-8809-0a0b0c0d0e0f');
      expect(uuid.value[14], '4');
      expect(<String>{'8', '9', 'a', 'b'}, contains(uuid.value[19]));
      expect(source.remaining, 0);
    });

    test('preserves random source failures', () {
      final failure = StructuredFailure(
        code: 'test.random.injected_failure',
        category: FailureCategory.platform,
        retryDisposition: RetryDisposition.retryable,
        message: 'Injected failure.',
      );
      final source = ByteSequenceRandomSource(
        <Result<List<int>, StructuredFailure>>[
          Err<List<int>, StructuredFailure>(failure),
        ],
      );
      final generator = Rfc9562UuidV4Generator(source);

      final result = generator.generateV4();

      expect(
        (result as Err<UuidIdentifier, StructuredFailure>).error,
        same(failure),
      );
    });
  });
}
