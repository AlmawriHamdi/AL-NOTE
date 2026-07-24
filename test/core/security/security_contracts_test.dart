// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DataClassification', () {
    test('contains exactly the approved classifications', () {
      expect(
        DataClassification.values.map((classification) => classification.label),
        <String>[
          'Public',
          'Internal',
          'Sensitive Content',
          'Derived Sensitive',
          'Temporary Sensitive',
          'Secret',
          'Security Audit',
          'Untrusted Plugin Metadata',
          'Anonymous Operational Metrics',
        ],
      );
      expect(DataClassification.values, hasLength(9));
    });
  });

  group('ResourceLimitKey', () {
    test('validates external key text with structured results', () {
      expect(
        ResourceLimitKey.parse('documents.expanded_bytes'),
        isA<Ok<ResourceLimitKey, StructuredFailure>>(),
      );
      for (final invalid in <String>[
        'single',
        'Documents.count',
        'documents..count',
        'documents count',
        'documents.count!',
      ]) {
        expect(
          ResourceLimitKey.parse(invalid),
          isA<Err<ResourceLimitKey, StructuredFailure>>(),
          reason: invalid,
        );
      }
    });

    test('has immutable value equality and hashing', () {
      final first = _key('documents.count');
      final second = _key('documents.count');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(<ResourceLimitKey>{first, second}, hasLength(1));
    });
  });

  group('ResourceLimitCeiling', () {
    test('requires a nonnegative external value with an explicit unit', () {
      final zero = ResourceLimitCeiling.create(
        value: 0,
        unit: ResourceLimitUnit.count,
      );
      final invalid = ResourceLimitCeiling.create(
        value: -1,
        unit: ResourceLimitUnit.bytes,
      );

      expect(
        (zero as Ok<ResourceLimitCeiling, StructuredFailure>).value,
        _ceiling(0, ResourceLimitUnit.count),
      );
      expect(invalid, isA<Err<ResourceLimitCeiling, StructuredFailure>>());
    });
  });

  group('ResourceLimitSnapshot', () {
    test('defensively copies input and exposes no mutable collection', () {
      final entries = <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[
        (
          key: _key('documents.count'),
          ceiling: _ceiling(100, ResourceLimitUnit.count),
        ),
      ];
      final snapshot = _snapshot(entries);

      entries.clear();

      expect(snapshot.ceilings, hasLength(1));
      expect(() => snapshot.ceilings.clear(), throwsUnsupportedError);
    });

    test('permits an empty caller-supplied snapshot without defaults', () {
      final snapshot = _snapshot(
        <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[],
      );

      expect(snapshot.ceilings, isEmpty);
    });

    test('rejects duplicate initial keys', () {
      final key = _key('documents.count');

      final result = ResourceLimitSnapshot.create([
        (key: key, ceiling: _ceiling(100, ResourceLimitUnit.count)),
        (key: key, ceiling: _ceiling(50, ResourceLimitUnit.count)),
      ]);

      expect(result, isA<Err<ResourceLimitSnapshot, StructuredFailure>>());
    });

    test('atomically tightens existing keys with matching units', () {
      final countKey = _key('documents.count');
      final bytesKey = _key('documents.expanded_bytes');
      final original = _snapshot([
        (key: countKey, ceiling: _ceiling(100, ResourceLimitUnit.count)),
        (key: bytesKey, ceiling: _ceiling(1000, ResourceLimitUnit.bytes)),
      ]);

      final result = original.tighten([
        (key: bytesKey, ceiling: _ceiling(800, ResourceLimitUnit.bytes)),
        (key: countKey, ceiling: _ceiling(80, ResourceLimitUnit.count)),
      ]);
      final tightened =
          (result as Ok<ResourceLimitSnapshot, StructuredFailure>).value;

      expect(tightened.ceilingFor(countKey)?.value, 80);
      expect(tightened.ceilingFor(bytesKey)?.value, 800);
      expect(original.ceilingFor(countKey)?.value, 100);
      expect(original.ceilingFor(bytesKey)?.value, 1000);
    });

    test('rejects unknown keys without changing the snapshot', () {
      final key = _key('documents.count');
      final original = _snapshot([
        (key: key, ceiling: _ceiling(100, ResourceLimitUnit.count)),
      ]);

      final result = original.tighten([
        (
          key: _key('documents.layers'),
          ceiling: _ceiling(10, ResourceLimitUnit.count),
        ),
      ]);

      expect(result, isA<Err<ResourceLimitSnapshot, StructuredFailure>>());
      expect(original.ceilingFor(key)?.value, 100);
      expect(original.ceilings, hasLength(1));
    });

    test('rejects unit changes without changing the snapshot', () {
      final key = _key('documents.expanded_bytes');
      final original = _snapshot([
        (key: key, ceiling: _ceiling(1000, ResourceLimitUnit.bytes)),
      ]);

      final result = original.tighten([
        (key: key, ceiling: _ceiling(500, ResourceLimitUnit.count)),
      ]);

      final failure =
          (result as Err<ResourceLimitSnapshot, StructuredFailure>).error;
      expect(failure.code, 'core.security.resource_limit_unit_mismatch');
      expect(original.ceilingFor(key)?.unit, ResourceLimitUnit.bytes);
      expect(original.ceilingFor(key)?.value, 1000);
    });

    test('rejects raised ceilings without changing the snapshot', () {
      final key = _key('documents.count');
      final original = _snapshot([
        (key: key, ceiling: _ceiling(100, ResourceLimitUnit.count)),
      ]);

      final result = original.tighten([
        (key: key, ceiling: _ceiling(101, ResourceLimitUnit.count)),
      ]);

      final failure =
          (result as Err<ResourceLimitSnapshot, StructuredFailure>).error;
      expect(failure.code, 'core.security.resource_limit_raise_rejected');
      expect(original.ceilingFor(key)?.value, 100);
    });

    test('rejects duplicate ambiguous updates atomically', () {
      final key = _key('documents.count');
      final original = _snapshot([
        (key: key, ceiling: _ceiling(100, ResourceLimitUnit.count)),
      ]);

      final result = original.tighten([
        (key: key, ceiling: _ceiling(90, ResourceLimitUnit.count)),
        (key: key, ceiling: _ceiling(80, ResourceLimitUnit.count)),
      ]);

      final failure =
          (result as Err<ResourceLimitSnapshot, StructuredFailure>).error;
      expect(failure.code, 'core.security.ambiguous_resource_limit_update');
      expect(original.ceilingFor(key)?.value, 100);
    });

    test('a later failed update does not apply an earlier valid update', () {
      final countKey = _key('documents.count');
      final bytesKey = _key('documents.expanded_bytes');
      final original = _snapshot([
        (key: countKey, ceiling: _ceiling(100, ResourceLimitUnit.count)),
        (key: bytesKey, ceiling: _ceiling(1000, ResourceLimitUnit.bytes)),
      ]);

      final result = original.tighten([
        (key: countKey, ceiling: _ceiling(80, ResourceLimitUnit.count)),
        (key: bytesKey, ceiling: _ceiling(1200, ResourceLimitUnit.bytes)),
      ]);

      expect(result, isA<Err<ResourceLimitSnapshot, StructuredFailure>>());
      expect(original.ceilingFor(countKey)?.value, 100);
      expect(original.ceilingFor(bytesKey)?.value, 1000);
    });
  });
}

ResourceLimitKey _key(String value) =>
    (ResourceLimitKey.parse(value) as Ok<ResourceLimitKey, StructuredFailure>)
        .value;

ResourceLimitCeiling _ceiling(int value, ResourceLimitUnit unit) =>
    (ResourceLimitCeiling.create(value: value, unit: unit)
            as Ok<ResourceLimitCeiling, StructuredFailure>)
        .value;

ResourceLimitSnapshot _snapshot(
  Iterable<({ResourceLimitKey key, ResourceLimitCeiling ceiling})> entries,
) =>
    (ResourceLimitSnapshot.create(entries)
            as Ok<ResourceLimitSnapshot, StructuredFailure>)
        .value;
