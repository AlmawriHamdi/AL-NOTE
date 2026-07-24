// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SchemaVersion', () {
    test('accepts positive values and rejects nonpositive values', () {
      expect(
        SchemaVersion.create(1),
        isA<Ok<SchemaVersion, StructuredFailure>>(),
      );
      expect(
        SchemaVersion.create(0),
        isA<Err<SchemaVersion, StructuredFailure>>(),
      );
      expect(
        SchemaVersion.create(-1),
        isA<Err<SchemaVersion, StructuredFailure>>(),
      );
    });
  });

  group('ContractVersion', () {
    test('accepts nonnegative components and rejects negative components', () {
      expect(
        ContractVersion.create(0, 0),
        isA<Ok<ContractVersion, StructuredFailure>>(),
      );
      expect(
        ContractVersion.create(-1, 0),
        isA<Err<ContractVersion, StructuredFailure>>(),
      );
      expect(
        ContractVersion.create(0, -1),
        isA<Err<ContractVersion, StructuredFailure>>(),
      );
    });

    test('requires equal majors and a sufficient provider minor', () {
      final required =
          (ContractVersion.create(2, 3)
                  as Ok<ContractVersion, StructuredFailure>)
              .value;
      final equal =
          (ContractVersion.create(2, 3)
                  as Ok<ContractVersion, StructuredFailure>)
              .value;
      final newer =
          (ContractVersion.create(2, 4)
                  as Ok<ContractVersion, StructuredFailure>)
              .value;
      final older =
          (ContractVersion.create(2, 2)
                  as Ok<ContractVersion, StructuredFailure>)
              .value;
      final differentMajor =
          (ContractVersion.create(3, 3)
                  as Ok<ContractVersion, StructuredFailure>)
              .value;

      expect(equal.isCompatibleProviderFor(required), isTrue);
      expect(newer.isCompatibleProviderFor(required), isTrue);
      expect(older.isCompatibleProviderFor(required), isFalse);
      expect(differentMajor.isCompatibleProviderFor(required), isFalse);
    });
  });

  group('Revision', () {
    test('validates the Web-safe range', () {
      expect(Revision.create(0), isA<Ok<Revision, StructuredFailure>>());
      expect(
        Revision.create(Revision.maximumValue),
        isA<Ok<Revision, StructuredFailure>>(),
      );
      expect(Revision.create(-1), isA<Err<Revision, StructuredFailure>>());
      expect(
        Revision.create(Revision.maximumValue + 1),
        isA<Err<Revision, StructuredFailure>>(),
      );
    });

    test('orders and increments revisions', () {
      final first =
          (Revision.create(4) as Ok<Revision, StructuredFailure>).value;
      final second =
          (first.increment() as Ok<Revision, StructuredFailure>).value;

      expect(first.compareTo(second), lessThan(0));
      expect(second.value, 5);
    });

    test('returns a structured overflow failure at the maximum', () {
      final maximum =
          (Revision.create(Revision.maximumValue)
                  as Ok<Revision, StructuredFailure>)
              .value;

      final result = maximum.increment();
      final failure = (result as Err<Revision, StructuredFailure>).error;

      expect(failure.code, 'core.versioning.revision_overflow');
      expect(failure.category, FailureCategory.resource);
      expect(failure.retryDisposition, RetryDisposition.never);
    });
  });

  test('schema, contract, and revision types remain distinct', () {
    final Object schema =
        (SchemaVersion.create(1) as Ok<SchemaVersion, StructuredFailure>).value;
    final Object contract =
        (ContractVersion.create(1, 0) as Ok<ContractVersion, StructuredFailure>)
            .value;
    final Object revision =
        (Revision.create(1) as Ok<Revision, StructuredFailure>).value;

    expect(schema.runtimeType, isNot(contract.runtimeType));
    expect(schema.runtimeType, isNot(revision.runtimeType));
    expect(contract.runtimeType, isNot(revision.runtimeType));
  });

  test('ContentIdentity is UUID-backed with value equality', () {
    final uuid =
        (UuidIdentifier.parse('a987fbc9-4bed-4078-8f07-9141ba07c9f3')
                as Ok<UuidIdentifier, StructuredFailure>)
            .value;

    final first = ContentIdentity(uuid);
    final second = ContentIdentity(uuid);

    expect(first.uuid, uuid);
    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
