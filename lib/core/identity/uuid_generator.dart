// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import '../random/random_source.dart';
import 'src/uuid_v4_adapter.dart';
import 'uuid_identifier.dart';

/// Generates UUID identifiers without exposing package-owned types.
abstract interface class UuidGenerator {
  /// Generates an RFC 9562 version 4 UUID.
  Result<UuidIdentifier, StructuredFailure> generateV4();
}

/// An RFC 9562 version 4 generator backed by an AL NOTE [RandomSource].
final class Rfc9562UuidV4Generator implements UuidGenerator {
  /// Creates a generator that obtains all random bytes from [randomSource].
  const Rfc9562UuidV4Generator(this.randomSource);

  /// The AL NOTE-owned source used for every random byte.
  final RandomSource randomSource;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    final randomResult = randomSource.nextBytes(16);
    return randomResult.fold<Result<UuidIdentifier, StructuredFailure>>(
      onOk: (bytes) {
        try {
          final generated = generateUuidV4FromBytes(bytes);
          return UuidIdentifier.parse(generated);
        } on Object {
          return Err<UuidIdentifier, StructuredFailure>(
            StructuredFailure(
              code: 'core.identity.uuid_generation_failure',
              category: FailureCategory.dependency,
              retryDisposition: RetryDisposition.retryable,
              message: 'UUID version 4 generation failed.',
            ),
          );
        }
      },
      onErr: Err<UuidIdentifier, StructuredFailure>.new,
    );
  }
}
