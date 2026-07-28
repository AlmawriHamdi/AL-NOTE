// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/files/src/bounded_json.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase4_test_support.dart';

void main() {
  group('bounded canonical JSON', () {
    test('sorts keys, preserves arrays, and distinguishes numeric forms', () {
      final codec = _json();
      final value = PreservedMap(<String, PreservedData>{
        'z': PreservedList(<PreservedData>[
          _integer(1),
          _double(1),
          const PreservedString('é'),
        ]),
        'a': const PreservedBoolean(true),
      });

      final bytes =
          (codec.encode(value) as Ok<List<int>, StructuredFailure>).value;

      expect(utf8.decode(bytes), '{"a":true,"z":[1,1.0,"\u00e9"]}');
      final decoded =
          (codec.decode(bytes) as Ok<PreservedData, StructuredFailure>).value;
      expect(decoded, value);
    });

    for (final source in <List<int>>[
      utf8.encode('{"a":1,"a":2}'),
      <int>[0xc3, 0x28],
      utf8.encode('"\\uD800"'),
      utf8.encode('"\\uDC00"'),
      utf8.encode('9007199254740992'),
      utf8.encode('1e999'),
      utf8.encode('true false'),
      <int>[0xef, 0xbb, 0xbf, 0x6e, 0x75, 0x6c, 0x6c],
    ]) {
      test('rejects malformed or unsafe input deterministically', () {
        final result = _json().decode(source);
        expect(result, isA<Err<PreservedData, StructuredFailure>>());
        expect(
          result.toString(),
          isNot(contains(utf8.decode(source, allowMalformed: true))),
        );
      });
    }

    test('enforces byte, depth, value, and string ceilings', () {
      BoundedJsonCodec codec({
        int bytes = 100,
        int depth = 10,
        int values = 10,
        int strings = 10,
      }) => BoundedJsonCodec(
        maximumBytes: bytes,
        maximumDepth: depth,
        maximumValues: values,
        maximumStringCodeUnits: strings,
      );

      expect(
        codec(bytes: 1).decode(utf8.encode('null')),
        isA<Err<PreservedData, StructuredFailure>>(),
      );
      expect(
        codec(depth: 1).decode(utf8.encode('[[null]]')),
        isA<Err<PreservedData, StructuredFailure>>(),
      );
      expect(
        codec(values: 2).decode(utf8.encode('[1,2]')),
        isA<Err<PreservedData, StructuredFailure>>(),
      );
      expect(
        codec(strings: 2).decode(utf8.encode('"abc"')),
        isA<Err<PreservedData, StructuredFailure>>(),
      );
      expect(
        codec(bytes: 3).encode(const PreservedString('long')),
        isA<Err<List<int>, StructuredFailure>>(),
      );
      expect(
        codec().decode(<int>[256]),
        isA<Err<PreservedData, StructuredFailure>>(),
      );
    });

    test('preserves Unicode and structural unknown data canonically', () {
      final source = utf8.encode('{"unknown":{"emoji":"📚","n":2.0}}');
      final decoded =
          (_json().decode(source) as Ok<PreservedData, StructuredFailure>)
              .value;
      final encoded =
          (_json().encode(decoded) as Ok<List<int>, StructuredFailure>).value;
      expect(
        _json().decode(encoded),
        Ok<PreservedData, StructuredFailure>(decoded),
      );
    });
  });

  group('resource integrity values', () {
    test('calculates and parses exact lowercase SHA-256', () {
      final digest =
          (Sha256Digest.calculate(utf8.encode('abc'))
                  as Ok<Sha256Digest, StructuredFailure>)
              .value;
      expect(
        digest.hexadecimal,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        Sha256Digest.parse(digest.hexadecimal),
        Ok<Sha256Digest, StructuredFailure>(digest),
      );
      expect(
        Sha256Digest.parse(digest.hexadecimal.toUpperCase()),
        isA<Err<Sha256Digest, StructuredFailure>>(),
      );
      expect(
        Sha256Digest.fromBytes(List<int>.filled(31, 0)),
        isA<Err<Sha256Digest, StructuredFailure>>(),
      );
    });

    test('captures immutable bytes and derives the digest path', () {
      final source = <int>[1, 2, 3];
      final resource =
          (DocumentResource.capture(
                    identity: ResourceIdentity.fromUuid(testUuid(70)),
                    mediaType: _media('image/png'),
                    role: _role('alnote.resource.image'),
                    schemaVersion: testSchemaVersion,
                    bytes: source,
                  )
                  as Ok<DocumentResource, StructuredFailure>)
              .value;
      source[0] = 9;

      expect(resource.bytes, <int>[1, 2, 3]);
      expect(resource.bytes.clear, throwsUnsupportedError);
      expect(
        resource.packagePath,
        'resources/${resource.digest.hexadecimal.substring(0, 2)}/${resource.digest.hexadecimal}',
      );
    });

    test('rejects size, hash, and path mismatches', () {
      final bytes = <int>[1, 2, 3];
      final digest =
          (Sha256Digest.calculate(bytes) as Ok<Sha256Digest, StructuredFailure>)
              .value;
      Result<DocumentResource, StructuredFailure> create({
        int length = 3,
        Sha256Digest? declared,
        String? path,
      }) => DocumentResource.create(
        identity: ResourceIdentity.fromUuid(testUuid(71)),
        digest: declared ?? digest,
        decodedByteLength: length,
        mediaType: _media('image/png'),
        role: _role('alnote.resource.image'),
        schemaVersion: testSchemaVersion,
        packagePath:
            path ??
            'resources/${digest.hexadecimal.substring(0, 2)}/${digest.hexadecimal}',
        bytes: bytes,
      );

      expect(
        create(length: 4),
        isA<Err<DocumentResource, StructuredFailure>>(),
      );
      expect(
        create(
          declared:
              (Sha256Digest.calculate(<int>[4])
                      as Ok<Sha256Digest, StructuredFailure>)
                  .value,
        ),
        isA<Err<DocumentResource, StructuredFailure>>(),
      );
      expect(
        create(path: 'resources/00/${digest.hexadecimal}'),
        isA<Err<DocumentResource, StructuredFailure>>(),
      );
    });

    test('validates media types and namespaced roles', () {
      expect(
        ResourceMediaType.parse('image/png'),
        isA<Ok<ResourceMediaType, StructuredFailure>>(),
      );
      expect(
        ResourceMediaType.parse('Image/PNG'),
        isA<Err<ResourceMediaType, StructuredFailure>>(),
      );
      expect(
        ResourceMediaType.parse('image/png; x=y'),
        isA<Err<ResourceMediaType, StructuredFailure>>(),
      );
      expect(
        ResourceRole.parse('alnote.resource.image'),
        isA<Ok<ResourceRole, StructuredFailure>>(),
      );
      expect(
        ResourceRole.parse('image'),
        isA<Err<ResourceRole, StructuredFailure>>(),
      );
    });

    test('invalid byte inputs fail structurally without disclosure', () {
      const secret = 'hostile-byte-secret';
      final throwing = _ThrowingBytes(secret);
      for (final result in <Object>[
        Sha256Digest.calculate(<int>[-1]),
        Sha256Digest.fromBytes(<int>[...List<int>.filled(31, 0), 256]),
        Sha256Digest.calculate(throwing),
        DocumentResource.capture(
          identity: ResourceIdentity.fromUuid(testUuid(72)),
          mediaType: _media('image/png'),
          role: _role('alnote.resource.image'),
          schemaVersion: testSchemaVersion,
          bytes: <int>[256],
        ),
      ]) {
        expect(result, isA<Err<Object, StructuredFailure>>());
        expect(result.toString(), isNot(contains(secret)));
      }
      final digest =
          (Sha256Digest.calculate(<int>[1])
                  as Ok<Sha256Digest, StructuredFailure>)
              .value;
      expect(digest.toString(), 'Sha256Digest(redacted)');
      expect(digest.toString(), isNot(contains(digest.hexadecimal)));
    });
  });

  group('storage boundaries', () {
    test('requires every explicit policy key with the correct unit', () {
      expect(
        AlnoteStorageLimits.fromSnapshot(phase4Limits()),
        isA<Ok<AlnoteStorageLimits, StructuredFailure>>(),
      );
      final empty =
          (ResourceLimitSnapshot.create(const [])
                  as Ok<ResourceLimitSnapshot, StructuredFailure>)
              .value;
      final failure =
          AlnoteStorageLimits.fromSnapshot(empty)
              as Err<AlnoteStorageLimits, StructuredFailure>;
      expect(failure.error.code, startsWith('documents.storage.'));
      expect(failure.toString(), isNot(contains('sensitive payload')));
    });

    test('affine storage bridge round-trips exact coefficients', () {
      final coefficients = <double>[1.25, 0.125, -0.25, 2.0, 3.5, -4.75];
      final transform =
          (AffineTransform2D.restoreFromStorage(coefficients)
                  as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      expect(transform.storageCoefficients, coefficients);
      expect(
        AffineTransform2D.restoreFromStorage(transform.storageCoefficients),
        Ok<AffineTransform2D, StructuredFailure>(transform),
      );
      expect(transform.storageCoefficients.clear, throwsUnsupportedError);
    });

    for (final invalid in <List<double>>[
      <double>[1, 0, 0, -1, 0, 0],
      <double>[1, 0, 0, 0, 0, 0],
      <double>[double.nan, 0, 0, 1, 0, 0],
      <double>[1, 1, 1, 1 + 1e-12, 0, 0],
      <double>[1, 0, 0, 1, 0],
    ]) {
      test('affine storage bridge rejects invalid persisted values', () {
        expect(
          AffineTransform2D.restoreFromStorage(invalid),
          isA<Err<AffineTransform2D, StructuredFailure>>(),
        );
      });
    }
  });
}

BoundedJsonCodec _json() => const BoundedJsonCodec(
  maximumBytes: 10000,
  maximumDepth: 32,
  maximumValues: 1000,
  maximumStringCodeUnits: 1000,
);

PreservedInteger _integer(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;

PreservedDouble _double(double value) =>
    (PreservedDouble.create(value) as Ok<PreservedDouble, StructuredFailure>)
        .value;

ResourceMediaType _media(String value) =>
    (ResourceMediaType.parse(value) as Ok<ResourceMediaType, StructuredFailure>)
        .value;

ResourceRole _role(String value) =>
    (ResourceRole.parse(value) as Ok<ResourceRole, StructuredFailure>).value;

final class _ThrowingBytes extends Iterable<int> {
  _ThrowingBytes(this.secret);
  final String secret;

  @override
  Iterator<int> get iterator => throw StateError(secret);
}
